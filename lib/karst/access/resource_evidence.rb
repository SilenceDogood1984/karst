# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require_relative "../value"
require_relative "../identity"

module Karst
  module Access
    # Given one exact resource (the specific record a route addresses by id)
    # and one specific principal (typically the successful outcome from an
    # Access::Sweep), reports simple, directly observed foreign-key
    # relationships between those two records. This is evidence, not an
    # authorization claim: it never states or implies *why* an outcome
    # occurred, only which foreign-key columns, if any, point from one given
    # record to the other's id.
    #
    # Deliberately narrow, matching the v1 scope this class was built for:
    # - only foreign-key-shaped columns (ending in "_id") on the two given
    #   records are ever inspected -- never an arbitrary attribute, so no
    #   other column value (name, email, token, ...) is ever read or shown;
    # - only a direct column-value comparison between the two given records,
    #   never a join, a has_many traversal, or any multi-hop graph walk;
    # - resource resolution from a route path is attempted only through
    #   Rails' own route recognition plus its controller-to-model naming
    #   convention, and only trusted when every step succeeds unambiguously
    #   (a recognized route with an :id segment, a controller name that
    #   classifies to a real loaded Active Record class, and a record that
    #   actually exists for that id). Anything softer -- an unrecognized
    #   route, a controller with no conventional model, a missing record --
    #   is reported as a limitation rather than guessed at.
    # rubocop:disable Metrics/ClassLength
    class ResourceEvidence
      class Error < StandardError; end

      # The resource side never gets Identity::PrincipalDescriptor's
      # configurable display_label hook -- there is no equivalent concept
      # for "the current route's resource" -- so it gets its own minimal,
      # equally attribute-free descriptor.
      ResourceDescriptor = Value.define(:model_name, :id)

      # from_model/from_id is whichever of the resource/principal actually
      # holds the foreign-key column; to_model/to_id is the other side.
      Relationship = Value.define(:column, :from_model, :from_id, :to_model, :to_id)

      Result = Value.define(:principal, :resource, :relationships, :observed_status, :observed_redirect,
                            :limitation) do
        # Plain-text rendering deliberately kept free of causal wording
        # ("owns", "is authorized", "grants") -- see class comment above.
        def to_text
          lines = [principal.display_label]
          lines << observed_line if observed_status || observed_redirect
          lines << "" << "Related state:"
          lines.concat(related_state_lines)
          lines.join("\n")
        end

        private

        def observed_line
          observed_redirect ? "Observed #{observed_status} → #{observed_redirect}" : "Observed #{observed_status}"
        end

        def related_state_lines
          return ["  Unavailable: #{limitation}"] if limitation
          return [no_relationship_line] if relationships.empty?

          grouped_relationship_lines
        end

        def no_relationship_line
          "  No observed foreign-key relationship to #{resource.model_name} ##{resource.id}."
        end

        def grouped_relationship_lines
          relationships.group_by { |rel| [rel.from_model, rel.from_id] }.flat_map do |(model, id), grouped|
            ["#{model} ##{id}"] + grouped.map { |rel| "  #{rel.column} → #{rel.to_model} ##{rel.to_id}" }
          end
        end
      end

      class << self
        # Resolves the resource, resolves the principal (from a
        # Sweep::Outcome's PrincipalDescriptor), and reports relationships in
        # one call. Either resolution step may fail safely -- see
        # #resolve_resource and #resolve_principal -- in which case the
        # Result carries a limitation instead of relationships.
        def for_outcome(outcome:, path:, http_method: "GET", application: nil)
          resource, resource_limitation = resolve_resource(path: path, http_method: http_method,
                                                           application: application)
          principal, principal_limitation = resolve_principal(outcome.principal)
          limitation = [resource_limitation, principal_limitation].compact.join("; ")

          return unresolved_result(outcome, limitation) if resource.nil? || principal.nil?

          new(resource: resource, principal: principal).call(
            observed_status: outcome.status, observed_redirect: outcome.redirect
          )
        end

        # Attempts to resolve the exact record a route addresses, trusting
        # only Rails' own route recognition and controller naming
        # convention, and only when every step is unambiguous. Returns
        # [record, nil] on success or [nil, reason] when any step is not
        # reliable -- never a guessed record.
        def resolve_resource(path:, http_method: "GET", application: nil)
          app = application || rails_application
          return [nil, "no Rails application is available to recognize the route"] unless app

          params = recognize(app, path, http_method)
          return [nil, "the route could not be recognized"] unless params

          id = params[:id]
          return [nil, "the recognized route has no :id segment addressing one specific resource"] unless id

          find_by_controller(params[:controller], id)
        end

        # Resolves the actual record behind a Karst::Identity::PrincipalDescriptor
        # (recorded by Access::Sweep as the safe principal representation).
        # Returns [record, nil] on success or [nil, reason] otherwise.
        def resolve_principal(descriptor)
          klass = active_record_class(descriptor.model_name)
          return [nil, "principal model #{descriptor.model_name} is not a loaded Active Record model"] unless klass

          record = klass.find_by(klass.primary_key => descriptor.id)
          return [nil, "no #{klass.name} record exists for id #{descriptor.id.inspect}"] unless record

          [record, nil]
        end

        private

        def rails_application
          defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        end

        def find_by_controller(controller, id)
          klass = active_record_class(controller.to_s.classify)
          return [nil, "the route's controller does not map to a loaded Active Record model by convention"] unless klass

          record = klass.find_by(klass.primary_key => id)
          return [nil, "no #{klass.name} record exists for id #{id.inspect}"] unless record

          [record, nil]
        end

        def unresolved_result(outcome, limitation)
          Result.new(principal: outcome.principal, resource: nil, relationships: [].freeze,
                     observed_status: outcome.status, observed_redirect: outcome.redirect,
                     limitation: limitation.empty? ? "the resource or principal could not be resolved" : limitation)
        end

        def recognize(app, path, http_method)
          app.routes.recognize_path(path, method: http_method)
        rescue StandardError
          nil
        end

        def active_record_class(name)
          klass = name.to_s.safe_constantize
          return nil unless defined?(ActiveRecord::Base) && klass.is_a?(Class) && klass < ActiveRecord::Base

          klass
        end
      end

      def initialize(resource:, principal:)
        @resource = resource
        @principal = principal
      end

      def call(observed_status: nil, observed_redirect: nil)
        Result.new(
          principal: Identity.describe(@principal),
          resource: ResourceDescriptor.new(model_name: model_name(@resource), id: primary_key_value(@resource)),
          relationships: relationships.freeze,
          observed_status: observed_status,
          observed_redirect: observed_redirect,
          limitation: nil
        )
      end

      private

      def relationships
        foreign_keys_from(@resource, @principal) + foreign_keys_from(@principal, @resource)
      end

      def foreign_keys_from(source, target)
        return [] unless active_record?(source) && active_record?(target)

        source.class.columns_hash.values.filter_map { |column| relationship_for(source, target, column) }
      end

      def relationship_for(source, target, column)
        return unless foreign_key_column?(source.class, column)
        return unless targets?(column, target.class)

        value = source.public_send(column.name)
        return if value.nil? || value != primary_key_value(target)

        Relationship.new(column: column.name, from_model: model_name(source), from_id: primary_key_value(source),
                         to_model: model_name(target), to_id: primary_key_value(target))
      end

      def foreign_key_column?(klass, column)
        column.name.end_with?("_id") && column.name != klass.primary_key
      end

      # "Obvious" is judged purely from the column's own name against the
      # target's actual class (including its Active Record ancestry, so a
      # single-table-inherited subclass still matches its base class's
      # conventional foreign key) -- never a declared association, never any
      # other column's value, and never a second hop through another model.
      def targets?(column, target_klass)
        candidate = column.name.delete_suffix("_id").classify.safe_constantize
        candidate.is_a?(Class) && (target_klass <= candidate || candidate <= target_klass)
      end

      def active_record?(record)
        defined?(ActiveRecord::Base) && record.is_a?(ActiveRecord::Base)
      end

      def model_name(record)
        record.class.respond_to?(:model_name) ? record.class.model_name.name.to_s : record.class.name.to_s
      end

      def primary_key_value(record)
        record.public_send(record.class.primary_key)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
