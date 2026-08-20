# frozen_string_literal: true

require "mcp"
require_relative "verify_access_tool"
require_relative "reproduce_request_tool"
require_relative "../version"

module Karst
  module Mcp
    # Builds and runs Karst's stdio MCP server: two tools
    # (VerifyAccessTool, ReproduceRequestTool), no prompts, no resources, no
    # other transport. The host Rails
    # application must already be booted (see
    # Rails::Command::Karst::Boot#boot_karst_application!, used by
    # `bin/rails karst:mcp`) before this is built -- the server itself never
    # boots or reboots the application, so one process serves every tool call
    # for its lifetime against the one already-running application.
    module Server
      INSTRUCTIONS = <<~TEXT.strip
        Karst verifies bounded runtime access to local paths in this Rails application.

        Agent proposes: a hypothesis about who can reach a path.
        Karst proves: it executes the real application, under real existing
        identities, and reports observed evidence -- HTTP status, redirect,
        halted callback, exception, and whether a usable outcome was found.

        Call verify_access(path:, method:) to check one path. Karst does not
        infer authorization rules, explain application code, or choose which
        principal to try on your behalf -- it only reports what actually
        happened when a real request was made under the application's own
        configured identities.

        Call reproduce_request(path:, method:, body:, content_type:) to answer a
        different question: "something calls this endpoint -- what request do I
        send to exercise the same behavior?". It issues exactly one request and
        returns the observed controller/action, halted callback, response, and a
        redacted cURL command for what Karst actually sent. Secrets are replaced
        by placeholders; a command that needs a credential filled in is working
        as intended.
      TEXT

      class << self
        def build
          MCP::Server.new(
            name: "karst",
            title: "Karst",
            version: Karst::VERSION,
            instructions: INSTRUCTIONS,
            tools: [VerifyAccessTool, ReproduceRequestTool],
            configuration: MCP::Configuration.new(exception_reporter: method(:report_exception))
          )
        end

        # Runs until the client closes stdin (or the process receives
        # SIGINT). stdout is reserved for MCP protocol frames; anything Karst
        # or the host application needs to say for local debugging goes to
        # stderr instead, matching how `rails server`/`rails console` behave.
        def run!
          server = build
          transport = MCP::Server::Transports::StdioTransport.new(server)
          server.transport = transport
          transport.open
        end

        private

        def report_exception(exception, _context)
          warn("karst-mcp: #{exception.class}: #{exception.message}")
        end
      end
    end
  end
end
