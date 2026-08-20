# frozen_string_literal: true

require_relative "../value"

module Karst
  module Reproduction
    # One request Karst actually issued, and what actually happened.
    #
    # Every member is either something Karst observed or an explicit
    # placeholder standing in for something Karst redacted. Nothing here is
    # inferred from routes, controller source, or strong-parameter
    # declarations: a field Karst could not observe is nil and is named in
    # #unobserved, so a consumer can say "Karst did not see this" instead of
    # reading an absent value as a negative result.
    #
    # body_representation says how faithfully body_params describes what was
    # sent:
    #
    #   :none    no request body was sent
    #   :json    a JSON object body, parsed and sanitized key by key
    #   :form    a form-encoded body, parsed and sanitized key by key
    #   :opaque  a body Karst sent verbatim but will not echo back, because
    #            it could not parse it well enough to sanitize it
    Observation = Value.define(
      :http_method, :url_path, :query_params, :route_params, :body_params, :body_representation,
      :content_type, :headers, :controller, :action, :status, :response_content_type, :redirect,
      :halted_callback, :exception_class, :writes_observed, :write_count,
      :database_rollback_attempted, :elapsed_ms, :principal, :unobserved
    ) do
      def observed?(field)
        !unobserved.include?(field.to_s)
      end

      def body?
        body_representation != :none
      end
    end
  end
end
