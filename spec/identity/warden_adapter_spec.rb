# frozen_string_literal: true

require "spec_helper"
require "karst"

WardenAdapterSpecPrincipal = Struct.new(:id)

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity::WardenAdapter do
  let(:proxy) { instance_double("Warden proxy", set_user: nil, logout: nil) }
  let(:session) { { "warden" => proxy } }
  let(:principal) { WardenAdapterSpecPrincipal.new(1) }

  context "without a scope (plain, non-Devise Warden)" do
    subject(:adapter) { described_class.new }

    it "calls set_user with no scope option" do
      adapter.assume(session, principal)

      expect(proxy).to have_received(:set_user).with(principal)
    end

    it "calls logout with no scope argument" do
      adapter.clear(session)

      expect(proxy).to have_received(:logout).with(no_args)
    end
  end

  context "with an explicit scope (the Devise-derived path)" do
    subject(:adapter) { described_class.new(scope: :admin) }

    it "passes the scope to set_user rather than assuming the default Warden scope" do
      adapter.assume(session, principal)

      expect(proxy).to have_received(:set_user).with(principal, scope: :admin)
    end

    it "passes the scope to logout so only that scope is cleared" do
      adapter.clear(session)

      expect(proxy).to have_received(:logout).with(:admin)
    end
  end

  it "raises Unavailable when the session has no initialized Warden proxy" do
    adapter = described_class.new(scope: :user)

    expect { adapter.assume({}, principal) }.to raise_error(Karst::Identity::Unavailable, /no initialized Warden/)
  end
end
# rubocop:enable Metrics/BlockLength
