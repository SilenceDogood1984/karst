# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/spec/principal"
require "karst/spec/scenario"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Spec::Scenario do
  def scenario(description_parts:, full_description:, example_outcome: :passed)
    described_class.new(
      example_id: "./spec/x_spec.rb[1:1]", file_path: "./spec/x_spec.rb", line_number: 3,
      description_parts: description_parts, full_description: full_description, example_outcome: example_outcome,
      controller: "XController", action: "show", http_method: "GET", route_pattern: "/x(.:format)",
      observed_path: "/x", observed_status: 200, observed_redirect: nil,
      principal: nil, principal_changed: false, sequence: 0
    )
  end

  describe "#name" do
    it "is the innermost description, not the whole describe chain" do
      example = scenario(description_parts: ["Author dashboard", "denies reader access"],
                         full_description: "Author dashboard denies reader access")

      expect(example.name).to eq("denies reader access")
    end

    it "falls back to full_description when there are no nested parts" do
      example = scenario(description_parts: [], full_description: "does a thing")

      expect(example.name).to eq("does a thing")
    end
  end

  describe "#passed?" do
    it "is true only for a passed outcome" do
      expect(scenario(description_parts: ["d"], full_description: "d", example_outcome: :passed)).to be_passed
      expect(scenario(description_parts: ["d"], full_description: "d", example_outcome: :failed)).not_to be_passed
      expect(scenario(description_parts: ["d"], full_description: "d", example_outcome: :pending)).not_to be_passed
    end
  end

  it "is immutable" do
    example = scenario(description_parts: ["d"], full_description: "d")

    expect(example).to be_frozen
    expect { example.instance_variable_set(:@controller, "Other") }.to raise_error(FrozenError)
  end
end
# rubocop:enable Metrics/BlockLength
