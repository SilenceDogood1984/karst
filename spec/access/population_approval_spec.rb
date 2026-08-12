# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationApproval do
  let(:source_object) { Struct.new(:unused).new }

  def candidate(source: :default, model: "User", scope: :system_admins)
    Karst::Access::PopulationDiscovery::Candidate.new(principal_source: source, model_name: model,
                                                      method_name: scope)
  end

  def discovery(*candidates)
    instance_double(Karst::Access::PopulationDiscovery::Result, candidates: candidates)
  end

  def record(*entries)
    Karst::Access::PopulationApprovals::Record.new(entries: entries, error: nil)
  end

  def entry(model = "User", scope = "system_admins")
    Karst::Access::PopulationApprovals::Entry.new(model_name: model, method_name: scope)
  end

  def approve(submitted, candidates: [candidate], sources: nil)
    sources ||= { default: source_object }
    described_class.new(discovery: discovery(*candidates), principal_sources: sources,
                        submitted: submitted, record: record).call
  end

  before do
    allow(Karst::Access::PopulationApprovals).to receive(:replace) do |entries|
      record(*entries)
    end
  end

  it "persists entries sourced from current discovery" do
    result = approve("default::User::system_admins")

    expect(result).to be_saved
    expect(result.record.entries).to eq([entry])
  end

  it "rejects malformed or undiscovered submitted populations atomically" do
    result = approve(["default::User::system_admins", "User::destroy_all"])

    expect(result).not_to be_saved
    expect(Karst::Access::PopulationApprovals).not_to have_received(:replace)
  end

  it "rejects a stale candidate absent from the current discovery pass" do
    result = approve("default::User::system_admins", candidates: [])

    expect(result).not_to be_saved
  end

  it "rejects a discovered candidate for a different principal source" do
    result = approve("admin::Admin::superusers",
                     candidates: [candidate(source: :admin, model: "Admin", scope: :superusers)],
                     sources: { member: source_object })

    expect(result).not_to be_saved
  end

  it "does not accept an already-approved population again" do
    approved = entry
    result = described_class.new(discovery: discovery(candidate), principal_sources: { default: source_object },
                                 submitted: "default::User::system_admins", record: record(approved)).call

    expect(result).not_to be_saved
  end
end
# rubocop:enable Metrics/BlockLength
