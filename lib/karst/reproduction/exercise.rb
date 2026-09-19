# frozen_string_literal: true

require "json"
require "active_support/notifications"
require "rack/utils"
require_relative "observation"
require_relative "sanitizer"
require_relative "../access/errors"
require_relative "../access/local_path"
require_relative "../access/probe_application"
require_relative "../access/database_isolation"
require_relative "../access/identity_probe"
require_relative "../identity"

module Karst
  module Reproduction
    # Issues exactly one request against the real application and reports what
    # happened.
    #
    # This is deliberately not Access::Sweep with the GET restriction lifted.
    # A sweep runs one route as up to 25 different users to answer "who can
    # reach this"; running a mutating method that way would mean 25 real
    # creates, 25 enqueued jobs, and 25 delivered mails, which is exactly why
    # Sweep refuses anything but GET and will keep refusing. Reproduction
    # answers a different question -- "what request exercises this behavior"
    # -- and one request is the entire answer, so the blast radius is one
    # request, always explicitly asked for, never automatic.
    #
    # Containment is the same same-connection rollback Access::Sweep and
    # Access::DatabaseIsolation use, with the same honest limit: database
    # writes on this connection are rolled back; jobs, mail, outbound HTTP,
    # files, and other connections are not. Callers are expected to say so
    # out loud, and every Karst surface that exposes this does.
    #
    # Identity runs through the exact same lifecycle Access::Sweep uses --
    # Access::IdentityProbe, wrapping the probe endpoint in an
    # Access::ObservedEndpoint so halt-time observation is possible -- rather
    # than a second reproduction-specific identity implementation. `principal`
    # is requested identity (intent); the Observation this class returns
    # carries a Karst::Identity::Evidence, never a bare echo of what was
    # asked for. A caller that wants a genuinely anonymous probe passes
    # Karst::Identity::ANONYMOUS (the default): Karst then establishes no
    # identity and verifies at runtime that the application resolved none,
    # exactly as an anonymous verify_access probe does -- a bare absence of a
    # principal is not the same claim.
    # rubocop:disable Metrics/ClassLength
    class Exercise
      METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze

      JSON_CONTENT_TYPE = %r{\Aapplication/(?:[\w.+-]+\+)?json\b}i
      private_constant :JSON_CONTENT_TYPE

      FORM_CONTENT_TYPE = %r{\Aapplication/x-www-form-urlencoded\b}i
      private_constant :FORM_CONTENT_TYPE

      # Exactly ActionDispatch::Http::Headers' own idea of a header name.
      # Anything outside this shape is passed through to the Rack env
      # verbatim by Http::Headers#[]= rather than being prefixed with
      # HTTP_, so a name like "rack.session" or "action_dispatch.request.
      # parameters" would not be a header at all -- it would be a caller
      # writing directly into the request environment Karst is supposed to
      # be observing.
      HEADER_NAME = /\A[A-Za-z0-9-]+\z/
      private_constant :HEADER_NAME

      # CGI variables Http::Headers maps a header name onto directly instead
      # of prefixing. Letting a caller set these would let the request Karst
      # issues differ from the request Karst reports -- a recipe describing a
      # request nobody made. CONTENT_TYPE is deliberately absent: it is a
      # real request header, and Karst sets it itself from `content_type`.
      RESERVED = %w[
        AUTH_TYPE CONTENT_LENGTH GATEWAY_INTERFACE HTTPS PATH_INFO PATH_TRANSLATED QUERY_STRING
        REMOTE_ADDR REMOTE_HOST REMOTE_IDENT REMOTE_USER REQUEST_METHOD SCRIPT_NAME
        SERVER_NAME SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE
      ].freeze
      private_constant :RESERVED

      # rubocop:disable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength
      def initialize(path:, http_method: "GET", body: nil, content_type: nil, headers: {},
                     principal: Karst::Identity::ANONYMOUS, application: nil)
        @http_method = http_method.to_s.strip.upcase
        raise Access::UnsupportedMethod, "unsupported HTTP method" unless METHODS.include?(@http_method)

        target = Access::LocalPath.parse(path)
        @path = target.path
        @query_params = Rack::Utils.parse_nested_query(target.query.to_s)
        @body = body.to_s.empty? ? nil : body.to_s
        @content_type = content_type.to_s.strip
        raise ArgumentError, "a content type is required when sending a request body" if @body && @content_type.empty?

        @headers = normalize_headers(headers)
        # A bare nil is treated exactly like Karst::Identity::ANONYMOUS
        # (the default) rather than as some third, identity-lifecycle-free
        # state: a caller that passes no principal still gets a real
        # anonymous probe, with the application's own runtime state verified
        # rather than silently assumed.
        @identity = Access::IdentityProbe.new(principal || Karst::Identity::ANONYMOUS)
        @application = application || Rails.application
        @probe_application = build_probe_application
      end
      # rubocop:enable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength

      def call
        raise Access::Unavailable, "request reproduction is development-only" unless Rails.env.development?
        raise Access::Unavailable, "Karst is disabled (config.enabled)" unless Karst.enabled?

        require "action_dispatch/testing/integration" unless defined?(ActionDispatch::Integration::Session)

        observe
      end

      private

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def observe
        session = ActionDispatch::Integration::Session.new(@identity.endpoint(@probe_application))
        configure_host(session)
        started = monotonic
        @writes = 0
        @halted_callback = nil
        @dispatch = nil
        @status = @redirect = @exception_class = @response_content_type = nil
        @route = { raw: {}, sanitized: {}, observed: false }

        with_rollback do
          # Never raises: a probe whose identity could not be established
          # still runs, and reports what the application actually saw.
          @identity.establish(session)
          begin
            subscribed do
              issue(session)
            end
          ensure
            begin
              # Strictly before release: clearing the identity is exactly
              # what would make a completed request look anonymous.
              @identity.observe(:request_completion)
              capture_target(session)
            ensure
              @identity.release(session)
            end
          end
        rescue StandardError => e
          @exception_class = e.class.name
        end

        build(elapsed(started))
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      # The query string travels in the target, exactly as a real client
      # sends it; `params` carries only the request body, so a GET never
      # grows a body it was not given.
      def issue(session)
        session.process(@http_method.downcase.to_sym, target, params: @body, headers: outgoing_headers)
      end

      def target
        query = Rack::Utils.build_nested_query(@query_params)
        query.empty? ? @path : "#{@path}?#{query}"
      end

      def outgoing_headers
        headers = @headers.dup
        headers["Content-Type"] = @content_type unless @content_type.empty?
        headers
      end

      # Notification subscriptions are process-wide, so every observer below
      # ignores anything raised on another thread: a concurrent request in a
      # real development server must never be mistaken for this
      # reproduction's own evidence.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def subscribed(&block)
        thread = Thread.current
        writes = lambda do |_name, _start, _finish, _id, payload|
          @writes += 1 if thread.equal?(Thread.current) && Access::DatabaseIsolation.mutation?(payload[:sql])
        end
        halts = lambda do |_name, _start, _finish, _id, payload|
          next unless thread.equal?(Thread.current)

          @halted_callback ||= payload[:filter]
          # The identity the application had established when this access
          # decision was made -- not after the request unwound.
          @identity.observe(:halted_callback)
        end
        dispatches = lambda do |_name, _start, _finish, _id, payload|
          @dispatch = payload if thread.equal?(Thread.current)
        end

        ActiveSupport::Notifications.subscribed(writes, "sql.active_record") do
          ActiveSupport::Notifications.subscribed(halts, "halted_callback.action_controller") do
            ActiveSupport::Notifications.subscribed(dispatches, "process_action.action_controller", &block)
          end
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def read_response(session)
        rendered = request_exception(session)
        return @exception_class = rendered.class.name if rendered

        @status = session.response.status
        @redirect = clean_redirect(session.response.location) if @status >= 300 && @status < 400
        @response_content_type = response_content_type(session)
      end

      # Integration::Session is intentionally reused for identity setup,
      # the target, and cleanup so cookies behave like one real client. Its
      # request and response pointers therefore always describe the most
      # recent request. Copy the target-owned values while the target is
      # still current; cleanup may then mutate the session without becoming
      # reproduction evidence.
      def capture_target(session)
        read_response(session)
        @route = route_params(session)
      end

      # rubocop:disable Metrics/MethodLength
      def build(elapsed_ms)
        route = @route
        body_params, representation = body_state
        response_type = @response_content_type
        Observation.new(
          http_method: @http_method, url_path: displayed_path(route), query_params: sanitized_query,
          route_params: route[:sanitized], body_params: body_params, body_representation: representation,
          content_type: @content_type.empty? ? nil : @content_type, headers: Sanitizer.headers(outgoing_headers),
          controller: dispatched(:controller), action: dispatched(:action),
          status: @status, response_content_type: response_type, redirect: @redirect,
          halted_callback: @halted_callback&.to_s, exception_class: @exception_class,
          writes_observed: @writes.positive?, write_count: @writes, database_rollback_attempted: true,
          elapsed_ms: elapsed_ms, identity: @identity.evidence,
          unobserved: unobserved(route, response_type).freeze
        )
      end
      # rubocop:enable Metrics/MethodLength

      def dispatched(key)
        value = @dispatch && @dispatch[key]
        value.to_s.empty? ? nil : value.to_s
      end

      def unobserved(route, response_type)
        missing = []
        missing << "controller" unless dispatched(:controller)
        missing << "action" unless dispatched(:action)
        missing << "route_params" unless route[:observed]
        missing << "status" if @status.nil?
        missing << "response_content_type" if response_type.nil?
        missing
      end

      # The router's own path_parameters, read back off the request Karst
      # just made -- observed routing, not a second recognize_path guess that
      # could disagree with what actually dispatched. Absent (a 404, a
      # routing error) means Karst observed no route, which is reported as
      # such rather than filled in.
      def route_params(session)
        raw = session.request.path_parameters
        return { raw: {}, sanitized: {}, observed: false } unless raw.is_a?(Hash) && !raw.empty?

        raw = raw.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value unless %w[controller action].include?(key.to_s)
        end
        { raw: raw, sanitized: sanitize(raw), observed: true }
      rescue StandardError
        { raw: {}, sanitized: {}, observed: false }
      end

      # A path segment that turned out to be a credential (a password-reset
      # token, a signed id) is still sitting in the URL after the parameter
      # itself was masked. Substituting the placeholder back into the path
      # keeps the generated command from leaking through the one channel
      # parameter filtering does not cover.
      def displayed_path(route)
        route[:sanitized].reduce(@path) do |path, (name, value)|
          raw = route[:raw][name]
          next path unless Sanitizer.masked?(value) && raw.is_a?(String) && !raw.empty?

          path.gsub(raw, "<#{name.upcase}>")
        end
      end

      def sanitized_query
        sanitize(@query_params)
      end

      def sanitize(params)
        Sanitizer.parameters(params, filters: filter_parameters)
      end

      # The reproduced application's own filter_parameters, never a global:
      # Karst issued this request against @application, so @application's
      # rules are the ones that decide what may be shown back.
      def filter_parameters
        @application.config.filter_parameters
      rescue StandardError
        nil
      end

      def body_state
        return [{}, :none] unless @body
        return [sanitize(parsed_json), :json] if json_body?
        return [sanitize(Rack::Utils.parse_nested_query(@body)), :form] if form_body?

        [{}, :opaque]
      rescue JSON::ParserError
        [{}, :opaque]
      end

      def json_body?
        @content_type.match?(JSON_CONTENT_TYPE) && parsed_json.is_a?(Hash)
      end

      def form_body?
        @content_type.match?(FORM_CONTENT_TYPE)
      end

      def parsed_json
        @parsed_json ||= JSON.parse(@body)
      end

      def response_content_type(session)
        value = session.response.content_type if session.response.respond_to?(:content_type)
        value.to_s.empty? ? nil : value.to_s
      rescue StandardError
        nil
      end

      def normalize_headers(headers)
        (headers || {}).each_with_object({}) do |(name, value), result|
          key = name.to_s.strip
          next if key.empty?

          raise ArgumentError, "#{key.inspect} is not a request header name" unless header_name?(key)

          result[key] = value.to_s
        end
      end

      def header_name?(name)
        name.match?(HEADER_NAME) && !RESERVED.include?(name.upcase.tr("-", "_"))
      end

      def with_rollback
        raise Access::Unavailable, "Active Record rollback isolation is unavailable" unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
      end

      def build_probe_application
        Access::ProbeApplication.for(@application)
      rescue Access::ProbeApplication::ConstructionError => e
        raise Access::Unavailable, e.message, cause: e
      end

      def configure_host(session)
        return unless @probe_application.respond_to?(:host) && @probe_application.host

        session.host!(@probe_application.host)
      end

      def request_exception(session)
        return unless session.respond_to?(:request) && session.request

        session.request.get_header("action_dispatch.exception")
      end

      def clean_redirect(location)
        return nil if location.to_s.empty?

        URI.parse(location).tap { |uri| uri.query = nil }.to_s
      rescue URI::InvalidURIError
        location.to_s.split("?", 2).first
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed(started)
        ((monotonic - started) * 1000.0).round(1)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
