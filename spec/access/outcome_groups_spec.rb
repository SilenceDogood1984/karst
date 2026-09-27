# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::OutcomeGroups do
  def descriptor(id)
    Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: "User ##{id}")
  end

  def evidence(id, observed_at: :halted_callback, source: :warden, changed: false)
    Karst::Identity::Evidence.new(
      requested: descriptor(id), observed: Karst::Identity::ObservedPrincipal.new(model_name: "User", id: id),
      confirmation: :confirmed, observed_at: observed_at, observation_source: source, observation_error: nil,
      establishment: :established, establishment_error: nil, cleanup_error: nil, changed_during_request: changed
    )
  end

  # rubocop:disable Metrics/ParameterLists
  def outcome(id: 1, status: 403, redirect: nil, exception_class: nil, halted_callback: :require_admin,
              elapsed_ms: 1.0, writes: 0, controller: "ReportsController", action: "show",
              sampling_reasons: [], identity: nil)
    Karst::Access::Outcome.new(
      principal: descriptor(id), status: status, redirect: redirect, exception_class: exception_class,
      writes_observed: writes.positive?, write_count: writes, elapsed_ms: elapsed_ms,
      database_rollback_attempted: true, sampling_reasons: sampling_reasons, body_marker_observed: nil,
      halted_callback: halted_callback, identity: identity || evidence(id), controller: controller, action: action
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def group(outcomes)
    described_class.group(outcomes, usable: Karst.config.usable_access_outcome)
  end

  it "classifies every Outcome field as either semantic or probe metadata, and nothing twice" do
    classified = described_class::SEMANTIC_FIELDS + described_class::PROBE_METADATA

    expect(classified).to match_array(Karst::Access::Outcome.members)
    expect(described_class::SEMANTIC_FIELDS & described_class::PROBE_METADATA).to be_empty
    expect(described_class::PROBE_METADATA).to include(:elapsed_ms, :principal, :identity, :sampling_reasons)
  end

  it "1. groups the same status observed at different speeds into one group" do
    outcomes = [17.2, 21.8, 19.1].each_with_index.map { |ms, index| outcome(id: index, elapsed_ms: ms) }

    groups = group(outcomes)

    expect(groups.size).to eq(1)
    expect(groups.first.outcomes).to eq(outcomes)
    expect(groups.first.count).to eq(3)
  end

  it "2. groups the same denial observed for different identities into one outcome" do
    outcomes = [outcome(id: 1), outcome(id: 2, sampling_reasons: ["role=member"]), outcome(id: 3)]

    expect(group(outcomes).map(&:count)).to eq([3])
  end

  it "3. keeps 403 and 404 apart" do
    expect(group([outcome(status: 403), outcome(status: 404, halted_callback: :require_admin)]).size).to eq(2)
  end

  it "4. keeps different redirect destinations apart, and equal ones together" do
    to_login = [outcome(id: 1, status: 302, redirect: "/login"), outcome(id: 2, status: 302, redirect: "/login")]
    elsewhere = outcome(id: 3, status: 302, redirect: "/subscribe")

    expect(group(to_login + [elsewhere]).map(&:count)).to eq([2, 1])
  end

  it "5. keeps different halted callbacks apart, and treats a Symbol and String callback as one" do
    groups = group([outcome(id: 1, halted_callback: :require_admin), outcome(id: 2, halted_callback: "require_admin"),
                    outcome(id: 3, halted_callback: :require_subscription)])

    expect(groups.map(&:count)).to eq([2, 1])
  end

  it "6. keeps different exception classes apart" do
    errors = [outcome(status: nil, halted_callback: nil, exception_class: "NoMethodError"),
              outcome(status: nil, halted_callback: nil, exception_class: "ArgumentError")]

    expect(group(errors).size).to eq(2)
  end

  it "7. groups the same result observed through different identity-observation traces" do
    outcomes = [outcome(id: 1, identity: evidence(1, observed_at: :halted_callback, source: :warden)),
                outcome(id: 2, identity: evidence(2, observed_at: :request_completion, source: :configured,
                                                     changed: true))]

    expect(group(outcomes).size).to eq(1)
  end

  it "8. orders groups deterministically: largest first, then by outcome, whatever the probe order" do
    outcomes = [outcome(id: 1, status: 404), outcome(id: 2, status: 403), outcome(id: 3, status: 302),
                outcome(id: 4, status: 403), outcome(id: 5, status: 200, halted_callback: nil)]

    orders = Array.new(5) do |seed|
      group(outcomes.shuffle(random: Random.new(seed))).map { |item| item.representative.status }
    end

    expect(orders.uniq).to eq([[403, 200, 302, 404]])
  end

  it "keeps members in the order they were probed" do
    outcomes = [outcome(id: 9), outcome(id: 2), outcome(id: 5)]

    expect(group(outcomes).first.outcomes.map { |item| item.principal.id }).to eq([9, 2, 5])
  end

  it "keeps different write evidence and different dispatch targets apart" do
    expect(group([outcome(writes: 0), outcome(writes: 1)]).size).to eq(2)
    expect(group([outcome(controller: "A"), outcome(controller: "B")]).size).to eq(2)
  end

  it "never mixes verdicts of the configured usable policy inside one group" do
    policy = ->(item) { item.identity.observation_source == :warden }
    outcomes = [outcome(id: 1, identity: evidence(1, source: :warden)),
                outcome(id: 2, identity: evidence(2, source: :configured))]

    groups = described_class.group(outcomes, usable: policy)

    expect(groups.map(&:usable)).to contain_exactly(true, false)
  end

  it "evaluates the usable policy exactly once per outcome" do
    calls = 0
    policy = lambda do |item|
      calls += 1
      item.status == 200
    end

    described_class.group(Array.new(7) { |index| outcome(id: index) }, usable: policy)

    expect(calls).to eq(7)
  end
end
# rubocop:enable Metrics/BlockLength
