# frozen_string_literal: true

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label
    attr_reader :buffer_size

    def initialize
      @enabled = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.development? || Rails.env.test? : false
      @buffer_size = 2_000
      @principals = nil
      @assume_identity = nil
      @clear_identity = nil
      @principal_label = nil
    end

    def buffer_size=(value)
      raise ArgumentError, "buffer_size must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @buffer_size = value
    end
  end
end
