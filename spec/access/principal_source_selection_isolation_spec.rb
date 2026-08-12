# frozen_string_literal: true

require "spec_helper"
require "karst"

# Deliberately does not stub Karst::Access::PrincipalSourceSelection.path
# itself -- unlike principal_source_selection_spec.rb and
# selected_principal_sources_spec.rb, this file exercises exactly the global
# spec_helper.rb isolation hook every other, unrelated spec in the suite
# relies on implicitly. See spec_helper.rb for why it exists, and
# spec/access/population_approvals_isolation_spec.rb for the identical proof
# for Karst::Access::PopulationApprovals: a real Rails::Application booted
# from within this repository (spec/support/test_application.rb's
# KarstTestApplication, spec/support/multi_devise_application.rb's
# KarstMultiDeviseApplication, and others) resolves Rails.root to this
# checkout, so an un-isolated run would read/write this gem's own
# tmp/karst/principal_source_selection.json -- and a developer's own local
# selection, made while dogfooding Karst against a real app in this
# checkout, must never leak into an unrelated example.
RSpec.describe "PrincipalSourceSelection test isolation" do
  it "never resolves inside this repository's own tmp/ directory by default" do
    path = Karst::Access::PrincipalSourceSelection.path

    expect(path).not_to start_with(File.expand_path("tmp/karst", Dir.pwd))
  end

  it "starts every example with no selection, regardless of what a developer may have selected locally" do
    expect(Karst::Access::PrincipalSourceSelection.load).to have_attributes(model_names: [], error: nil)
  end

  it "does not let a write from this example survive into another example's isolated path" do
    Karst::Access::PrincipalSourceSelection.replace(["LeakProbeModel"])

    expect(Karst::Access::PrincipalSourceSelection.load.model_names).to eq(["LeakProbeModel"])
  end

  it "keeps an unrelated Karst::Access::SelectedPrincipalSources.mappings call from ever reading a stray " \
     "selection file from another host, even when Karst considers itself squarely inside the local-selection " \
     "workflow this file exists to guard" do
    allow(Karst::Access::ApprovedPopulations).to receive(:local_environment?).and_return(true)
    stub_const("Devise", Module.new)
    allow(Devise).to receive(:mappings).and_return({})

    expect(Karst::Access::PrincipalSourceSelection).to receive(:load).and_call_original
    expect(Karst::Access::SelectedPrincipalSources.mappings).to eq([])
  end
end
