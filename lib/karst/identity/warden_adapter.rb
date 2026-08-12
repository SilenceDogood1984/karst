# frozen_string_literal: true

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
      def initialize(scope: nil)
        @scope = scope
      end

      def assume(session, principal)
        proxy = proxy_for(session)
        @scope ? proxy.set_user(principal, scope: @scope) : proxy.set_user(principal)
      end

      def clear(session)
        proxy = proxy_for(session)
        @scope ? proxy.logout(@scope) : proxy.logout
      end

      private

      def proxy_for(session)
        env = rack_env(session)
        proxy = env && env["warden"]
        return proxy if proxy.respond_to?(:set_user) && proxy.respond_to?(:logout)

        raise Unavailable, "the session has no initialized Warden proxy; configure identity hooks"
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
