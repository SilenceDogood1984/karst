# frozen_string_literal: true

require_relative "karst/version"
require_relative "karst/configuration"
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
      @subscription ||= Subscription.new
    end
  end
end

require_relative "karst/railtie" if defined?(Rails::Railtie)
