# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity::Snapshot do
  after do
    Karst.config.principals = nil
  end

  it "resolves the effective principal sources exactly once for readiness, browser support, and sources" do
    Karst.config.principals = -> { [] }
    allow(Karst.config).to receive(:principal_sources).and_call_original

    snapshot = Karst::Identity.snapshot

    expect(Karst.config).to have_received(:principal_sources).once
    expect(snapshot.principal_sources.keys).to eq([:default])
    expect(snapshot.setup_state).to be_a(Karst::Identity::SetupState)
    expect(snapshot.browser_supported?).to be(false)
  end

  it "resolves once even on the inferred Devise path, where readiness inspects every source's model" do
    model = Class.new do
      def self.name
        "SnapshotUser"
      end
    end
    stub_const("Warden::Manager", Class.new)
    stub_const("Devise", Module.new)
    allow(Devise).to receive(:mappings).and_return(user: Struct.new(:to, :name).new(model, :user))
    calls = 0
    Karst.config.principals = lambda do
      calls += 1
      [model.new]
    end
    allow(Karst.config).to receive(:principal_sources).and_call_original

    snapshot = Karst::Identity.snapshot

    expect(Karst.config).to have_received(:principal_sources).once
    expect(calls).to eq(1)
    expect(snapshot.setup_state.status).to eq(:ready_mixed)
    expect(snapshot.browser_supported?).to be(true)
  end

  it "is nil-safe when nothing is configured, and says so only when sources are demanded" do
    snapshot = Karst::Identity.snapshot

    expect(snapshot.principal_sources).to be_nil
    expect { snapshot.principal_sources! }
      .to raise_error(Karst::Identity::Unavailable, "no principal source is configured")
  end

  it "never outlives the operation that took it: a later snapshot sees changed configuration" do
    Karst.config.principals = -> { [:first] }
    first = Karst::Identity.snapshot
    Karst.config.principals = -> { [:second] }
    second = Karst::Identity.snapshot

    expect(first.principal_sources[:default].evaluate).to eq([:first])
    expect(second.principal_sources[:default].evaluate).to eq([:second])
  end
end

RSpec.describe Karst::Access::PrincipalSource do
  it "evaluates its records callable once per #evaluated_once copy, and afresh for each new copy" do
    calls = 0
    source = described_class.new(name: :default, records: lambda {
      calls += 1
      [calls]
    })

    once = source.evaluated_once
    3.times { once.evaluate }
    once.with_populations(admins: -> { [] }).evaluate
    source.evaluated_once.evaluate

    expect(calls).to eq(2)
    expect(once.records).to equal(source.records)
  end

  it "does not memoize a callable that raises" do
    calls = 0
    once = described_class.new(name: :default, records: lambda {
      calls += 1
      raise "boom"
    }).evaluated_once

    2.times { expect { once.evaluate }.to raise_error("boom") }
    expect(calls).to eq(2)
  end
end
# rubocop:enable Metrics/BlockLength
