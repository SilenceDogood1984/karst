# frozen_string_literal: true

module Karst
  module Identity
    # Optional convenience for a request-like object whose Rack environment
    # already contains a Warden proxy. Warden cannot be bootstrapped safely
    # from a bare ActionDispatch::Integration::Session, so applications using
    # those sessions should configure explicit hooks (usually test endpoints).
    class WardenAdapter
      def assume(session, principal)
        proxy_for(session).set_user(principal)
      end

      def clear(session)
        proxy_for(session).logout
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
