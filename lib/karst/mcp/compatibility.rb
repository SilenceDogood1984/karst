# frozen_string_literal: true

module Karst
  module Mcp
    # Karst's MCP adapter is optional, but when requested it uses the MCP 1.5
    # server, tool, schema, response, and stdio transport APIs. Keep the
    # development dependency and the command's runtime activation guard on the
    # same deliberately narrow, tested release series.
    module Compatibility
      REQUIREMENT = "~> 1.5.0"
    end
  end
end
