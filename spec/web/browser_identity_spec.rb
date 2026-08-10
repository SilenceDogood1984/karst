# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/browser_identity"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::BrowserIdentity do
  let(:principal_class) { Struct.new(:id) }
  let(:request_class) { Struct.new(:session) }

  let(:principal) { principal_class.new(27) }
  let(:session) { {} }
  let(:request) { request_class.new(session) }
  subject(:identity) { described_class.new(request) }

  before do
    Karst.config.principals = -> { [principal] }
    Karst.config.assume_browser_identity = ->(_request, selected) { session["user_id"] = selected.id }
    Karst.config.clear_browser_identity = ->(_request) { session.delete("user_id") }
  end

  after do
    Karst.config.principals = nil
    Karst.config.assume_browser_identity = nil
    Karst.config.clear_browser_identity = nil
  end

  def params(overrides = {})
    descriptor = Karst::Identity.describe(principal)
    { "csrf_token" => identity.token, "principal_type" => descriptor.model_name,
      "principal_id" => descriptor.id.to_s, "path" => "/documents/22/reader?secret=gone" }.merge(overrides)
  end

  it "establishes browser identity and returns the query-free local target" do
    expect(identity.assume(params)).to eq("/documents/22/reader")
    expect(session).to include("user_id" => 27)
    expect(identity).to be_active
  end

  it "rejects invalid and out-of-scope principals" do
    expect { identity.assume(params("principal_id" => "999999")) }
      .to raise_error(Karst::Identity::Unavailable, /configured source/)

    other = principal_class.new(99)
    expect { identity.assume(params("principal_id" => other.id.to_s)) }
      .to raise_error(Karst::Identity::Unavailable, /configured source/)
  end

  it "rejects external return paths" do
    expect { identity.assume(params("path" => "https://example.com/steal")) }
      .to raise_error(Karst::Identity::Unavailable, /local application path/)
  end

  it "requires a same-session nonce" do
    expect { identity.assume(params("csrf_token" => "wrong")) }
      .to raise_error(Karst::Identity::Unavailable, /CSRF/)
  end

  it "clears browser identity and returns to the local path" do
    identity.assume(params)
    expect(identity.clear("csrf_token" => identity.token, "path" => "/documents/22/reader")).to eq(
      "/documents/22/reader"
    )
    expect(session).not_to include("user_id")
    expect(identity).not_to be_active
  end
end
# rubocop:enable Metrics/BlockLength
