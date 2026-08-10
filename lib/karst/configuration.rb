# frozen_string_literal: true

require_relative "access/principal_source"
require_relative "access/artifact_source"
require_relative "access/scenario"

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label,
                  :assume_browser_identity, :clear_browser_identity
    attr_reader :buffer_size, :access_sweep_limit, :usable_access_outcome, :principal_candidate_pool_size,
                :principal_dimensions, :artifact_sources, :access_scenarios

    MAX_ACCESS_SWEEP_LIMIT = 100

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
      @usable_access_outcome = ->(outcome) { outcome.status && (200..299).cover?(outcome.status) }
      @principal_candidate_pool_size = 1_000
      @principal_dimensions = {}
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

    def principal_sources=(sources)
      @configured_principal_sources = Access::PrincipalSource.normalize(sources)
    end

    # The effective, normalized principal population(s) Karst may sample
    # from or resolve into: explicit config.principal_sources when
    # configured, otherwise a bare config.principals (plus any
    # config.principal_dimensions) wrapped as one implicit :default source,
    # or nil when neither is configured. A Hash of Symbol => PrincipalSource.
    def principal_sources
      return @configured_principal_sources if @configured_principal_sources
      return nil unless @principals

      { default: Access::PrincipalSource.new(name: :default, records: @principals, dimensions: @principal_dimensions) }
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

    def buffer_size=(value)
      raise ArgumentError, "buffer_size must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @buffer_size = value
    end

    def usable_access_outcome=(policy)
      raise ArgumentError, "usable_access_outcome must be callable" unless policy.respond_to?(:call)

      @usable_access_outcome = policy
    end
  end
end
