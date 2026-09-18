# frozen_string_literal: true

require_relative "../value"
require_relative "devise_support"

module Karst
  module Identity
    # The one place a principal object's stable model name is derived, shared
    # by requested-identity description (Identity.describe) and runtime
    # observation below, so the two can never disagree about what "User"
    # means for the same object.
    module Naming
      module_function

      def model_name_for(klass)
        klass.respond_to?(:model_name) ? klass.model_name.name.to_s : klass.name.to_s
      end
    end

    # What the *application* resolved as its own authenticated principal
    # during a probe request -- never what Karst asked for. Deliberately
    # narrower than PrincipalDescriptor: an observation carries no display
    # label or authentication identifier, because it is evidence about a
    # request rather than a record Karst selected and can describe.
    ObservedPrincipal = Value.define(:model_name, :id)

    # Handed to config.observe_identity. `controller` is the exact
    # ActionController instance that processed the probe request (Rails sets
    # env["action_controller.instance"] in ActionController::Metal#set_request!
    # before any callback runs, so it is present even for a request halted in
    # a before_action); `request` is an ActionDispatch::Request over the same
    # env, and `env` the raw Rack env.
    ObservationContext = Value.define(:controller, :request, :env)

    # One attempt to observe the application's runtime principal.
    # `principal` is an ObservedPrincipal, or nil for "the application
    # resolved no principal" -- which is only meaningful when `error` is nil.
    # `source` names which seam produced it (:configured, :warden), so a
    # consumer can tell an application-authored observation from an inferred
    # one. A non-nil `error` means Karst could not determine what identity the
    # application used at all, and nothing may be concluded from `principal`.
    Observation = Value.define(:principal, :source, :error) do
      def observable?
        error.nil?
      end
    end

    # Observes the principal the Rails application actually used, from the
    # runtime state of the probe request itself.
    #
    # Two seams, in order of authority:
    #
    #   1. config.observe_identity -- an application-authored callable given
    #      the controller instance that processed the request. This is the
    #      only seam that can observe an identity the application keeps
    #      somewhere Karst cannot know about (a @current_user set by a
    #      before_action, a Current attribute, a custom session lookup).
    #
    #   2. The Warden proxy on the probe request's own env, read through
    #      Warden's public Proxy#user. For a Devise application this is the
    #      same object Devise's own current_<scope> helper returns, and
    #      reading it neither runs authentication strategies nor mutates the
    #      request (Proxy#user only deserializes an existing session, unlike
    #      Proxy#authenticate).
    #
    # With neither available, Karst reports the observation as unobservable
    # rather than assuming the requested identity was the one that ran.
    module Observer
      UNCONFIGURED = "no runtime identity observation seam is available; " \
                     "configure config.observe_identity (or use Karst's Devise/Warden integration)"

      class << self
        def observe(env, requested: nil)
          return unobservable("the probe request environment was not captured") unless env.is_a?(Hash)

          hook = Karst.config.observe_identity
          return observe_with_hook(hook, env) if hook
          return observe_with_warden(env, requested) if warden_proxy(env)

          unobservable(UNCONFIGURED)
        end

        # Public so Identity.describe and observation agree on model naming.
        def model_name_for(klass)
          Naming.model_name_for(klass)
        end

        private

        def observe_with_hook(hook, env)
          raise ConfigurationError, "config.observe_identity must be callable" unless hook.respond_to?(:call)

          observed(hook.call(context_for(env)), :configured)
        rescue ConfigurationError
          raise
        rescue StandardError => e
          unobservable("config.observe_identity raised #{e.class}: #{e.message}")
        end

        def context_for(env)
          ObservationContext.new(controller: env["action_controller.instance"],
                                 request: action_dispatch_request(env), env: env)
        end

        def action_dispatch_request(env)
          return nil unless defined?(ActionDispatch::Request)

          ActionDispatch::Request.new(env)
        rescue StandardError
          nil
        end

        # Every scope the application might have authenticated under, most
        # likely first: the requested principal's own Devise scope, then every
        # other registered one (so an anonymous probe contaminated under some
        # *other* scope is still seen), then Warden's own default scope for a
        # plain non-Devise Warden setup.
        def observe_with_warden(env, requested)
          proxy = warden_proxy(env)
          scopes(requested).each do |scope|
            user = scope ? proxy.user(scope: scope) : proxy.user
            return observed(user, :warden) if user
          end
          Observation.new(principal: nil, source: :warden, error: nil)
        rescue StandardError => e
          unobservable("reading the Warden proxy raised #{e.class}: #{e.message}")
        end

        def scopes(requested)
          registered = DeviseSupport.mappings.map(&:scope)
          return [nil] if registered.empty?

          preferred = requested && DeviseSupport.mapping_for(requested.class)&.scope
          ([preferred] + registered).compact.uniq
        end

        # false and nil both mean "the application resolved no principal";
        # anything that cannot state a stable identity is unobservable rather
        # than silently reported as some principal.
        def observed(value, source)
          return Observation.new(principal: nil, source: source, error: nil) if value.nil? || value == false

          id = identifier_of(value)
          return unobservable("the observed principal (#{value.class}) has no usable id", source: source) if id.nil?

          Observation.new(principal: ObservedPrincipal.new(model_name: model_name_for(value.class), id: id),
                          source: source, error: nil)
        rescue StandardError => e
          unobservable("describing the observed principal raised #{e.class}: #{e.message}", source: source)
        end

        def identifier_of(value)
          value.respond_to?(:id) ? value.id : nil
        end

        def warden_proxy(env)
          proxy = env["warden"]
          proxy if proxy.respond_to?(:user)
        end

        def unobservable(message, source: nil)
          Observation.new(principal: nil, source: source, error: message)
        end
      end
    end
  end
end
