# frozen_string_literal: true

module Karst
  module Access
    # An explicitly configured, bounded population of application records.
    class ArtifactSource
      MAX_LIMIT = 1_000

      attr_reader :name, :records, :limit

      def initialize(name:, records:, limit:)
        raise ArgumentError, "artifact source name must be present" if name.to_s.empty?
        raise ArgumentError, "artifact source records must be callable" unless records.respond_to?(:call)
        unless limit.is_a?(Integer) && limit.positive? && limit <= MAX_LIMIT
          raise ArgumentError, "artifact source limit must be between 1 and #{MAX_LIMIT}"
        end

        @name = name.to_sym
        @records = records
        @limit = limit
        freeze
      end

      # Applies LIMIT at the relation boundary. Enumerable sources are only
      # consumed lazily through the same explicit bound.
      def candidates
        source = records.call
        source = source.limit(limit) if source.respond_to?(:limit)
        source.each.lazy.take(limit).to_a.freeze
      end
    end
  end
end
