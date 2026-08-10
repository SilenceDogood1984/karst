# frozen_string_literal: true

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label,
                  :assume_browser_identity, :clear_browser_identity
    attr_reader :buffer_size, :access_sweep_limit

    MAX_ACCESS_SWEEP_LIMIT = 100

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
    end

    def access_sweep_limit=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_ACCESS_SWEEP_LIMIT
        raise ArgumentError, "access_sweep_limit must be between 1 and #{MAX_ACCESS_SWEEP_LIMIT}"
      end

      @access_sweep_limit = value
    end

    def buffer_size=(value)
      raise ArgumentError, "buffer_size must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @buffer_size = value
    end
  end
end
