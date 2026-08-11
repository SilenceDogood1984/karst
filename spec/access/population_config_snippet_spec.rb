# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationConfigSnippet do
  def candidate(model_name:, method_name:, principal_source: nil)
    Karst::Access::PopulationDiscovery::Candidate.new(
      model_name: model_name, method_name: method_name, principal_source: principal_source
    )
  end

  def valid_ruby?(code)
    RubyVM::InstructionSequence.compile(code)
    true
  rescue SyntaxError
    false
  end

  describe ".generate" do
    it "renders a flat config.principal_populations snippet for a single :default source" do
      selected = [
        candidate(model_name: "User", method_name: :system_admins, principal_source: :default),
        candidate(model_name: "User", method_name: :auditors, principal_source: :default)
      ]

      result = described_class.generate(selected)

      expect(result.code).to include("config.principal_populations = {")
      expect(result.code).to include("system_admins: -> { User.system_admins }")
      expect(result.code).to include("auditors: -> { User.auditors }")
      expect(result.unwired).to be_empty
    end

    it "generates valid Ruby" do
      selected = [candidate(model_name: "User", method_name: :system_admins, principal_source: :default)]

      expect(valid_ruby?(described_class.generate(selected).code)).to be(true)
    end

    it "nests under config.principal_sources when more than one named source is selected" do
      selected = [
        candidate(model_name: "Author", method_name: :admins, principal_source: :authors),
        candidate(model_name: "Reader", method_name: :admins, principal_source: :readers)
      ]

      result = described_class.generate(selected)

      expect(result.code).to include("config.principal_sources = {")
      expect(result.code).to include("authors: {")
      expect(result.code).to include("readers: {")
      expect(result.code).to include("admins: -> { Author.admins }")
      expect(result.code).to include("admins: -> { Reader.admins }")
      expect(valid_ruby?(result.code)).to be(true)
    end

    it "keeps the same population name distinguishable across two different models" do
      selected = [
        candidate(model_name: "Author", method_name: :admins, principal_source: :authors),
        candidate(model_name: "Reader", method_name: :admins, principal_source: :readers)
      ]

      result = described_class.generate(selected)

      expect(result.code).to include("Author.admins")
      expect(result.code).to include("Reader.admins")
      expect(result.code.scan("admins: ->").size).to eq(2)
    end

    it "reports a candidate with no matching principal source as unwired instead of dropping it" do
      selected = [candidate(model_name: "Subscription", method_name: :renewable, principal_source: nil)]

      result = described_class.generate(selected)

      expect(result.wired).to be_empty
      expect(result.unwired.map(&:model_name)).to eq(["Subscription"])
      expect(result.code).not_to include("Subscription")
    end

    it "renders a placeholder comment, still valid Ruby, when nothing is selected" do
      result = described_class.generate([])

      expect(result.code).to start_with("#")
      expect(valid_ruby?(result.code)).to be(true)
    end

    it "deduplicates the same model/method pair submitted more than once" do
      selected = [
        candidate(model_name: "User", method_name: :admins, principal_source: :default),
        candidate(model_name: "User", method_name: :admins, principal_source: :default)
      ]

      result = described_class.generate(selected)

      expect(result.code.scan("admins: ->").size).to eq(1)
    end
  end
end
# rubocop:enable Metrics/BlockLength
