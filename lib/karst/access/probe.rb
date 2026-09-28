# frozen_string_literal: true

require "active_support/notifications"
require "uri"
require_relative "errors"
require_relative "probe_application"
require_relative "database_isolation"
require_relative "identity_probe"
require_relative "../identity"
require_relative "../value"

module Karst
  module Access
    # The one place Karst executes a request against the application and
    # observes what it did.
    #
    # Access::Sweep ("which identities get through this route?") and
    # Reproduction::Exercise ("what does this exact request do?") issue every
    # request through #call and differ only in what they ask and how they
    # present the answer. So one request, as one identity, against one target
    # produces one observation, whichever feature -- and whichever CLI
    # command, MCP tool, or panel operation above it -- asked.
    #
    # Every probe runs in three phases, and only the middle one is the request
    # under test:
    #
    #   setup     Access::IdentityProbe#establish (sign-in requests and hooks),
    #             plus Karst's own Warden sign-in when it can only be applied
    #             inside the target request itself (see Identity.establishing)
    #   target    exactly one request, observed
    #   teardown  Access::IdentityProbe#release (sign-out requests and hooks)
    #
    # Target evidence -- mutating SQL, the halted callback, the controller
    # lifecycle, renders -- is recorded only by subscriptions that exist for
    # the target request's own duration, only on this thread, and never while
    # Karst is doing its own identity work inside that request. A sign-in
    # that inserts a session row, a sign-out that deletes it, or a Devise
    # :trackable UPDATE is setup/teardown, never the route's behavior; a write
    # the route itself makes always is. Writes are counted when attempted, so
    # the rollback below never erases them from the evidence.
    #
    # All three phases run inside one rollback-only transaction on the same
    # connection -- containment for database writes on that connection and
    # nothing else (jobs, mail, outbound HTTP, files, and other connections are
    # not contained).
    #
    # Three kinds of failure are kept apart rather than folded together:
    #
    #   - The target raising (or rendering a captured exception) is observed
    #     application behavior: exception_class/exception_phase.
    #   - Identity setup failing is identity evidence (identity.establishment
    #     :failed and its error). The target still runs and is still
    #     observed -- except when Karst's own in-request sign-in raised, in
    #     which case the route never ran and nothing is reported for it.
    #   - Karst failing to observe (one of its own subscribers raising, a
    #     misconfigured observe_identity, a request that never reached the
    #     application) fails the call with ObservationError or the
    #     configuration error itself. Evidence Karst could not gather is never
    #     reported as the application having done nothing.
    class Probe
      # The authoritative observation of one target request.
      #
      # controller/action are the controller the target request dispatched to,
      # read from its own Rack env (nil when it reached none).
      # controller_completed is whether process_action finished without an
      # exception (nil when process_action never ran). status, redirect
      # (query-stripped), response_content_type, and route_params (the
      # router's own path_parameters, minus controller/action) are read only
      # when the target completed, so a raising target never inherits an
      # earlier request's response. halted_callback is the filter exactly as
      # Rails reported it. write_count counts mutating SQL statements the
      # target attempted. elapsed_ms covers the whole probe, setup and
      # teardown included.
      Observation = Value.define(
        :identity, :controller, :action, :controller_completed, :status, :redirect, :response_content_type,
        :halted_callback, :exception_class, :exception_phase, :rendered, :write_count, :route_params, :elapsed_ms
      )

      def initialize(application)
        @endpoint = ProbeApplication.for(application)
      rescue ProbeApplication::ConstructionError => e
        raise Unavailable, e.message, cause: e
      end

      # `target` is a local path, including any query string, exactly as it
      # is sent. `body` travels as the request body, never as query
      # parameters.
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def call(principal:, target:, http_method: "GET", body: nil, headers: {})
        identity = IdentityProbe.new(principal)
        session = open_session(identity)
        method = http_method.to_s.downcase.to_sym
        window = TargetWindow.new(identity)
        started = monotonic
        with_rollback do
          # Never raises: a probe whose identity could not be established
          # still runs, and reports what the application actually saw.
          identity.establish(session)
          begin
            window.run { session.process(method, target, params: body, headers: headers) }
            # Strictly before release: clearing the identity is exactly what
            # would make a completed request look anonymous, and a sign-out
            # request would replace the target's env and response.
            identity.observe(:request_completion)
            window.capture(session)
          ensure
            identity.release(session)
          end
        end
        window.verify!
        window.observation(elapsed(started))
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      private

      # One fresh integration session per probe, reused for setup, target,
      # and teardown so cookies behave like one real client.
      def open_session(identity)
        require "action_dispatch/testing/integration" unless defined?(ActionDispatch::Integration::Session)

        session = ActionDispatch::Integration::Session.new(identity.endpoint(@endpoint))
        session.host!(@endpoint.host) if @endpoint.respond_to?(:host) && @endpoint.host
        session
      end

      def with_rollback
        raise Unavailable, "Active Record rollback isolation is unavailable" unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed(started)
        ((monotonic - started) * 1000.0).round(1)
      end

      # Everything observed about one target request: open only while that
      # request runs, on the thread that runs it.
      # rubocop:disable Metrics/ClassLength
      class TargetWindow
        def initialize(identity)
          @identity = identity
          @thread = Thread.current
          @writes = 0
          @render_events = []
          @paused = false
        end

        # rubocop:disable Naming/BlockForwarding -- anonymous block forwarding
        # needs Ruby 3.1; this file runs on Ruby 2.7.
        def run(&request)
          @identity.begin_target
          subscribed(&request)
          @completed = true
        rescue Identity::EstablishmentError => e
          # Karst's own sign-in raised inside the request, before the
          # application dispatched it: identity setup failed, and the route
          # never ran.
          @identity.establishment_failed(e.message)
        rescue StandardError => e
          target_raised(e)
        end
        # rubocop:enable Naming/BlockForwarding

        def capture(session)
          env = @identity.request_env
          @controller, @action = dispatched(env)
          @controller_completed = !@dispatch.key?(:exception) if @dispatch
          return unless @completed && env

          # Rails may render an application exception through ShowExceptions
          # rather than re-raise it, depending on host and Rails-version
          # configuration; the original is then recorded on the env.
          @exception = env["action_dispatch.exception"]
          return if @exception

          # Only now is session.request/session.response provably the target's:
          # ActionDispatch::Integration::Session reassigns them only after the
          # request returns without raising.
          @status = session.response.status
          @redirect = clean_redirect(session.response.location) if @status >= 300 && @status < 400
          @response_content_type = response_content_type(session)
          @route_params = route_params(session)
        end

        # A misconfigured observation seam is a configuration error and says
        # so; any other failure of Karst's own observation means the evidence
        # is incomplete, and none of it is reported.
        def verify!
          return unless @failure
          raise @failure if @failure.is_a?(Identity::ConfigurationError)

          raise ObservationError,
                "Karst could not observe this request (#{@failure.class}: #{@failure.message}); " \
                "no evidence was reported for it",
                cause: @failure
        end

        def observation(elapsed_ms)
          Observation.new(
            identity: @identity.evidence, controller: @controller, action: @action,
            controller_completed: @controller_completed, status: @status, redirect: @redirect,
            response_content_type: @response_content_type, halted_callback: @halted_callback,
            exception_class: @exception&.class&.name, exception_phase: (exception_phase if @exception),
            rendered: rendered, write_count: @writes, route_params: @route_params, elapsed_ms: elapsed_ms
          )
        end

        private

        # Only an exception from a request that actually reached the
        # application is the application's own; anything earlier is Karst
        # failing to issue the request at all.
        def target_raised(error)
          if @identity.request_env
            @exception = error
          else
            @failure ||= error # rubocop:disable Naming/MemoizedInstanceVariableName
          end
        end

        # Notification subscriptions are process-wide; #recording? keeps a
        # concurrent request on another thread of a real development server
        # from ever being counted as this target's evidence.
        def subscribed(&block)
          notifications = ActiveSupport::Notifications
          notifications.subscribed(guarded(:record_write), "sql.active_record") do
            notifications.subscribed(guarded(:record_halt), "halted_callback.action_controller") do
              notifications.subscribed(guarded(:record_render), "!render_template.action_view") do
                notifications.subscribed(guarded(:record_dispatch), "process_action.action_controller", &block)
              end
            end
          end
        end

        # A subscriber that raises would raise into the application's own
        # instrumented code -- a SQL statement, a callback chain, a
        # transaction -- and surface as the target's exception. Karst's
        # failure is kept as Karst's instead (see #verify!).
        def guarded(handler)
          lambda do |_name, _start, _finish, _id, payload|
            send(handler, payload) if recording?
          rescue StandardError => e
            @failure ||= e
          end
        end

        def recording?
          Thread.current.equal?(@thread) && !@paused && !Identity.establishing?
        end

        def record_write(payload)
          @writes += 1 if DatabaseIsolation.mutation?(payload[:sql])
        end

        def record_halt(payload)
          @halted_callback ||= payload[:filter]
          # The identity the application had established when this access
          # decision was made -- not after the request unwound. Karst's own
          # observation, so nothing it causes is the target's evidence.
          pause { @identity.observe(:halted_callback) }
        end

        # "!render_template.action_view" -- not the higher-level, no-bang
        # "render_template.action_view" -- because it is the one event
        # ActionView::Template itself fires for every template, partial, and
        # layout it renders, and the only one carrying that template's own
        # relative virtual_path rather than an absolute source file. It fires
        # once per Template#render call, whether that call completed or raised
        # (payload[:exception]/[:exception_object] are set first when it
        # raised), so it is a faithful, ordered record of what the target
        # request rendered.
        def record_render(payload)
          return unless payload[:virtual_path]

          @render_events << { virtual_path: payload[:virtual_path].to_s, completed: !payload.key?(:exception),
                              exception_object: payload[:exception_object] }
        end

        # The last process_action to finish is the outermost one.
        def record_dispatch(payload)
          @dispatch = payload
        end

        def pause
          @paused = true
          yield
        ensure
          @paused = false
        end

        # Rails puts the dispatching controller on the request env before any
        # callback runs, so this is present even for a halted request.
        def dispatched(env)
          instance = env && env["action_controller.instance"]
          return [nil, nil] unless instance

          [presence(instance.class.name), presence(instance.respond_to?(:action_name) ? instance.action_name : nil)]
        rescue StandardError
          [nil, nil]
        end

        def presence(value)
          value.to_s.empty? ? nil : value.to_s
        end

        def rendered
          @render_events.map { |event| { virtual_path: event[:virtual_path], completed: event[:completed] }.freeze }
                        .freeze
        end

        # The most specific phase Karst can prove an observed exception
        # occurred in, never guessed from its class or message.
        #
        # A render-level exception reaches the controller wrapped in a new
        # ActionView::Template::Error (see ActionView::Template#handle_render_
        # error), so the object the request ultimately raised is not the one
        # "!render_template.action_view" recorded -- it is that object's
        # #cause, or its #cause's #cause for a partial nested inside a
        # template inside a layout. Walking #cause is therefore required to
        # recognize a render exception at all once it has unwound past the
        # template that raised it.
        def exception_phase
          return "render" if @render_events.any? { |event| same_exception?(@exception, event[:exception_object]) }
          return "controller" if @dispatch&.key?(:exception)

          "unknown"
        end

        def same_exception?(exception, candidate)
          return false unless candidate

          chain = exception
          depth = 0
          while chain && depth < 20
            return true if chain.equal?(candidate)

            chain = chain.respond_to?(:cause) ? chain.cause : nil
            depth += 1
          end
          false
        end

        # The router's own path_parameters -- observed routing, not a second
        # recognize_path guess that could disagree with what dispatched.
        # nil when Karst observed no route.
        def route_params(session)
          raw = session.request.path_parameters
          return nil unless raw.is_a?(Hash) && !raw.empty?

          raw.each_with_object({}) do |(key, value), result|
            result[key.to_s] = value unless %w[controller action].include?(key.to_s)
          end
        rescue StandardError
          nil
        end

        def response_content_type(session)
          value = session.response.content_type if session.response.respond_to?(:content_type)
          value.to_s.empty? ? nil : value.to_s
        rescue StandardError
          nil
        end

        # Query-and-fragment-stripped, never just query-stripped: a redirect
        # target is exactly as capable of carrying a credential in its
        # fragment (an OAuth-style "/callback#access_token=...") as in its
        # query string, and a fragment is never sent back to the server on
        # the follow-up request, so there is no reason reproduction needs it
        # either. The regex fallback below mirrors that -- it drops
        # everything from the first "?" *or* "#", whichever comes first --
        # so a Location Karst cannot even parse as a URI still cannot leak
        # through the one delimiter the query-only split used to miss.
        def clean_redirect(location)
          text = location.to_s
          return nil if text.empty?

          uri = URI.parse(text)
          uri.query = nil
          uri.fragment = nil
          uri.to_s
        rescue StandardError
          text.split(/[?#]/, 2).first
        end
      end
      private_constant :TargetWindow
      # rubocop:enable Metrics/ClassLength
    end
  end
end
