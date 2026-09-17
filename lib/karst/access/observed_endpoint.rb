# frozen_string_literal: true

module Karst
  module Access
    # Wraps the probe endpoint for exactly one probe request so Karst holds
    # the request's own Rack env while it is still running.
    #
    # This is what makes halt-time identity observation possible: when
    # "halted_callback.action_controller" fires, the request has not returned
    # yet, so ActionDispatch::Integration::Session cannot hand Karst its env
    # (it only records one afterwards, and not at all when the application
    # raises). Rails has already put the dispatching controller instance on
    # this same env object by then -- ActionController::Metal#set_request!
    # sets env["action_controller.instance"] before any callback runs -- and
    # every middleware in the probe stack mutates that one env in place, so
    # holding it here is enough to observe the application's runtime identity
    # both mid-request and after it, without instrumenting the application.
    class ObservedEndpoint
      def initialize(app, probe)
        @app = app
        @probe = probe
      end

      def call(env)
        @probe.capture_env(env)
        @app.call(env)
      end

      # ActionDispatch::Integration::Session asks the endpoint it was given
      # for things other than #call (#routes, for url_options), so this must
      # stay transparent rather than merely callable.
      def respond_to_missing?(name, include_private = false)
        @app.respond_to?(name, include_private) || super
      end

      # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- anonymous
      # argument/block forwarding needs Ruby 3.x; this file runs on Ruby 2.7.
      def method_missing(name, *arguments, &block)
        return @app.public_send(name, *arguments, &block) if @app.respond_to?(name)

        super
      end
      # rubocop:enable Naming/BlockForwarding, Style/ArgumentsForwarding
    end
  end
end
