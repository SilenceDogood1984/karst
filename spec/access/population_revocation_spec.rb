# frozen_string_literal: true

require "spec_helper"
require "karst/access/population_revocation"

RSpec.describe Karst::Access::PopulationRevocation do
  def entry(model_name, method_name)
    Karst::Access::PopulationApprovals::Entry.new(model_name: model_name, method_name: method_name)
  end

  let(:first) { entry("User", "admins") }
  let(:second) { entry("User", "auditors") }
  let(:record) { Karst::Access::PopulationApprovals::Record.new(entries: [first, second], error: nil) }

  it "removes exactly the submitted stored approval" do
    saved = Karst::Access::PopulationApprovals::Record.new(entries: [second], error: nil)
    allow(Karst::Access::PopulationApprovals).to receive(:replace).with([second]).and_return(saved)

    result = described_class.new(submitted: "User::admins", record: record).call
    expect(result.record).to eq(saved)
    expect(result.revoked).to be(true)
  end

  it "does not write for an unknown or malformed submitted value" do
    allow(Karst::Access::PopulationApprovals).to receive(:replace)
    result = described_class.new(submitted: "User::missing", record: record).call

    expect(result.record).to equal(record)
    expect(result.revoked).to be(false)
    expect(Karst::Access::PopulationApprovals).not_to have_received(:replace)
  end
end
