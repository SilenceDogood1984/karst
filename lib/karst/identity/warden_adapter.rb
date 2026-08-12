# frozen_string_literal: true

require_relative "../execution_context"

module Karst
  module Identity
    # Optional convenience for a request-like object whose Rack environment
    # already contains a Warden proxy. Warden cannot be bootstrapped safely
    # from a bare ActionDispatch::Integration::Session, so applications using
    # those sessions should configure explicit hooks (usually test endpoints).
    #
    # `scope:` is the Warden/Devise scope (e.g. `:user`, `:admin`) this
    # adapter operates under. When known (see DeviseSupport), it is always
    # passed explicitly rather than relying on Warden's own default scope --
    # a Devise app almost always protects routes with a specific scope, and
    # guessing wrong would silently authenticate under the wrong one. When
    # nil, `set_user`/`logout` are called without a scope, matching Warden's
    # own default behavior for a plain, non-Devise Warden setup.
    class WardenAdapter
      # Karst::Identity.with calls #assume before the caller's own block ever
      # issues a request, so no env["warden"] proxy can exist yet -- Warden
      # only builds one inside Warden::Manager#call, once a request actually
      # reaches it (see Access::ProbeApplication). #assume therefore queues
      # the principal here instead of reaching for a proxy that cannot exist,
      # and .install_hook! below applies it the moment this exact thread's
      # own probe request reaches Warden -- the same queue-for-next-request
      # idiom Warden::Test::Helpers#login_as and
      # Devise::Test::IntegrationHelpers#sign_in use for the identical
      # problem in integration tests. Karst uses its own thread-local
      # ExecutionContext instead of Warden's own global Test::Helpers queue,
      # so this stays scoped to the exact thread that queued it -- a
      # concurrent unrelated request on another thread of a real development
      # server never observes it.
      PENDING_PRINCIPAL_KEY = :karst_warden_pending_principal
      private_constant :PENDING_PRINCIPAL_KEY

      class << self
        # Registered once per process (Warden::Hooks callbacks are
        # class-level, so this necessarily runs for every Warden::Manager
        # instance, including the host application's own) and is a no-op
        # unless this exact thread has a principal queued. The real Warden
        # gem always provides Warden::Manager.on_request (Warden::Hooks is
        # core, not an extra); the guard exists only so a minimal
        # Warden::Manager stand-in (a bare stub Class, as several existing
        # specs use to exercise ambiguous-Devise-setup paths that never
        # reach this code) can't crash Karst with a NoMethodError instead of
        # deferral simply staying unavailable, same as before this existed.
        def hook_installable?
          defined?(Warden::Manager) && Warden::Manager.respond_to?(:on_request)
        end

        def install_hook!
          return if @installed

          @installed = true
          Warden::Manager.on_request do |proxy|
            pending = Karst::ExecutionContext.delete(PENDING_PRINCIPAL_KEY)
            next unless pending

            principal, scope = pending
            scope ? proxy.set_user(principal, scope: scope) : proxy.set_user(principal)
          end
        end
      end

      attr_reader :scope

      def initialize(scope: nil)
        @scope = scope
      end

      def assume(session, principal)
        proxy = existing_proxy(session)
        return apply(proxy, principal) if proxy
        return queue_for_next_request(principal) if deferrable?(session)

        raise Unavailable, "the session has no initialized Warden proxy; configure identity hooks"
      end

      def clear(session)
        proxy = proxy_for(session)
        @scope ? proxy.logout(@scope) : proxy.logout
      ensure
        Karst::ExecutionContext.delete(PENDING_PRINCIPAL_KEY)
      end

      private

      def apply(proxy, principal)
        @scope ? proxy.set_user(principal, scope: @scope) : proxy.set_user(principal)
      end

      # Deferral only ever helps a real pre-dispatch integration session --
      # something that will itself later be routed through Warden::Manager,
      # letting .install_hook! consume the queued principal when that
      # happens. A bare Hash (the shape every other caller in this codebase,
      # and custom identity hooks, already use to carry an env["warden"] key
      # directly) has no such future dispatch to defer to, so queuing for it
      # would silently do nothing forever -- raising immediately, as before,
      # is the correct and only honest outcome there.
      def deferrable?(session)
        !session.is_a?(Hash) && session.respond_to?(:request) && self.class.hook_installable?
      end

      def queue_for_next_request(principal)
        self.class.install_hook!
        Karst::ExecutionContext[PENDING_PRINCIPAL_KEY] = [principal, @scope]
      end

      def proxy_for(session)
        existing_proxy(session) ||
          (raise Unavailable, "the session has no initialized Warden proxy; configure identity hooks")
      end

      def existing_proxy(session)
        env = rack_env(session)
        proxy = env && env["warden"]
        proxy if proxy.respond_to?(:set_user) && proxy.respond_to?(:logout)
      end

      def rack_env(session)
        return session if session.is_a?(Hash)
        return session.env if session.respond_to?(:env)
        return session.request.env if session.respond_to?(:request) && session.request.respond_to?(:env)

        nil
      end
    end
  end
end
