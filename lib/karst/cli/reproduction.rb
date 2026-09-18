# frozen_string_literal: true

require "json"
require_relative "../../karst"
require_relative "identity_serialization"
require_relative "../reproduction/exercise"
require_relative "../reproduction/curl"

module Karst
  module CLI
    # The one adapter over Karst::Reproduction::Exercise, shared by
    # `bin/rails karst:reproduce`, the MCP reproduce_request tool, and the
    # /karst panel -- exactly as Karst::CLI::Verification is shared by
    # `karst:verify` and verify_access. Nothing downstream re-runs an
    # Exercise or re-serializes an Observation, so the recipe an agent reads
    # and the recipe a developer reads cannot drift apart.
    #
    # This class owns two decisions Exercise deliberately does not: which
    # identity to send the request under (the first candidate Karst's own
    # sampler offers, or a genuine anonymous probe), and how an Observation
    # becomes a stable evidence document.
    # rubocop:disable Metrics/ClassLength
    class Reproduction
      include IdentitySerialization

      # 2 (was 1): `identity` is now a Karst::Identity::Evidence document --
      # requested/observed/confirmation, exactly like verify_access -- rather
      # than a mechanism/assumed pair that only ever described what Karst
      # asked for. A consumer reading the old `assumed` key and believing it
      # described the identity the request actually ran under is precisely
      # the false attribution this schema exists to make impossible.
      SCHEMA_VERSION = 2

      # Same-connection rollback contains database writes and nothing else.
      # Named in the document rather than left implicit, so an agent
      # reasoning about whether to issue a mutating request sees the real
      # boundary instead of assuming "isolated" means isolated.
      NOT_ISOLATED = ["background jobs", "mail", "outbound HTTP", "files", "other database connections"].freeze

      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, http_method: "GET", body: nil, content_type: nil, headers: {},
                     anonymous: false, base_url: nil, output: $stdout, json: false)
        @path = path
        @http_method = http_method
        @body = body
        @content_type = content_type
        @headers = headers || {}
        @anonymous = anonymous
        @base_url = base_url.to_s.empty? ? Karst::Reproduction::Curl::DEFAULT_BASE_URL : base_url.to_s
        @output = output
        @json = json
      end
      # rubocop:enable Metrics/ParameterLists

      def call
        observation = run
        @output.puts(@json ? JSON.generate(document(observation)) : human(observation))
        observation.exception_class ? 1 : 0
      rescue Access::Error, Identity::Error, ArgumentError => e
        @output.puts(@json ? JSON.generate(error_document(e)) : "Karst cannot reproduce this request:\n#{e.message}")
        2
      end

      # The stable evidence document, with no dependency on @output. Always
      # returns a Hash -- either the recipe or error_document(e) -- so no
      # adapter has to decide how a Karst failure becomes a transport error.
      def evidence
        document(run)
      rescue Access::Error, Identity::Error, ArgumentError => e
        error_document(e)
      end

      private

      def run
        @identity_reason = nil
        principal = @anonymous ? Identity::ANONYMOUS : sampled_principal
        Karst::Reproduction::Exercise.new(
          path: @path, http_method: @http_method, body: @body, content_type: @content_type,
          headers: @headers, principal: principal
        ).call
      end

      # One candidate, not a sample: reproduction issues exactly one request,
      # so asking the sampler for more than one would query for records
      # Karst has already decided it will never send. Falling back to
      # Identity::ANONYMOUS (rather than a bare nil) when no candidate is
      # available means this still runs, and is still confirmed, as a real
      # anonymous probe -- never a request whose identity Karst simply never
      # got around to establishing.
      def sampled_principal
        selection = Access::PrincipalSelection.new(sources: Identity.principal_sources, limit: 1).call
        principal = selection.principals.first
        return principal if principal

        @identity_reason = "no principal was available from the configured principal source"
        Identity::ANONYMOUS
      rescue Identity::Error => e
        @identity_reason = e.message
        Identity::ANONYMOUS
      end

      # rubocop:disable Metrics/MethodLength
      def document(observation)
        {
          schema_version: SCHEMA_VERSION,
          request: request(observation),
          identity: identity(observation),
          execution: execution(observation),
          response: response(observation),
          unobserved: observation.unobserved,
          isolation: { database: "same_connection_rollback_attempted", not_isolated: NOT_ISOLATED },
          reproduce: { curl: curl(observation) },
          summary: { elapsed_ms: observation.elapsed_ms }
        }
      end
      # rubocop:enable Metrics/MethodLength

      def request(observation)
        {
          method: observation.http_method, path: observation.url_path,
          url: Karst::Reproduction::Curl.url(observation, @base_url),
          query_params: observation.query_params, route_params: observation.route_params,
          content_type: observation.content_type, body_format: observation.body_representation.to_s,
          body: (observation.body? ? observation.body_params : nil), headers: observation.headers
        }
      end

      # The same requested/observed/confirmation document verify_access
      # produces (see Karst::CLI::IdentitySerialization), plus `reason`: why
      # Karst ran this request under no identity at all, when that was not
      # what the caller asked for (an anonymous request the caller
      # deliberately chose carries no reason -- there is nothing to explain).
      def identity(observation)
        identity_document(observation.identity).merge(reason: @identity_reason)
      end

      def execution(observation)
        {
          controller: observation.controller, action: observation.action,
          halted_callback: observation.halted_callback, exception_class: observation.exception_class,
          writes_observed: observation.writes_observed, write_count: observation.write_count,
          database_rollback_attempted: observation.database_rollback_attempted
        }
      end

      def response(observation)
        { status: observation.status, content_type: observation.response_content_type,
          redirect: observation.redirect }
      end

      def curl(observation)
        Karst::Reproduction::Curl.render(observation, base_url: @base_url)
      end

      def error_document(error)
        type = error.is_a?(Identity::Error) ? "configuration_error" : "input_error"
        { schema_version: SCHEMA_VERSION, error: { type: type, message: error.message } }
      end

      def human(observation)
        lines = ["Karst request reproduction", "", "Request",
                 "  #{observation.http_method} #{observation.url_path}"]
        append_identity(lines, observation)
        append_execution(lines, observation)
        append_response(lines, observation)
        append_effects(lines, observation)
        append_unobserved(lines, observation)
        lines.push("", "Reproduce", curl(observation).lines.map { |line| "  #{line}" }.join.rstrip)
        lines.join("\n")
      end

      def append_identity(lines, observation)
        lines.push("", "Identity", "  #{identity_line(observation.identity)}")
        lines << "  (#{@identity_reason})" if @identity_reason
        lines << "  Karst assumed this identity directly; it did not exercise how an external " \
                 "client would authenticate this endpoint."
      end

      def append_execution(lines, observation)
        lines.push("", "Observed execution")
        lines << if observation.controller
                   "  #{observation.controller}##{observation.action}"
                 else
                   "  no controller dispatched"
                 end
        lines << "  halted at #{observation.halted_callback}" if observation.halted_callback
        lines << "  exception #{observation.exception_class}" if observation.exception_class
      end

      def append_response(lines, observation)
        lines.push("", "Observed response")
        type = observation.response_content_type
        lines << if observation.status
                   "  #{observation.status}#{" #{type}" if type}"
                 else
                   "  no response observed"
                 end
        lines << "  redirect #{observation.redirect}" if observation.redirect
      end

      def append_effects(lines, observation)
        lines.push("", "Observed effects",
                   "  #{observation.write_count} database #{observation.write_count == 1 ? 'write' : 'writes'} " \
                   "(rollback attempted on the same connection)")
        lines << "  Not isolated: #{NOT_ISOLATED.join(', ')}."
      end

      def append_unobserved(lines, observation)
        return if observation.unobserved.empty?

        lines.push("", "Not observed", "  #{observation.unobserved.join(', ')}")
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
