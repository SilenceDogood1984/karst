# frozen_string_literal: true

require_relative "../value"
require_relative "observation"

module Karst
  module Identity
    # The three identities of one probe request, kept deliberately apart:
    #
    #   requested -- what the caller asked Karst to execute as (intent).
    #                nil means an anonymous probe was requested.
    #   establishment -- what Karst's own identity seam managed to set up
    #                (setup), never evidence on its own.
    #   observed  -- what the Rails application itself resolved as its
    #                authenticated principal while running the request
    #                (evidence).
    #
    # `confirmation` is the only field a machine consumer should read to
    # decide whether a principal claim is true, and it fails closed:
    #
    #   :confirmed           requested a principal, observed that same one
    #   :confirmed_anonymous requested anonymous, observed no principal
    #   :mismatch            requested a principal, observed a different one
    #   :absent              requested a principal, observed none
    #   :contaminated        requested anonymous, observed a principal
    #   :unobservable        Karst could not determine what identity the
    #                        application used
    #
    # Only :confirmed and :confirmed_anonymous are evidence about identity.
    Evidence = Value.define(:requested, :observed, :confirmation, :observed_at, :observation_source,
                            :observation_error, :establishment, :establishment_error, :cleanup_error,
                            :changed_during_request) do
      def confirmed?
        %i[confirmed confirmed_anonymous].include?(confirmation)
      end

      def anonymous_probe?
        requested.nil?
      end
    end

    # Derives one Evidence from the observations a probe actually collected.
    module EvidenceBuilder
      class << self
        # `halt` is the observation taken at the moment an access callback
        # halted the request -- the state the application had established
        # when that access decision was made -- and `completion` the one
        # taken after the request returned. Both may be nil (never attempted).
        # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
        def build(requested:, halt: nil, completion: nil, establishment: nil,
                  establishment_error: nil, cleanup_error: nil)
          decisive = decisive_observation(halt, completion)
          Evidence.new(
            requested: requested,
            observed: decisive&.observable? ? decisive.principal : nil,
            confirmation: confirmation(requested, decisive),
            observed_at: decisive&.observable? ? phase_of(decisive, halt) : nil,
            observation_source: decisive&.source,
            observation_error: decisive&.error,
            establishment: establishment,
            establishment_error: establishment_error,
            cleanup_error: cleanup_error,
            changed_during_request: changed?(halt, completion)
          )
        end
        # rubocop:enable Metrics/ParameterLists, Metrics/MethodLength

        private

        # The halt moment is the one that explains an access decision, so it
        # wins whenever it produced a real observation; a failed observation
        # there still falls back to the completed request rather than
        # discarding evidence Karst does hold.
        def decisive_observation(halt, completion)
          return halt if halt&.observable?
          return completion if completion&.observable?

          halt || completion
        end

        def phase_of(decisive, halt)
          decisive.equal?(halt) ? :halted_callback : :request_completion
        end

        def confirmation(requested, decisive)
          return :unobservable if decisive.nil? || !decisive.observable?
          return anonymous_confirmation(decisive.principal) if requested.nil?
          return :absent if decisive.principal.nil?

          same?(requested, decisive.principal) ? :confirmed : :mismatch
        end

        def anonymous_confirmation(observed)
          observed.nil? ? :confirmed_anonymous : :contaminated
        end

        def same?(requested, observed)
          requested.model_name.to_s == observed.model_name.to_s &&
            requested.id.to_s == observed.id.to_s
        end

        def changed?(halt, completion)
          return false unless halt&.observable? && completion&.observable?

          halt.principal != completion.principal
        end
      end
    end
  end
end
