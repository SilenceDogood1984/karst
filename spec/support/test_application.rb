# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "active_record/railtie"
require "karst"

# A deliberately small, test-only Rails application for compatibility checks.
class KarstTestApplication < Rails::Application
  class << self
    attr_accessor :initializer_ran, :listener_count_after_initialization, :prepare_count,
                  :subscribed_during_initializer, :subscription_handle_after_initialization

    def run_prepare_cycle
      reloader.prepare!
    end

    def owned_subscription_handle
      Karst.send(:subscription).instance_variable_get(:@handle)
    end

    def owned_listener_count
      ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").count do |listener|
        listener.equal?(owned_subscription_handle)
      end
    end
  end

  self.initializer_ran = false
  self.prepare_count = 0
  self.subscribed_during_initializer = nil

  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-integration-test-secret"
  config.active_support.deprecation = :stderr
  config.active_record.database_selector = nil if config.active_record.respond_to?(:database_selector=)
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)

  initializer "karst.integration_harness" do
    self.class.subscribed_during_initializer = Karst.subscribed?
    Karst.configure { |configuration| configuration.enabled = ENV.fetch("KARST_ENABLED", "true") == "true" }
    self.class.initializer_ran = true
  end

  config.to_prepare do
    KarstTestApplication.prepare_count += 1
  end
end

KarstTestApplication.initialize!
KarstTestApplication.subscription_handle_after_initialization = KarstTestApplication.owned_subscription_handle
KarstTestApplication.listener_count_after_initialization = KarstTestApplication.owned_listener_count
