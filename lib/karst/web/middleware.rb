# frozen_string_literal: true

require_relative "locality"
require_relative "panel"
require_relative "badge"
require_relative "browser_identity"
require_relative "route_lookup"
require_relative "../execution_context"
require "rack/utils"
require "rack/request"
require "active_support/notifications"
require_relative "../access/sweep"
require_relative "../access/principal_sampler"

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
    # rubocop:disable Metrics/ClassLength
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
        return call_owned(env) if owned?(env)

        return @app.call(env) unless development? && @locality.local?(env["REMOTE_ADDR"])

        call_with_badge(env)
      end

      private

      def call_owned(env)
        return @app.call(env) unless development? && @locality.local?(env["REMOTE_ADDR"])

        params = owned_params(env)
        lookup = recognize_manual_route(env, params)
        params = lookup.params if lookup
        browser_identity = BrowserIdentity.new(Rack::Request.new(env))
        identity_response = mutate_browser_identity(env, params, browser_identity)
        return identity_response if identity_response

        Panel.render(params: params, access_result: analyze(env, params), route_lookup_limitation: lookup&.limitation,
                     csrf_token: browser_token(browser_identity),
                     browser_identity_active: browser_identity_active?(browser_identity))
      end

      def call_with_badge(env)
        Karst::ExecutionContext[CONTEXT_KEY] = nil
        status, headers, body = @app.call(env)
        context = Karst::ExecutionContext[CONTEXT_KEY]

        Badge.apply(status: status, headers: headers, body: body, context: context) || [status, headers, body]
      ensure
        Karst::ExecutionContext.delete(CONTEXT_KEY)
      end

      def owned?(env)
        env["PATH_INFO"] == OWNED_PATH
      end

      def owned_params(env)
        query = Rack::Utils.parse_nested_query(env["QUERY_STRING"].to_s)
        return query unless env["REQUEST_METHOD"] == "POST"

        query.merge(Rack::Request.new(env).POST)
      end

      def recognize_manual_route(env, params)
        return unless env["REQUEST_METHOD"] == "GET" && params["operation"] == "route_lookup"

        RouteLookup.new(path: params["path"], http_method: params["method"]).call
      end

      def analyze(env, params)
        return nil unless env["REQUEST_METHOD"] == "POST" && params["operation"] == "access_sweep"

        sampled = Access::PrincipalSampler.new(source: Identity.principals).call
        Access::Sweep.new(path: params["path"], http_method: params["method"], principals: sampled.principals).call
      rescue Access::Error, Identity::Error, ArgumentError => e
        e
      end

      def mutate_browser_identity(env, params, browser_identity)
        return unless env["REQUEST_METHOD"] == "POST"

        path = case params["operation"]
               when "test_as" then browser_identity.assume(params)
               when "stop_test_as" then browser_identity.clear(params)
               end
        path && [303, { "location" => path, "cache-control" => "no-store" }, []]
      rescue Identity::Error
        [403, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, ["Forbidden"]]
      end

      def browser_token(browser_identity)
        browser_identity.token if Identity.browser_supported?
      rescue Identity::Error
        nil
      end

      def browser_identity_active?(browser_identity)
        Identity.browser_supported? && browser_identity.active?
      rescue Identity::Error
        false
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

          Karst::ExecutionContext[CONTEXT_KEY] = Badge::Context.new(
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
    # rubocop:enable Metrics/ClassLength
  end
end
