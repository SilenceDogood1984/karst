# frozen_string_literal: true

require "json"
require_relative "../../karst"

module Karst
  module CLI
    # Presentation-only adapter for Access::Search. It deliberately receives
    # Search's result and converts only its public evidence values to stable,
    # privacy-bounded primitives.
    # Formatting necessarily enumerates the complete public schema in one
    # place, keeping the versioned contract auditable.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    class Verification
      SCHEMA_VERSION = 1

      def initialize(path:, http_method: "GET", output: $stdout, json: false)
        @path = path
        @http_method = http_method
        @output = output
        @json = json
      end

      def call
        result = run_search
        @output.puts(@json ? JSON.generate(document(result)) : human(result))
        result.verified_outcome ? 0 : 1
      rescue Access::Error, Identity::Error, ArgumentError => e
        @output.puts(@json ? JSON.generate(error_document(e)) : "Karst cannot verify this route:\n#{e.message}")
        2
      end

      # The same schema-versioned evidence document --json prints, without
      # any dependency on @output/stdout -- the shared entry point every
      # other adapter (currently only the MCP server) calls instead of
      # duplicating Access::Search invocation or result serialization. Always
      # returns a Hash: either the success document or, on any of the same
      # errors #call rescues, error_document(e) -- never raises.
      def evidence
        document(run_search)
      rescue Access::Error, Identity::Error, ArgumentError => e
        error_document(e)
      end

      private

      def run_search
        validate_setup!
        Access::Search.new(path: @path, http_method: @http_method, sources: Identity.principal_sources).call
      end

      def validate_setup!
        state = Identity.setup_state
        return if state.status.to_s.start_with?("ready_")

        message = state.message || "no principal source is configured"
        raise Identity::ConfigurationError, message
      end

      def document(result)
        winner = result.verified_outcome
        {
          schema_version: SCHEMA_VERSION,
          request: { method: result.http_method, path: result.path },
          verified_usable: !winner.nil?,
          verified_principal: winner && principal(winner.principal),
          verified_outcome: winner && outcome(winner, include_principal: false),
          source: result.verified_source,
          sample: sweep(result.initial),
          populations: result.attempts.map { |attempt| population(attempt) },
          summary: { request_count: result.request_count, elapsed_ms: result.elapsed_ms }
        }
      end

      def sweep(result)
        {
          candidate_pool_size: result.candidate_pool_size,
          users_tested: result.outcomes.size,
          verified_usable: result.outcomes.any? { |item| Karst.config.usable_access_outcome.call(item) },
          database_isolation: result.database_isolation.to_s,
          outcomes: grouped_outcomes(result.outcomes)
        }
      end

      def population(attempt)
        data = { name: attempt.name.to_s, source: attempt.source_name.to_s, state: attempt.state.to_s }
        data[:reason] = attempt.error if attempt.error
        return data unless attempt.result

        data.merge(users_tested: attempt.result.outcomes.size, outcomes: grouped_outcomes(attempt.result.outcomes))
      end

      def grouped_outcomes(outcomes)
        outcomes.group_by { |item| outcome(item, include_principal: false) }.map do |evidence, items|
          evidence.merge(count: items.size, principals: items.map { |item| principal(item.principal) })
        end
      end

      def outcome(item, include_principal: true)
        data = {
          status: item.status, redirect: item.redirect, exception_class: item.exception_class,
          halted_callback: item.halted_callback&.to_s, writes_observed: item.writes_observed,
          write_count: item.write_count, database_rollback_attempted: item.database_rollback_attempted,
          elapsed_ms: item.elapsed_ms
        }
        data[:principal] = principal(item.principal) if include_principal
        data
      end

      def principal(value)
        { model: value.model_name.to_s, id: primitive_id(value.id), label: value.display_label.to_s }
      end

      def primitive_id(value)
        value.is_a?(Integer) ? value : value.to_s
      end

      def error_document(error)
        type = error.is_a?(Identity::Error) ? "configuration_error" : "input_error"
        { schema_version: SCHEMA_VERSION, error: { type: type, message: error.message } }
      end

      def human(result)
        lines = ["Karst verification", "", "#{result.http_method} #{result.path}", "", "Sample",
                 "  #{result.initial.outcomes.size} users tested",
                 "  #{sample_usable_count(result)} verified usable"]
        append_key_evidence(lines, result.initial.outcomes)
        append_populations(lines, result)
        append_result(lines, result)
        lines.join("\n")
      end

      def sample_usable_count(result)
        result.initial.outcomes.count { |item| Karst.config.usable_access_outcome.call(item) }
      end

      def append_key_evidence(lines, outcomes)
        evidence = outcomes.first
        return unless evidence

        lines << "  status #{evidence.status}" if evidence.status
        lines << "  redirect #{evidence.redirect}" if evidence.redirect
        lines << "  halted at #{evidence.halted_callback}" if evidence.halted_callback
        lines << "  exception #{evidence.exception_class}" if evidence.exception_class
        lines << "  WARNING: #{evidence.write_count} writes observed" if evidence.writes_observed
      end

      def append_populations(lines, result)
        return if result.attempts.empty?

        lines.push("", "Candidate populations")
        result.attempts.each do |attempt|
          count = attempt.result&.outcomes&.size || 0
          lines << "  #{attempt.name}: #{attempt.state} (#{count} users tested)"
          append_key_evidence(lines, attempt.result.outcomes) if attempt.result
        end
      end

      def append_result(lines, result)
        lines.push("", "Result")
        if result.verified_outcome
          lines << "  verified usable user: #{result.verified_outcome.principal.display_label}"
          source = result.verified_source
          lines << "  source: #{source[:type]}#{"=#{source[:name]}" if source[:name]}"
        else
          lines << "  no verified usable user found"
        end
        lines << "  #{result.request_count} requests in #{result.elapsed_ms} ms"
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
  end
end
