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

        # Mutates the caller's own env in place (filling in only keys it
        # doesn't already set -- @defaults never overrides an explicit
        # incoming value) rather than building a new merged Hash. Downstream
        # middleware Karst wraps this env with, in particular Warden::Manager
        # setting env["warden"], must remain visible on the exact env object
        # ActionDispatch::Integration::Session retains as #request.env after
        # the call returns -- a fresh copy would silently discard every
        # mutation the moment this method returned, leaving Karst unable to
        # find that same Warden proxy again afterward (see WardenAdapter#clear).
        def call(env)
          @defaults.each { |key, value| env[key] = value unless env.key?(key) }
          @app.call(env)
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
          endpoint = wrap_warden(endpoint)
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

        # Mirrors the host application's own middleware order (Warden::Manager
        # sits directly in front of the router, inside session/flash/cookies)
        # so `env["warden"]` exists for Karst::Identity::WardenAdapter -- the
        # same object a real host request would see. Without this, a Devise
        # (or otherwise Warden-based) application's probes would fail every
        # single principal with Karst::Identity::Unavailable, since nothing
        # else in this deliberately minimal Rack stack ever initializes a
        # Warden proxy. Reuses Devise's own already-configured Warden::Config
        # (scope defaults, session serializers, failure app) when Devise is
        # present, rather than an empty default one, so a probe that reaches
        # an unauthenticated 401/302 behaves exactly as it would for a real
        # request instead of raising "No Failure App provided".
        # Falls back to leaving `endpoint` unwrapped, rather than letting
        # construction failure abort the whole probe, when Warden::Manager
        # doesn't behave like the real middleware (for example a bare stand-in
        # Class with Object's own zero-argument #initialize, as several specs
        # use to exercise Devise-detection paths where explicit
        # config.assume_identity/config.assume_browser_identity hooks already
        # make WardenAdapter -- and so this wrapping -- unnecessary).
        # Passed through the config block, never as Warden::Manager.new's own
        # `options` argument: that constructor special-cases an
        # options[:default_strategies] key by deleting it and re-adding it
        # via `@config.default_strategies(*default_strategies)`, which
        # assumes a flat Array of strategy names. Devise's own
        # warden_config[:default_strategies] is already a Hash keyed by
        # scope (e.g. {user: [...], admin: [...]}); splatting that Hash
        # turns each [scope, strategies] pair into a positional argument, so
        # every scope name (:admin, :user, ...) ends up misfiled into the
        # :_all strategy list as if it were itself a strategy -- harmless
        # for a single scope (nothing ever runs real strategies for a
        # principal Karst just set_user'd into that exact scope), but a
        # probed principal under one scope hitting a route gated on another
        # then raises Warden's own "Invalid strategy admin" the moment
        # multiple Devise models are involved. config.merge! after
        # construction copies the same Hash in verbatim instead.
        def wrap_warden(endpoint)
          return endpoint unless defined?(Warden::Manager)

          Warden::Manager.new(endpoint) { |config| config.merge!(devise_warden_config) }
        rescue StandardError
          endpoint
        end

        # A duplicate, never the live object: Warden::Manager#initialize
        # destructively deletes :default_strategies from whatever options
        # Hash it's given, and Devise's own warden_config is the one shared,
        # mutable object every real host request also authenticates through
        # -- corrupting it here would silently break the host application's
        # own Devise authentication after a single Karst probe.
        #
        # Devise only populates warden_config (failure_app, scope_defaults,
        # session serializers) the first time its routes finalize, which
        # normally has already happened by the time a real /karst request
        # reaches Sweep (Identity.setup_state/principal_sources already
        # forced it via Devise.mappings). Calling Devise.mappings here too
        # makes that a guarantee rather than an incidental ordering, so the
        # very first sweep of a freshly booted process still gets a complete
        # config instead of an empty one.
        def devise_warden_config
          return {} unless defined?(Devise) && Devise.respond_to?(:warden_config)

          Devise.mappings if Devise.respond_to?(:mappings)
          Devise.warden_config&.dup || {}
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
