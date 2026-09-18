# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity::EvidenceBuilder do
  def requested(id: 27, model: "User")
    Karst::Identity::PrincipalDescriptor.new(model_name: model, id: id, display_label: "#{model} ##{id}")
  end

  def observed(id: 27, model: "User")
    Karst::Identity::Observation.new(
      principal: Karst::Identity::ObservedPrincipal.new(model_name: model, id: id), source: :configured, error: nil
    )
  end

  def anonymous_observation
    Karst::Identity::Observation.new(principal: nil, source: :configured, error: nil)
  end

  def failed_observation
    Karst::Identity::Observation.new(principal: nil, source: nil, error: "no seam")
  end

  it "confirms only when the application resolved the exact principal that was requested" do
    evidence = described_class.build(requested: requested, completion: observed)

    expect(evidence.confirmation).to eq(:confirmed)
    expect(evidence).to be_confirmed
  end

  it "compares identity by model and id, not by object" do
    evidence = described_class.build(requested: requested(id: 27), completion: observed(id: "27"))

    expect(evidence.confirmation).to eq(:confirmed)
  end

  it "reports a different model with the same id as a mismatch" do
    evidence = described_class.build(requested: requested(model: "User"), completion: observed(model: "Admin"))

    expect(evidence.confirmation).to eq(:mismatch)
  end

  it "reports an absent identity when the application resolved nobody" do
    expect(described_class.build(requested: requested, completion: anonymous_observation).confirmation)
      .to eq(:absent)
  end

  it "confirms an anonymous probe only when no principal was observed" do
    expect(described_class.build(requested: nil, completion: anonymous_observation).confirmation)
      .to eq(:confirmed_anonymous)
  end

  it "reports a contaminated anonymous probe when a principal was observed anyway" do
    evidence = described_class.build(requested: nil, completion: observed)

    expect(evidence.confirmation).to eq(:contaminated)
    expect(evidence).not_to be_confirmed
  end

  it "never confirms an unobservable probe, named or anonymous" do
    [requested, nil].each do |intent|
      evidence = described_class.build(requested: intent, completion: failed_observation)

      expect(evidence.confirmation).to eq(:unobservable)
      expect(evidence.observation_error).to eq("no seam")
    end
  end

  it "is unobservable when nothing was ever observed" do
    expect(described_class.build(requested: requested).confirmation).to eq(:unobservable)
  end

  it "prefers the identity observed when the access decision was made" do
    evidence = described_class.build(requested: requested(id: 1), halt: observed(id: 1), completion: observed(id: 2))

    expect(evidence.observed_at).to eq(:halted_callback)
    expect(evidence.observed.id).to eq(1)
    expect(evidence.confirmation).to eq(:confirmed)
    expect(evidence.changed_during_request).to be(true)
  end

  it "falls back to the completed request when the halt-time observation failed" do
    evidence = described_class.build(requested: requested, halt: failed_observation, completion: observed)

    expect(evidence.observed_at).to eq(:request_completion)
    expect(evidence.confirmation).to eq(:confirmed)
    expect(evidence.changed_during_request).to be(false)
  end

  it "carries establishment and cleanup outcomes without letting them stand in for observation" do
    evidence = described_class.build(requested: requested, completion: anonymous_observation,
                                     establishment: :failed, establishment_error: "RuntimeError: nope",
                                     cleanup_error: "RuntimeError: teardown")

    expect(evidence.establishment).to eq(:failed)
    expect(evidence.establishment_error).to eq("RuntimeError: nope")
    expect(evidence.cleanup_error).to eq("RuntimeError: teardown")
    expect(evidence.confirmation).to eq(:absent)
  end
end
# rubocop:enable Metrics/BlockLength
