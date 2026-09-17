# frozen_string_literal: true

require "json"
require "time"
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
      # 2 (was 1): every principal field is now explicitly either a
      # *requested* identity (what Karst was asked to run as) or an
      # *observed* one (what the application itself resolved at runtime),
      # and each outcome carries an `identity` document saying whether the
      # two agree. The ambiguous v1 `principal`/`verified_principal` keys are
      # gone rather than renamed in place: a consumer reading "principal" and
      # believing it described the request that actually ran is precisely the
      # false attribution this schema exists to make impossible.
      SCHEMA_VERSION = 2

      # A deliberate identity-free probe: no principal is established, and
      # the application is expected to resolve none. Requires no principal
      # source at all, so a route can be probed anonymously in an application
      # Karst could not otherwise test.
      ANONYMOUS = :anonymous

      def initialize(path:, http_method: "GET", output: $stdout, json: false, identity: nil)
        @path = path
        @http_method = http_method
        @output = output
        @json = json
        @identity = normalize_identity(identity)
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

      def normalize_identity(value)
        return nil if value.nil?
        return ANONYMOUS if value.to_s == ANONYMOUS.to_s

        raise ArgumentError, "identity must be \"anonymous\" when given"
      end

      def anonymous?
        @identity == ANONYMOUS
      end

      def run_search
        return anonymous_search if anonymous?

        validate_setup!
        Access::Search.new(path: @path, http_method: @http_method, sources: Identity.principal_sources).call
      end

      # One request, no principal source consulted and none required: the
      # whole point is that nothing is authenticated. Reuses Search::Result so
      # every adapter below stays identical for both probe kinds.
      def anonymous_search
        sweep = Access::Sweep.new(path: @path, http_method: @http_method,
                                  principals: [Identity::ANONYMOUS], limit: 1).call
        Access::Search::Result.new(initial: sweep, attempts: [].freeze)
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
          probe: { identity: anonymous? ? "anonymous" : "application_identities" },
          provenance: provenance,
          verified_usable: !winner.nil?,
          verified_identity: winner && identity(winner.identity),
          verified_outcome: winner && outcome(winner),
          source: result.verified_source,
          sample: sweep(result.initial),
          populations: result.attempts.map { |attempt| population(attempt) },
          summary: { request_count: result.request_count, elapsed_ms: result.elapsed_ms }
        }
      end

      # What execution produced these observations. Deliberately cheap and
      # certain: versions, environment, and when the probe ran. It does not
      # yet carry an application source digest/commit -- a consumer that must
      # know the evidence still matches the code it is reasoning about needs
      # freshness machinery this adapter does not own.
      def provenance
        {
          karst_version: Karst::VERSION,
          rails_version: defined?(Rails::VERSION::STRING) ? Rails::VERSION::STRING : nil,
          rails_env: defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.to_s : nil,
          ruby_version: RUBY_VERSION,
          observed_at: Time.now.utc.iso8601
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

      # Outcomes that observed the same thing are reported once, with every
      # probe's own identity evidence listed under it -- so "three requests
      # halted at authorize_admin" never flattens into one claim about who
      # made them.
      def grouped_outcomes(outcomes)
        outcomes.group_by { |item| outcome(item) }.map do |evidence, items|
          evidence.merge(count: items.size, identities: items.map { |item| identity(item.identity) })
        end
      end

      def outcome(item)
        {
          status: item.status, redirect: item.redirect, exception_class: item.exception_class,
          halted_callback: item.halted_callback&.to_s, writes_observed: item.writes_observed,
          write_count: item.write_count, database_rollback_attempted: item.database_rollback_attempted,
          elapsed_ms: item.elapsed_ms, controller: item.controller, action: item.action
        }
      end

      # The whole point of this schema version. `requested` is intent,
      # `observed` is what the application resolved while running the
      # request, and `confirmation` is the only field that says whether a
      # principal claim about this request is true. Anything other than
      # "confirmed"/"confirmed_anonymous" means it is not.
      def identity(evidence)
        return nil unless evidence

        {
          requested: evidence.requested && principal(evidence.requested),
          observed: evidence.observed && { model: evidence.observed.model_name.to_s,
                                           id: primitive_id(evidence.observed.id) },
          confirmation: evidence.confirmation.to_s,
          observed_at: evidence.observed_at&.to_s,
          observation_source: evidence.observation_source&.to_s,
          observation_error: evidence.observation_error,
          establishment: evidence.establishment&.to_s,
          establishment_error: evidence.establishment_error,
          cleanup_error: evidence.cleanup_error,
          changed_during_request: evidence.changed_during_request
        }
      end

      def principal(value)
        # JSON is also the MCP contract. Framework-inferred login identifiers
        # must never cross that machine-readable boundary. An application-
        # authored principal_label remains explicit configuration and keeps
        # its longstanding serialization behavior.
        label = if Karst.config.principal_label
                  value.display_label.to_s
                else
                  "#{value.model_name} ##{value.id}"
                end
        { model: value.model_name.to_s, id: primitive_id(value.id), label: label }
      end

      def primitive_id(value)
        value.is_a?(Integer) ? value : value.to_s
      end

      def error_document(error)
        type = error.is_a?(Identity::Error) ? "configuration_error" : "input_error"
        { schema_version: SCHEMA_VERSION, error: { type: type, message: error.message } }
      end

      def human(result)
        lines = ["Karst verification", "", "#{result.http_method} #{result.path}",
                 "Probe identity: #{anonymous? ? 'anonymous' : "the application's own identities"}", "",
                 anonymous? ? "Probe" : "Sample",
                 "  #{result.initial.outcomes.size} #{anonymous? ? 'request' : 'users tested'}"]
        lines << "  #{sample_usable_count(result)} verified usable" unless anonymous?
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

        append_response_evidence(lines, evidence)
        lines << "  #{identity_line(evidence.identity)}" if evidence.identity
        lines << "  WARNING: #{evidence.write_count} writes observed" if evidence.writes_observed
      end

      def append_response_evidence(lines, evidence)
        lines << "  status #{evidence.status}" if evidence.status
        lines << "  redirect #{evidence.redirect}" if evidence.redirect
        lines << "  halted at #{evidence.halted_callback}" if evidence.halted_callback
        lines << "  exception #{evidence.exception_class}" if evidence.exception_class
      end

      # Says what the application actually did with identity, never what was
      # asked of it.
      def identity_line(evidence)
        case evidence.confirmation
        when :confirmed then "observed #{observed_label(evidence)} (identity confirmed)"
        when :confirmed_anonymous then "observed no principal (anonymous confirmed)"
        when :absent then "requested #{requested_label(evidence)}, observed no principal (NOT confirmed)"
        when :mismatch then "requested #{requested_label(evidence)}, observed #{observed_label(evidence)} (MISMATCH)"
        when :contaminated then "anonymous probe observed #{observed_label(evidence)} (CONTAMINATED)"
        else "identity unobservable: #{evidence.observation_error}"
        end
      end

      def observed_label(evidence)
        evidence.observed ? "#{evidence.observed.model_name} ##{evidence.observed.id}" : "no principal"
      end

      def requested_label(evidence)
        evidence.requested ? "#{evidence.requested.model_name} ##{evidence.requested.id}" : "anonymous"
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
        winner = result.verified_outcome
        if winner
          lines << "  verified usable: #{winner_label(winner)}"
          lines << "  #{identity_line(winner.identity)}" if winner.identity
          source = result.verified_source
          lines << "  source: #{source[:type]}#{"=#{source[:name]}" if source[:name]}"
        else
          lines << (anonymous? ? "  not usable anonymously" : "  no verified usable user found")
        end
        lines << "  #{result.request_count} requests in #{result.elapsed_ms} ms"
      end

      def winner_label(winner)
        winner.principal ? winner.principal.display_label : "anonymous request"
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
  end
end
