# frozen_string_literal: true

require_relative "access/principal_source"
require_relative "access/artifact_source"
require_relative "access/scenario"
require_relative "identity/devise_support"

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label,
                  :assume_browser_identity, :clear_browser_identity
    attr_reader :buffer_size, :access_sweep_limit, :usable_access_outcome, :principal_candidate_pool_size,
                :principal_dimensions, :principal_populations, :artifact_sources, :access_scenarios,
                :population_retry_limit, :configured_principal_sources

    MAX_ACCESS_SWEEP_LIMIT = 100

    # How many records a single configured candidate population may
    # contribute when Karst automatically retries it after an ordinary
    # sample found nothing usable (see Karst::Access::Search). Kept
    # deliberately small: the point of a population retry is to answer
    # "does this population reach the behavior at all," which one or two
    # records already settle -- not to survey the population. The total
    # number of extra requests a retry may issue is bounded separately, by
    # access_sweep_limit, so adding populations can never make an analysis
    # cost more than roughly twice an ordinary sweep.
    MAX_POPULATION_RETRY_LIMIT = 10

    # Conservative hard ceiling on how many recent principals a
    # representative-sampling candidate pool may ever cover. This bounds the
    # cost of every dimension-discovery and target-lookup query the sampler
    # issues (each is scoped to this fixed, already-derived pool),
    # independent of how large the underlying table actually is.
    MAX_PRINCIPAL_CANDIDATE_POOL_SIZE = 10_000

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def initialize
      @enabled = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.development? || Rails.env.test? : false
      @buffer_size = 2_000
      @principals = nil
      @assume_identity = nil
      @clear_identity = nil
      @principal_label = nil
      @assume_browser_identity = nil
      @clear_browser_identity = nil
      @access_sweep_limit = 25
      @usable_access_outcome = lambda do |outcome|
        outcome.status == 200 && outcome_attribute_empty?(outcome, :exception_class) &&
          outcome_attribute_empty?(outcome, :halted_callback)
      end
      @principal_candidate_pool_size = 1_000
      @population_retry_limit = 3
      @principal_dimensions = {}
      @principal_populations = {}
      @configured_principal_sources = nil
      @artifact_sources = {}
      @access_scenarios = {}
    end

    def artifact_source(name, limit:, &block)
      source = Access::ArtifactSource.new(name: name, records: block, limit: limit)
      @artifact_sources = @artifact_sources.merge(source.name => source).freeze
      source
    end

    # rubocop:disable Metrics/ParameterLists
    def access_scenario(name, artifact:, path:, expect:, combination_limit: 25, stop_on_match: true)
      source = @artifact_sources[artifact.to_sym]
      raise ArgumentError, "unknown artifact source: #{artifact}" unless source

      scenario = Access::Scenario.new(name: name, artifact_source: source, path: path, expect: expect,
                                      combination_limit: combination_limit, stop_on_match: stop_on_match)
      @access_scenarios = @access_scenarios.merge(scenario.name => scenario).freeze
      scenario
    end
    # rubocop:enable Metrics/ParameterLists
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def principal_dimensions=(dimensions)
      @principal_dimensions = Access::PrincipalDimension.normalize(dimensions)
    end

    # An application-authored hint about meaningful candidate populations for
    # whatever config.principals returns -- a Hash of name => zero-argument
    # callable, each expected to return an ActiveRecord::Relation scoped to
    # that same model, for example:
    #
    #   config.principal_populations = {
    #     system_admins: -> { User.system_admins },
    #     auditors: -> { User.auditors }
    #   }
    #
    # Karst never infers that a population grants access or produces any UI
    # state; it only tries records from it (see
    # Karst::Access::PrincipalSampler/CandidatePopulation). nil/{} (the
    # default) considers no populations at all. Karst does not attempt to
    # verify that a callable's body is a "real" Rails named scope -- it only
    # checks what calling it actually returns. Applications representing
    # identity as more than one model configure populations per source
    # instead (see config.principal_sources).
    def principal_populations=(populations)
      @principal_populations = Access::PrincipalSource.normalize_populations(:default, populations)
    end

    def principal_sources=(sources)
      @configured_principal_sources = Access::PrincipalSource.normalize(sources)
    end

    # The effective, normalized principal population(s) Karst may sample
    # from or resolve into: explicit config.principal_sources when
    # configured, otherwise a bare config.principals (plus any
    # config.principal_dimensions/config.principal_populations) wrapped as
    # one implicit :default source, otherwise -- when neither is configured
    # -- one inferred Devise model wrapped the same way (see
    # Karst::Identity::DeviseSupport), or nil when none of those apply. A
    # Hash of Symbol => PrincipalSource.
    def principal_sources
      return @configured_principal_sources if @configured_principal_sources
      return default_principal_source(@principals) if @principals

      inferred = Identity::DeviseSupport.unambiguous_mapping
      return nil unless inferred

      default_principal_source(-> { inferred.model.all })
    end

    def access_sweep_limit=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_ACCESS_SWEEP_LIMIT
        raise ArgumentError, "access_sweep_limit must be between 1 and #{MAX_ACCESS_SWEEP_LIMIT}"
      end

      @access_sweep_limit = value
    end

    def principal_candidate_pool_size=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_PRINCIPAL_CANDIDATE_POOL_SIZE
        raise ArgumentError,
              "principal_candidate_pool_size must be between 1 and #{MAX_PRINCIPAL_CANDIDATE_POOL_SIZE}"
      end

      @principal_candidate_pool_size = value
    end

    def population_retry_limit=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_POPULATION_RETRY_LIMIT
        raise ArgumentError, "population_retry_limit must be between 1 and #{MAX_POPULATION_RETRY_LIMIT}"
      end

      @population_retry_limit = value
    end

    def buffer_size=(value)
      raise ArgumentError, "buffer_size must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @buffer_size = value
    end

    def usable_access_outcome=(policy)
      raise ArgumentError, "usable_access_outcome must be callable" unless policy.respond_to?(:call)

      @usable_access_outcome = policy
    end

    private

    def default_principal_source(records)
      { default: Access::PrincipalSource.new(name: :default, records: records,
                                             dimensions: @principal_dimensions,
                                             populations: @principal_populations) }
    end

    # Older/custom outcome-like values may expose only a status. An absent
    # optional evidence field means Karst did not observe that evidence, just
    # as an explicit nil does; it must not make the policy itself crash.
    def outcome_attribute_empty?(outcome, attribute)
      !outcome.respond_to?(attribute) || outcome.public_send(attribute).nil?
    end
  end
end
