# frozen_string_literal: true

require_relative "sensitive_attribute_names"

module Karst
  module Access
    # One coarse, non-PII observed state an application has told Karst is
    # worth deliberately representing while sampling principals -- for
    # example `role: :role` or `system_admin: :system_admin?`. This answers
    # "which observed states should Karst try to cover," a different
    # question from Karst::Access::PrincipalSource ("which records may Karst
    # consider at all").
    #
    # A dimension is sampling evidence, not an authorization claim: Karst may
    # report `role=local_admin`, and must never imply `local_admin grants
    # access` -- that would require separate, future authorization evidence.
    #
    # An accessor is one of:
    #   - a Symbol/String naming a plain attribute or a predicate method
    #     (`:role`, `:system_admin?`) -- called with #public_send;
    #   - a callable of arity 1 (`->(user) { ... }`) invoked with the record.
    #
    # Both the dimension's own name and, when it names one, the accessor are
    # rejected at construction time if either looks like a PII-shaped
    # attribute (email, name, phone, token, ...) -- see
    # SensitiveAttributeNames. A callable accessor cannot be introspected
    # this way; applications remain responsible for not wiring one to
    # read/return PII. Karst dimensions are for coarse state, not user
    # identity data.
    class PrincipalDimension
      attr_reader :name, :accessor

      def initialize(name:, accessor:)
        @name = name.to_sym
        @accessor = accessor
        validate!
      end

      def callable?
        @accessor.respond_to?(:call)
      end

      # The real column this dimension reads, only when the accessor names
      # one directly on klass, or is Rails' own auto-generated `<boolean
      # column>?` query method for one (`premium?` for a `premium` boolean
      # column returns exactly the column's value, so it is just as
      # queryable as the bare column). A method-only predicate that is *not*
      # that generated form (a computed `def system_admin?; ...; end`, or a
      # `?` method over a non-boolean column, whose value is a truthiness
      # check rather than the literal column value) returns nil here and
      # instead gets bounded in-memory evaluation over an already-fetched
      # candidate pool (see PrincipalSampler).
      def column_for(klass)
        return nil if callable?

        klass.columns_hash[@accessor.to_s] || boolean_predicate_column(klass)
      end

      def value_for(record)
        callable? ? @accessor.call(record) : record.public_send(@accessor)
      end

      def reason(record)
        "#{@name}=#{format_value(value_for(record))}"
      end

      # Booleans/nil render as `true`/`false`/`` (inspect); everything else
      # (a role string, an enum key, a plan tier) renders plainly -- so a
      # configured `role: :role` reads `role=local_admin`, not the quoted
      # `role="local_admin"` a blind #inspect would produce.
      def format_value(value)
        case value
        when true, false, nil then value.inspect
        else value.to_s
        end
      end

      # Accepts a raw Hash of name => accessor (the shape config.
      # principal_dimensions= receives) or one already built by another call
      # to .normalize, so callers never need to special-case which they hold.
      def self.normalize(dimensions)
        return {} if dimensions.nil?
        raise ArgumentError, "principal_dimensions must be a Hash of name => attribute/predicate/callable" unless
          dimensions.is_a?(Hash)

        dimensions.each_with_object({}) do |(name, accessor), normalized|
          dimension = accessor.is_a?(PrincipalDimension) ? accessor : new(name: name, accessor: accessor)
          normalized[dimension.name] = dimension
        end
      end

      private

      def boolean_predicate_column(klass)
        return nil unless @accessor.to_s.end_with?("?")

        column = klass.columns_hash[@accessor.to_s.delete_suffix("?")]
        column if column&.type == :boolean
      end

      def validate!
        validate_accessor_shape!
        validate_not_sensitive!
      end

      def validate_accessor_shape!
        return if callable? || named_accessor?

        raise ArgumentError,
              "principal dimension #{@name.inspect} must be a Symbol/String attribute or predicate, or a callable"
      end

      def validate_not_sensitive!
        raise ArgumentError, sensitive_name_message if SensitiveAttributeNames.match?(@name)
        return unless named_accessor? && SensitiveAttributeNames.match?(@accessor.to_s.delete_suffix("?"))

        raise ArgumentError, sensitive_accessor_message
      end

      def named_accessor?
        @accessor.is_a?(Symbol) || @accessor.is_a?(String)
      end

      def sensitive_name_message
        "principal dimension name #{@name.inspect} looks like a sensitive attribute and is rejected; " \
          "Karst dimensions are for coarse state, not user identity data"
      end

      def sensitive_accessor_message
        "principal dimension #{@name.inspect} reads #{@accessor.inspect}, which looks like a sensitive " \
          "attribute and is rejected; Karst dimensions are for coarse state, not user identity data"
      end
    end
  end
end
