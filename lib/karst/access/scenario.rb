# frozen_string_literal: true

require_relative "../value"

module Karst
  module Access
    # One application-authored artifact probe: Karst executes it but does not
    # infer its path, candidate records, or definition of an observed match.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
    class Scenario
      MAX_COMBINATIONS = 100
      EXPECTATION_KEYS = %i[status redirect body_includes].freeze

      attr_reader :name, :artifact_source, :path, :expectation, :combination_limit, :stop_on_match

      def initialize(name:, artifact_source:, path:, expect:, combination_limit: 25, stop_on_match: true)
        raise ArgumentError, "scenario path must be callable" unless path.respond_to?(:call)
        unless combination_limit.is_a?(Integer) && combination_limit.positive? && combination_limit <= MAX_COMBINATIONS
          raise ArgumentError, "combination_limit must be between 1 and #{MAX_COMBINATIONS}"
        end

        @name = name.to_sym
        @artifact_source = artifact_source
        @path = path
        @expectation = normalize_expectation(expect).freeze
        @combination_limit = combination_limit
        @stop_on_match = stop_on_match == true
        freeze
      end

      private

      def normalize_expectation(value)
        raise ArgumentError, "expect must be a non-empty Hash" unless value.is_a?(Hash) && !value.empty?

        normalized = value.each_with_object({}) { |(key, item), memo| memo[key.to_sym] = item }
        unknown = normalized.keys - EXPECTATION_KEYS
        raise ArgumentError, "unsupported expectation: #{unknown.join(', ')}" unless unknown.empty?
        if normalized.key?(:status) && !normalized[:status].is_a?(Integer)
          raise ArgumentError,
                "status must be an Integer"
        end

        normalized
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
  end
end
