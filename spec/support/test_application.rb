# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "active_record/railtie"
require "karst"

# A deliberately small, test-only Rails application for compatibility checks.
class KarstTestApplication < Rails::Application
  class << self
    attr_accessor :initializer_ran, :prepare_count

    def run_prepare_cycle
      reloader.prepare!
    end
  end

  self.initializer_ran = false
  self.prepare_count = 0

  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-integration-test-secret"
  config.active_support.deprecation = :stderr
  config.active_record.database_selector = nil if config.active_record.respond_to?(:database_selector=)
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)

  initializer "karst.integration_harness" do
    self.class.initializer_ran = true
  end

  config.to_prepare do
    KarstTestApplication.prepare_count += 1
  end
end

KarstTestApplication.initialize!
