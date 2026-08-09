# frozen_string_literal: true

require "spec_helper"
require_relative "../support/identity_application"

KarstIdentityIntegrationUser = Struct.new(:id)

# rubocop:disable Metrics/BlockLength
RSpec.describe "custom session identity" do
  let(:session) { ActionDispatch::Integration::Session.new(KarstIdentityApplication) }

  before do
    Karst.configure do |config|
      config.assume_identity = lambda do |target, principal|
        target.post("/karst_test_login", params: { user_id: principal.id })
      end
      config.clear_identity = ->(target) { target.delete("/karst_test_logout") }
    end
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
  end

  it "denies anonymously, allows each assumed user, and is anonymous after every clear" do
    session.get("/protected")
    expect(session.response.status).to eq(401)

    [KarstIdentityIntegrationUser.new(1), KarstIdentityIntegrationUser.new(2)].each do |user|
      Karst::Identity.with(session, user) do
        session.get("/protected")
        expect(session.response.status).to eq(200)
      end
      session.get("/protected")
      expect(session.response.status).to eq(401)
    end
  end

  it "clears the custom session when the controlled operation raises" do
    expect do
      Karst::Identity.with(session, KarstIdentityIntegrationUser.new(1)) { raise "probe failed" }
    end.to raise_error("probe failed")

    session.get("/protected")
    expect(session.response.status).to eq(401)
  end
end
# rubocop:enable Metrics/BlockLength
