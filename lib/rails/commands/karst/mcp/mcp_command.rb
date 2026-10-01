# frozen_string_literal: true

require "rails/command"
require_relative "../boot"
require "karst/mcp/compatibility"
require "karst/version"

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
            gem "mcp", *::Karst::Mcp::Compatibility::REQUIREMENTS
          rescue Gem::LoadError
            abort mcp_unavailable_message
          end

          require "karst/mcp/server"
        end

        # "Not installed" and "installed at a version Karst does not support"
        # need different fixes, so they get different messages: telling an
        # application that already has mcp in its bundle to add it would
        # send its developer looking for a problem they don't have.
        def mcp_unavailable_message
          requirement = ::Karst::Mcp::Compatibility.gemfile_requirement
          installed = installed_mcp_version
          if installed
            "Karst MCP found mcp #{installed}, but Karst #{::Karst::VERSION} " \
              "requires mcp #{requirement}. Constrain it in your Gemfile with " \
              "gem \"mcp\", #{requirement} and run bundle update mcp."
          else
            "Karst MCP requires the optional dependency. " \
              "Add gem \"mcp\", #{requirement} to your Gemfile and run bundle install."
          end
        end

        # The mcp version this process can see but could not activate, if
        # any. Bundler marks every gem in the bundle as loaded, so under
        # `bin/rails` this is the version the bundle resolved; outside
        # Bundler, it is the newest one installed.
        def installed_mcp_version
          spec = Gem.loaded_specs["mcp"] || Gem::Specification.find_all_by_name("mcp").max_by(&:version)
          spec&.version
        end
      end
    end
  end
end
