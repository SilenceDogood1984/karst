# frozen_string_literal: true

require_relative "../value"
require_relative "sweep"
require_relative "principal_dimension"
require_relative "sensitive_attribute_names"

module Karst
  module Access
    # Selects a small candidate set without ever scanning the full principal
    # relation: one bounded recent pool, stratified in memory by whatever
    # states the application declared, with schema-derived states as a
    # best-effort fallback when it declared none.
    #
    # Application-authored *populations* deliberately do not live here. They
    # are a second search stage owned by Karst::Access::Search, which runs
    # them only after an ordinary sample observes no usable outcome -- a
    # population folded into this sample would silently become part of an
    # ordinary-looking result, and Karst could never report the stronger,
    # true story: "the ordinary sample failed; then system_admins reached
    # it." This class only selects candidates. Access::Sweep remains the
    # sole source of behavioral evidence.
    # rubocop:disable Metrics/ClassLength
    class PrincipalSampler
      class UnsupportedPrimaryKey < Error; end

      CARDINALITY_CUTOFF = 10
      MAX_DIMENSIONS = 8
      TENANCY_FK_TOKENS = %w[tenant account organization org company workspace team customer client shop].freeze
      ALLOWED_SCALAR_TYPES = %i[integer bigint string].freeze

      Candidate = Value.define(:principal, :reasons)
      Result = Value.define(:principals, :candidates, :strategy, :queries, :candidate_pool_size)
      DimensionValue = Struct.new(:reason, :matcher, keyword_init: true)
      private_constant :DimensionValue

      # Exactly one bounded recent-pool query. Every stratification decision
      # after that is made in memory over that pool.
      def self.query_budget(_limit = nil)
        1
      end

      def initialize(source:, limit: Karst.config.access_sweep_limit,
                     pool_size: Karst.config.principal_candidate_pool_size, dimensions: {})
        @source = source
        @limit = limit
        @pool_size = pool_size
        @dimensions = dimensions
        @queries = 0
        @query_budget = self.class.query_budget
      end

      def call
        relation = active_record_relation
        return fallback_sample unless relation

        representative_sample(relation)
      end

      def self.representative_capable?(source)
        return true if defined?(ActiveRecord::Relation) && source.is_a?(ActiveRecord::Relation)

        defined?(ActiveRecord::Base) && source.is_a?(Class) && source < ActiveRecord::Base
      rescue StandardError
        false
      end

      private

      def active_record_relation
        return @source if defined?(ActiveRecord::Relation) && @source.is_a?(ActiveRecord::Relation)

        @source.all if defined?(ActiveRecord::Base) && @source.is_a?(Class) && @source < ActiveRecord::Base
      end

      def fallback_sample
        principals = @source.each.lazy.take(@limit).to_a
        candidates = principals.map { |principal| Candidate.new(principal: principal, reasons: []) }
        Result.new(principals: principals, candidates: candidates, strategy: :first_n, queries: 0,
                   candidate_pool_size: nil)
      end

      # rubocop:disable Metrics/MethodLength
      def representative_sample(relation)
        klass = relation.klass
        primary_key = single_primary_key!(klass)
        pool = recent_pool(relation, klass, primary_key)
        selected = {}

        dimensions = configured_dimensions(pool)
        # Generic schema guesses are the fallback for an application that has
        # declared no states of its own -- never a supplement to the ones it
        # did declare.
        dimensions = generic_dimensions(pool, klass) if dimensions.empty?
        apply_dimensions(pool, primary_key, dimensions, selected)
        fill_remaining(pool, primary_key, selected)

        candidates = selected.values
        Result.new(principals: candidates.map(&:principal), candidates: candidates,
                   strategy: :representative, queries: @queries, candidate_pool_size: @pool_size)
      end

      # rubocop:enable Metrics/MethodLength
      def recent_pool(relation, klass, primary_key)
        return [] unless query_allowed?

        order = klass.columns_hash.key?("created_at") ? { created_at: :desc } : { primary_key => :desc }
        @queries += 1
        relation.reorder(order).limit(@pool_size).to_a
      end

      def single_primary_key!(klass)
        primary_key = klass.primary_key
        return primary_key if primary_key.is_a?(String)

        raise UnsupportedPrimaryKey,
              "Karst::Access::PrincipalSampler requires #{klass.name} to have a single-column primary key " \
              "(got #{primary_key.inspect}); pass an already-materialized Array/Enumerable of principals " \
              "instead to use bounded-first sampling"
      end

      def query_allowed?
        @queries < @query_budget
      end

      def configured_dimensions(pool)
        @dimensions.values.filter_map do |dimension|
          values = pool.group_by { |record| dimension.value_for(record) }
          next unless useful_values?(values)

          values.sort_by { |value, _| value.to_s }.map do |value, _|
            dimension_value("#{dimension.name}=#{dimension.format_value(value)}") do |record|
              dimension.value_for(record) == value
            end
          end
        end
      end

      def generic_dimensions(pool, klass)
        candidate_columns(klass).first(MAX_DIMENSIONS).filter_map do |column|
          values = generic_values(pool, klass, column)
          next unless values

          values
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def generic_values(pool, klass, column)
        if enum_mapping(klass, column)
          enum_mapping(klass, column).keys.sort.map do |value|
            equality_value(column, value, value)
          end
        elsif column.type == :boolean
          [true, false].map { |value| equality_value(column, value, value.inspect) }
        elsif nullable_foreign_key?(klass, column)
          [true, false].map { |present| foreign_key_value(column, present) }
        elsif ALLOWED_SCALAR_TYPES.include?(column.type)
          scalar_values(pool, column)
        end
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def scalar_values(pool, column)
        values = pool.map { |record| record.public_send(column.name) }.uniq
        return unless values.size.between?(2, CARDINALITY_CUTOFF)

        values.sort_by(&:to_s).map { |value| equality_value(column, value, value.inspect) }
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def apply_dimensions(pool, primary_key, dimensions, selected)
        queues = dimensions.map(&:dup)
        loop do
          progressed = false
          queues.each do |queue|
            value = queue.shift
            next unless value

            progressed = true
            record = pool.find { |candidate| value.matcher.call(candidate) }
            next unless record

            id = record.public_send(primary_key)
            existing = selected[id]
            reasons = existing ? (existing.reasons + [value.reason]).uniq : [value.reason]
            selected[id] = Candidate.new(principal: record, reasons: reasons)
            break if selected.size >= @limit
          end
          break if selected.size >= @limit || !progressed
        end
      end

      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def fill_remaining(pool, primary_key, selected)
        pool.each do |record|
          break if selected.size >= @limit

          id = record.public_send(primary_key)
          selected[id] ||= Candidate.new(principal: record, reasons: [])
        end
      end

      def candidate_columns(klass)
        klass.columns_hash.values.reject do |column|
          column.name == klass.primary_key || SensitiveAttributeNames.match?(column.name) ||
            encrypted_attribute?(klass, column) || tenancy_foreign_key?(column)
        end
      end

      def encrypted_attribute?(klass, column)
        klass.respond_to?(:encrypted_attributes) && klass.encrypted_attributes&.include?(column.name.to_sym)
      end

      def tenancy_foreign_key?(column)
        column.name.end_with?("_id") &&
          column.name.downcase.split("_").any? { |token| TENANCY_FK_TOKENS.include?(token) }
      end

      def nullable_foreign_key?(klass, column)
        column.name.end_with?("_id") && column.name != klass.primary_key && column.null
      end

      def enum_mapping(klass, column)
        klass.defined_enums[column.name] if klass.respond_to?(:defined_enums)
      end

      def equality_value(column, value, label)
        dimension_value("#{column.name}=#{label}") do |record|
          record.public_send(column.name) == value
        end
      end

      def foreign_key_value(column, present)
        label = present ? "present" : "absent"
        dimension_value("#{column.name} #{label}") do |record|
          record.public_send(column.name).nil? != present
        end
      end

      def dimension_value(reason, &matcher)
        DimensionValue.new(reason: reason, matcher: matcher)
      end

      def useful_values?(values)
        values.size.between?(2, CARDINALITY_CUTOFF)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
