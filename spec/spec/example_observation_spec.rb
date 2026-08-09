# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/spec/principal"
require "karst/spec/request_observation"
require "karst/spec/example_observation"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Spec::ExampleObservation do
  def request(format:)
    Karst::Spec::RequestObservation.new(
      sequence: 0, http_method: "GET", path: "/x", route_pattern: "/x(.:format)",
      controller: "XController", action: "show", format: format,
      status: 200, redirect_location: nil,
      principal_before: nil, principal_after: nil, principal_changed: false
    )
  end

  def example(requests)
    described_class.new(
      example_id: "./spec/x_spec.rb[1:1]", file_path: "./spec/x_spec.rb", line_number: 3,
      spec_type: :request, description_parts: ["X", "does a thing"],
      full_description: "X does a thing", karst_explicit: false, karst_name: nil,
      outcome: :passed, requests: requests
    )
  end

  describe "#browser_facing?" do
    it "is true when any request rendered html" do
      expect(example([request(format: "json"), request(format: "html")])).to be_browser_facing
    end

    it "is false when every request was a non-html format" do
      expect(example([request(format: "json")])).not_to be_browser_facing
    end

    it "is false with no requests at all" do
      expect(example([])).not_to be_browser_facing
    end
  end
end
# rubocop:enable Metrics/BlockLength
