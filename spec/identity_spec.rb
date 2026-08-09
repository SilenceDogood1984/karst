# frozen_string_literal: true

require "spec_helper"
require "karst"

KarstIdentitySpecPrincipal = Struct.new(:id)

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity do
  after do
    Karst.configure do |config|
      config.principals = nil
      config.assume_identity = nil
      config.clear_identity = nil
      config.principal_label = nil
    end
  end

  it "leaves an unavailable principal source untouched until requested" do
    expect(Karst.config.principals).to be_nil
    expect { described_class.principals }.to raise_error(Karst::Identity::Unavailable, /principal source/)
  end

  it "returns a configured source result without enumerating it" do
    relation = Object.new
    Karst.config.principals = -> { relation }

    expect(described_class.principals).to equal(relation)
  end

  it "validates a principal source only when used" do
    Karst.config.principals = []

    expect { described_class.principals }.to raise_error(Karst::Identity::ConfigurationError, /callable/)
  end

  it "builds a PII-safe descriptor without calling arbitrary to_s" do
    principal = KarstIdentitySpecPrincipal.new(123)
    allow(principal).to receive(:to_s).and_raise("must not be called")

    descriptor = described_class.describe(principal)

    expect(descriptor).to have_attributes(
      model_name: "KarstIdentitySpecPrincipal", id: 123, display_label: "KarstIdentitySpecPrincipal #123"
    )
    expect(descriptor).to be_frozen
  end

  it "uses an explicitly configured label only when describing" do
    calls = 0
    Karst.config.principal_label = lambda do |principal|
      calls += 1
      "Test account #{principal.id}"
    end
    principal = KarstIdentitySpecPrincipal.new(4)
    expect(calls).to eq(0)

    expect(described_class.describe(principal).display_label).to eq("Test account 4")
    expect(calls).to eq(1)
  end

  it "clears an assumed identity after success and after a request exception" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = ->(target, principal) { target.principal = principal }
    Karst.config.clear_identity = ->(target) { target.principal = nil }
    principal = KarstIdentitySpecPrincipal.new(1)

    expect(described_class.with(session, principal) { session.principal }).to equal(principal)
    expect(session.principal).to be_nil
    expect { described_class.with(session, principal) { raise "request failed" } }.to raise_error("request failed")
    expect(session.principal).to be_nil
  end

  it "clears partial identity when the assumption hook itself raises" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = lambda do |target, principal|
      target.principal = principal
      raise "setup failed"
    end
    Karst.config.clear_identity = ->(target) { target.principal = nil }

    expect { described_class.with(session, KarstIdentitySpecPrincipal.new(1)) { nil } }.to raise_error("setup failed")
    expect(session.principal).to be_nil
  end

  it "does not leak sequential principals and supports an explicit clear" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = ->(target, principal) { target.principal = principal }
    Karst.config.clear_identity = ->(target) { target.principal = nil }
    first = KarstIdentitySpecPrincipal.new(1)
    second = KarstIdentitySpecPrincipal.new(2)

    expect(described_class.with(session, first) { session.principal.id }).to eq(1)
    expect(described_class.with(session, second) { session.principal.id }).to eq(2)
    session.principal = first
    described_class.clear(session)
    expect(session.principal).to be_nil
  end

  it "fails loudly when configured hooks are incomplete" do
    Karst.config.assume_identity = ->(_session, _principal) {}

    expect { described_class.with(Object.new, KarstIdentitySpecPrincipal.new(1)) { nil } }
      .to raise_error(Karst::Identity::ConfigurationError, /both be callable/)
  end

  it "reports identity as unavailable when Warden is absent" do
    hide_const("Warden") if defined?(Warden)

    expect { described_class.clear(Object.new) }.to raise_error(Karst::Identity::Unavailable, /Warden is unavailable/)
  end

  it "uses public APIs on an existing Warden proxy when Warden is present" do
    stub_const("Warden::Manager", Class.new)
    proxy = instance_double("Warden proxy")
    allow(proxy).to receive(:set_user)
    allow(proxy).to receive(:logout)
    principal = KarstIdentitySpecPrincipal.new(8)

    described_class.with({ "warden" => proxy }, principal) { nil }

    expect(proxy).to have_received(:set_user).with(principal)
    expect(proxy).to have_received(:logout)
  end
end
# rubocop:enable Metrics/BlockLength
