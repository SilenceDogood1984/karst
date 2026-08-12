# frozen_string_literal: true

require "rails/command"
require "karst/mcp/server"
require_relative "../boot"

module Rails
  module Command
    module Karst
      # Rails command entry point for Karst's MCP server: `bin/rails karst:mcp`.
      # Boots the host application once, the same way any other Karst Rails
      # command does (see Karst::Boot), then serves verify_access tool calls
      # over stdio for the lifetime of the process -- never a second
      # application copy per call.
      class McpCommand < Base
        include Karst::Boot

        desc "Run Karst's MCP server over stdio, exposing the verify_access tool"
        def perform(*)
          boot_karst_application!
          ::Karst::Mcp::Server.run!
        end
      end
    end
  end
end
