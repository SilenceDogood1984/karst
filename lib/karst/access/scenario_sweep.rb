# frozen_string_literal: true

require_relative "../value"
require_relative "sweep"

module Karst
  module Access
    ArtifactDescriptor = Value.define(:model_name, :id, :display_label)
    ScenarioOutcome = Value.define(:principal, :artifact, :path, :status, :redirect, :exception_class,
                                   :writes_observed, :write_count, :elapsed_ms, :database_rollback_attempted,
                                   :sampling_reasons, :expected, :body_marker_observed, :match)
    ScenarioResult = Value.define(:scenario_name, :outcomes, :elapsed_ms, :combination_limit,
                                  :artifact_candidate_limit, :stopped_on_match, :candidate_pool_size)

    # Executes the deliberately small principal x artifact primitive. The
    # global combination cap is checked before every request and may stop at
    # the first matching observation.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    class ScenarioSweep
      def initialize(scenario:, principals:, application: nil, candidate_pool_size: nil, sampling_reasons: {})
        @scenario = scenario
        @principals = principals
        @application = application
        @candidate_pool_size = candidate_pool_size
        @sampling_reasons = sampling_reasons
      end

      def call
        started = monotonic
        outcomes = []
        stopped = false
        bounded_principals.each do |principal|
          artifacts.each do |artifact|
            break if outcomes.size >= @scenario.combination_limit

            observed = probe(principal, artifact)
            outcomes << observed
            if observed.match && @scenario.stop_on_match
              stopped = true
              break
            end
          end
          break if stopped || outcomes.size >= @scenario.combination_limit
        end
        ScenarioResult.new(scenario_name: @scenario.name, outcomes: outcomes.freeze, elapsed_ms: elapsed(started),
                           combination_limit: @scenario.combination_limit,
                           artifact_candidate_limit: @scenario.artifact_source.limit,
                           stopped_on_match: stopped, candidate_pool_size: @candidate_pool_size)
      end

      private

      def bounded_principals
        source = @principals
        source = source.limit(Karst.config.access_sweep_limit) if source.respond_to?(:limit)
        source.each.lazy.take(Karst.config.access_sweep_limit).to_a
      end

      def artifacts
        @artifacts ||= @scenario.artifact_source.candidates
      end

      def probe(principal, artifact)
        path = @scenario.path.call(artifact)
        marker = @scenario.expectation[:body_includes]
        base = Sweep.new(path: path, principals: [principal], limit: 1, application: @application,
                         sampling_reasons: @sampling_reasons, body_includes: marker).call.outcomes.first
        marker_observed = base.body_marker_observed
        scenario_outcome(base, artifact, path, marker_observed, matches?(base, marker_observed))
      rescue StandardError => e
        descriptor = Karst::Identity.describe(principal)
        ScenarioOutcome.new(principal: descriptor, artifact: describe(artifact), path: safe_path(path), status: nil,
                            redirect: nil, exception_class: e.class.name, writes_observed: false, write_count: 0,
                            elapsed_ms: 0.0, database_rollback_attempted: false, sampling_reasons: [].freeze,
                            expected: @scenario.expectation, body_marker_observed: nil, match: false)
      end

      def scenario_outcome(base, artifact, path, marker_observed, match)
        ScenarioOutcome.new(principal: base.principal, artifact: describe(artifact), path: path.to_s,
                            status: base.status, redirect: base.redirect, exception_class: base.exception_class,
                            writes_observed: base.writes_observed, write_count: base.write_count,
                            elapsed_ms: base.elapsed_ms, database_rollback_attempted: base.database_rollback_attempted,
                            sampling_reasons: base.sampling_reasons, expected: @scenario.expectation,
                            body_marker_observed: marker_observed, match: match)
      end

      def matches?(outcome, marker_observed)
        expected = @scenario.expectation
        return false if outcome.exception_class
        return false if expected.key?(:status) && outcome.status != expected[:status]
        return false if expected.key?(:redirect) && outcome.redirect != expected[:redirect]
        return false if expected.key?(:body_includes) && !marker_observed

        true
      end

      def describe(record)
        model = record.class.respond_to?(:model_name) ? record.class.model_name.name : record.class.name
        id = record.respond_to?(:id) ? record.id : nil
        label = id.nil? ? model : "#{model} ##{id}"
        ArtifactDescriptor.new(model_name: model, id: id, display_label: label)
      end

      def safe_path(path)
        path&.to_s
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed(started)
        ((monotonic - started) * 1000.0).round(1)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  end
end
