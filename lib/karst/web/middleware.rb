# frozen_string_literal: true

require_relative "locality"
require_relative "panel"
require "rack/utils"

module Karst
  module Web
    # Owns Karst's development-only HTTP evidence surface directly at the Rack
    # boundary, rather than through a Rails engine. An engine would mount routes,
    # load ActionView, and integrate into the host application's controller
    # stack; Karst needs none of that to answer "what evidence does Karst
    # currently hold," and all of it would blur the line between Karst's own
    # page and the host application it is inspecting.
    #
    # Sitting on the Rack boundary also keeps a path open for later
    # request-scoped evidence: a future version of this middleware can observe
    # and correlate the requests passing through it without redesigning how
    # "/karst" itself is served, and without depending on any host rendering
    # assumptions.
    class Middleware
      OWNED_PATH = "/karst"
      private_constant :OWNED_PATH

      def initialize(app)
        @app = app
        @locality = Locality.new
      end

      def call(env)
        return @app.call(env) unless owned?(env) && development? && @locality.local?(env["REMOTE_ADDR"])

        Panel.render(params: Rack::Utils.parse_nested_query(env["QUERY_STRING"].to_s))
      end

      private

      def owned?(env)
        env["PATH_INFO"] == OWNED_PATH
      end

      # Re-checked per request as defense in depth: the middleware is only
      # inserted into the stack in development (see Railtie), but this keeps
      # that guarantee independent of how or when the middleware was inserted.
      def development?
        Rails.env.development?
      end
    end
  end
end
