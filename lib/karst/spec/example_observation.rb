# frozen_string_literal: true

module Karst
  module Spec
    # One RSpec example's complete observed request history: every request it
    # issued, in order, plus enough of RSpec's own metadata (file/line,
    # nested description, stable example id, pass/fail outcome) to present
    # and re-locate the example without re-parsing spec source.
    ExampleObservation = Data.define(
      :example_id,
      :file_path,
      :line_number,
      :spec_type,
      :description_parts,
      :full_description,
      :karst_explicit,
      :karst_name,
      :outcome,
      :requests
    ) do
      # An example is part of Karst's route/page catalog only if at least one
      # of its requests rendered HTML -- an examples whose only requests are
      # JSON API calls has nothing to show a person exercising a page.
      def browser_facing?
        requests.any? { |request| request.format == "html" }
      end
    end
  end
end
