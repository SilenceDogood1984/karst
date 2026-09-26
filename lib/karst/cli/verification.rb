# frozen_string_literal: true

require "json"
require "time"
require_relative "../../karst"
require_relative "identity_serialization"
require_relative "principal_reference"

module Karst
  module CLI
    # Presentation-only adapter for Access::Search. It deliberately receives
    # Search's result and converts only its public evidence values to stable,
    # privacy-bounded primitives.
    # Formatting necessarily enumerates the complete public schema in one
    # place, keeping the versioned contract auditable.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    class Verification
      include IdentitySerialization

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

      # `as`, when given, is a human-only "MODEL:ID" reference (e.g.
      # "User:72") naming one existing principal to run this probe as
      # instead of sampling one -- see Karst::CLI::PrincipalReference. It is
      # resolved exclusively through Karst::Identity.resolve, so it can never
      # select a record outside a configured principal source. Mutually
      # exclusive with `identity: "anonymous"`; nothing about this reaches
      # the MCP verify_access tool, which never accepts it.
      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, http_method: "GET", output: $stdout, json: false, identity: nil, as: nil)
        @path = path
        @http_method = http_method
        @output = output
        @json = json
        @identity = normalize_identity(identity)
        PrincipalReference.parse(as) if as
        raise ArgumentError, "--anonymous and --as cannot be combined" if anonymous? && as

        @as = as
      end
      # rubocop:enable Metrics/ParameterLists

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

      # An additive third value alongside the documented "anonymous" and
      # "application_identities": a --as probe is still a real application
      # identity, just a human-selected one rather than one Karst sampled --
      # a distinction worth reporting honestly rather than folding into
      # "application_identities" and implying this result came from the
      # ordinary search.
      def probe_identity
        return "anonymous" if anonymous?
        return "specific_principal" if @as

        "application_identities"
      end

      def run_search
        return anonymous_search if anonymous?

        validate_setup!
        return as_search if @as

        Access::Search.new(path: @path, http_method: @http_method, sources: Identity.principal_sources).call
      end

      # One request against exactly the requested principal, never a sample
      # and never a population retry: --as means "run as this one existing
      # record," not "start a search that happens to prefer it." Wrapped in
      # Access::Search::Result (with no attempts) purely so every downstream
      # adapter method below stays the same for every probe kind.
      def as_search
        principal = PrincipalReference.resolve(@as)
        sweep = Access::Sweep.new(path: @path, http_method: @http_method, principals: [principal], limit: 1).call
        Access::Search::Result.new(initial: sweep, attempts: [].freeze)
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
          probe: { identity: probe_identity },
          provenance: provenance,
          verified_usable: !winner.nil?,
          verified_identity: winner && identity_document(winner.identity),
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
          evidence.merge(count: items.size, identities: items.map { |item| identity_document(item.identity) })
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

      def error_document(error)
        type = error.is_a?(Identity::Error) ? "configuration_error" : "input_error"
        { schema_version: SCHEMA_VERSION, error: { type: type, message: error.message } }
      end

      def human(result)
        lines = ["Karst verification", "", "#{result.http_method} #{result.path}",
                 "Probe identity: #{probe_identity_description}", "",
                 probe_section_heading,
                 "  #{result.initial.outcomes.size} #{anonymous? ? 'request' : 'users tested'}"]
        lines << "  #{sample_usable_count(result)} verified usable" unless anonymous?
        append_key_evidence(lines, result.initial.outcomes)
        append_populations(lines, result)
        append_result(lines, result)
        lines.join("\n")
      end

      def probe_identity_description
        return "anonymous" if anonymous?
        return "the specific principal requested via --as" if @as

        "the application's own identities"
      end

      def probe_section_heading
        return "Probe" if anonymous?
        return "Requested" if @as

        "Sample"
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
