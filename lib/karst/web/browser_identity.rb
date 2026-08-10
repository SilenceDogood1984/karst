# frozen_string_literal: true

require "securerandom"
require "uri"
require "active_support/security_utils"

module Karst
  module Web
    # State-changing browser identity operations and their same-session CSRF
    # token. Rails controller CSRF is unavailable because /karst is served at
    # the Rack boundary, before Action Controller dispatch.
    class BrowserIdentity
      TOKEN_KEY = "karst.csrf_token"
      ACTIVE_KEY = "karst.browser_identity_active"

      def initialize(request)
        @request = request
      end

      def token
        session[TOKEN_KEY] ||= SecureRandom.hex(32)
      end

      def active?
        session[ACTIVE_KEY] == true
      end

      def assume(params)
        verify_token!(params["csrf_token"])
        principal = Identity.resolve(model_name: params["principal_type"], id: params["principal_id"])
        raise Identity::Unavailable, "principal is not in the configured source" unless principal

        Identity.assume_browser(@request, principal)
        session[ACTIVE_KEY] = true
        return_path(params["path"])
      end

      def clear(params)
        verify_token!(params["csrf_token"])
        Identity.clear_browser(@request)
        session.delete(ACTIVE_KEY)
        return_path(params["path"])
      end

      private

      def session
        @request.session
      rescue StandardError
        raise Identity::Unavailable, "a writable Rack session is required"
      end

      def verify_token!(submitted)
        expected = session[TOKEN_KEY]
        valid = expected && submitted && expected.bytesize == submitted.bytesize &&
                ActiveSupport::SecurityUtils.secure_compare(expected, submitted)
        raise Identity::Unavailable, "invalid Karst CSRF token" unless valid
      end

      def return_path(value)
        raw = value.to_s.split("?", 2).first
        uri = URI.parse(raw)
        valid = uri.relative? && raw.start_with?("/") && !raw.start_with?("//")
        raise Identity::Unavailable, "return path must be a local application path" unless valid

        raw
      rescue URI::InvalidURIError
        raise Identity::Unavailable, "return path must be a valid local application path"
      end
    end
  end
end
