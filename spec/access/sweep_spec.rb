# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "action_dispatch/testing/integration"
require "active_record"
require "karst"

# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe Karst::Access::Sweep do
  Principal = Struct.new(:id)

  class FakeResponse
    attr_accessor :status, :location
  end

  class FakeSession
    attr_reader :response

    def initialize(_application)
      @response = FakeResponse.new
      @identity = nil
    end

    attr_writer :identity

    def get(path)
      raise "private value" if @identity.id == 4

      @response.status = { 1 => 200, 2 => 302, 3 => 403 }.fetch(@identity.id)
      @response.location = "/login?return_to=#{path}" if @response.status == 302
      return unless path == "/writes"

      ActiveSupport::Notifications.instrument("sql.active_record", sql: "UPDATE documents SET seen = 1")
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(ActiveRecord::Base).to receive(:transaction) do |requires_new:, &block|
      expect(requires_new).to be(true)
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    stub_const("ActionDispatch::Integration::Session", FakeSession)
    Karst.config.access_sweep_limit = 25
    Karst.config.assume_identity = ->(session, principal) { session.identity = principal }
    Karst.config.clear_identity = ->(session) { session.identity = nil }
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
    Karst.config.access_sweep_limit = 25
  end

  it "records grouped observed outcomes, strips redirect queries, and continues after exceptions" do
    result = described_class.new(path: "/documents/123/edit?token=secret",
                                 principals: (1..4).map { |id| Principal.new(id) }, application: Object.new).call

    expect(result.path).to eq("/documents/123/edit")
    expect(result.outcomes.map(&:status)).to eq([200, 302, 403, nil])
    expect(result.outcomes[1].redirect).to eq("/login")
    expect(result.outcomes[3].exception_class).to eq("RuntimeError")
    expect(result.outcomes).to all(be_frozen)
    expect(result.groups.size).to eq(4)
    expect(result.database_isolation).to eq(:same_connection_rollback_attempted)
    expect(result.outcomes).to all(have_attributes(database_rollback_attempted: true))
  end

  it "groups response behavior independently from database-write evidence" do
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 1, display_label: "User #1")
    attributes = { principal: descriptor, status: 200, redirect: nil, exception_class: nil,
                   write_count: 0, elapsed_ms: 1.0, database_rollback_attempted: true }
    clean = Karst::Access::Outcome.new(**attributes, writes_observed: false)
    writing = Karst::Access::Outcome.new(**attributes, writes_observed: true, write_count: 1)
    result = Karst::Access::Result.new(path: "/documents", http_method: "GET", outcomes: [clean, writing],
                                       elapsed_ms: 2.0, aborted_reason: nil,
                                       database_isolation: :same_connection_rollback_attempted)

    expect(result.groups.values).to eq([[clean, writing]])
  end

  it "limits relation-like sources before materializing them" do
    relation = double("relation")
    limited = [Principal.new(1), Principal.new(2)]
    expect(relation).to receive(:limit).with(2).ordered.and_return(limited)
    expect(relation).not_to receive(:to_a)

    result = described_class.new(path: "/documents", principals: relation, limit: 2,
                                 application: Object.new).call
    expect(result.outcomes.size).to eq(2)
  end

  it "uses a fresh session for every principal and detects mutating SQL" do
    expect(ActionDispatch::Integration::Session).to receive(:new).twice.and_call_original
    result = described_class.new(path: "/writes", principals: [Principal.new(1), Principal.new(2)],
                                 application: Object.new).call

    expect(result.outcomes.map(&:writes_observed)).to eq([true, true])
    expect(result.outcomes.map(&:write_count)).to eq([1, 1])
  end

  it "rejects unsafe targets, unsupported methods, excessive limits, and non-development execution" do
    expect { described_class.new(path: "https://example.com", principals: []) }.to raise_error(Karst::Access::UnsafeTarget)
    expect { described_class.new(path: "//example.com", principals: []) }.to raise_error(Karst::Access::UnsafeTarget)
    expect { described_class.new(path: "/documents", principals: [], http_method: "POST") }.to raise_error(Karst::Access::UnsupportedMethod)
    expect { described_class.new(path: "/documents", principals: [], limit: 26) }.to raise_error(ArgumentError)

    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect { described_class.new(path: "/documents", principals: [], application: Object.new).call }.to raise_error(Karst::Access::Unavailable)
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
