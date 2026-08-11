# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationSuggestion do
  describe ".rank" do
    it "ranks populations sharing a token with the observed signal ahead of ones that do not" do
      ranked = described_class.rank(
        observed: :authorize_admin, population_names: %i[admins system_admins auditors responders]
      )

      expect(ranked[:suggested].map(&:name)).to contain_exactly(:admins, :system_admins)
      expect(ranked[:other].map(&:name)).to contain_exactly(:auditors, :responders)
    end

    it "orders suggestions by the number of matched tokens, highest first" do
      ranked = described_class.rank(observed: :system_admin_role, population_names: %i[system_admins admins])

      expect(ranked[:suggested].map(&:name)).to eq(%i[system_admins admins])
    end

    it "reports which tokens matched, transparently" do
      ranked = described_class.rank(observed: :authorize_admin, population_names: [:admins])

      expect(ranked[:suggested].first.matched_tokens).to eq(["admin"])
    end

    it "never hides a population -- every input name appears in exactly one bucket" do
      names = %i[admins system_admins auditors responders]
      ranked = described_class.rank(observed: :authorize_admin, population_names: names)

      all_returned = (ranked[:suggested] + ranked[:other]).map(&:name)
      expect(all_returned).to match_array(names)
    end

    it "strips common framework/verb tokens from the observed signal only" do
      ranked = described_class.rank(observed: :authorize_admin, population_names: [:authorize])

      expect(ranked[:suggested]).to be_empty
      expect(ranked[:other].map(&:name)).to eq([:authorize])
    end

    it "treats a nil observed signal as no match for anything, without raising" do
      ranked = described_class.rank(observed: nil, population_names: %i[admins auditors])

      expect(ranked[:suggested]).to be_empty
      expect(ranked[:other].map(&:name)).to contain_exactly(:admins, :auditors)
    end

    it "returns empty buckets for an empty population list" do
      ranked = described_class.rank(observed: :authorize_admin, population_names: [])

      expect(ranked[:suggested]).to eq([])
      expect(ranked[:other]).to eq([])
    end
  end
end
# rubocop:enable Metrics/BlockLength
