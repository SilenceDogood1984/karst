# frozen_string_literal: true

require_relative "../value"

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
    #
    # `principal_before`/`principal_after` are both kept, not collapsed to
    # whichever was active when the request began: a signup or checkout
    # scenario that establishes a session is exactly the case where the
    # identity a request produces matters as much as the identity it started
    # with, and either side alone would discard real evidence.
    Scenario = Value.define(
      :example_id,
      :file_path,
      :line_number,
      :description_parts,
      :full_description,
      :karst_explicit,
      :karst_name,
      :example_outcome,
      :controller,
      :action,
      :http_method,
      :route_pattern,
      :observed_path,
      :observed_status,
      :observed_redirect,
      :principal_before,
      :principal_after,
      :principal_changed,
      :sequence
    ) do
      # The most specific zero-config name available without repeating the
      # whole describe chain: RSpec's own nesting already puts the most
      # specific description last. Never invents a persona the spec itself
      # did not name.
      def name
        karst_name || description_parts.last || full_description
      end

      def passed?
        example_outcome == :passed
      end

      def explicit?
        karst_explicit
      end
    end
  end
end
