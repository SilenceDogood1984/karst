# frozen_string_literal: true

require_relative "../identity"
require_relative "observed_endpoint"

module Karst
  module Access
    # One probe request's complete identity lifecycle, kept out of
    # Access::Probe so the rule it exists to enforce stays readable:
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

      # Called as the target request starts. Identity setup may already have
      # issued requests on the same session (a sign-in endpoint, a clear
      # hook), and only the target's own env may ever be observed -- so
      # whatever setup left behind is forgotten here, and a target that never
      # reaches the application leaves nothing to observe at all.
      def begin_target
        @request_env = nil
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

      # Karst's own sign-in raised inside the target request itself (see
      # Identity::EstablishmentError): identity was never established, and
      # the request stopped before the application dispatched it. Whatever
      # half-applied state its env holds is not the application's, so
      # nothing is observed from it.
      def establishment_failed(message)
        @establishment = :failed
        @establishment_error = message
        @request_env = nil
        @observations[:request_completion] ||=
          Identity::Observation.new(principal: nil, source: nil,
                                    error: "the request stopped during Karst's own sign-in, before the application ran")
      end

      # Called at each moment worth observing. Ignores events raised on
      # another thread: ActiveSupport::Notifications subscriptions are
      # process-wide, and a concurrent request in a real development server
      # must never be mistaken for this probe.
      def observe(phase)
        return unless Thread.current == @thread

        @observations[phase] ||= Identity::Observer.observe(@request_env, requested: observable_principal)
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
