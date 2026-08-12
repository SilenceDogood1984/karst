# frozen_string_literal: true

require "securerandom"
require "active_support/security_utils"

module Karst
  module Web
    # Synchronizer-token protection for state-changing forms served directly
    # from Karst's Rack middleware, where Action Controller CSRF is unavailable.
    class Csrf
      TOKEN_KEY = "karst.csrf_token"

      class InvalidToken < StandardError; end

      def initialize(request)
        @request = request
      end

      def token
        session[TOKEN_KEY] ||= SecureRandom.hex(32)
      end

      def verify!(submitted)
        expected = session[TOKEN_KEY]
        valid = expected && submitted && expected.bytesize == submitted.bytesize &&
                ActiveSupport::SecurityUtils.secure_compare(expected, submitted)
        raise InvalidToken, "invalid Karst CSRF token" unless valid
      end

      def rotate!
        session[TOKEN_KEY] = SecureRandom.hex(32)
      end

      private

      def session
        @request.session
      rescue StandardError
        raise InvalidToken, "a writable Rack session is required"
      end
    end
  end
end
