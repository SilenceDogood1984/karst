# frozen_string_literal: true

require "rails/railtie"

module Karst
  # Installs Karst after application initializers have configured it, and
  # separately inserts Karst's development-only web surface. These are kept as
  # two independent initializers on purpose: capture subscription and HTTP
  # exposure are separate concerns with separate lifecycles, even though both
  # happen to be Rails integration points.
  class Railtie < Rails::Railtie
    # Must run before the middleware stack is built (a later Finisher
    # initializer), not in config.after_initialize, which runs after the stack
    # already exists and would have no effect. Lazily requires the web surface
    # so a plain `require "karst"` never loads Rack rendering concerns outside
    # development.
    initializer "karst.web_middleware", before: :build_middleware_stack do |app|
      next unless Rails.env.development?

      require_relative "web/middleware"
      app.middleware.use(Web::Middleware)

      Rails.logger&.info("Karst: evidence at /karst")
    end

    config.after_initialize do
      Karst.subscribe! if Karst.enabled?
    end

    rake_tasks do
      load File.expand_path("../tasks/karst.rake", __dir__)
    end
  end

  private_constant :Railtie
end
