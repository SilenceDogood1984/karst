# frozen_string_literal: true

require "json"
require "fileutils"

module Karst
  module Spec
    # Collects ExampleObservation instances as the suite runs and serializes
    # them to one deterministic JSON artifact on disk. Never touches the host
    # application's database: this is the only persistence Reporter performs.
    class Reporter
      def initialize
        @examples = []
        @mutex = Mutex.new
      end

      def record(example_observation)
        @mutex.synchronize { @examples << example_observation }
        self
      end

      def to_a
        @mutex.synchronize { @examples.dup }
      end

      # Ordered by file path then line number, independent of RSpec run order
      # (`--order random` reshuffles examples but must not reshuffle the
      # artifact), so two runs of an unchanged suite produce identical JSON.
      def write(path)
        browser_facing = @mutex.synchronize { @examples.select(&:browser_facing?) }
        ordered = browser_facing.sort_by { |example| [example.file_path.to_s, example.line_number.to_i] }

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(ordered.map { |example| serialize(example) })}\n")
        path
      end

      private

      # rubocop:disable Metrics/MethodLength
      def serialize(example)
        {
          "example_id" => example.example_id,
          "file_path" => example.file_path,
          "line_number" => example.line_number,
          "spec_type" => example.spec_type&.to_s,
          "description_parts" => example.description_parts,
          "full_description" => example.full_description,
          "karst_explicit" => example.karst_explicit,
          "karst_name" => example.karst_name,
          "outcome" => example.outcome.to_s,
          "requests" => example.requests.map { |request| serialize_request(request) }
        }
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/MethodLength
      def serialize_request(request)
        {
          "sequence" => request.sequence,
          "method" => request.http_method,
          "path" => request.path,
          "route_pattern" => request.route_pattern,
          "controller" => request.controller,
          "action" => request.action,
          "format" => request.format,
          "status" => request.status,
          "redirect_location" => request.redirect_location,
          "principal_before" => serialize_principal(request.principal_before),
          "principal_after" => serialize_principal(request.principal_after),
          "principal_changed" => request.principal_changed
        }
      end
      # rubocop:enable Metrics/MethodLength

      def serialize_principal(principal)
        return nil unless principal

        { "type" => principal.type, "id" => principal.id, "scope" => principal.scope&.to_s }
      end
    end
  end
end
