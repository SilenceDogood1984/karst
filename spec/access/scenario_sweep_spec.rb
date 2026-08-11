# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "active_record"
require "karst"

# rubocop:disable Layout/LineLength, Lint/ConstantDefinitionInBlock, Metrics/BlockLength
RSpec.describe Karst::Access::ScenarioSweep do
  ScenarioPrincipal = Struct.new(:id)
  ScenarioArtifact = Struct.new(:id)

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    Karst.config.assume_identity = ->(session, principal) { session.identity = principal }
    Karst.config.clear_identity = ->(session) { session.identity = nil }
    allow(ActiveRecord::Base).to receive(:transaction) do |**_options, &block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end

    response = Struct.new(:status, :location, :body)
    session = Class.new do
      define_method(:initialize) { |_app| @response = response.new }
      attr_reader :response
      attr_accessor :identity

      define_method(:get) do |path|
        @response.status = path.include?("missing") ? 404 : 200
        @response.location = path.include?("redirect") ? "/done?token=x" : nil
        @response.status = 302 if @response.location
        @response.body = path.include?("marker") ? "Spreadsheet rendered" : "plain"
        raise "observed" if path.include?("raise")
      end
    end
    stub_const("ActionDispatch::Integration::Session", session)
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
  end

  def scenario(artifacts, expect:, path: nil, **options)
    source = Karst::Access::ArtifactSource.new(name: :imports, records: -> { artifacts }, limit: 10)
    Karst::Access::Scenario.new(name: :import, artifact_source: source,
                                path: path || ->(item) { "/imports/#{item.id}" }, expect: expect, **options)
  end

  it "executes principal x artifact paths and accepts expected 200 and 404 observations" do
    artifacts = [ScenarioArtifact.new("ok"), ScenarioArtifact.new("missing")]
    result = described_class.new(scenario: scenario(artifacts, expect: { status: 404 }, stop_on_match: false),
                                 principals: [ScenarioPrincipal.new(1), ScenarioPrincipal.new(2)], application: Object.new).call

    expect(result.outcomes.size).to eq(4)
    expect(result.outcomes.map(&:path)).to eq(["/imports/ok", "/imports/missing"] * 2)
    expect(result.outcomes.select(&:match).map(&:status)).to eq([404, 404])
    two_hundred = described_class.new(scenario: scenario([ScenarioArtifact.new("ok")], expect: { status: 200 }),
                                      principals: [ScenarioPrincipal.new(1)], application: Object.new).call
    expect(two_hundred.outcomes.first.match).to be(true)
  end

  it "uses a fresh isolated identity session for every combination" do
    expect(ActionDispatch::Integration::Session).to receive(:new).twice.and_call_original
    configured = scenario([ScenarioArtifact.new("ok"), ScenarioArtifact.new("missing")], expect: { status: 500 },
                                                                                         stop_on_match: false)

    described_class.new(scenario: configured, principals: [ScenarioPrincipal.new(1)], application: Object.new).call
  end

  it "evaluates body and redirect predicates and reports mismatches" do
    marker = described_class.new(scenario: scenario([ScenarioArtifact.new("marker")],
                                                    expect: { status: 200, body_includes: "Spreadsheet" }),
                                 principals: [ScenarioPrincipal.new(1)], application: Object.new).call.outcomes.first
    redirect = described_class.new(scenario: scenario([ScenarioArtifact.new("redirect")],
                                                      expect: { redirect: "/done" }),
                                   principals: [ScenarioPrincipal.new(1)], application: Object.new).call.outcomes.first
    mismatch = described_class.new(scenario: scenario([ScenarioArtifact.new("ok")], expect: { status: 404 }),
                                   principals: [ScenarioPrincipal.new(1)], application: Object.new).call.outcomes.first

    expect(marker).to have_attributes(match: true, body_marker_observed: true)
    expect(redirect).to have_attributes(match: true, redirect: "/done")
    expect(mismatch.match).to be(false)
  end

  it "stops at the combination bound and stops early on a match" do
    bounded = scenario([ScenarioArtifact.new("a"), ScenarioArtifact.new("b")], expect: { status: 404 },
                                                                               combination_limit: 3, stop_on_match: false)
    expect(described_class.new(scenario: bounded, principals: [ScenarioPrincipal.new(1), ScenarioPrincipal.new(2)],
                               application: Object.new).call.outcomes.size).to eq(3)

    early = scenario([ScenarioArtifact.new("missing"), ScenarioArtifact.new("b")], expect: { status: 404 })
    result = described_class.new(scenario: early, principals: [ScenarioPrincipal.new(1), ScenarioPrincipal.new(2)],
                                 application: Object.new).call
    expect(result).to have_attributes(stopped_on_match: true)
    expect(result.outcomes.size).to eq(1)
  end

  it "fairly exercises both axes before a smaller combination budget is exhausted" do
    configured = scenario([ScenarioArtifact.new("a"), ScenarioArtifact.new("b"), ScenarioArtifact.new("c")],
                          expect: { status: 500 }, combination_limit: 4, stop_on_match: false)
    result = described_class.new(scenario: configured,
                                 principals: [ScenarioPrincipal.new(1), ScenarioPrincipal.new(2),
                                              ScenarioPrincipal.new(3)], application: Object.new).call

    expect(result.outcomes.map { |outcome| outcome.principal.id }.uniq.size).to be > 1
    expect(result.outcomes.map { |outcome| outcome.artifact.id }.uniq).to contain_exactly("a", "b", "c")
  end

  it "records request exceptions but surfaces path-generation failures as scenario errors" do
    request_error = described_class.new(scenario: scenario([ScenarioArtifact.new("raise")], expect: { status: 200 }),
                                        principals: [ScenarioPrincipal.new(1)], application: Object.new).call.outcomes.first
    expect(request_error).to have_attributes(exception_class: "RuntimeError", match: false)

    broken = scenario([ScenarioArtifact.new(1)], expect: { status: 200 }, path: ->(_item) { raise KeyError, "bad path" })
    expect do
      described_class.new(scenario: broken, principals: [ScenarioPrincipal.new(1)], application: Object.new).call
    end.to raise_error(Karst::Access::ScenarioDefinitionError, /:import.*KeyError: bad path/)
  end

  it "limits a relation before materializing it" do
    relation = double("relation")
    expect(relation).to receive(:limit).with(2).and_return([ScenarioArtifact.new(1), ScenarioArtifact.new(2)])
    expect(relation).not_to receive(:to_a)
    source = Karst::Access::ArtifactSource.new(name: :imports, records: -> { relation }, limit: 2)
    expect(source.candidates.size).to eq(2)
  end
end
# rubocop:enable Layout/LineLength, Lint/ConstantDefinitionInBlock, Metrics/BlockLength
