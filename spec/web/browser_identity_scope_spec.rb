# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/browser_identity"

# Karst::Web::BrowserIdentity's own responsibility in the multi-Devise-model
# story: retain exactly the scope Identity.assume_browser actually used, and
# hand that same scope back to Identity.clear_browser, rather than making
# Identity guess which of several selected sources the assumed principal
# came from. Devise/Warden scope *resolution* itself is
# Karst::Identity::DeviseSupport's job (see
# spec/identity/devise_golden_path_spec.rb) -- this file proves only that
# BrowserIdentity carries the value through the session correctly, so it
# stubs Identity.assume_browser/clear_browser directly.
# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::BrowserIdentity do
  let(:principal_class) { Struct.new(:id) }
  let(:request_class) { Struct.new(:session) }

  let(:principal) { principal_class.new(9) }
  let(:session) { {} }
  let(:request) { request_class.new(session) }
  subject(:identity) { described_class.new(request) }

  before do
    allow(Karst::Identity).to receive(:browser_supported?).and_return(true)
    allow(Karst::Identity).to receive(:resolve).and_return(principal)
  end

  def params(overrides = {})
    { "csrf_token" => identity.token, "principal_type" => "Admin", "principal_id" => "9",
      "path" => "/documents/9" }.merge(overrides)
  end

  it "stores the scope assume_browser returns and hands that exact scope back to clear_browser" do
    allow(Karst::Identity).to receive(:assume_browser).with(request, principal).and_return(:admin)
    allow(Karst::Identity).to receive(:clear_browser)

    identity.assume(params)
    identity.clear("csrf_token" => identity.token, "path" => "/documents/9")

    expect(Karst::Identity).to have_received(:clear_browser).with(request, scope: :admin)
  end

  it "distinguishes which of several selected sources produced the assumed identity" do
    allow(Karst::Identity).to receive(:assume_browser).with(request, principal).and_return(:user)
    allow(Karst::Identity).to receive(:clear_browser)

    identity.assume(params)
    identity.clear("csrf_token" => identity.token, "path" => "/documents/9")

    expect(Karst::Identity).to have_received(:clear_browser).with(request, scope: :user)
  end

  it "passes no scope when assume_browser used explicit hooks (no Devise scope concept)" do
    allow(Karst::Identity).to receive(:assume_browser).with(request, principal).and_return(nil)
    allow(Karst::Identity).to receive(:clear_browser)

    identity.assume(params)
    identity.clear("csrf_token" => identity.token, "path" => "/documents/9")

    expect(Karst::Identity).to have_received(:clear_browser).with(request, scope: nil)
  end

  it "does not leak a previously assumed scope into a later, differently scoped assumption" do
    allow(Karst::Identity).to receive(:assume_browser).with(request, principal).and_return(:admin)
    identity.assume(params)

    other = principal_class.new(11)
    allow(Karst::Identity).to receive(:resolve).and_return(other)
    allow(Karst::Identity).to receive(:assume_browser).with(request, other).and_return(:user)
    identity.assume(params("principal_id" => "11", "csrf_token" => identity.token))

    allow(Karst::Identity).to receive(:clear_browser)
    identity.clear("csrf_token" => identity.token, "path" => "/documents/9")

    expect(Karst::Identity).to have_received(:clear_browser).with(request, scope: :user)
  end
end
# rubocop:enable Metrics/BlockLength
