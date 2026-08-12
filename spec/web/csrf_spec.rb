# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require "karst/web/csrf"

RSpec.describe Karst::Web::Csrf do
  let(:session) { {} }
  let(:request) { instance_double(Rack::Request, session: session) }
  subject(:csrf) { described_class.new(request) }

  it "creates and reuses one session synchronizer token" do
    expect(csrf.token).to match(/\A[0-9a-f]{64}\z/)
    expect(csrf.token).to eq(session.fetch("karst.csrf_token"))
  end

  it "accepts only the current token" do
    token = csrf.token

    expect { csrf.verify!(token) }.not_to raise_error
    expect { csrf.verify!("wrong") }.to raise_error(described_class::InvalidToken)
    expect { csrf.verify!(nil) }.to raise_error(described_class::InvalidToken)
  end

  it "rotates and invalidates the previous token" do
    previous = csrf.token
    csrf.rotate!

    expect(csrf.token).not_to eq(previous)
    expect { csrf.verify!(previous) }.to raise_error(described_class::InvalidToken)
  end

  it "fails closed without a writable Rack session" do
    allow(request).to receive(:session).and_raise(RuntimeError)

    expect { csrf.token }.to raise_error(described_class::InvalidToken, /writable Rack session/)
  end
end
