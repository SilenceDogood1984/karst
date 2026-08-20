# frozen_string_literal: true

require "uri"
require_relative "errors"

module Karst
  module Access
    # The single definition of "a local application path Karst may execute".
    # Access::Sweep and Reproduction::Exercise both route their caller-supplied
    # target through here, so there is exactly one place to audit rather than
    # one per caller -- a security check duplicated across callers is a
    # security check that eventually diverges.
    module LocalPath
      Parsed = Struct.new(:path, :query, keyword_init: true)

      class << self
        # Splits a target into its path and raw query string, refusing
        # anything that is not a local application path. A scheme, an
        # authority, or a protocol-relative "//host" target is rejected
        # outright rather than normalized into something local-looking.
        def parse(value)
          raw = value.to_s
          path, query = raw.split("?", 2)
          path = path.to_s
          uri = URI.parse(path)
          local = uri.relative? && path.start_with?("/") && !path.start_with?("//")
          raise UnsafeTarget, "target must be a local application path" unless local

          Parsed.new(path: path, query: query)
        rescue URI::InvalidURIError
          raise UnsafeTarget, "target must be a valid local application path"
        end

        # The query-stripped path, for callers (Access::Sweep) that
        # deliberately never carry a query string.
        def path(value)
          parse(value).path
        end
      end
    end
  end
end
