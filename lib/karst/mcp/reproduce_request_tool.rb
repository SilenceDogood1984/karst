# frozen_string_literal: true

require "json"
require "mcp"
require_relative "../cli/reproduction"

module Karst
  module Mcp
    # Karst's second, and deliberately last, MCP tool: a thin transport
    # adapter over Karst::CLI::Reproduction#evidence.
    #
    # It exists separately from verify_access rather than as a mode of it
    # because the two answer different questions with different blast
    # radii. verify_access answers "which existing user can reach this
    # page", by issuing up to access_sweep_limit bounded GET requests
    # automatically; it is documented as GET-only and must stay that way,
    # since running a mutating method as 25 users would mean 25 real
    # creates, 25 enqueued jobs, and 25 delivered mails. reproduce_request
    # answers "what request exercises this behavior", by issuing exactly
    # one request the caller fully specified. Folding a mutating,
    # caller-supplied-body mode into a tool whose contract promises bounded
    # read-only verification would make that contract false.
    class ReproduceRequestTool < MCP::Tool
      tool_name "reproduce_request"
      description <<~DESCRIPTION.strip
        Issue exactly one request against the running local Rails application and
        return a redacted, reproducible recipe for it.

        Use this to answer "something calls this Rails endpoint -- what request
        do I send to exercise the same behavior?". Karst executes the real
        application inside a rolled-back database transaction and reports what
        actually happened: the controller and action that dispatched, any halted
        callback (this is the observed authentication or authorization gate --
        Karst never infers one from code), any raised exception, observed
        database writes, response status and content type, plus a cURL command
        for the exact request Karst sent.

        This is observed runtime evidence. A field Karst could not observe is
        null and named in "unobserved"; nothing is inferred from routes,
        controller source, or strong parameters.

        Secrets are never returned. Request parameters pass through the
        application's own Rails config.filter_parameters plus a conservative
        credential-name filter, and credential-bearing headers are replaced by
        placeholders such as <API_KEY> or <AUTH_TOKEN> without their values ever
        being read. A returned command that needs a credential filled in is
        working as intended.

        Side effects: exactly one request is issued. Database writes on the
        request's own connection are rolled back; background jobs, mail,
        outbound HTTP, files, and other database connections are not isolated.
        Prefer a non-GET method only when the caller actually asked to exercise
        that behavior.
      DESCRIPTION

      input_schema(
        properties: {
          path: {
            type: "string",
            description: "Local application path, e.g. \"/api/v1/inspections\". Must be local " \
                         "(no scheme/host). May include a query string."
          },
          method: {
            type: "string",
            description: "HTTP method to issue.",
            enum: %w[GET HEAD POST PUT PATCH DELETE],
            default: "GET"
          },
          body: { type: "string", description: "Raw request body. Requires content_type." },
          content_type: {
            type: "string",
            description: "Content type of body, e.g. \"application/json\". Required whenever body is given."
          },
          headers: {
            type: "object",
            description: "Request headers to send, as name => value. Credential-bearing headers are " \
                         "sent as given but never echoed back.",
            additionalProperties: { type: "string" }
          },
          anonymous: {
            type: "boolean",
            description: "Send without assuming any application identity. Defaults to false, in which " \
                         "case Karst assumes one existing identity from the application's own " \
                         "configured principal source.",
            default: false
          },
          base_url: {
            type: "string",
            description: "Base URL for the generated cURL command. Defaults to http://localhost:3000."
          }
        },
        required: ["path"]
      )

      class << self
        # server_context is part of MCP::Tool's call signature; this tool
        # needs no per-request context beyond its own arguments.
        # rubocop:disable Lint/UnusedMethodArgument, Metrics/ParameterLists
        def call(path:, method: "GET", body: nil, content_type: nil, headers: nil,
                 anonymous: false, base_url: nil, server_context: nil)
          document = ::Karst::CLI::Reproduction.new(
            path: path, http_method: method, body: body, content_type: content_type,
            headers: headers || {}, anonymous: anonymous, base_url: base_url
          ).evidence
          MCP::Tool::Response.new([{ type: "text", text: JSON.generate(document) }], error: document.key?(:error))
        end
        # rubocop:enable Lint/UnusedMethodArgument, Metrics/ParameterLists
      end
    end
  end
end
