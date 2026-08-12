# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "active_record/railtie"
require "active_support/notifications"
require "karst"

# Models development middleware such as rack-mini-profiler, which keeps
# request-local state that a recursive call through Rails.application corrupts.
class KarstNonReentrantMiddleware
  class << self
    attr_accessor :calls
  end
  self.calls = 0

  def initialize(app)
    @app = app
  end

  def call(env)
    raise "host middleware was recursively entered" if Thread.current[:karst_host_middleware_active]

    Thread.current[:karst_host_middleware_active] = true
    self.class.calls += 1
    @app.call(env)
  ensure
    Thread.current[:karst_host_middleware_active] = false
  end
end

# A deliberately small, test-only Rails application for compatibility checks.
class KarstTestApplication < Rails::Application
  class << self
    attr_accessor :initializer_ran, :prepare_count

    def run_prepare_cycle
      reloader.prepare!
    end

    def sql_listener_count
      ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
    end
  end

  self.initializer_ran = false
  self.prepare_count = 0

  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-integration-test-secret"
  # Keep browser HostAuthorization active while giving Karst a host that the
  # application explicitly permits for integration requests.
  config.hosts << "karst-probe.example"
  config.active_support.deprecation = :stderr
  config.active_record.database_selector = nil if config.active_record.respond_to?(:database_selector=)
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)
  config.middleware.use KarstNonReentrantMiddleware

  initializer "karst.integration_harness" do
    Karst.configure { |configuration| configuration.enabled = ENV.fetch("KARST_ENABLED", "true") == "true" }
    self.class.initializer_ran = true
  end

  config.to_prepare do
    KarstTestApplication.prepare_count += 1
  end
end

KarstTestApplication.initialize!
