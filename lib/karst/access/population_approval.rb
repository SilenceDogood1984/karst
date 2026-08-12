# frozen_string_literal: true

require_relative "population_approvals"

module Karst
  module Access
    # Adds explicitly selected candidates from one current discovery pass to
    # the local approval record. Submitted values are treated only as keys:
    # the Entry objects written below always come from discovery itself.
    class PopulationApproval
      Result = Value.define(:record, :error) do
        def saved?
          error.nil? && record.error.nil?
        end
      end

      SEPARATOR = "::"

      def initialize(discovery:, principal_sources:, submitted:, record: PopulationApprovals.load)
        @discovery = discovery
        @principal_sources = principal_sources
        @submitted = Array(submitted).map(&:to_s)
        @record = record
      end

      def call
        selected = selected_candidates
        return rejected("Select at least one current candidate population.") if @submitted.empty?
        return rejected("A submitted population is no longer available for this principal source.") unless selected

        entries = @record.entries + selected.map do |candidate|
          PopulationApprovals::Entry.new(model_name: candidate.model_name,
                                         method_name: candidate.method_name.to_s)
        end
        record = PopulationApprovals.replace(entries)
        Result.new(record: record, error: record.error)
      end

      private

      def selected_candidates
        candidates = applicable_candidates
        by_key = candidates.to_h { |candidate| [candidate_key(candidate), candidate] }
        return unless @submitted.uniq.size == @submitted.size
        return unless @submitted.all? { |key| by_key.key?(key) }

        @submitted.map { |key| by_key.fetch(key) }
      end

      def applicable_candidates
        names = @principal_sources.keys.map(&:to_s)
        @discovery.candidates.select do |candidate|
          candidate.principal_source && names.include?(candidate.principal_source.to_s) &&
            !@record.approved?(candidate.model_name, candidate.method_name)
        end
      end

      def candidate_key(candidate)
        [candidate.principal_source, candidate.model_name, candidate.method_name].join(SEPARATOR)
      end

      def rejected(message)
        Result.new(record: @record, error: message)
      end
    end
  end
end
