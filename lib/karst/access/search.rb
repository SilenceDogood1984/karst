# frozen_string_literal: true

require_relative "../value"
require_relative "sweep"
require_relative "principal_source"
require_relative "principal_selection"
require_relative "candidate_population"

module Karst
  module Access
    # Orchestrates the two-stage search for a user who can actually use a
    # route: the ordinary bounded sample first, then -- only if that found
    # nothing usable -- one bounded retry against each *approved* candidate
    # population, stopping at the first verified success.
    #
    # This is deliberately an orchestrator built on top of the existing
    # primitives rather than new behavior inside them. Access::Sweep still
    # owns every actual request (and therefore every rollback, write
    # observation, exception, and halted-callback observation), and
    # CandidatePopulation still owns resolving one configured callable into
    # bounded records. Search only decides what to run next and records what
    # it chose not to run.
    #
    # Approval boundary: the populations considered here come exclusively
    # from configuration -- config.principal_populations, or a
    # config.principal_sources[...] :populations entry. A name merely
    # *discovered* by Karst::Access::PopulationDiscovery is never executed
    # automatically; discovery only ever produces text for a developer to
    # copy into their own configuration.
    # rubocop:disable Metrics/ClassLength
    class Search
      # Why a population contributed nothing, kept explicit rather than
      # inferred from an empty result so the panel can say what actually
      # happened instead of implying every population was tested:
      #
      #   :usable           ran, and produced a usable outcome
      #   :no_match         ran, and produced no usable outcome
      #   :empty            resolved, but currently matches no records
      #   :already_tried    resolved, but every candidate was already tested
      #   :unresolved       the callable did not yield usable records
      #   :skipped          not tried -- a usable user was already found
      #   :budget_exhausted not tried -- the retry request budget was reached
      PopulationAttempt = Value.define(:name, :source_name, :state, :result, :error) do
        def ran?
          !result.nil?
        end
      end

      # `initial` is the ordinary Access::Sweep::Result; `attempts` is one
      # PopulationAttempt per approved population, in configuration order,
      # including the ones deliberately not run.
      Result = Value.define(:initial, :attempts) do
        def path
          initial.path
        end

        def http_method
          initial.http_method
        end

        # Every outcome observed across both stages, initial sample first.
        def all_outcomes
          ([initial] + attempts.filter_map(&:result)).flat_map(&:outcomes)
        end

        def attempted
          attempts.select(&:ran?)
        end

        def population_request_count
          attempted.sum { |attempt| attempt.result.outcomes.size }
        end
      end

      def initialize(path:, http_method: "GET", sources: nil, application: nil)
        @path = path
        @http_method = http_method
        @sources = sources || {}
        @application = application
        @requests_used = 0
        @tried_keys = {}
      end

      def call
        initial = initial_sweep
        return Result.new(initial: initial, attempts: [].freeze) if usable?(initial.outcomes) || approved.empty?

        Result.new(initial: initial, attempts: attempt_populations.freeze)
      end

      private

      def initial_sweep
        sampled = PrincipalSelection.new(sources: sample_sources).call
        record_tried(sampled.principals)
        Sweep.new(path: @path, http_method: @http_method, principals: sampled.principals,
                  application: @application, candidate_pool_size: sampled.candidate_pool_size,
                  sampling_reasons: sampling_reasons(sampled)).call
      end

      # The ordinary sample deliberately runs *without* candidate
      # populations, even though PrincipalSampler is able to fold them in
      # directly. A population that is silently mixed into the first sample
      # can never be reported as "this is what it took to reach the
      # behavior" -- it just quietly becomes part of an ordinary-looking
      # result. Keeping populations out of stage one and letting this class
      # own them in stage two is what makes the two-stage evidence
      # ("25 recent users, none usable -> system_admins -> User #27 -> 200")
      # true as stated. Dimensions still apply to the sample; only
      # populations move.
      def sample_sources
        @sources.transform_values do |source|
          PrincipalSource.new(name: source.name, records: source.records, dimensions: source.dimensions)
        end
      end

      def sampling_reasons(sampled)
        sampled.candidates.to_h { |candidate| [candidate.principal, candidate.reasons] }
      end

      # Configuration order, across sources and then within each source --
      # Ruby Hashes preserve insertion order, so this is exactly the order
      # the application declared, never a heuristic ranking.
      def approved
        @approved ||= @sources.flat_map do |source_name, source|
          source.populations.map { |name, callable| [source_name, name, callable, source] }
        end
      end

      def attempt_populations
        found = false
        approved.map do |source_name, name, callable, source|
          next skip(source_name, name, :skipped) if found

          attempt = attempt_population(source_name, name, callable, source)
          found = attempt.state == :usable
          attempt
        end
      end

      def attempt_population(source_name, name, callable, source)
        return skip(source_name, name, :budget_exhausted) unless budget_remaining.positive?

        resolved = candidate_records(source_name, name, callable, source)
        return resolved if resolved.is_a?(PopulationAttempt)

        sweep_population(source_name, name, resolved[:records], resolved[:population])
      rescue StandardError => e
        skip(source_name, name, :unresolved, error: "#{e.class}: #{e.message}")
      end

      # Returns either the records to probe or a terminal PopulationAttempt
      # explaining why there are none. Resolution costs exactly one bounded
      # LIMIT query -- never a COUNT, never full materialization.
      def candidate_records(source_name, name, callable, source)
        klass = source.record_klass
        return skip(source_name, name, :unresolved, error: "source is not an Active Record model") unless klass

        population = CandidatePopulation.resolve(name: name, callable: callable, source_klass: klass,
                                                 limit: resolve_limit)
        return skip(source_name, name, :unresolved, error: "did not resolve to a usable relation") unless population
        return skip(source_name, name, :empty) if population.records.empty?

        fresh_records(source_name, name, population)
      end

      def fresh_records(source_name, name, population)
        fresh = population.records.reject { |record| @tried_keys.key?(identity_key(record)) }
        return skip(source_name, name, :already_tried) if fresh.empty?

        { records: fresh.first(per_population_limit), population: population }
      end

      def sweep_population(source_name, name, records, population)
        record_tried(records)
        @requests_used += records.size
        result = Sweep.new(path: @path, http_method: @http_method, principals: records, limit: records.size,
                           application: @application,
                           sampling_reasons: population_reasons(records, population)).call
        state = usable?(result.outcomes) ? :usable : :no_match
        PopulationAttempt.new(name: name, source_name: source_name, state: state, result: result, error: nil)
      end

      def population_reasons(records, population)
        records.to_h { |record| [record, [population.provenance]] }
      end

      def skip(source_name, name, state, error: nil)
        PopulationAttempt.new(name: name, source_name: source_name, state: state, result: nil, error: error)
      end

      # Resolving a few more rows than will actually be probed guarantees
      # deduplication cannot produce a false ":already_tried": if a
      # population holds at least (cap + already-tried) rows, at most
      # already-tried of them can be duplicates, so at least `cap` fresh
      # ones survive. Still one bounded query, and still small -- the
      # already-tried set is itself capped by access_sweep_limit twice over.
      def resolve_limit
        per_population_limit + @tried_keys.size
      end

      def per_population_limit
        [Karst.config.population_retry_limit, budget_remaining].min
      end

      # The whole retry stage may never issue more requests than an ordinary
      # sweep already may, so enabling populations at most doubles the cost
      # of an analysis regardless of how many are configured.
      def budget_remaining
        Karst.config.access_sweep_limit - @requests_used
      end

      def usable?(outcomes)
        policy = Karst.config.usable_access_outcome
        outcomes.any? { |outcome| policy.call(outcome) }
      end

      def record_tried(records)
        records.each { |record| @tried_keys[identity_key(record)] = true }
      end

      # Identity by model plus primary key, so the same row arriving as two
      # separate Active Record instances (once from the sample, once from a
      # population) is recognised as already tested. Falls back to object
      # identity for anything without an id, which is never worse than the
      # previous behaviour of always re-probing.
      def identity_key(record)
        id = record.respond_to?(:id) ? record.id : nil
        id.nil? ? [nil, record.object_id] : [record.class.name, id]
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
