# frozen_string_literal: true

require_relative "../cli/reproduction"

module Karst
  module Mcp
    # MCP-specific boundary in front of the human-capable reproduction
    # adapter. CLI and /karst callers intentionally use CLI::Reproduction
    # directly and retain its full method support; an MCP caller reaches it
    # only after this allowlist has accepted the method.
    class Reproduction
      SAFE_METHODS = %w[GET HEAD].freeze

      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, method: "GET", body: nil, content_type: nil, headers: nil,
                     anonymous: false, base_url: nil)
        @path = path
        @method = method.to_s.strip.upcase
        @body = body
        @content_type = content_type
        @headers = headers
        @anonymous = anonymous
        @base_url = base_url
      end
      # rubocop:enable Metrics/ParameterLists

      def evidence
        return disabled_document unless permitted?

        CLI::Reproduction.new(
          path: @path, http_method: @method, body: @body, content_type: @content_type,
          headers: @headers || {}, anonymous: @anonymous, base_url: @base_url
        ).evidence
      end

      private

      def permitted?
        SAFE_METHODS.include?(@method) || Karst.config.mcp_mutating_requests == true
      end

      def disabled_document
        {
          schema_version: CLI::Reproduction::SCHEMA_VERSION,
          error: {
            type: "method_disabled",
            message: "#{displayed_method} is disabled for MCP reproduction; the host application must " \
                     "explicitly enable mutating MCP requests with config.mcp_mutating_requests = true"
          }
        }
      end

      def displayed_method
        @method.empty? ? "the requested method" : @method
      end
    end
  end
end
