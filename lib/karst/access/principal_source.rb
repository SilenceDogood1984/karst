# frozen_string_literal: true

require_relative "principal_dimension"

module Karst
  module Access
    # One allowed principal population Karst may sample from or resolve
    # into -- "which records may Karst consider at all," a different
    # question from Karst::Access::PrincipalDimension ("which observed
    # states should Karst try to cover while sampling within it").
    #
    # `records` is a callable Karst evaluates lazily, exactly like the
    # legacy `config.principals` -- never enumerated, sampled, or
    # materialized just by building a PrincipalSource. A single legacy
    # config.principals (plus any config.principal_dimensions) is normalized
    # into one implicit `:default` PrincipalSource internally (see
    # Karst::Configuration#principal_sources), so every downstream consumer
    # (PrincipalSelection, Identity.resolve, the panel) only ever has to
    # handle "one or more sources," never a separate single-source case.
    class PrincipalSource
      attr_reader :name, :records, :dimensions

      def initialize(name:, records:, dimensions: {})
        raise ArgumentError, "principal source #{name.inspect} must be callable" unless records.respond_to?(:call)

        @name = name.to_sym
        @records = records
        @dimensions = PrincipalDimension.normalize(dimensions)
      end

      # Evaluates the configured records callable. Never enumerates or
      # queries on its own -- for an Active Record source this only builds a
      # Relation, exactly like Karst::Identity.principals already did for
      # the single-source case.
      def evaluate
        records.call
      end

      # Accepts a raw Hash of name => (callable, or {records:, dimensions:})
      # -- the shape config.principal_sources= receives.
      def self.normalize(sources)
        return nil if sources.nil?
        raise ArgumentError, "principal_sources must be a Hash of name => records/{records:, dimensions:}" unless
          sources.is_a?(Hash)

        sources.each_with_object({}) do |(name, spec), normalized|
          source = spec.is_a?(PrincipalSource) ? spec : from_spec(name, spec)
          normalized[source.name] = source
        end
      end

      def self.from_spec(name, spec)
        return new(name: name, records: spec) if spec.respond_to?(:call)

        unless spec.is_a?(Hash)
          raise ArgumentError, "principal source #{name.inspect} must be callable or a Hash with :records"
        end

        new(name: name, records: fetch_any(spec, :records), dimensions: fetch_any(spec, :dimensions) || {})
      end

      def self.fetch_any(hash, key)
        hash.fetch(key) { hash[key.to_s] }
      end
      private_class_method :fetch_any
    end
  end
end
