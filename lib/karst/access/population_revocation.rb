# frozen_string_literal: true

require_relative "population_approvals"

module Karst
  module Access
    # Removes one exact, already-stored approval while preserving every other
    # entry. Submitted values can never add or alter an approval.
    class PopulationRevocation
      Result = Value.define(:record, :revoked)

      SEPARATOR = "::"

      def initialize(submitted:, record: PopulationApprovals.load)
        @submitted = submitted.to_s
        @record = record
      end

      def call
        entry = @record.entries.find { |candidate| key(candidate) == @submitted }
        return Result.new(record: @record, revoked: false) unless entry

        record = PopulationApprovals.replace(@record.entries - [entry])
        Result.new(record: record, revoked: record.error.nil?)
      end

      private

      def key(entry)
        [entry.model_name, entry.method_name].join(SEPARATOR)
      end
    end
  end
end
