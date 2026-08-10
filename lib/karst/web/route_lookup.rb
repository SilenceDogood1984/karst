# frozen_string_literal: true

require "uri"
require "active_support/core_ext/string/inflections"

module Karst
  module Web
    # Establishes route context for a manually entered application path. Rails'
    # router is the authority: Karst does not infer a controller or action from
    # the shape of the URL.
    class RouteLookup
      Result = Struct.new(:params, :limitation, keyword_init: true)

      def initialize(path:, http_method:, application: Rails.application)
        @path = path.to_s.strip
        @http_method = http_method.to_s.strip.upcase
        @application = application
      end

      def call
        path = local_path
        recognized = @application.routes.recognize_path(path, method: method)
        return limitation("the recognized route did not identify a controller and action") unless complete?(recognized)

        Result.new(params: recognized_params(recognized, path))
      rescue URI::InvalidURIError
        limitation("Path must be a valid local application path.")
      rescue ActionController::RoutingError
        limitation("Rails could not recognize that path and method. Karst will not guess the route.")
      rescue StandardError => e
        limitation("Rails route recognition was unavailable (#{e.class}). Karst will not guess the route.")
      end

      private

      def complete?(recognized)
        !recognized[:controller].to_s.empty? && !recognized[:action].to_s.empty?
      end

      def recognized_params(recognized, path)
        {
          "controller" => "#{recognized[:controller].to_s.camelize}Controller",
          "action" => recognized[:action].to_s, "method" => method, "path" => path
        }
      end

      def local_path
        raw = @path.split("?", 2).first
        uri = URI.parse(raw)
        valid = uri.relative? && raw.start_with?("/") && !raw.start_with?("//")
        raise URI::InvalidURIError unless valid

        raw
      end

      def method
        @http_method.empty? ? "GET" : @http_method
      end

      def limitation(message)
        Result.new(params: { "method" => method, "path" => @path }, limitation: message)
      end
    end
  end
end
