# frozen_string_literal: true

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label,
                  :assume_browser_identity, :clear_browser_identity
    attr_reader :buffer_size, :access_sweep_limit, :usable_access_outcome, :principal_candidate_pool_size

    MAX_ACCESS_SWEEP_LIMIT = 100

    # Conservative hard ceiling on how many recent principals a
    # representative-sampling candidate pool may ever cover. This bounds the
    # cost of every dimension-discovery and target-lookup query the sampler
    # issues (each is scoped to this fixed, already-derived pool),
    # independent of how large the underlying table actually is.
    MAX_PRINCIPAL_CANDIDATE_POOL_SIZE = 10_000

    # rubocop:disable Metrics/MethodLength
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
    end
    # rubocop:enable Metrics/MethodLength

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
