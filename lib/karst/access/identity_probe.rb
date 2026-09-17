# frozen_string_literal: true

require_relative "../identity"
require_relative "observed_endpoint"

module Karst
  module Access
    # One probe request's complete identity lifecycle, kept out of
    # Access::Sweep so the rule it exists to enforce stays readable:
    #
    #   a requested identity is intent, an established one is setup, and only
    #   an observed one is evidence.
    #
    # Deliberately never raises out of establishment or release. A probe whose
    # identity setup failed is exactly the probe whose runtime observation
    # matters most ("asked for User#123, application saw nobody, halted at
    # authorize_admin"), so the request still runs and is still observed --
    # the failure is recorded as evidence rather than swallowing the probe or
    # being mistaken for an application exception.
    class IdentityProbe
      # Establishment outcomes:
      #
      #   :established        the requested identity's assume seam ran
      #   :failed             that seam raised (identity was not established)
      #   :cleared            an anonymous probe: no identity was established
      #                       and any queued/configured identity was dropped
      #   :clear_failed       an anonymous probe whose configured
      #                       clear_identity hook raised
      attr_reader :requested, :request_env

      def initialize(principal)
        @principal = principal
        @anonymous = Identity.anonymous?(principal)
        @requested = @anonymous ? nil : Identity.describe(principal)
        @observations = {}
        @thread = Thread.current
      end

      def anonymous?
        @anonymous
      end

      def endpoint(application)
        ObservedEndpoint.new(application, self)
      end

      def capture_env(env)
        @request_env = env
      end

      def establish(session)
        @anonymous ? establish_anonymous(session) : establish_principal(session)
      end

      # Runs in the caller's ensure, so it must survive anything the request
      # did. An anonymous probe established nothing, but still releases: a
      # configured clear hook is the application's own "make this anonymous
      # again" seam, and a Warden principal queued for a request that never
      # reached Warden must not survive into the next probe.
      def release(session)
        Identity.clear(session, principal: @principal) unless @anonymous
      rescue StandardError => e
        @cleanup_error = describe_error(e)
      ensure
        Identity::WardenAdapter.discard_pending!
      end

      # Called at each moment worth observing. Ignores events raised on
      # another thread: ActiveSupport::Notifications subscriptions are
      # process-wide, and a concurrent request in a real development server
      # must never be mistaken for this probe.
      def observe(phase)
        return unless Thread.current == @thread

        @dispatched ||= dispatched_from(@request_env)
        @observations[phase] ||= Identity::Observer.observe(@request_env, requested: observable_principal)
      end

      # The controller class and action the probed request actually reached,
      # recorded at observation time rather than read back afterwards: an
      # identity seam that signs a probe out through its own endpoint issues
      # a second request on the same session, and the last env Karst holds is
      # then that sign-out request's, not the probed route's.
      def dispatched
        @dispatched || [nil, nil]
      end

      def observed_this_probe?(phase)
        @observations.key?(phase)
      end

      def evidence
        Identity::EvidenceBuilder.build(requested: @requested, halt: @observations[:halted_callback],
                                        completion: @observations[:request_completion],
                                        establishment: @establishment,
                                        establishment_error: @establishment_error,
                                        cleanup_error: @cleanup_error)
      end

      private

      def dispatched_from(env)
        instance = env && env["action_controller.instance"]
        return nil unless instance

        [instance.class.name, (instance.action_name if instance.respond_to?(:action_name))]
      rescue StandardError
        nil
      end

      def observable_principal
        @anonymous ? nil : @principal
      end

      def establish_principal(session)
        Identity.assume(session, @principal)
        @establishment = :established
      rescue StandardError => e
        @establishment = :failed
        @establishment_error = describe_error(e)
      end

      # Every probe already runs in its own freshly built integration session,
      # which carries no cookies and no Warden proxy, so anonymity is
      # established by construction rather than by logging something out.
      # What can still leak across probes is Karst's own queued identity, so
      # that is dropped explicitly; a configured clear_identity hook is then
      # run as well, because it is the only seam that can reach application
      # state Karst does not know about.
      def establish_anonymous(session)
        Identity::WardenAdapter.discard_pending!
        @establishment = :cleared
        hook = Karst.config.clear_identity
        return unless hook.respond_to?(:call)

        hook.call(session)
      rescue StandardError => e
        @establishment = :clear_failed
        @establishment_error = describe_error(e)
      end

      def describe_error(error)
        "#{error.class}: #{error.message}"
      end
    end
  end
end
