# frozen_string_literal: true

require "rails/railtie"

module Karst
  # Inserts Karst's development-only web surface. Karst installs no
  # notification subscription, no eager-loaded state, no rake tasks (its CLI
  # ships as Rails::Command classes under lib/rails/commands instead), and
  # nothing that runs on an ordinary application request outside development.
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
  end

  private_constant :Railtie
end
