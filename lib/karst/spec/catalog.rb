# frozen_string_literal: true

require "json"
require_relative "principal"
require_relative "scenario"

module Karst
  module Spec
    # Read-only index over the JSON artifact Karst::Spec::Observer writes,
    # answering "what scenarios have been observed for this controller/action"
    # without requiring RSpec, Rails, or the host application's database to be
    # loaded. This is pure data ingestion: JSON primitives in, immutable
    # Scenario objects out. It never deserializes arbitrary Ruby objects,
    # never constantizes a principal type, and never queries anything.
    #
    # A Catalog is always in exactly one of three states:
    #
    # - :missing -- the artifact does not exist yet (the suite has never
    #   been run with the observer installed).
    # - :invalid -- the artifact exists but could not be read as the expected
    #   JSON array (empty file, malformed JSON, or an incompatible top-level
    #   shape). `error` holds a human-readable reason.
    # - :ready -- the artifact was a valid JSON array. `scenarios` may still
    #   be empty (a suite that observed zero browser-facing requests), which
    #   is deliberately distinct from :missing: "no scenarios cover this
    #   route" is not the same claim as "the catalog was never generated."
    #
    # Malformed individual entries inside an otherwise valid array (a request
    # missing its controller, an example with no requests at all) are skipped
    # individually rather than invalidating the whole artifact.
    # rubocop:disable Metrics/ClassLength
    class Catalog
      DEFAULT_RELATIVE_PATH = File.join("tmp", "karst", "scenarios.json")
      private_constant :DEFAULT_RELATIVE_PATH

      EMPTY = [].freeze
      private_constant :EMPTY

      OUTCOMES = %w[passed failed pending].freeze
      private_constant :OUTCOMES

      class << self
        # Rails' own tmp/ convention when available, otherwise a plain
        # relative path so this stays usable from a bare Ruby process (tests,
        # a future CLI) with no Rails loaded.
        def default_path
          return DEFAULT_RELATIVE_PATH unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

          File.join(Rails.root.to_s, DEFAULT_RELATIVE_PATH)
        end

        def load(path: default_path)
          new(*read(path))
        end

        private

        def read(path)
          return [:missing, EMPTY, nil] unless File.exist?(path)

          raw = File.read(path)
          return [:invalid, EMPTY, "scenario artifact at #{path} is empty"] if raw.strip.empty?

          parse(raw, path)
        end

        def parse(raw, path)
          parsed = JSON.parse(raw)
          return [:invalid, EMPTY, "scenario artifact at #{path} is not a JSON array"] unless parsed.is_a?(Array)

          [:ready, build_scenarios(parsed), nil]
        rescue JSON::ParserError => e
          [:invalid, EMPTY, "scenario artifact at #{path} is not valid JSON: #{e.message}"]
        end

        # Ordered deterministically so two reads of an unchanged artifact
        # agree: passed examples before failed/pending ones, then file path,
        # line number, example id, and finally request sequence (the
        # tie-breaker that keeps multiple scenarios from the same example in
        # their original request order). There is no `explicit` signal yet --
        # Task B's `karst:` metadata will add one more leading key here
        # without otherwise touching this method.
        def build_scenarios(examples)
          scenarios = examples.flat_map { |example| scenarios_from_example(example) }
          scenarios.sort_by { |scenario| sort_key(scenario) }.freeze
        end

        def sort_key(scenario)
          [scenario.passed? ? 0 : 1, scenario.file_path, scenario.line_number, scenario.example_id, scenario.sequence]
        end

        def scenarios_from_example(example)
          return EMPTY unless example.is_a?(Hash) && valid_example?(example)

          example["requests"].filter_map { |request| scenario_from_request(request, example) }
        end

        def valid_example?(example)
          example["example_id"].is_a?(String) && example["file_path"].is_a?(String) &&
            example["line_number"].is_a?(Integer) && example["description_parts"].is_a?(Array) &&
            example["full_description"].is_a?(String) && example["requests"].is_a?(Array)
        end

        # A request only becomes a Scenario once it carries enough evidence to
        # be indexed and shown: a browser-facing (HTML) response, a resolved
        # controller/action, an HTTP method, and its position within the
        # example. Everything else observed about the request (route pattern,
        # path, status, redirect target, principal before/after) is retained
        # as-is, including nil, since a nil there is itself real evidence
        # (e.g. the request never reached `process_action`).
        def scenario_from_request(request, example)
          return nil unless request.is_a?(Hash) && request["format"] == "html" && valid_request?(request)

          build_scenario(request, example)
        rescue StandardError
          nil
        end

        def valid_request?(request)
          required = %w[controller action method].all? { |key| non_empty_string?(request[key]) }
          required && request["sequence"].is_a?(Integer)
        end

        def non_empty_string?(value)
          value.is_a?(String) && !value.empty?
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def build_scenario(request, example)
          Scenario.new(
            example_id: example["example_id"], file_path: example["file_path"], line_number: example["line_number"],
            description_parts: example["description_parts"].freeze, full_description: example["full_description"],
            example_outcome: outcome_for(example["outcome"]),
            controller: request["controller"], action: request["action"], http_method: request["method"],
            route_pattern: request["route_pattern"], observed_path: request["path"],
            observed_status: request["status"], observed_redirect: request["redirect_location"],
            principal_before: principal_from(request["principal_before"]),
            principal_after: principal_from(request["principal_after"]),
            principal_changed: request["principal_changed"] == true, sequence: request["sequence"]
          ).freeze
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def outcome_for(raw)
          OUTCOMES.include?(raw) ? raw.to_sym : :unknown
        end

        def principal_from(raw)
          return nil unless raw.is_a?(Hash)

          Principal.new(type: raw["type"], id: raw["id"], scope: raw["scope"])
        end
      end
      private_class_method :new

      attr_reader :status, :scenarios, :error

      def initialize(status, scenarios, error)
        @status = status
        @scenarios = scenarios
        @error = error
        @index = build_index(scenarios)
        freeze
      end

      def ready?
        status == :ready
      end

      # Indexed primarily by controller/action -- Rails' own stable routing
      # identity -- so "/things/1" and "/things/2" report as the same
      # capability instead of fragmenting by dynamic id. `http_method`
      # narrows further for the (uncommon) case where one controller/action
      # legitimately answers more than one verb; omitted, every scenario for
      # that controller/action is returned regardless of method.
      def scenarios_for(controller:, action:, http_method: nil)
        matches = @index.fetch([controller, action], EMPTY)
        return matches if http_method.nil?

        normalized = http_method.to_s.upcase
        matches.select { |scenario| scenario.http_method == normalized }.freeze
      end

      private

      def build_index(scenarios)
        scenarios.group_by { |scenario| [scenario.controller, scenario.action] }
                 .transform_values(&:freeze)
                 .freeze
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
