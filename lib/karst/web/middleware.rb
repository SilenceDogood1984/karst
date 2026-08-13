# frozen_string_literal: true

require_relative "locality"
require_relative "panel"
require_relative "populations_panel"
require_relative "badge"
require_relative "browser_identity"
require_relative "csrf"
require_relative "route_lookup"
require_relative "../execution_context"
require "rack/utils"
require "rack/request"
require "json"
require "active_support/notifications"
require_relative "../access/sweep"
require_relative "../access/search"
require_relative "../access/principal_selection"
require_relative "../access/candidate_population"
require_relative "../access/population_discovery"
require_relative "../access/population_approvals"
require_relative "../access/approved_populations"
require_relative "../access/principal_source_selection"
require_relative "../access/population_approval"
require_relative "../access/population_revocation"
require_relative "../identity/devise_support"

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

      POPULATIONS_PATH = "/karst/populations"
      private_constant :POPULATIONS_PATH

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

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def call_owned(env)
        return @app.call(env) unless development? && @locality.local?(env["REMOTE_ADDR"])
        return call_populations(env) if env["PATH_INFO"] == POPULATIONS_PATH

        params = owned_params(env)
        lookup = recognize_manual_route(env, params)
        params = lookup.params if lookup
        selection, denied = principal_source_selection_result(env, params)
        return denied if denied

        request = Rack::Request.new(env)
        csrf = Csrf.new(request)
        browser_identity = BrowserIdentity.new(request, csrf: csrf)
        approval, denied = inline_population_approval_result(env, params, csrf)
        return denied if denied

        identity_response = mutate_browser_identity(env, params, browser_identity)
        return identity_response if identity_response

        result = analyze(env, params, approval: approval)
        candidates = inline_population_candidates(result)
        Panel.render(params: params, access_result: result, route_lookup_limitation: lookup&.limitation,
                     csrf_token: csrf_token(csrf),
                     browser_identity_active: browser_identity_active?(browser_identity),
                     unapproved_candidates: candidates, population_approval_error: approval&.error,
                     principal_source_selection_saved: !selection.nil? && selection.error.nil?,
                     principal_source_selection_error: selection&.error)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # [selection_record, nil] once saved, [nil, forbidden_response] when an
      # attempted save was refused, or [nil, nil] for any other operation.
      # Unlike every other operation Karst serves at /karst, saving a
      # selection writes local state that outlives the request -- exactly
      # like approving a candidate population -- and this page issues no
      # CSRF token of its own precisely while ambiguous
      # (Identity.browser_supported? is false until a selection resolves the
      # ambiguity), so the check is same-origin rather than token-based; see
      # #approved_origin?.
      def principal_source_selection_result(env, params)
        return [nil, nil] unless saving_principal_source_selection?(env, params)
        return [nil, forbidden] unless approved_origin?(env)

        [save_principal_source_selection(params), nil]
      end

      def saving_principal_source_selection?(env, params)
        env["REQUEST_METHOD"] == "POST" && params["operation"] == "select_principal_sources"
      end

      def inline_population_approval_result(env, params, csrf)
        return [nil, nil] unless env["REQUEST_METHOD"] == "POST" && params["operation"] == "approve_populations"
        return [nil, forbidden] unless approved_origin?(env)

        csrf.verify!(params["csrf_token"])
        discovery = Access::PopulationDiscovery.new.call
        approval = Access::PopulationApproval.new(discovery: discovery, principal_sources: Identity.principal_sources,
                                                  submitted: params["population"]).call
        [approval, nil]
      rescue Csrf::InvalidToken, Identity::Error
        [nil, forbidden]
      end

      # Only a model Devise itself currently maps can ever be written --
      # exactly like candidate-population approval only ever writes a
      # currently discovered scope -- so this form can never seed the file
      # with an arbitrary submitted class name.
      def save_principal_source_selection(params)
        submitted = Array(params["principal"]).map(&:to_s)
        names = Identity::DeviseSupport.mappings.map { |mapping| mapping.model.name }
                                       .select { |name| submitted.include?(name) }
        Access::PrincipalSourceSelection.replace(names)
      end

      # Revocation changes local state that outlives the request, so every
      # POST to this path must
      # have come from Karst's own page. There is no Rack session to hang a
      # CSRF token on here (this page deliberately touches none), so the
      # check is same-origin rather than token-based; a cross-site form POST
      # cannot forge Origin, so it cannot revoke anything. GET -- the page
      # itself -- stays unauthenticated exactly like /karst.
      def call_populations(env)
        return forbidden unless approved_origin?(env)

        params = owned_params(env)
        revoking = env["REQUEST_METHOD"] == "POST" && params["operation"] == "revoke_population"
        result = Access::PopulationRevocation.new(submitted: params["population"]).call if revoking
        record = result&.record || Access::PopulationApprovals.load
        render_populations(record, result&.revoked)
      end

      def render_populations(record, revoked)
        Web::PopulationsPanel.render(
          approved: record.entries, stale: stale_approvals(record),
          storage_path: Access::PopulationApprovals.display_path, storage_error: record.error, revoked: revoked
        )
      end

      def stale_approvals(record)
        Access::ApprovedPopulations.stale(safe_principal_sources, record: record)
      rescue StandardError
        [].freeze
      end

      def safe_principal_sources
        Identity.principal_sources
      rescue Identity::Error
        {}
      end

      # An absent Origin (a non-browser client, or an older browser that
      # only sends Referer) falls back to Referer; a POST carrying neither
      # is refused rather than trusted.
      def approved_origin?(env)
        return true unless env["REQUEST_METHOD"] == "POST"

        request = Rack::Request.new(env)
        expected = "#{request.scheme}://#{request.host_with_port}"
        origin = env["HTTP_ORIGIN"]
        return origin == expected if origin

        referer = env["HTTP_REFERER"].to_s
        referer == expected || referer.start_with?("#{expected}/")
      end

      def forbidden
        [403, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, ["Forbidden"]]
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
        [OWNED_PATH, POPULATIONS_PATH].include?(env["PATH_INFO"])
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

      # One analysis operation, not two: Access::Search runs the ordinary
      # bounded sample and, only if that finds nothing usable, automatically
      # retries each *approved* candidate population in configuration order
      # (see Karst::Access::Search). There is deliberately no separate
      # "try this population" operation for a developer to press --
      # and no path by which a merely discovered, unapproved population
      # name can be executed.
      def analyze(env, params, approval: nil)
        return nil unless env["REQUEST_METHOD"] == "POST"
        return nil unless params["operation"] == "access_sweep" || approval

        Access::Search.new(path: params["path"], http_method: params["method"],
                           sources: Identity.principal_sources).call
      rescue Access::Error, Identity::Error, ArgumentError => e
        e
      end

      # Application-defined groups on an already-configured user source a
      # developer could still approve. Computed only after an
      # analysis that found nothing usable -- the one moment the answer is
      # actionable -- so an ordinary panel render never parses model source,
      # and the main page stays a contextual approval step rather than a
      # population-management dashboard. Discovery executes nothing.
      def inline_population_candidates(result)
        return [] unless result.is_a?(Access::Search::Result) && result.verified_outcome.nil?

        record = Access::PopulationApprovals.load
        Access::PopulationDiscovery.new.call.candidates.select do |candidate|
          candidate.principal_source && !record.approved?(candidate.model_name, candidate.method_name)
        end
      rescue StandardError
        []
      end

      def mutate_browser_identity(env, params, browser_identity)
        return unless env["REQUEST_METHOD"] == "POST"

        path = case params["operation"]
               when "test_as" then browser_identity.assume(params)
               when "stop_test_as" then browser_identity.clear(params)
               end
        path && identity_navigation_response(env, params, path)
      rescue Identity::Error
        forbidden
      end

      def identity_navigation_response(env, params, path)
        if params["operation"] == "test_as" && env["HTTP_ACCEPT"].to_s.include?("application/json")
          body = JSON.generate(location: path)
          [200, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }, [body]]
        else
          [303, { "location" => path, "cache-control" => "no-store" }, []]
        end
      end

      def csrf_token(csrf)
        csrf.token
      rescue Csrf::InvalidToken
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
      # config.enabled is read live rather than at insertion time, so turning
      # Karst off never depends on initializer ordering.
      def development?
        Rails.env.development? && Karst.enabled?
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

        # A query string can carry a token (password reset, OAuth callback,
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
