# frozen_string_literal: true

require_relative "../value"
require_relative "candidate_population"

module Karst
  module Access
    # The explicit, bounded "does this discovered candidate actually work"
    # step -- deliberately separate from Karst::Access::PopulationDiscovery,
    # which never executes anything. Only ever resolves a model/method pair
    # that a given Karst::Access::PopulationDiscovery::Result itself already
    # discovered; a submitted name that is not on that list is rejected
    # without calling anything, so this can never become a general "call any
    # class method by name" endpoint. Every resolution is bounded to
    # PREVIEW_LIMIT rows via Karst::Access::CandidatePopulation.resolve --
    # never a COUNT, never full materialization.
    class PopulationPreview
      PREVIEW_LIMIT = 3

      Result = Value.define(:model_name, :method_name, :resolved, :records, :error)

      def self.call(model_name:, method_name:, discovery_result:)
        new(model_name: model_name, method_name: method_name, discovery_result: discovery_result).call
      end

      def initialize(model_name:, method_name:, discovery_result:)
        @model_name = model_name.to_s
        @method_name = method_name.to_s
        @discovery_result = discovery_result
      end

      def call
        return unresolved("this is not a discovered candidate") unless known_candidate?

        klass = model_class
        return unresolved("the model could not be resolved") unless klass

        resolve(klass)
      end

      private

      def known_candidate?
        @discovery_result.candidates.any? do |candidate|
          candidate.model_name == @model_name && candidate.method_name.to_s == @method_name
        end
      end

      def model_class
        return nil unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.descendants.find { |klass| klass.name == @model_name }
      end

      def resolve(klass)
        method_name = @method_name
        population = CandidatePopulation.resolve(
          name: method_name.to_sym, callable: -> { klass.public_send(method_name) },
          source_klass: klass, limit: PREVIEW_LIMIT
        )
        return unresolved("did not resolve to a usable ActiveRecord::Relation for #{@model_name}") unless population

        Result.new(model_name: @model_name, method_name: @method_name, resolved: true, records: population.records,
                   error: nil)
      end

      def unresolved(error)
        Result.new(model_name: @model_name, method_name: @method_name, resolved: false, records: [].freeze,
                   error: error)
      end
    end
  end
end
