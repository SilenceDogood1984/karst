# frozen_string_literal: true

module Karst
  module Mcp
    # Karst's MCP adapter is optional, but when requested it uses the MCP
    # server, tool, schema, response, and stdio transport APIs, which are
    # unchanged across the 1.5 and 1.6 release series. Keep the development
    # dependency and the command's runtime activation guard on the same
    # bounded, tested range: CI exercises its oldest release and the newest
    # 1.6.x, and a later minor series is admitted only after it has been
    # tested the same way.
    module Compatibility
      REQUIREMENTS = [">= 1.5.0", "< 1.7"].freeze

      class << self
        # The requirement as it is written in a Gemfile, e.g.
        # `">= 1.5.0", "< 1.7"`.
        def gemfile_requirement
          REQUIREMENTS.map(&:inspect).join(", ")
        end
      end
    end
  end
end
