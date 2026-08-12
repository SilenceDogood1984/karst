# frozen_string_literal: true

require "active_support/notifications"
require "uri"
require_relative "probe_application"
require_relative "database_isolation"
require_relative "../identity"
require_relative "../value"

module Karst
  module Access
    class Error < StandardError; end
    class UnsafeTarget < Error; end
    class UnsupportedMethod < Error; end
    class Unavailable < Error; end

    # sampling_reasons is a frozen Array of short evidence strings (e.g.
    # "role=local_admin", "source=authors") explaining why PrincipalSampler
    # or PrincipalSelection deliberately included this principal, or an
    # empty Array when the principal came from plain first-N/fill sampling
    # or was supplied directly rather than through a sampler. This is
    # sampling evidence, not an authorization claim.
    Outcome = Value.define(:principal, :status, :redirect, :exception_class,
                           :writes_observed, :write_count, :elapsed_ms, :database_rollback_attempted,
                           :sampling_reasons, :body_marker_observed, :halted_callback)

    # candidate_pool_size is nil unless the caller supplying `principals` (see
    # Access::PrincipalSampler::Result) knows it sampled from a bounded
    # recent-N pool rather than the full principal source -- callers use it
    # to report the sampling scope truthfully rather than implying every
    # principal was considered.
    Result = Value.define(:path, :http_method, :outcomes, :elapsed_ms, :aborted_reason, :database_isolation,
                          :candidate_pool_size) do
      def groups
        outcomes.group_by { |item| [item.status, item.redirect, item.exception_class, item.halted_callback] }
      end
    end

    # Sequentially observes one concrete local GET using a fresh integration
    # session and a rollback-only transaction for every bounded principal.
    # rubocop:disable Metrics/ClassLength
    class Sweep
      # sampling_reasons optionally maps a principal (by Ruby equality, so
      # the same Active Record identity even across separate instances) to
      # the Array of reasons it was selected for -- see
      # Access::PrincipalSampler::Candidate/PrincipalSelection. A principal
      # with no entry simply gets an empty Array on its Outcome.
      # rubocop:disable Metrics/ParameterLists
      # rubocop:disable Metrics/MethodLength
      def initialize(path:, principals:, http_method: "GET", limit: Karst.config.access_sweep_limit,
                     application: nil, candidate_pool_size: nil, sampling_reasons: {}, body_includes: nil)
        @path = normalize_path(path)
        @http_method = http_method.to_s.upcase
        raise UnsupportedMethod, "access sweeps support GET only" unless @http_method == "GET"
        raise ArgumentError, "limit exceeds configured access_sweep_limit" unless valid_limit?(limit)

        @principals = principals
        @limit = limit
        @application = application || Rails.application
        @probe_application = build_probe_application
        @candidate_pool_size = candidate_pool_size
        @sampling_reasons = sampling_reasons
        @body_includes = body_includes
      end
      # rubocop:enable Metrics/MethodLength
      # rubocop:enable Metrics/ParameterLists

      def call
        raise Unavailable, "access sweeps are development-only" unless Rails.env.development?
        raise Unavailable, "Karst is disabled (config.enabled)" unless Karst.enabled?

        require "action_dispatch/testing/integration" unless defined?(ActionDispatch::Integration::Session)

        started = monotonic
        outcomes = bounded_principals.map { |principal| probe(principal) }
        Result.new(path: @path, http_method: @http_method, outcomes: outcomes.freeze,
                   elapsed_ms: elapsed(started), aborted_reason: nil,
                   database_isolation: :same_connection_rollback_attempted,
                   candidate_pool_size: @candidate_pool_size)
      end

      private

      def normalize_path(value)
        raw = value.to_s.split("?", 2).first
        uri = URI.parse(raw)
        local = uri.relative? && raw.start_with?("/") && !raw.start_with?("//")
        raise UnsafeTarget, "target must be a local application path" unless local

        raw
      rescue URI::InvalidURIError
        raise UnsafeTarget, "target must be a valid local application path"
      end

      def valid_limit?(limit)
        limit.is_a?(Integer) && limit.positive? && limit <= Karst.config.access_sweep_limit
      end

      def bounded_principals
        source = @principals
        source = source.limit(@limit) if source.respond_to?(:limit)
        source.each.lazy.take(@limit).to_a
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def probe(principal)
        session = ActionDispatch::Integration::Session.new(@probe_application)
        configure_host(session)
        started = monotonic
        status = redirect = exception_class = nil
        body_marker_observed = nil
        halted_callback = nil
        writes = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          writes += 1 if DatabaseIsolation.mutation?(payload[:sql])
        end
        halt_observer = lambda do |_name, _start, _finish, _id, payload|
          halted_callback = payload[:filter]
        end

        with_rollback do
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            Karst::Identity.with(session, principal) do
              ActiveSupport::Notifications.subscribed(halt_observer, "halted_callback.action_controller") do
                session.get(@path)
              end
              rendered_exception = request_exception(session)
              if rendered_exception
                exception_class = rendered_exception.class.name
              else
                status = session.response.status
                if @body_includes && session.response.respond_to?(:body)
                  body_marker_observed = session.response.body.to_s.include?(@body_includes.to_s)
                end
                redirect = clean_redirect(session.response.location) if status >= 300 && status < 400
              end
            end
          end
        rescue StandardError => e
          exception_class = e.class.name
        end
        Outcome.new(principal: Karst::Identity.describe(principal), status: status, redirect: redirect,
                    exception_class: exception_class, writes_observed: writes.positive?, write_count: writes,
                    elapsed_ms: elapsed(started), database_rollback_attempted: true,
                    sampling_reasons: (@sampling_reasons[principal] || []).freeze,
                    body_marker_observed: body_marker_observed, halted_callback: halted_callback)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def with_rollback
        raise Unavailable, "Active Record rollback isolation is unavailable" unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
      end

      def build_probe_application
        ProbeApplication.for(@application)
      rescue ProbeApplication::ConstructionError => e
        raise Unavailable, e.message, cause: e
      end

      def configure_host(session)
        return unless @probe_application.respond_to?(:host) && @probe_application.host

        session.host!(@probe_application.host)
      end

      # Rails may either re-raise an application exception or render it through
      # ShowExceptions, depending on host and Rails-version configuration. The
      # latter records the original exception in the integration request env.
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
