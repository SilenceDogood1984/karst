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
    # `identity` is a Karst::Identity::Evidence, carrying the identity Karst
    # was asked to send this request under (requested), what Karst's own
    # seam established (establishment), and what the application itself
    # resolved while running the request (observed) -- exactly the same
    # lifecycle Access::Sweep runs. There is deliberately no bare "principal"
    # field here: a requested/assumed identity is intent, not evidence about
    # what ran, and only `identity.confirmation` may be read to decide
    # whether they agree.
    #
    # body_representation says how faithfully body_params describes what was
    # sent:
    #
    #   :none    no request body was sent
    #   :json    a JSON object body, parsed and sanitized key by key
    #   :form    a form-encoded body, parsed and sanitized key by key
    #   :opaque  a body Karst sent verbatim but will not echo back, because
    #            it could not parse it well enough to sanitize it
    #
    # controller_completed, exception_class/exception_phase, and response
    # (status/redirect/response_content_type) are three separate target-scoped
    # facts, deliberately never inferred from one another:
    #
    #   controller_completed  true  -- process_action.action_controller finished
    #                                  with no exception
    #                         false  -- it finished carrying one
    #                       nil/unobserved -- it never fired for this request
    #                                  at all (nothing dispatched)
    #
    #   exception_phase        the most specific instrumentation-proven phase
    #                          an observed exception occurred in --
    #                          "controller", "render", or "unknown" -- derived
    #                          by matching the exception object (and its
    #                          #cause chain, since ActionView wraps a render
    #                          exception in ActionView::Template::Error before
    #                          it reaches the controller) against instrumented
    #                          render events. nil whenever exception_class is
    #                          nil: there is no phase to report for a request
    #                          that raised nothing.
    #
    # Both are read off ActiveSupport::Notifications payloads captured while
    # the target request ran, never off session.request/session.response --
    # those two objects are only updated by ActionDispatch::Integration::Session
    # *after* Rack::Test's app.call returns without raising. A target request
    # that raises before producing a response leaves them holding whatever the
    # previous request on the same session (identity establishment, most
    # often) last wrote, so reading them post-hoc would silently attribute an
    # earlier request's status/content type/location to this one.
    #
    # rendered is an Array of { virtual_path:, completed: } entries, one per
    # ActionView template/partial/layout Karst observed the target request
    # attempt (via "!render_template.action_view", the only notification
    # exposing a template's own relative virtual_path rather than its
    # absolute source file), in the order each one finished or raised.
    # completed is false exactly when that specific render carried an
    # exception; never inferred from the request's overall outcome.
    Observation = Value.define(
      :http_method, :url_path, :query_params, :route_params, :body_params, :body_representation,
      :content_type, :headers, :controller, :action, :controller_completed,
      :status, :response_content_type, :redirect,
      :halted_callback, :exception_class, :exception_phase, :rendered, :writes_observed, :write_count,
      :database_rollback_attempted, :elapsed_ms, :identity, :unobserved
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
