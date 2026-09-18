# frozen_string_literal: true

require "json"
require "mcp"
require_relative "../cli/verification"

module Karst
  module Mcp
    # The one MCP tool Karst exposes: a thin transport adapter over
    # Karst::CLI::Verification#evidence, itself a thin adapter over
    # Access::Search. This class owns no verification behavior of its own --
    # it only shapes one MCP request into a Verification call and returns
    # exactly the evidence document `bin/rails karst:verify --json` would
    # print, so an agent calling this tool sees the same bounded runtime
    # evidence a developer sees at the terminal, never a separate MCP result
    # model.
    #
    # Every safety boundary an agent might reach for -- which principal to
    # run as, which population to try, whether to skip rollback, how many
    # requests to issue -- is owned by the host application's Karst
    # configuration and Access::Search itself; nothing about that is
    # settable here. The only inputs are the request an agent is allowed to
    # make: which path, and which HTTP method (GET only, currently).
    class VerifyAccessTool < MCP::Tool
      tool_name "verify_access"
      description <<~DESCRIPTION.strip
        Verify bounded GET access to a local path in the running Rails application.

        Karst executes the real application, under real existing identities
        drawn from the application's own configured principal source(s), inside
        a rolled-back database transaction, and reports what actually happened:
        HTTP status, redirect target, any halted callback, any raised
        exception, and whether a usable outcome was found. This is observed
        runtime evidence, not an inference about authorization rules -- Karst
        never explains *why* an outcome occurred, and this tool never
        impersonates the developer's browser or exposes Test As.

        Identity is reported as evidence, not intent. Every outcome carries an
        `identity` document separating the identity Karst was asked to run as
        (`requested`) from the one the application itself resolved while
        running the request (`observed`). Only `identity.confirmation` of
        "confirmed" or "confirmed_anonymous" means the request provably ran as
        that principal; "absent", "mismatch", "contaminated" and
        "unobservable" all mean it did not, and must never be reported as a
        principal having reached the route.

        Pass identity: "anonymous" to probe the route with no principal at
        all -- a request Karst also verifies the application actually saw as
        anonymous.
      DESCRIPTION

      input_schema(
        properties: {
          path: {
            type: "string",
            description: "Local application path to verify, e.g. \"/admin/imports/123\". " \
                         "Must be a local path (no scheme/host)."
          },
          method: {
            type: "string",
            description: "HTTP method to verify. Only GET is currently supported.",
            default: "GET"
          },
          identity: {
            type: "string",
            enum: %w[application_identities anonymous],
            description: "Which identity to probe as. \"application_identities\" (the default) runs the " \
                         "route as real existing identities from the application's own principal " \
                         "source(s); \"anonymous\" runs it with no principal established at all and " \
                         "verifies the application observed none.",
            default: "application_identities"
          }
        },
        required: ["path"]
      )

      class << self
        # server_context is part of MCP::Tool's call signature (the server
        # passes it by keyword whenever a tool's #call accepts it) but this
        # tool needs no per-request context beyond its own arguments.
        # rubocop:disable Lint/UnusedMethodArgument
        def call(path:, method: "GET", identity: nil, server_context: nil)
          document = ::Karst::CLI::Verification.new(path: path, http_method: method,
                                                    identity: probe_identity(identity)).evidence
          MCP::Tool::Response.new([{ type: "text", text: JSON.generate(document) }], error: document.key?(:error))
        end
        # rubocop:enable Lint/UnusedMethodArgument

        private

        # "application_identities" is the documented default rather than a
        # second spelling of nil, so an agent that passes it explicitly gets
        # the ordinary search instead of an argument error.
        def probe_identity(value)
          return nil if value.nil? || value.to_s == "application_identities"

          value
        end
      end
    end
  end
end
