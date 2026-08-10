# frozen_string_literal: true

require_relative "../value"
require_relative "sweep"

module Karst
  module Access
    # Selects a small, bounded, deterministic set of candidate principals from
    # a large Active Record scope, biased toward covering distinct observed
    # database-state dimensions (booleans, enums, nullable-FK presence,
    # low-cardinality scalars) rather than the first N rows encountered. This
    # is schema-state diversity, not behavioral diversity -- the sampler never
    # executes a route, so it has no evidence about how any of these states
    # actually behave; that evidence only exists once Access::Sweep runs.
    #
    # This class only selects candidates -- it never executes a route, never
    # compares outcomes, and never inspects PII. Its result is fed to
    # Karst::Access::Sweep exactly like any other bounded principal source.
    #
    # For a generic Enumerable (not an Active Record relation/class), it falls
    # back to the same bounded-first strategy Sweep itself already used.
    # rubocop:disable Metrics/ClassLength
    class PrincipalSampler
      # Raised when the Active Record source has no single, simple primary
      # key column (a composite primary key, or none at all). Sampling relies
      # on ordering and excluding by one primary-key column throughout; rather
      # than fail confusingly deep inside a query chain, this fails fast at
      # the boundary with an actionable message. A plain Enumerable/Array
      # principal source (including an already-materialized `relation.to_a`)
      # is unaffected -- it never reaches this path.
      class UnsupportedPrimaryKey < Error; end

      # A column is considered a candidate for stratification only when the
      # number of distinct values observed does not exceed this cutoff.
      # Chosen conservatively: enough to represent a handful of workflow
      # states (a status enum, a small set of plans/tiers) while remaining
      # cheap to discover with a single bounded query and remaining useless
      # for anything resembling a tenant/account identifier at real scale.
      CARDINALITY_CUTOFF = 10

      # Caps how many columns are ever considered as stratification
      # dimensions, and how many of those require a discovery query (plain
      # scalar columns; enums/booleans/nullable-FK presence are free -- their
      # possible values are known from schema/model metadata, not a query).
      # Both caps exist purely to bound query volume on wide tables; they do
      # not depend on row count.
      MAX_DIMENSIONS = 8
      MAX_SCALAR_DISCOVERY_QUERIES = 8

      # Column names are never PII-inspected, only compared (case-insensitive,
      # underscore-tokenized) against this list. Deliberately conservative:
      # false positives (skipping a safe column) are free; false negatives
      # are not.
      SENSITIVE_TOKENS = %w[
        email name first last full phone mobile fax address street city zip
        postal country ssn social security password secret salt encrypted
        token key api credential auth login username url website dob birth
        card cvv iban passport license
      ].freeze

      # Foreign-key-shaped columns (ending in "_id") whose name suggests a
      # tenant/account boundary are excluded from candidacy outright, not
      # just when non-nullable. A *nullable* tenant-style foreign key would
      # otherwise reach #nullable_foreign_key_targets, which samples
      # presence/absence without ever running the cardinality check below --
      # so cardinality alone cannot be the thing keeping a high-cardinality
      # tenant/account identifier out of the sampler; this name-based
      # exclusion is what actually guarantees it, regardless of nullability.
      TENANCY_FK_TOKENS = %w[tenant account organization org company workspace team customer client shop].freeze

      ALLOWED_SCALAR_TYPES = %i[integer bigint string].freeze

      Candidate = Value.define(:principal, :reasons)
      Result = Value.define(:principals, :candidates, :strategy, :queries)

      # Deterministic, in-memory predicate plus an Active Record scope for the
      # same criterion. Internal only -- never returned to callers.
      Target = Struct.new(:key, :reason, :matcher, :scope, keyword_init: true)
      private_constant :Target

      # Total SQL queries #call will ever issue for a given limit, across
      # every query-issuing step (seed selection, scalar-column cardinality
      # discovery, per-target lookups, and the final fill query). This is a
      # hard cap enforced at every one of those call sites individually (see
      # #query_allowed?), not merely an estimate: #call always issues at most
      # this many queries, regardless of table width or row count. Reaching
      # the cap simply means #call may return fewer than `limit` principals
      # rather than exceeding its query budget.
      def self.query_budget(limit)
        MAX_SCALAR_DISCOVERY_QUERIES + (limit * 4) + 2
      end

      def initialize(source:, limit: Karst.config.access_sweep_limit)
        @source = source
        @limit = limit
        @queries = 0
        @query_budget = self.class.query_budget(limit)
      end

      def call
        relation = active_record_relation
        return fallback_sample unless relation

        representative_sample(relation)
      end

      # No query, no enumeration: a pure type check used by the panel to
      # decide which label to show before any sweep runs.
      def self.representative_capable?(source)
        return true if defined?(ActiveRecord::Relation) && source.is_a?(ActiveRecord::Relation)

        defined?(ActiveRecord::Base) && source.is_a?(Class) && source < ActiveRecord::Base
      rescue StandardError
        false
      end

      private

      def active_record_relation
        return @source if defined?(ActiveRecord::Relation) && @source.is_a?(ActiveRecord::Relation)
        return @source.all if defined?(ActiveRecord::Base) && @source.is_a?(Class) && @source < ActiveRecord::Base

        nil
      end

      def fallback_sample
        principals = @source.each.lazy.take(@limit).to_a
        candidates = principals.map { |principal| Candidate.new(principal: principal, reasons: []) }
        Result.new(principals: principals, candidates: candidates, strategy: :first_n, queries: 0)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def representative_sample(relation)
        klass = relation.klass
        primary_key = single_primary_key!(klass)
        dimensions = build_dimensions(relation, klass)
        selected = {}
        covered = {}

        seed_candidate(relation, primary_key, dimensions, covered, selected)
        each_target(dimensions) do |target|
          break if selected.size >= @limit || !query_allowed?
          next if covered.key?(target.key)

          record = fetch_matching(relation, primary_key, target, selected.keys)
          next unless record

          covered[target.key] = true
          selected[record.public_send(primary_key)] = Candidate.new(principal: record, reasons: [target.reason])
        end
        fill_remaining(relation, primary_key, selected)

        candidates = selected.values
        Result.new(principals: candidates.map(&:principal), candidates: candidates,
                   strategy: :representative, queries: @queries)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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

      def seed_candidate(relation, primary_key, dimensions, covered, selected)
        return unless query_allowed?

        @queries += 1
        seed = relation.order(primary_key).limit(1).first
        return unless seed

        selected[seed.public_send(primary_key)] = Candidate.new(
          principal: seed, reasons: cover_matching(seed, dimensions, covered)
        )
      end

      def cover_matching(seed, dimensions, covered)
        matched = dimensions.flatten.select { |target| target.matcher.call(seed) }
        matched.each { |target| covered[target.key] = true }
        matched.map(&:reason)
      end

      def each_target(dimensions)
        queues = dimensions.map(&:dup)
        loop do
          progressed = false
          queues.each do |queue|
            next if queue.empty?

            yield queue.shift
            progressed = true
          end
          break unless progressed
        end
      end

      def fetch_matching(relation, primary_key, target, exclude_ids)
        return nil unless query_allowed?

        @queries += 1
        scope = target.scope.call(relation)
        scope = scope.where.not(primary_key => exclude_ids) if exclude_ids.any?
        scope.order(primary_key).limit(1).first
      end

      def fill_remaining(relation, primary_key, selected)
        remaining = @limit - selected.size
        return if remaining <= 0 || !query_allowed?

        @queries += 1
        relation.where.not(primary_key => selected.keys).order(primary_key).limit(remaining).each do |record|
          selected[record.public_send(primary_key)] = Candidate.new(principal: record, reasons: [])
        end
      end

      # Returns an Array of dimensions, each an Array of Target -- the shape
      # #each_target round-robins over to interleave coverage across
      # dimensions rather than exhausting one dimension before the next.
      def build_dimensions(relation, klass)
        @scalar_discovery_budget = MAX_SCALAR_DISCOVERY_QUERIES
        dimensions = []
        candidate_columns(klass).each do |column|
          break if dimensions.size >= MAX_DIMENSIONS || !query_allowed?

          targets = dimension_targets(relation, column, klass)
          dimensions << targets if targets && targets.size > 1
        end
        dimensions
      end

      def dimension_targets(relation, column, klass)
        enum_targets(column, klass) || boolean_targets(column) || nullable_foreign_key_targets(column, klass) ||
          scalar_dimension_targets(relation, column)
      end

      def scalar_dimension_targets(relation, column)
        return nil unless ALLOWED_SCALAR_TYPES.include?(column.type) && @scalar_discovery_budget.positive? &&
                          query_allowed?

        @scalar_discovery_budget -= 1
        scalar_targets(relation, column)
      end

      def candidate_columns(klass)
        klass.columns_hash.values.reject do |column|
          column.name == klass.primary_key || sensitive_name?(column.name) || encrypted_attribute?(klass, column) ||
            tenancy_foreign_key?(column)
        end
      end

      def sensitive_name?(column_name)
        column_name.to_s.downcase.split("_").any? { |token| SENSITIVE_TOKENS.include?(token) }
      end

      # See TENANCY_FK_TOKENS: this is what actually keeps a high-cardinality
      # tenant/account foreign key out of candidacy, independent of whether
      # the column happens to be nullable (and therefore would otherwise
      # reach the cardinality-check-free presence/absence path).
      def tenancy_foreign_key?(column)
        return false unless column.name.end_with?("_id")

        column.name.to_s.downcase.split("_").any? { |token| TENANCY_FK_TOKENS.include?(token) }
      end

      def encrypted_attribute?(klass, column)
        klass.respond_to?(:encrypted_attributes) && klass.encrypted_attributes&.include?(column.name.to_sym)
      end

      def enum_targets(column, klass)
        return nil unless klass.respond_to?(:defined_enums)

        mapping = klass.defined_enums[column.name]
        return nil unless mapping

        mapping.keys.sort.map { |key| equality_target(column, key, label: key) }
      end

      def boolean_targets(column)
        return nil unless column.type == :boolean

        [true, false].map { |value| equality_target(column, value) }
      end

      def nullable_foreign_key_targets(column, klass)
        return nil unless column.name.end_with?("_id") && column.name != klass.primary_key && column.null

        [foreign_key_target(column, true), foreign_key_target(column, false)]
      end

      def foreign_key_target(column, present)
        label = present ? "present" : "absent"
        Target.new(
          key: "#{column.name}:#{label}", reason: "#{column.name} #{label}",
          matcher: ->(record) { record.public_send(column.name).nil? != present },
          scope: ->(rel) { present ? rel.where.not(column.name => nil) : rel.where(column.name => nil) }
        )
      end

      def scalar_targets(relation, column)
        @queries += 1
        values = relation.distinct.limit(CARDINALITY_CUTOFF + 1).pluck(column.name)
        return nil if values.size > CARDINALITY_CUTOFF || values.size <= 1

        values.sort_by(&:to_s).map { |value| equality_target(column, value) }
      end

      # Shared shape for enum/boolean/scalar dimensions: a Target whose
      # matcher and scope both reduce to a plain column equality check.
      # Nullable-FK presence is the one dimension kind that is not an
      # equality check, so it builds its own Target (#foreign_key_target).
      def equality_target(column, value, label: value.inspect)
        Target.new(key: "#{column.name}=#{value}", reason: "#{column.name}=#{label}",
                   matcher: ->(record) { record.public_send(column.name) == value },
                   scope: ->(rel) { rel.where(column.name => value) })
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
