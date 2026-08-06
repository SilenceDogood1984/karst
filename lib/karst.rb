# frozen_string_literal: true

require_relative "karst/version"
require_relative "karst/configuration"
require_relative "karst/buffer"
require_relative "karst/sql/event"
require_relative "karst/subscription"

# Public entry point for Karst configuration and subscription ownership.
module Karst
  class << self
    def configure
      yield config
    end

    def config
      @config ||= Configuration.new
    end

    def enabled?
      config.enabled
    end

    def buffer
      @buffer ||= Buffer.new(capacity: config.buffer_size)
    end

    def subscribe!
      subscription.subscribe! if enabled?
    end

    def unsubscribe!
      subscription.unsubscribe!
    end

    def subscribed?
      subscription.subscribed?
    end

    private

    def subscription
      @subscription ||= Subscription.new(receiver: buffer)
    end
  end
end

railties_available = defined?(Rails::Railtie) || Gem::Specification.find_all_by_name("railties").any?
require_relative "karst/railtie" if railties_available
