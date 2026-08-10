# frozen_string_literal: true

module Karst
  module Access
    # Builds the smallest Rack endpoint which still gives a controller request
    # Rails' cookie and session facilities. Calling Rails.application here would
    # recursively enter every host middleware (including the middleware which
    # initiated the sweep). RouteSet is the stable Rails dispatch boundary: it
    # performs recognition and controller dispatch, but has no host middleware.
    class ProbeApplication
      # Supplies the same Rails request environment as Rails::Application
      # without calling its compiled middleware stack.
      class Environment
        def initialize(app, defaults)
          @app = app
          @defaults = defaults
        end

        def call(env)
          @app.call(@defaults.merge(env))
        end
      end
      private_constant :Environment

      class << self
        def for(application)
          return application unless rails_application?(application)

          require_dependencies
          endpoint = application.routes
          endpoint = ActionDispatch::Flash.new(endpoint) if defined?(ActionDispatch::Flash)
          endpoint = session_middleware(application).new(endpoint, **session_options(application))
          endpoint = ActionDispatch::Cookies.new(endpoint)
          Environment.new(endpoint, application.env_config)
        end

        private

        def require_dependencies
          require "action_dispatch/middleware/cookies"
          require "action_dispatch/middleware/flash"
          require "action_dispatch/middleware/session/cookie_store"
        end

        def rails_application?(application)
          application.respond_to?(:routes) && application.respond_to?(:config)
        end

        def session_middleware(application)
          application.config.session_store || ActionDispatch::Session::CookieStore
        end

        def session_options(application)
          application.config.session_options.to_h
        end
      end
    end
  end
end
