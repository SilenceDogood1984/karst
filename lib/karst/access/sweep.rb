# frozen_string_literal: true

require_relative "errors"
require_relative "local_path"
require_relative "probe"
require_relative "outcome_groups"
require_relative "../identity"
require_relative "../value"

module Karst
  module Access
    # sampling_reasons is a frozen Array of short evidence strings (e.g.
    # "role=local_admin", "source=authors") explaining why PrincipalSampler
    # or PrincipalSelection deliberately included this principal, or an
    # empty Array when the principal came from plain first-N/fill sampling
    # or was supplied directly rather than through a sampler. This is
    # sampling evidence, not an authorization claim.
    #
    # `principal` is the *requested* identity -- what Karst was asked to
    # execute as, nil for a deliberate anonymous probe -- and is intent, not
    # evidence. What the application actually resolved lives in `identity`
    # (a Karst::Identity::Evidence), and only its #confirmation says whether
    # the two agree. Nothing may conclude "this request ran as User#123" from
    # `principal` alone.
    #
    # controller/action are the controller class name and action the request
    # actually dispatched to, observed from the probe request's own env, or
    # nil when it never reached a controller.
    #
    # Every evidence field is Access::Probe's observation of the target
    # request alone: write_count never includes identity setup/teardown.
    Outcome = Value.define(:principal, :status, :redirect, :exception_class,
                           :writes_observed, :write_count, :elapsed_ms, :database_rollback_attempted,
                           :sampling_reasons, :halted_callback, :identity, :controller, :action)

    # candidate_pool_size is nil unless the caller supplying `principals` (see
    # Access::PrincipalSampler::Result) knows it sampled from a bounded
    # recent-N pool rather than the full principal source -- callers use it
    # to report the sampling scope truthfully rather than implying every
    # principal was considered.
    Result = Value.define(:path, :http_method, :outcomes, :elapsed_ms, :aborted_reason, :database_isolation,
                          :candidate_pool_size) do
      # Semantic outcome groups (see Access::OutcomeGroups), largest first,
      # as semantic key => member outcomes.
      def groups
        OutcomeGroups.group(outcomes).to_h { |group| [group.key, group.outcomes] }
      end
    end

    # Runs one concrete local GET as each of a bounded set of principals, in
    # order, and collects what happened to each. Every request is one
    # Access::Probe call -- a fresh session and a rollback-only transaction per
    # principal -- so a sweep's per-principal evidence is exactly what
    # reproducing that request as that principal observes. Sweep itself owns
    # only the population: bounding it, and attaching why each principal was
    # sampled.
    class Sweep
      # sampling_reasons optionally maps a principal (by Ruby equality, so
      # the same Active Record identity even across separate instances) to
      # the Array of reasons it was selected for -- see
      # Access::PrincipalSampler::Candidate/PrincipalSelection. A principal
      # with no entry simply gets an empty Array on its Outcome.
      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, principals:, http_method: "GET", limit: Karst.config.access_sweep_limit,
                     application: nil, candidate_pool_size: nil, sampling_reasons: {})
        @path = normalize_path(path)
        @http_method = http_method.to_s.upcase
        raise UnsupportedMethod, "access sweeps support GET only" unless @http_method == "GET"
        raise ArgumentError, "limit exceeds configured access_sweep_limit" unless valid_limit?(limit)

        @principals = principals
        @limit = limit
        @probe = Probe.new(application || Rails.application)
        @candidate_pool_size = candidate_pool_size
        @sampling_reasons = sampling_reasons
      end
      # rubocop:enable Metrics/ParameterLists

      def call
        raise Unavailable, "access sweeps are development-only" unless Rails.env.development?
        raise Unavailable, "Karst is disabled (config.enabled)" unless Karst.enabled?

        started = monotonic
        outcomes = bounded_principals.map do |principal|
          outcome(principal, @probe.call(principal: principal, http_method: @http_method, target: @path))
        end
        Result.new(path: @path, http_method: @http_method, outcomes: outcomes.freeze,
                   elapsed_ms: elapsed(started), aborted_reason: nil,
                   database_isolation: :same_connection_rollback_attempted,
                   candidate_pool_size: @candidate_pool_size)
      end

      private

      def normalize_path(value)
        LocalPath.path(value)
      end

      def valid_limit?(limit)
        limit.is_a?(Integer) && limit.positive? && limit <= Karst.config.access_sweep_limit
      end

      def bounded_principals
        source = @principals
        source = source.limit(@limit) if source.respond_to?(:limit)
        source.each.lazy.take(@limit).to_a
      end

      def outcome(principal, observed)
        writes = observed.write_count
        Outcome.new(principal: observed.identity.requested, status: observed.status, redirect: observed.redirect,
                    exception_class: observed.exception_class, writes_observed: writes.positive?,
                    write_count: writes, elapsed_ms: observed.elapsed_ms, database_rollback_attempted: true,
                    sampling_reasons: (@sampling_reasons[principal] || []).freeze,
                    halted_callback: observed.halted_callback, identity: observed.identity,
                    controller: observed.controller, action: observed.action)
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
