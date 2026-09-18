# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"
require "karst/cli/verification"

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe Karst::CLI::Verification do
  Descriptor = Karst::Identity::PrincipalDescriptor
  Outcome = Karst::Access::Outcome
  SweepResult = Karst::Access::Result
  SearchResult = Karst::Access::Search::Result
  Attempt = Karst::Access::Search::PopulationAttempt

  # rubocop:disable Metrics/ParameterLists
  def outcome(status: 200, callback: nil, redirect: nil, exception: nil, writes: 0, confirmation: :confirmed)
    requested = Descriptor.new(model_name: "User", id: 27, display_label: "User #27")
    Outcome.new(principal: requested,
                status: status, redirect: redirect, exception_class: exception, writes_observed: writes.positive?,
                write_count: writes, elapsed_ms: 2.5, database_rollback_attempted: true,
                sampling_reasons: [].freeze, body_marker_observed: nil, halted_callback: callback,
                identity: identity_evidence(requested, confirmation), controller: "ImportsController",
                action: "index")
  end
  # rubocop:enable Metrics/ParameterLists

  def identity_evidence(requested, confirmation)
    observed = (Karst::Identity::ObservedPrincipal.new(model_name: "User", id: 27) if confirmation == :confirmed)
    Karst::Identity::Evidence.new(requested: requested, observed: observed, confirmation: confirmation,
                                  observed_at: :request_completion, observation_source: :configured,
                                  observation_error: nil, establishment: :established, establishment_error: nil,
                                  cleanup_error: nil, changed_during_request: false)
  end

  def sweep(outcomes)
    SweepResult.new(path: "/admin/imports", http_method: "GET", outcomes: outcomes, elapsed_ms: 3.0,
                    aborted_reason: nil, database_isolation: :same_connection_rollback_attempted,
                    candidate_pool_size: 100)
  end

  def run(result, json: true)
    output = StringIO.new
    allow(Karst::Identity).to receive(:setup_state).and_return(
      Karst::Identity::SetupState.new(status: :ready_explicit, message: nil)
    )
    allow(Karst::Identity).to receive(:principal_sources).and_return(default: double)
    allow(Karst::Access::Search).to receive(:new).and_return(instance_double(Karst::Access::Search, call: result))
    code = described_class.new(path: "/admin/imports?secret=yes", output: output, json: json).call
    [code, output.string]
  end

  it "emits versioned JSON for a verified ordinary sample without population attempts" do
    result = SearchResult.new(initial: sweep([outcome]), attempts: [])
    code, text = run(result)
    document = JSON.parse(text)

    expect(code).to eq(0)
    expect(document).to include("schema_version" => 2, "verified_usable" => true, "populations" => [])
    expect(document.dig("verified_identity", "requested", "label")).to eq("User #27")
    expect(document.dig("verified_identity", "observed")).to eq("model" => "User", "id" => 27)
    expect(document.dig("verified_identity", "confirmation")).to eq("confirmed")
    expect(document.dig("probe", "identity")).to eq("application_identities")
    expect(document["provenance"]).to include("karst_version" => Karst::VERSION)
    expect(text).not_to include("secret")
  end

  it "does not serialize a framework-inferred authentication identifier" do
    inferred = Descriptor.new(model_name: "User", id: 27,
                              display_label: "user@example.com · User #27",
                              authentication_key: :email,
                              authentication_identifier: "user@example.com")
    attributes = outcome.to_h
    attributes[:principal] = inferred
    attributes[:identity] = identity_evidence(inferred, :confirmed)
    item = Outcome.new(**attributes)
    _code, text = run(SearchResult.new(initial: sweep([item]), attempts: []))

    expect(JSON.parse(text).dig("verified_identity", "requested", "label")).to eq("User #27")
    expect(text).not_to include("user@example.com")
  end

  it "preserves population state, halted callback, write, and exception observations" do
    denied = outcome(status: 204, callback: :redirect_if_suspended, writes: 1)
    failed = outcome(status: nil, exception: "RuntimeError")
    attempts = [Attempt.new(name: :admins, source_name: :default, state: :no_match,
                            result: sweep([failed]), error: nil),
                Attempt.new(name: :auditors, source_name: :default, state: :budget_exhausted,
                            result: nil, error: nil)]
    result = SearchResult.new(initial: sweep([denied]), attempts: attempts)
    code, text = run(result)
    document = JSON.parse(text)

    expect(code).to eq(1)
    expect(document["verified_usable"]).to be(false)
    expect(document.dig("sample", "outcomes", 0)).to include(
      "status" => 204, "halted_callback" => "redirect_if_suspended", "writes_observed" => true
    )
    expect(document["populations"].map { |item| item["state"] }).to eq(%w[no_match budget_exhausted])
    expect(text).to include("RuntimeError")
  end

  it "uses the configured usable outcome policy rather than defining CLI success" do
    original_policy = Karst.config.usable_access_outcome
    Karst.config.usable_access_outcome = ->(item) { item.status == 204 }
    result = SearchResult.new(initial: sweep([outcome(status: 204)]), attempts: [])

    expect(run(result).first).to eq(0)
  ensure
    Karst.config.usable_access_outcome = original_policy
  end

  it "emits only a structured error and returns 2 for unsafe input" do
    output = StringIO.new
    allow(Karst::Identity).to receive(:setup_state).and_return(
      Karst::Identity::SetupState.new(status: :ready_explicit, message: nil)
    )
    allow(Karst::Identity).to receive(:principal_sources).and_return(default: double)
    allow(Karst::Access::Search).to receive(:new).and_raise(Karst::Access::UnsafeTarget, "local paths only")

    code = described_class.new(path: "//evil.example.com", output: output, json: true).call

    expect(code).to eq(2)
    expect(JSON.parse(output.string)).to eq(
      "schema_version" => 2, "error" => { "type" => "input_error", "message" => "local paths only" }
    )
  end

  it "prints compact human-readable evidence instead of JSON" do
    code, text = run(SearchResult.new(initial: sweep([outcome]), attempts: []), json: false)

    expect(code).to eq(0)
    expect(text).to include("Karst verification", "verified usable: User #27",
                            "observed User #27 (identity confirmed)", "1 requests")
    expect { JSON.parse(text) }.to raise_error(JSON::ParserError)
  end

  describe "anonymous probes" do
    def anonymous_run(outcomes, json: true)
      output = StringIO.new
      sweep_result = sweep(outcomes)
      probe = instance_double(Karst::Access::Sweep, call: sweep_result)
      allow(Karst::Access::Sweep).to receive(:new).and_return(probe)
      code = described_class.new(path: "/admin/imports", output: output, json: json, identity: "anonymous").call
      [code, output.string]
    end

    def anonymous_outcome(status: 302, callback: :authorize_admin)
      attributes = outcome(status: status, callback: callback).to_h
      attributes[:principal] = nil
      attributes[:identity] = Karst::Identity::Evidence.new(
        requested: nil, observed: nil, confirmation: :confirmed_anonymous, observed_at: :halted_callback,
        observation_source: :warden, observation_error: nil, establishment: :cleared, establishment_error: nil,
        cleanup_error: nil, changed_during_request: false
      )
      Outcome.new(**attributes)
    end

    it "runs without consulting a principal source at all" do
      allow(Karst::Identity).to receive(:setup_state)
        .and_return(Karst::Identity::SetupState.new(status: :unavailable, message: "nothing configured"))

      code, text = anonymous_run([anonymous_outcome])
      document = JSON.parse(text)

      expect(code).to eq(1)
      expect(document.dig("probe", "identity")).to eq("anonymous")
      expect(document.dig("sample", "outcomes", 0, "identities", 0))
        .to include("requested" => nil, "observed" => nil, "confirmation" => "confirmed_anonymous")
    end

    it "says what the application observed, not what was asked of it, in human output" do
      _code, text = anonymous_run([anonymous_outcome], json: false)

      expect(text).to include("Probe identity: anonymous",
                              "observed no principal (anonymous confirmed)",
                              "halted at authorize_admin", "not usable anonymously")
    end

    it "reports a contaminated anonymous probe as unusable evidence, never as anonymous" do
      contaminated = anonymous_outcome(status: 200, callback: nil).to_h
      contaminated[:identity] = Karst::Identity::Evidence.new(
        requested: nil, observed: Karst::Identity::ObservedPrincipal.new(model_name: "User", id: 27),
        confirmation: :contaminated, observed_at: :request_completion, observation_source: :warden,
        observation_error: nil, establishment: :cleared, establishment_error: nil, cleanup_error: nil,
        changed_during_request: false
      )
      _code, text = anonymous_run([Outcome.new(**contaminated)], json: false)

      expect(text).to include("anonymous probe observed User #27 (CONTAMINATED)")
    end

    it "rejects an identity it does not implement rather than quietly running the ordinary search" do
      expect { described_class.new(path: "/x", identity: "root") }
        .to raise_error(ArgumentError, /anonymous/)
    end
  end

  describe "#evidence" do
    def evidence(path: "/admin/imports")
      allow(Karst::Identity).to receive(:setup_state).and_return(
        Karst::Identity::SetupState.new(status: :ready_explicit, message: nil)
      )
      allow(Karst::Identity).to receive(:principal_sources).and_return(default: double)
      described_class.new(path: path).evidence
    end

    it "returns the exact same Hash --json would print, without touching stdout" do
      result = SearchResult.new(initial: sweep([outcome]), attempts: [])
      allow(Karst::Access::Search).to receive(:new).and_return(instance_double(Karst::Access::Search, call: result))
      output = StringIO.new

      document = evidence
      described_class.new(path: "/admin/imports", output: output, json: true).call

      expect(JSON.generate(document)).to eq(output.string.chomp)
    end

    it "returns an error document instead of raising for the same errors #call rescues" do
      allow(Karst::Access::Search).to receive(:new).and_raise(Karst::Access::UnsafeTarget, "local paths only")

      expect(evidence).to eq(
        schema_version: 2, error: { type: "input_error", message: "local paths only" }
      )
    end

    it "surfaces a configuration error (e.g. no principal source) as an error document, never a crash" do
      allow(Karst::Identity).to receive(:setup_state).and_return(
        Karst::Identity::SetupState.new(status: :unavailable, message: nil)
      )

      document = described_class.new(path: "/admin/imports").evidence

      expect(document).to eq(
        schema_version: 2, error: { type: "configuration_error", message: "no principal source is configured" }
      )
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Lint/ConstantDefinitionInBlock
