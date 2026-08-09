# frozen_string_literal: true

module Karst
  module Spec
    # One RSpec example exercising one specific browser-facing controller/action
    # request, built entirely from evidence already present in the JSON artifact
    # Karst::Spec::Observer writes.
    #
    # `observed_status`/`observed_redirect` describe what this spec execution
    # observed while it ran, never what the example asserted -- a failing or
    # pending example still produces a Scenario, and `example_outcome` is how
    # a consumer tells "verified" apart from "merely observed."
    #
    # An example that issues several browser-facing requests (a denied attempt
    # followed by an allowed retry, a sign-in followed by the page it unlocks)
    # legitimately produces one Scenario per such request: Karst never
    # collapses an example down to "its last request," and never labels any
    # request as authentication setup versus the subject under test.
    Scenario = Data.define(
      :example_id,
      :file_path,
      :line_number,
      :description_parts,
      :full_description,
      :example_outcome,
      :controller,
      :action,
      :http_method,
      :route_pattern,
      :observed_path,
      :observed_status,
      :observed_redirect,
      :principal,
      :principal_changed,
      :sequence
    ) do
      # The most specific zero-config name available without repeating the
      # whole describe chain: RSpec's own nesting already puts the most
      # specific description last. Never invents a persona the spec itself
      # did not name.
      def name
        description_parts.last || full_description
      end

      def passed?
        example_outcome == :passed
      end
    end
  end
end
