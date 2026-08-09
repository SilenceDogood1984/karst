# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "active_support/isolated_execution_state"
require_relative "principal"
require_relative "request_observation"
require_relative "example_observation"
require_relative "reporter"

module Karst
  module Spec
    class InvalidMetadataError < StandardError; end

    # Turns real RSpec execution into Karst's route/scenario catalog.
    #
    # Karst never parses spec source, route-helper arguments, or FactoryBot
    # calls to build this catalog. It observes the same runtime facts the
    # request-evidence engine already relies on -- ActiveSupport::Notifications
    # for controller/render events, and Warden's public hooks for the
    # authenticated principal -- while an example actually runs, and records
    # only what those events say. An example that never issues an HTTP
    # request produces no observation at all.
    #
    # Explicitly out of scope here: provisioning scenario state, database
    # cloning or isolation, browser/session switching, source analysis, and
    # any UI. This module only builds and writes the catalog artifact.
    # rubocop:disable Metrics/ModuleLength
    module Observer
      KEY = :karst_spec_observer_current
      private_constant :KEY

      # Mutable accumulator for the example currently running. `principal` is
      # updated in place by the Warden hooks as the example progresses, so
      # each request observes the principal that was active when it happened.
      Current = Struct.new(:requests, :principal, keyword_init: true)
      private_constant :Current

      # Mutable request-in-progress. Frozen into a RequestObservation once the
      # example finishes; never exposed outside this module. Named
      # `http_method`, not `method`, so it never shadows Object#method.
      RequestBuilder = Struct.new(
        :sequence, :http_method, :path, :route_pattern, :controller, :action, :format,
        :status, :redirect_location, :principal_before, :principal_after,
        keyword_init: true
      )
      private_constant :RequestBuilder

      # rubocop:disable Metrics/ClassLength
      class << self
        attr_reader :reporter, :output_path

        # rubocop:disable Metrics/MethodLength
        def install!(output:)
          @install_mutex ||= Mutex.new
          @install_mutex.synchronize do
            return @reporter if @installed

            raise "Karst::Spec::Observer requires RSpec to already be loaded" unless defined?(RSpec)

            @output_path = output
            @reporter = Reporter.new
            subscribe_notifications
            subscribe_warden
            configure_rspec
            @installed = true
            @reporter
          end
        end
        # rubocop:enable Metrics/MethodLength

        # The one seam RSpec's `around` hook calls into: start tracking,
        # run the example, then convert whatever was tracked into an
        # immutable ExampleObservation and hand it to the Reporter.
        def wrap_example(example)
          karst_explicit, karst_name = karst_metadata(example)
          start_example!
          yield
        ensure
          finish_and_record!(example, karst_explicit: karst_explicit, karst_name: karst_name)
        end

        private

        def current
          ActiveSupport::IsolatedExecutionState[KEY]
        end

        def start_example!
          ActiveSupport::IsolatedExecutionState[KEY] = Current.new(requests: [], principal: nil)
        end

        def finish_example!
          state = current
          ActiveSupport::IsolatedExecutionState.delete(KEY)
          state
        end

        def subscribe_notifications
          ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
            on_start_processing(args.last)
          end
          ActiveSupport::Notifications.subscribe("redirect_to.action_controller") do |*args|
            on_redirect(args.last)
          end
          ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
            on_process_action(args.last)
          end
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def on_start_processing(payload)
          state = current
          return unless state

          state.requests << RequestBuilder.new(
            sequence: state.requests.size,
            http_method: payload[:method],
            path: strip_query(payload[:path]),
            route_pattern: route_pattern_for(payload[:request]),
            controller: payload[:controller],
            action: payload[:action],
            format: payload[:format]&.to_s,
            status: nil,
            redirect_location: nil,
            principal_before: state.principal,
            principal_after: state.principal
          )
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        def on_redirect(payload)
          builder = current&.requests&.last
          return unless builder

          builder.redirect_location = strip_query(strip_host(payload[:location]))
        end

        def on_process_action(payload)
          state = current
          builder = state&.requests&.last
          return unless builder

          builder.status = payload[:status]
          builder.principal_after = state.principal
        end

        # Query strings can carry tokens (password resets, OAuth callbacks,
        # signed URLs) and are never retained, on request paths or on
        # redirect targets below -- either can leak the same class of secret
        # into the catalog artifact.
        def strip_query(value)
          value.to_s.split("?").first
        end

        def strip_host(location)
          location.to_s.sub(%r{\Ahttps?://[^/]+}, "")
        end

        # Uses Rails' own routing engine to recover the declared path pattern
        # (e.g. "/things/:id(.:format)") for the exact request that was
        # already routed, rather than guessing from route-helper call sites
        # in spec source. Falls back to nil -- never a guess -- if routing
        # metadata is unavailable.
        def route_pattern_for(request)
          return nil unless request && defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          pattern = nil
          Rails.application.routes.router.recognize(request) do |route, _params|
            pattern = route.path.spec.to_s
            break
          end
          pattern
        rescue StandardError
          nil
        end

        # Warden is optional: an application with no Warden-based
        # authentication simply never populates `principal`, and every
        # request is recorded with `principal: nil` and role :subject.
        # rubocop:disable Metrics/MethodLength
        def subscribe_warden
          return unless defined?(Warden::Manager)

          Warden::Manager.after_set_user do |user, _auth, opts|
            state = current
            next unless state

            state.principal = Principal.new(type: user.class.name, id: user.id, scope: opts[:scope])
          end

          Warden::Manager.before_logout do |_user, _auth, _opts|
            state = current
            next unless state

            state.principal = nil
          end
        end
        # rubocop:enable Metrics/MethodLength

        def configure_rspec
          RSpec.configure do |config|
            config.around do |example|
              Observer.wrap_example(example) { example.run }
            end

            config.after(:suite) do
              Observer.reporter.write(Observer.output_path)
            end
          end
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def finish_and_record!(example, karst_explicit:, karst_name:)
          state = finish_example!
          return unless state
          return if state.requests.empty?

          reporter.record(
            ExampleObservation.new(
              example_id: example.id,
              file_path: example.metadata[:file_path],
              line_number: example.metadata[:line_number],
              spec_type: example.metadata[:type],
              description_parts: description_parts(example),
              full_description: example.full_description,
              karst_explicit: karst_explicit,
              karst_name: karst_name,
              outcome: outcome_for(example),
              requests: freeze_requests(state.requests)
            ).freeze
          )
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # RSpec finalizes `execution_result.status` in Example#finish, which
        # runs strictly after the around-hook chain returns -- it is always
        # nil at this point, however this method is reached. `exception` and
        # `pending_message` are set earlier, before `run_after_example`, so
        # this mirrors RSpec's own status derivation instead of reading a
        # field that has not been assigned yet.
        def outcome_for(example)
          return :failed if example.exception
          return :pending if example.execution_result.pending_message

          :passed
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def freeze_requests(builders)
          builders.map do |builder|
            RequestObservation.new(
              sequence: builder.sequence,
              http_method: builder.http_method,
              path: builder.path,
              route_pattern: builder.route_pattern,
              controller: builder.controller,
              action: builder.action,
              format: builder.format,
              status: builder.status,
              redirect_location: builder.redirect_location,
              principal_before: builder.principal_before,
              principal_after: builder.principal_after,
              principal_changed: builder.principal_after != builder.principal_before
            ).freeze
          end.freeze
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        def description_parts(example)
          outer = example.example_group.parent_groups.reverse.map(&:description)
          (outer + [example.description]).freeze
        end

        # rubocop:disable Metrics/MethodLength
        def karst_metadata(example)
          return [false, nil] unless example.metadata.key?(:karst)

          value = example.metadata[:karst]
          name = if value.is_a?(String)
                   value
                 elsif value.is_a?(Hash) && value.keys == [:name]
                   value[:name]
                 end

          unless name.is_a?(String) && !name.strip.empty?
            raise InvalidMetadataError,
                  "Invalid karst: metadata for #{example.id}; expected a non-empty String or { name: non_empty_string }"
          end

          [true, name]
        end
        # rubocop:enable Metrics/MethodLength
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
