# frozen_string_literal: true

require "active_support/notifications"
require "uri"
require_relative "probe_application"
require_relative "../identity"
require_relative "../value"

module Karst
  module Access
    class Error < StandardError; end
    class UnsafeTarget < Error; end
    class UnsupportedMethod < Error; end
    class Unavailable < Error; end

    Outcome = Value.define(:principal, :status, :redirect, :exception_class,
                           :writes_observed, :write_count, :elapsed_ms, :database_rollback_attempted)

    # candidate_pool_size is nil unless the caller supplying `principals` (see
    # Access::PrincipalSampler::Result) knows it sampled from a bounded
    # recent-N pool rather than the full principal source -- callers use it
    # to report the sampling scope truthfully rather than implying every
    # principal was considered.
    Result = Value.define(:path, :http_method, :outcomes, :elapsed_ms, :aborted_reason, :database_isolation,
                          :candidate_pool_size) do
      def groups
        outcomes.group_by { |item| [item.status, item.redirect, item.exception_class] }
      end
    end

    # Sequentially observes one concrete local GET using a fresh integration
    # session and a rollback-only transaction for every bounded principal.
    class Sweep
      MUTATION = %r{\A\s*(?:/\*.*?\*/\s*)*(INSERT|UPDATE|DELETE)\b}im

      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, principals:, http_method: "GET", limit: Karst.config.access_sweep_limit,
                     application: nil, candidate_pool_size: nil)
        @path = normalize_path(path)
        @http_method = http_method.to_s.upcase
        raise UnsupportedMethod, "access sweeps support GET only" unless @http_method == "GET"
        raise ArgumentError, "limit exceeds configured access_sweep_limit" unless valid_limit?(limit)

        @principals = principals
        @limit = limit
        @application = application || Rails.application
        @probe_application = build_probe_application
        @candidate_pool_size = candidate_pool_size
      end
      # rubocop:enable Metrics/ParameterLists

      def call
        raise Unavailable, "access sweeps are development-only" unless Rails.env.development?

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

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def probe(principal)
        session = ActionDispatch::Integration::Session.new(@probe_application)
        configure_host(session)
        started = monotonic
        status = redirect = exception_class = nil
        writes = 0
        callback = ->(_name, _start, _finish, _id, payload) { writes += 1 if payload[:sql].to_s.match?(MUTATION) }

        with_rollback do
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            Karst::Identity.with(session, principal) do
              session.get(@path)
              rendered_exception = request_exception(session)
              if rendered_exception
                exception_class = rendered_exception.class.name
              else
                status = session.response.status
                redirect = clean_redirect(session.response.location) if status >= 300 && status < 400
              end
            end
          end
        rescue StandardError => e
          exception_class = e.class.name
        end
        Outcome.new(principal: Karst::Identity.describe(principal), status: status, redirect: redirect,
                    exception_class: exception_class, writes_observed: writes.positive?, write_count: writes,
                    elapsed_ms: elapsed(started), database_rollback_attempted: true)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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
  end
end
