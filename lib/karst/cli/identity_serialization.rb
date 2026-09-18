# frozen_string_literal: true

module Karst
  module CLI
    # The one place a Karst::Identity::Evidence becomes the JSON/MCP-facing
    # identity document, shared by Karst::CLI::Verification and
    # Karst::CLI::Reproduction so the two schemas can never describe identity
    # evidence differently -- a probe's `identity` document means the same
    # thing regardless of which adapter produced it.
    module IdentitySerialization
      private

      # The whole point of this schema. `requested` is intent, `observed` is
      # what the application resolved while running the request, and
      # `confirmation` is the only field that says whether a principal claim
      # about this request is true. Anything other than
      # "confirmed"/"confirmed_anonymous" means it is not.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def identity_document(evidence)
        return nil unless evidence

        {
          requested: evidence.requested && principal(evidence.requested),
          observed: observed_principal(evidence.observed),
          confirmation: evidence.confirmation.to_s,
          observed_at: evidence.observed_at&.to_s,
          observation_source: evidence.observation_source&.to_s,
          observation_error: evidence.observation_error,
          establishment: evidence.establishment&.to_s,
          establishment_error: evidence.establishment_error,
          cleanup_error: evidence.cleanup_error,
          changed_during_request: evidence.changed_during_request
        }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def observed_principal(value)
        return nil unless value

        { model: value.model_name.to_s, id: primitive_id(value.id) }
      end

      def principal(value)
        # JSON is also the MCP contract. Framework-inferred login identifiers
        # must never cross that machine-readable boundary. An application-
        # authored principal_label remains explicit configuration and keeps
        # its longstanding serialization behavior.
        label = if Karst.config.principal_label
                  value.display_label.to_s
                else
                  "#{value.model_name} ##{value.id}"
                end
        { model: value.model_name.to_s, id: primitive_id(value.id), label: label }
      end

      def primitive_id(value)
        value.is_a?(Integer) ? value : value.to_s
      end

      # Says what the application actually did with identity, never what was
      # asked of it.
      def identity_line(evidence)
        case evidence.confirmation
        when :confirmed then "observed #{observed_label(evidence)} (identity confirmed)"
        when :confirmed_anonymous then "observed no principal (anonymous confirmed)"
        when :absent then "requested #{requested_label(evidence)}, observed no principal (NOT confirmed)"
        when :mismatch then "requested #{requested_label(evidence)}, observed #{observed_label(evidence)} (MISMATCH)"
        when :contaminated then "anonymous probe observed #{observed_label(evidence)} (CONTAMINATED)"
        else "identity unobservable: #{evidence.observation_error}"
        end
      end

      def observed_label(evidence)
        evidence.observed ? "#{evidence.observed.model_name} ##{evidence.observed.id}" : "no principal"
      end

      def requested_label(evidence)
        evidence.requested ? "#{evidence.requested.model_name} ##{evidence.requested.id}" : "anonymous"
      end
    end
  end
end
