# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../support/execution_parity_fixture"
require_relative "../support/qualification_contract_spike"

# rubocop:disable Metrics/BlockLength
RSpec.describe "qualification contract spike (not a public API)" do
  let(:member) { KarstParityPrincipal.create!(id: 501, role: "member") }
  let(:admin) { KarstParityPrincipal.create!(id: 502, role: "admin") }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstParitySession.delete_all
    KarstParityPrincipal.delete_all
    KarstParityIdentity.configure!
  end

  def observe(path, principal: Karst::Identity::ANONYMOUS, **options)
    Karst::Reproduction::Exercise.new(path: path, principal: principal,
                                      application: KarstTestApplication, **options).call
  end

  def contract(path, **options)
    QualificationContractSpike.build(observe(path, **options))
  end

  it "observes a public request as confirmed anonymous without claiming universal public access" do
    result = contract("/parity/public")
    expect(result[:identity]).to include(requested: nil, resolved: nil, confirmed: true,
                                         confirmation: "confirmed_anonymous")
    expect(result[:behavior]).to include(status: 200, controller_completed: true)
    expect(result[:predicates]).to eq([])
  end

  it "separates requested identity from a target that actually ran anonymously" do
    Karst.config.assume_identity = ->(_session, _principal) {}
    result = contract("/parity/member", principal: member)
    expect(result[:identity]).to include(requested: { model: "KarstParityPrincipal", id: member.id },
                                         resolved: nil, confirmed: false, confirmation: "absent")
    expect(result[:behavior]).to include(status: 401, halted_callback: "require_authentication")
  end

  it "keeps unobservable identity unknown, including on a successful response" do
    Karst.config.observe_identity = ->(_context) { raise "token=private-observer-secret" }
    result = contract("/parity/member", principal: member)
    expect(result[:identity]).to include(confirmation: "unobservable", resolved: nil, confirmed: false)
    expect(result[:behavior][:status]).to eq(200)
    expect(result[:unknowns].last[:question]).to include("principal")
    expect(JSON.generate(result)).not_to include("private-observer-secret")
  end

  it "confirms the authenticated principal without promoting it to a state requirement" do
    result = contract("/parity/member", principal: member)
    expect(result[:identity]).to include(resolved: { model: "KarstParityPrincipal", id: member.id },
                                         confirmation: "confirmed", confirmed: true)
    expect(result[:behavior][:status]).to eq(200)
    expect(result[:predicates]).to eq([])
  end

  it "cannot extract role from anonymous, member and admin counterfactuals" do
    results = [Karst::Identity::ANONYMOUS, member, admin].map do |principal|
      contract("/parity/admin", principal: principal)
    end
    expect(results.map { |item| item[:behavior][:status] }).to eq([401, 403, 200])
    expect(results.map { |item| item[:behavior][:halted_callback] })
      .to eq(["require_authentication", "authorize_admin", nil])
    expect(results.map { |item| item[:predicates] }).to eq([[], [], []])
    expect(results.map { |item| item[:unknowns].first }.uniq.size).to eq(1)
    expect(results.flat_map { |item| QualificationConstructionReport.rows(item) }).to eq([])
  end

  it "records a redirect without exporting its destination or calling it authorization denial" do
    result = contract("/parity/redirect", principal: member)
    expect(result[:behavior]).to include(status: 302, redirected: true, controller_completed: true)
    expect(result[:predicates]).to eq([])
  end

  it "records a target exception without inheriting login response evidence" do
    result = contract("/parity/boom", principal: member)
    expect(result[:behavior]).to include(status: nil, exception_class: "RuntimeError",
                                         exception_phase: "controller", controller_completed: false)
    expect(result[:identity][:confirmation]).to eq("confirmed")
    expect(result[:predicates]).to eq([])
  end

  it "does not treat callback completion as proof that the action body ran" do
    result = contract("/parity/admin", principal: member)
    expect(result[:behavior]).to include(status: 403, halted_callback: "authorize_admin",
                                         controller_completed: true)
  end

  it "has byte-stable JSON for repeated observations with identical semantic evidence" do
    first = JSON.generate(contract("/parity/member", principal: member))
    second = JSON.generate(contract("/parity/member", principal: member))
    expect(second).to eq(first)
    expect(JSON.parse(first).keys).to eq(%w[schema target identity behavior predicates unknowns])
  end

  it "withholds request values, concrete paths, labels, errors and timing from the projection" do
    Karst.config.principal_label = ->(_principal) { "private-label@example.test" }
    path = "/parity/items/private-path-secret?token=private-query-secret"
    result = contract(path, principal: member, headers: { "Authorization" => "Bearer private-header-secret" })
    json = JSON.generate(result)
    expect(json).not_to match(/private-|elapsed|authentication_identifier|route_params|url_path/)
    expect(result[:target]).to include(method: "GET", route_pattern: nil,
                                       controller: "KarstParityController", action: "show")
  end

  it "does not serialize opaque callback objects as source paths" do
    observation = observe("/parity/public")
    opaque = observation.to_h.merge(halted_callback: "#<Proc:/private/source.rb:5>")
    result = QualificationContractSpike.build(Karst::Reproduction::Observation.new(**opaque))
    expect(result[:behavior][:halted_callback]).to eq("[opaque callback]")
  end

  it "preserves render events as behavior, never qualifying state" do
    observation = observe("/parity/public")
    rendered = observation.to_h.merge(rendered: [{ virtual_path: "example/show", completed: true }])
    result = QualificationContractSpike.build(Karst::Reproduction::Observation.new(**rendered))
    expect(result[:behavior][:rendered]).to eq([{ virtual_path: "example/show", completed: true }])
    expect(result[:predicates]).to eq([])
  end
end

RSpec.describe QualificationConstructionReport do
  # Hypothetical predicates exercise the mapping boundary. The probe cannot
  # emit these today; no test fixture knowledge is inserted into the contract.
  let(:predicate) do
    { subject: "User", path: ["role"], operator: "eq", value: "admin",
      basis: "observed", evidence_ref: "application-decision/1" }
  end

  it "requires an inspected exact-attribute capability even for observed equality" do
    expect(described_class.classify(predicate)).to eq("not representable")
    expect(described_class.classify(predicate, exact_attributes: [["User", ["role"]]]))
      .to eq("directly representable")
  end

  it "requires explicit named vocabulary for a non-attribute state" do
    decision = predicate.merge(path: ["active_membership"], value: true)
    key = decision.values_at(:subject, :path, :operator, :value)
    expect(described_class.classify(decision, named_states: [key]))
      .to eq("requires named construction vocabulary")
  end

  it "rejects weaker evidence, missing references, and opaque policy results" do
    capabilities = { exact_attributes: [["User", ["role"]]] }
    expect(described_class.classify(predicate.merge(basis: "derived"), **capabilities))
      .to eq("not representable")
    expect(described_class.classify(predicate.merge(evidence_ref: nil), **capabilities))
      .to eq("not representable")
    expect(described_class.classify(predicate.merge(subject: "Pundit", path: ["allowed?"])))
      .to eq("not representable")
  end
end
# rubocop:enable Metrics/BlockLength
