# frozen_string_literal: true

require_relative "../value"
require_relative "sweep"
require_relative "principal_dimension"
require_relative "sensitive_attribute_names"

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

      # candidate_pool_size is the configured recent-N bound representative
      # discovery was scoped to (nil for the generic-Enumerable fallback,
      # which has no query-scoped pool concept) -- callers use it to report
      # the sampling scope truthfully instead of implying the full principal
      # universe was searched.
      Result = Value.define(:principals, :candidates, :strategy, :queries, :candidate_pool_size)

      # Deterministic, in-memory predicate plus an Active Record scope for the
      # same criterion. Internal only -- never returned to callers.
      Target = Struct.new(:key, :reason, :matcher, :scope, keyword_init: true)
      private_constant :Target

      # Total SQL queries #call will ever issue for a given limit, across
      # every query-issuing step (bounded-pool derivation, seed selection,
      # scalar-column cardinality discovery, per-target lookups, and the
      # final fill query). This is a hard cap enforced at every one of those
      # call sites individually (see #query_allowed?), not merely an
      # estimate: #call always issues at most this many queries, regardless
      # of table width or row count. Reaching the cap simply means #call may
      # return fewer than `limit` principals rather than exceeding its query
      # budget.
      def self.query_budget(limit)
        1 + MAX_SCALAR_DISCOVERY_QUERIES + (limit * 4) + 2
      end

      # dimensions is a Hash of Symbol => PrincipalDimension (see
      # Karst::Access::PrincipalDimension), already validated/normalized by
      # the caller (Configuration or PrincipalSource) -- PrincipalSampler
      # never accepts raw accessor values directly.
      def initialize(source:, limit: Karst.config.access_sweep_limit,
                     pool_size: Karst.config.principal_candidate_pool_size, dimensions: {})
        @source = source
        @limit = limit
        @pool_size = pool_size
        @dimensions = dimensions
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
        Result.new(principals: principals, candidates: candidates, strategy: :first_n, queries: 0,
                   candidate_pool_size: nil)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def representative_sample(relation)
        klass = relation.klass
        primary_key = single_primary_key!(klass)
        pool = bounded_pool_relation(relation, klass, primary_key)
        dimensions = build_dimensions(pool, klass)
        selected = {}
        covered = {}

        seed_candidate(pool, primary_key, dimensions, covered, selected)
        each_target(dimensions) do |target|
          break if selected.size >= @limit || !query_allowed?
          next if covered.key?(target.key)

          record = fetch_matching(pool, primary_key, target, selected.keys)
          next unless record

          covered[target.key] = true
          selected[record.public_send(primary_key)] = Candidate.new(principal: record, reasons: [target.reason])
        end
        fill_remaining(pool, primary_key, selected)

        candidates = selected.values
        Result.new(principals: candidates.map(&:principal), candidates: candidates,
                   strategy: :representative, queries: @queries, candidate_pool_size: @pool_size)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Derives a bounded "most recent @pool_size principals" relation and
      # fixes it as a literal primary-key list (`WHERE pk IN (1, 2, 3, ...)`)
      # rather than merely chaining `.limit` on the relation every later step
      # reuses. Merely chaining `.limit` would not be a true preselected
      # pool: Active Record merges every `.where`/`.order` clause added
      # later into the *same* query, so the LIMIT would apply after those
      # additional conditions rather than before them, letting a dimension
      # lookup silently reach rows outside the intended pool.
      #
      # The pool is resolved with exactly one query here, not re-derived as
      # a live subquery on every later query: a correlated `pk IN (SELECT pk
      # FROM ... ORDER BY ... LIMIT n)` subquery would be safe but pays that
      # ORDER BY/LIMIT cost again on every single query representative
      # discovery issues, which reintroduces an unbounded-relation-shaped
      # cost on any column (typically created_at) without a supporting
      # index -- exactly the scaling failure this pool exists to remove.
      # Fixing the ids once and inlining them as a literal list (not bind
      # parameters, via `where("pk IN (?)", ids)`) also sidesteps some
      # database adapters' bind-parameter-count ceilings at the configured
      # hard maximum pool size. The ids come only from this process's own
      # prior query result, never from external input, so literal inlining
      # (quoted through Active Record's own sanitizer) carries no injection
      # risk. Every later `.where` on the returned relation is ANDed against
      # this fixed, already-bounded id list, so no query issued against it
      # can ever inspect a row outside the pool, regardless of what
      # conditions representative discovery adds.
      def bounded_pool_relation(relation, klass, primary_key)
        return relation.none unless query_allowed?

        recency_ordered = if klass.columns_hash.key?("created_at")
                            relation.reorder(created_at: :desc)
                          else
                            relation.reorder(primary_key => :desc)
                          end
        @queries += 1
        pool_ids = recency_ordered.limit(@pool_size).pluck(primary_key)
        relation.where("#{primary_key} IN (?)", pool_ids)
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

      # Every query in representative discovery now runs against the bounded
      # pool, whose rows sit at the high end of the primary key range (the
      # pool is "most recent," and recency and primary-key order correlate
      # in virtually every real schema). Ordering ascending by primary key,
      # as this and #fetch_matching/#fill_remaining did before the pool
      # existed, would force exactly the kind of full-table scan the pool
      # exists to avoid: to find the smallest matching id, the database
      # walks the primary-key index from its very start, past every
      # excluded low-id row, before ever reaching the pool. Descending order
      # instead reaches pool-dense territory on the first rows examined.
      def seed_candidate(relation, primary_key, dimensions, covered, selected)
        return unless query_allowed?

        @queries += 1
        seed = relation.order(primary_key => :desc).limit(1).first
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
        scope.order(primary_key => :desc).limit(1).first
      end

      def fill_remaining(relation, primary_key, selected)
        remaining = @limit - selected.size
        return if remaining <= 0 || !query_allowed?

        @queries += 1
        relation.where.not(primary_key => selected.keys).order(primary_key => :desc).limit(remaining).each do |record|
          selected[record.public_send(primary_key)] = Candidate.new(principal: record, reasons: [])
        end
      end

      # Returns an Array of dimensions, each an Array of Target -- the shape
      # #each_target round-robins over to interleave coverage across
      # dimensions rather than exhausting one dimension before the next.
      # Configured dimensions (see #configured_dimension_targets) always go
      # first and are never capped by MAX_DIMENSIONS -- an application that
      # explicitly named a dimension gets it, full stop; MAX_DIMENSIONS only
      # bounds how much *generic* schema discovery fills in around them.
      def build_dimensions(relation, klass)
        @scalar_discovery_budget = MAX_SCALAR_DISCOVERY_QUERIES
        dimensions = configured_dimension_targets(relation, klass)
        configured_columns = @dimensions.values.filter_map { |dimension| dimension.column_for(klass)&.name }
        add_generic_dimensions(relation, klass, dimensions, configured_columns)
        dimensions
      end

      def add_generic_dimensions(relation, klass, dimensions, configured_columns)
        candidate_columns(klass).each do |column|
          break if dimensions.size >= MAX_DIMENSIONS || !query_allowed?
          next if configured_columns.include?(column.name)

          targets = dimension_targets(relation, column, klass)
          dimensions << targets if targets && targets.size > 1
        end
      end

      def dimension_targets(relation, column, klass)
        enum_targets(column, klass) || boolean_targets(column) || nullable_foreign_key_targets(column, klass) ||
          scalar_dimension_targets(relation, column)
      end

      # Builds one Target group per configured PrincipalDimension (see
      # Karst::Access::PrincipalDimension), in configured order. A dimension
      # backed by a real column (an enum, boolean, or plain scalar) is
      # discovered the same bounded way generic schema dimensions are -- a
      # single `DISTINCT ... LIMIT` query, never a full scan. A dimension
      # that is not a real column (a predicate method, or a callable) cannot
      # be translated to SQL, so it is instead evaluated once, in Ruby, over
      # the already query-bounded `relation` (the recent-N candidate pool
      # #representative_sample derived) -- never per-row against the full
      # table -- via #configured_pool_targets.
      def configured_dimension_targets(relation, klass)
        return [] if @dimensions.empty?

        @pool_records = nil
        results = []
        @dimensions.each_value do |dimension|
          break unless query_allowed?

          targets = configured_targets_for(relation, klass, dimension)
          results << targets if targets && targets.size > 1
        end
        results
      end

      def configured_targets_for(relation, klass, dimension)
        column = dimension.column_for(klass)
        return configured_column_targets(relation, column, klass, dimension) if column

        @pool_records ||= materialize_pool(relation)
        configured_pool_targets(dimension, @pool_records, klass.primary_key)
      end

      def materialize_pool(relation)
        return [] unless query_allowed?

        @queries += 1
        relation.to_a
      end

      def configured_column_targets(relation, column, klass, dimension)
        configured_enum_targets(column, klass, dimension) || configured_boolean_targets(column, dimension) ||
          configured_scalar_targets(relation, column, dimension)
      end

      def configured_enum_targets(column, klass, dimension)
        return nil unless klass.respond_to?(:defined_enums)

        mapping = klass.defined_enums[column.name]
        return nil unless mapping

        mapping.keys.sort.map { |key| configured_equality_target(dimension, column, key) }
      end

      def configured_boolean_targets(column, dimension)
        return nil unless column.type == :boolean

        [true, false].map { |value| configured_equality_target(dimension, column, value) }
      end

      def configured_scalar_targets(relation, column, dimension)
        return nil unless query_allowed?

        @queries += 1
        values = relation.distinct.limit(CARDINALITY_CUTOFF + 1).pluck(column.name)
        return nil if values.size > CARDINALITY_CUTOFF || values.size <= 1

        values.sort_by(&:to_s).map { |value| configured_equality_target(dimension, column, value) }
      end

      def configured_equality_target(dimension, column, value)
        Target.new(
          key: "dimension:#{dimension.name}=#{value}", reason: "#{dimension.name}=#{dimension.format_value(value)}",
          matcher: ->(record) { record.public_send(column.name) == value },
          scope: ->(rel) { rel.where(column.name => value) }
        )
      end

      # A predicate/callable dimension has no SQL scope, so its Target scope
      # instead narrows to the exact primary keys observed (within the
      # already-bounded pool) to hold that value -- still a single bounded,
      # deterministic query per target through the ordinary #fetch_matching
      # path, never a second unbounded scan.
      def configured_pool_targets(dimension, pool_records, primary_key)
        grouped = pool_records.group_by { |record| dimension.value_for(record) }
        return nil if grouped.size <= 1 || grouped.size > CARDINALITY_CUTOFF

        grouped.sort_by { |value, _records| value.to_s }
               .map { |value, records| configured_pool_target(dimension, primary_key, value, records) }
      end

      def configured_pool_target(dimension, primary_key, value, records)
        ids = records.map { |record| record.public_send(primary_key) }
        Target.new(
          key: "dimension:#{dimension.name}=#{value}", reason: "#{dimension.name}=#{dimension.format_value(value)}",
          matcher: ->(record) { dimension.value_for(record) == value },
          scope: ->(rel) { rel.where(primary_key => ids) }
        )
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
        SensitiveAttributeNames.match?(column_name)
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
