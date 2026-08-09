# frozen_string_literal: true

require "ipaddr"
require_relative "panel"

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

      LOOPBACK_RANGES = [IPAddr.new("127.0.0.0/8"), IPAddr.new("::1")].freeze
      private_constant :LOOPBACK_RANGES

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless owned?(env) && development? && loopback?(env)

        Panel.render
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

      # Only Rack's own REMOTE_ADDR, never client-supplied X-Forwarded-For or
      # Forwarded headers, which a non-local client could set to claim locality.
      def loopback?(env)
        address = IPAddr.new(env["REMOTE_ADDR"].to_s)
        LOOPBACK_RANGES.any? { |range| range.include?(address) }
      rescue IPAddr::Error
        false
      end
    end
  end
end
