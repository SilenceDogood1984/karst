# frozen_string_literal: true

require "uri"
require_relative "csrf"

module Karst
  module Web
    # State-changing browser identity operations. Synchronizer-token behavior
    # belongs to Web::Csrf and is shared with other Rack-boundary forms.
    class BrowserIdentity
      ACTIVE_KEY = "karst.browser_identity_active"

      # The exact Devise/Warden scope the currently assumed identity was
      # established under (see Identity.assume_browser), retained for the
      # lifetime of the browser session so #clear can hand it straight back
      # to Identity.clear_browser instead of that having to guess which of
      # several selected sources produced the principal being cleared.
      SCOPE_KEY = "karst.browser_identity_scope"

      def initialize(request, csrf: Csrf.new(request))
        @request = request
        @csrf = csrf
      end

      def token
        @csrf.token
      end

      def active?
        session[ACTIVE_KEY] == true
      end

      def assume(params)
        verify_token!(params["csrf_token"])
        target = return_path(params["path"])
        principal = Identity.resolve(model_name: params["principal_type"], id: params["principal_id"])
        raise Identity::Unavailable, "principal is not in the configured source" unless principal

        scope = Identity.assume_browser(@request, principal)
        # Authentication hooks may clear or replace the host session. Rebuild
        # Karst's control state only after that transition, and invalidate the
        # token which authorized it rather than carrying pre-assumption state
        # into the assumed identity.
        session[ACTIVE_KEY] = true
        session[SCOPE_KEY] = scope&.to_s
        rotate_token!
        target
      end

      def clear(params)
        verify_token!(params["csrf_token"])
        target = return_path(params["path"])
        scope = session[SCOPE_KEY]
        Identity.clear_browser(@request, scope: scope&.to_sym)
        session.delete(ACTIVE_KEY)
        session.delete(SCOPE_KEY)
        target
      end

      private

      def session
        @request.session
      rescue StandardError
        raise Identity::Unavailable, "a writable Rack session is required"
      end

      def verify_token!(submitted)
        @csrf.verify!(submitted)
      rescue Csrf::InvalidToken => e
        raise Identity::Unavailable, e.message
      end

      def rotate_token!
        @csrf.rotate!
      end

      # A blank path is not a caller error: the panel renders this same
      # hidden field for "Stop testing as" from a plain /karst visit with no
      # ?path= in the query string (bookmarked, or reached without a route
      # already selected) -- exactly what happens right after Test As
      # navigates the browser away to the tested page and a developer comes
      # back to /karst directly. Falling back to /karst itself keeps that
      # button working instead of raising and leaving the assumed identity
      # active.
      def return_path(value)
        return "/karst" if value.to_s.empty?

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
