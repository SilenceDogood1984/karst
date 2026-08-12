# frozen_string_literal: true

require "spec_helper"
require "karst"

# Deliberately does not stub Karst::Access::PopulationApprovals.path itself --
# unlike population_approvals_spec.rb and approved_populations_spec.rb, this
# file exercises exactly the global spec_helper.rb isolation hook every other,
# unrelated spec in the suite relies on implicitly. See spec_helper.rb for why
# it exists: a real Rails::Application booted from within this repository
# (spec/support/test_application.rb's KarstTestApplication, used throughout
# spec/integration) resolves Rails.root to this checkout, so an un-isolated
# run would read/write this gem's own tmp/karst/approved_populations.json.
RSpec.describe "PopulationApprovals test isolation" do
  it "never resolves inside this repository's own tmp/ directory by default" do
    path = Karst::Access::PopulationApprovals.path

    expect(path).not_to start_with(File.expand_path("tmp/karst", Dir.pwd))
  end

  it "starts every example with no approvals, regardless of what a developer may have approved locally" do
    expect(Karst::Access::PopulationApprovals.load).to have_attributes(entries: [], error: nil)
  end

  it "does not let a write from this example survive into another example's isolated path" do
    Karst::Access::PopulationApprovals.replace(
      [Karst::Access::PopulationApprovals::Entry.new(model_name: "LeakProbe", method_name: "leaked")]
    )

    expect(Karst::Access::PopulationApprovals.load.entries.map(&:display_label)).to eq(["LeakProbe.leaked"])
  end

  it "keeps an unrelated Configuration#principal_sources call from ever reading a stray approval file" do
    # local_environment? is forced true so Configuration#principal_sources
    # actually takes the approval-reading path here, regardless of whether
    # this file happens to run alone (no Rails loaded at all) or as part of
    # the full suite -- proving isolation holds even when Karst considers
    # itself squarely inside the workflow this file exists to guard, rather
    # than passing only because that path was skipped.
    allow(Karst::Access::ApprovedPopulations).to receive(:local_environment?).and_return(true)
    stub_const("IsolationProbeUser", Class.new)
    configuration = Karst.const_get(:Configuration, false).new
    configuration.principals = -> { IsolationProbeUser }

    expect(Karst::Access::PopulationApprovals).to receive(:load).and_call_original
    expect(configuration.principal_sources.fetch(:default).populations).to eq({})
  end
end
