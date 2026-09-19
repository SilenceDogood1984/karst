# frozen_string_literal: true

require "rails/command"
require_relative "../boot"
require "karst/mcp/compatibility"

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
          load_mcp!
          boot_karst_application!
          ::Karst::Mcp::Server.run!
        end

        private

        def load_mcp!
          begin
            gem "mcp", ::Karst::Mcp::Compatibility::REQUIREMENT
          rescue Gem::LoadError
            abort "Karst MCP requires the optional dependency. " \
                  "Add gem \"mcp\", \"#{::Karst::Mcp::Compatibility::REQUIREMENT}\" " \
                  "to your Gemfile and run bundle install."
          end

          require "karst/mcp/server"
        end
      end
    end
  end
end
