# frozen_string_literal: true

require_relative "locality"
require_relative "panel"
require_relative "badge"
require "rack/utils"
require "active_support/notifications"
require "active_support/isolated_execution_state"

module Karst
  module Web
    # Owns Karst's development-only HTTP evidence surface directly at the Rack
    # boundary, rather than through a Rails engine. An engine would mount routes,
    # load ActionView, and integrate into the host application's controller
    # stack; Karst needs none of that to answer "what evidence does Karst
    # currently hold," and all of it would blur the line between Karst's own
    # page and the host application it is inspecting.
    #
    # Beyond serving /karst itself, this middleware also gives every other
    # development HTML response a tiny link back into /karst, already scoped
    # to the controller/action that produced it (see Badge). Karst sees a
    # request before Rails routes it, so the controller/action that will
    # eventually handle it is not yet known -- that evidence only exists once
    # ActionController has actually dispatched the request, and is captured
    # here via a real process_action.action_controller notification rather
    # than guessed from the request path. Request-local state, not global
    # mutable state, carries that evidence from the notification callback
    # (which fires nested inside @app.call, on whatever thread or fiber is
    # serving this request) back out to the code injecting the badge, so
    # concurrent Puma requests never cross-contaminate each other's context.
    class Middleware
      OWNED_PATH = "/karst"
      private_constant :OWNED_PATH

      CONTEXT_KEY = :karst_web_request_context
      private_constant :CONTEXT_KEY

      def initialize(app)
        @app = app
        @locality = Locality.new
        self.class.ensure_context_capture!
      end

      def call(env)
        if owned?(env)
          return @app.call(env) unless development? && @locality.local?(env["REMOTE_ADDR"])

          return Panel.render(params: Rack::Utils.parse_nested_query(env["QUERY_STRING"].to_s))
        end

        return @app.call(env) unless development? && @locality.local?(env["REMOTE_ADDR"])

        call_with_badge(env)
      end

      private

      def call_with_badge(env)
        ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = nil
        status, headers, body = @app.call(env)
        context = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]

        Badge.apply(status: status, headers: headers, body: body, context: context) || [status, headers, body]
      ensure
        ActiveSupport::IsolatedExecutionState.delete(CONTEXT_KEY)
      end

      def owned?(env)
        env["PATH_INFO"] == OWNED_PATH
      end

      # Re-checked per request as defense in depth: the middleware is only
      # inserted into the stack in development (see Railtie), but this keeps
      # that guarantee independent of how or when the middleware was inserted.
      def development?
        Rails.env.development?
      end

      class << self
        # One subscription for the process lifetime of this middleware class,
        # regardless of how many instances Rack::Builder creates: the
        # notification is process-wide by nature, and its callback only ever
        # writes into the current thread/fiber's own IsolatedExecutionState
        # slot, so a single subscription safely serves every request.
        def ensure_context_capture!
          @context_capture_mutex ||= Mutex.new
          @context_capture_mutex.synchronize do
            next if @context_capture_installed

            ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
              capture_context(args.last)
            end
            @context_capture_installed = true
          end
        end

        private

        def capture_context(payload)
          return unless payload.respond_to?(:[])

          ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = Badge::Context.new(
            controller: payload[:controller], action: payload[:action],
            http_method: payload[:method], path: strip_query(payload[:path])
          )
        rescue StandardError
          nil
        end

        # Mirrors Karst::Spec::Observer's own treatment of request paths: a
        # query string can carry a token (password reset, OAuth callback,
        # signed URL), and this path is only ever contextual display evidence
        # in the panel, never route identity, so it is never worth the risk.
        def strip_query(value)
          value.to_s.split("?").first
        end
      end
    end
  end
end
