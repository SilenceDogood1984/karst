# frozen_string_literal: true

module Karst
  module Access
    # Builds the smallest Rack endpoint which still gives a controller request
    # Rails' cookie and session facilities. Calling Rails.application here would
    # recursively enter every host middleware (including the middleware which
    # initiated the sweep). RouteSet is the stable Rails dispatch boundary: it
    # performs recognition and controller dispatch, but has no host middleware.
    class ProbeApplication
      class ConstructionError < StandardError; end

      # Supplies the same Rails request environment as Rails::Application
      # without calling its compiled middleware stack.
      class Environment
        attr_reader :host

        def initialize(app, defaults, host)
          @app = app
          @defaults = defaults
          @host = host
        end

        def call(env)
          @app.call(@defaults.merge(env))
        end
      end
      private_constant :Environment

      class << self
        def for(application)
          return application unless rails_application?(application)

          build(application)
        rescue LoadError, StandardError => e
          raise ConstructionError,
                "Karst could not build the Rails probe endpoint; check the application's session store configuration",
                cause: e
        end

        private

        def build(application)
          require_dependencies
          endpoint = application.routes
          endpoint = ActionDispatch::Flash.new(endpoint)
          endpoint = session_middleware(application).new(endpoint, **session_options(application))
          endpoint = ActionDispatch::Cookies.new(endpoint)
          Environment.new(endpoint, application.env_config, probe_host(application))
        end

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

        def probe_host(application)
          candidates = [application.routes.default_url_options[:host]]
          candidates.concat(Array(application.config.hosts).grep(String))
          if defined?(ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT)
            candidates.concat(ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT.grep(String))
          end
          candidates.filter_map { |candidate| safe_host(candidate) }.first
        end

        def safe_host(candidate)
          host = candidate.to_s.sub(/\A\./, "")
          return if host.empty? || host.match?(%r{[\s/:]})

          host
        end
      end
    end
  end
end
