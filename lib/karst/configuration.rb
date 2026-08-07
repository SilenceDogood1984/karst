# frozen_string_literal: true

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled
    attr_reader :buffer_size

    def initialize
      @enabled = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.development? || Rails.env.test? : false
      @buffer_size = 2_000
      @buffer_size_consumed = false
      @buffer_size_mutex = Mutex.new
    end

    def buffer_size=(value)
      raise ArgumentError, "buffer_size must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @buffer_size_mutex.synchronize do
        raise ArgumentError, "buffer_size must be configured before buffer initialization" if @buffer_size_consumed

        @buffer_size = value
      end
    end

    private

    def consume_buffer_size!
      @buffer_size_mutex.synchronize do
        @buffer_size_consumed = true
        @buffer_size
      end
    end
  end
end
