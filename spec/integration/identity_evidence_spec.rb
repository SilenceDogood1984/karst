# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../support/test_application"
require "karst/cli/verification"

ActiveRecord::Schema.define do
  create_table :karst_identity_evidence_principals, force: true do |table|
    table.string :role, null: false, default: "member"
  end
end

class KarstIdentityEvidencePrincipal < ActiveRecord::Base
  scope :admins, -> { where(role: "admin") }
end

# A conventional custom-authentication controller: one before_action
# resolves the principal from the session, a later one makes the access
# decision. Nothing here knows Karst exists.
class KarstIdentityEvidenceController < ActionController::Base
  before_action :set_current_principal
  # Declared before the gate it wraps: a callback declared after
  # authorize_admin would never start once that gate halts the chain.
  around_action :swap_identity_after_the_decision, only: :volatile_document
  before_action :authorize_admin, only: %i[admin_document volatile_document]

  # Public so config.observe_identity can read what the application itself
  # resolved -- the application's own seam, not a Karst-specific hook.
  attr_reader :current_principal

  def login
    session[:principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:principal_id)
    head :no_content
  end

  def document
    render plain: "document for #{@current_principal&.id.inspect}"
  end

  def admin_document
    render plain: "admin document"
  end

  def volatile_document
    render plain: "volatile document"
  end

  def boom
    raise "fixture exploded"
  end

  private

  def set_current_principal
    @current_principal = KarstIdentityEvidencePrincipal.find_by(id: session[:principal_id])
  end

  def authorize_admin
    return redirect_to("/identity_evidence/login_page") if @current_principal.nil?

    head(:forbidden) unless @current_principal.role == "admin"
  end

  # Runs after the access decision has already been made and halted the
  # chain, so the identity the application ends the request with is not the
  # one it made the decision with.
  def swap_identity_after_the_decision
    yield
    @current_principal = KarstIdentityEvidencePrincipal.admins.first
  end
end

# Added directly through the mapper for the same reason mcp_server_spec.rb
# does: .draw clears and redraws the whole set shared with every other spec
# file's routes on the one KarstTestApplication.
KarstTestApplication.routes.send(:eval_block, proc {
  post "/identity_evidence/login", to: "karst_identity_evidence#login"
  delete "/identity_evidence/logout", to: "karst_identity_evidence#logout"
  get "/identity_evidence/document", to: "karst_identity_evidence#document"
  get "/identity_evidence/admin_document", to: "karst_identity_evidence#admin_document"
  get "/identity_evidence/volatile_document", to: "karst_identity_evidence#volatile_document"
  get "/identity_evidence/boom", to: "karst_identity_evidence#boom"
})

# rubocop:disable Metrics/BlockLength
RSpec.describe "runtime-confirmed identity evidence" do
  let(:member) { KarstIdentityEvidencePrincipal.create!(role: "member") }
  let(:other_member) { KarstIdentityEvidencePrincipal.create!(role: "member") }
  let(:admin) { KarstIdentityEvidencePrincipal.create!(role: "admin") }

  # The honest seam: log in through the application's own endpoint, exactly
  # as a real caller would.
  def working_login
    lambda do |session, principal|
      session.post "/identity_evidence/login", params: { id: principal.id }
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstIdentityEvidencePrincipal.delete_all
    @cleared = 0
    Karst.config.assume_identity = working_login
    Karst.config.clear_identity = lambda do |session|
      @cleared += 1
      session.delete "/identity_evidence/logout"
    end
    # The application's own runtime principal, read off the controller that
    # actually processed the request.
    Karst.config.observe_identity = ->(context) { context.controller&.current_principal }
  end

  after do
    %i[assume_identity clear_identity observe_identity principals].each do |hook|
      Karst.config.public_send("#{hook}=", nil)
    end
  end

  def probe(principals, path: "/identity_evidence/document")
    Karst::Access::Sweep.new(path: path, principals: Array(principals), limit: [Array(principals).size, 1].max,
                             application: KarstTestApplication).call
  end

  def identity_of(result, index = 0)
    result.outcomes[index].identity
  end

  # A -- an anonymous probe is anonymous in the application, not only in
  # Karst's own metadata.
  it "runs a deliberately anonymous probe and confirms the application observed no principal" do
    member
    result = probe([Karst::Identity::ANONYMOUS])
    evidence = identity_of(result)

    expect(evidence.requested).to be_nil
    expect(evidence.observed).to be_nil
    expect(evidence.confirmation).to eq(:confirmed_anonymous)
    expect(evidence.establishment).to eq(:cleared)
    expect(result.outcomes.first.principal).to be_nil
  end

  # B / J -- the whole point: the application resolved the exact principal
  # Karst asked for, and said so at runtime.
  it "confirms a named identity the application actually resolved, on a request that succeeded" do
    result = probe([admin], path: "/identity_evidence/admin_document")
    evidence = identity_of(result)

    expect(result.outcomes.first.status).to eq(200)
    expect(result.outcomes.first.halted_callback).to be_nil
    expect(evidence.confirmation).to eq(:confirmed)
    expect(evidence.requested.id).to eq(admin.id)
    expect(evidence.observed).to eq(Karst::Identity::ObservedPrincipal.new(model_name:
      "KarstIdentityEvidencePrincipal", id: admin.id))
    expect(evidence.establishment).to eq(:established)
    expect(evidence.observation_source).to eq(:configured)
  end

  # C -- the exact Task #81 false attribution: Karst was asked to run as a
  # principal, its setup seam "succeeded", and the application still ran the
  # request anonymously.
  it "refuses to confirm a requested identity the application never resolved" do
    Karst.config.assume_identity = ->(_session, _principal) {} # establishes nothing
    result = probe([member])
    evidence = identity_of(result)

    expect(evidence.requested.id).to eq(member.id)
    expect(evidence.observed).to be_nil
    expect(evidence.confirmation).to eq(:absent)
    expect(evidence.confirmed?).to be(false)
    expect(evidence.establishment).to eq(:established)
  end

  # D -- observed somebody, but not who was asked for.
  it "reports a mismatch when the application resolved a different principal" do
    impostor = other_member
    Karst.config.assume_identity = lambda do |session, _principal|
      session.post "/identity_evidence/login", params: { id: impostor.id }
    end
    result = probe([member])
    evidence = identity_of(result)

    expect(evidence.requested.id).to eq(member.id)
    expect(evidence.observed.id).to eq(impostor.id)
    expect(evidence.confirmation).to eq(:mismatch)
  end

  # E -- fail closed: an observation seam that cannot answer never confirms.
  it "reports an unobservable identity rather than assuming the requested one ran" do
    Karst.config.observe_identity = ->(_context) { raise "resolver exploded" }
    result = probe([member])
    evidence = identity_of(result)

    expect(evidence.confirmation).to eq(:unobservable)
    expect(evidence.observation_error).to include("resolver exploded")
    expect(evidence.confirmed?).to be(false)
  end

  it "never confirms an identity when no observation seam is configured at all" do
    Karst.config.observe_identity = nil
    result = probe([member])

    expect(identity_of(result).confirmed?).to be(false)
  end

  # F -- an anonymous probe that was not actually anonymous is invalid, not
  # anonymous.
  it "reports a contaminated anonymous probe when the application resolved a principal anyway" do
    stale = member
    Karst.config.observe_identity = ->(_context) { stale }
    result = probe([Karst::Identity::ANONYMOUS])
    evidence = identity_of(result)

    expect(evidence.confirmation).to eq(:contaminated)
    expect(evidence.observed.id).to eq(stale.id)
    expect(evidence.confirmed?).to be(false)
  end

  # G -- authentication succeeded; authorization then said no. These are not
  # the same observation.
  it "keeps a confirmed identity when authorization, not authentication, rejected the request" do
    result = probe([member], path: "/identity_evidence/admin_document")
    outcome = result.outcomes.first

    expect(outcome.status).to eq(403)
    expect(outcome.halted_callback).to eq(:authorize_admin)
    expect(outcome.identity.confirmation).to eq(:confirmed)
    expect(outcome.identity.observed.id).to eq(member.id)
  end

  # H -- the same halt, with a radically different meaning.
  it "distinguishes a halt reached with no established identity from one reached as the requested user" do
    Karst.config.assume_identity = ->(_session, _principal) {}
    result = probe([admin], path: "/identity_evidence/admin_document")
    outcome = result.outcomes.first

    expect(outcome.status).to eq(302)
    expect(outcome.redirect).to end_with("/identity_evidence/login_page")
    expect(outcome.halted_callback).to eq(:authorize_admin)
    expect(outcome.identity.confirmation).to eq(:absent)
    expect(outcome.identity.requested.id).to eq(admin.id)
  end

  # I -- anonymous plus the mechanism that stopped it: the counterfactual
  # half a later adapter needs.
  it "retains the halting mechanism for a confirmed-anonymous probe" do
    result = probe([Karst::Identity::ANONYMOUS], path: "/identity_evidence/admin_document")
    outcome = result.outcomes.first

    expect(outcome.identity.confirmation).to eq(:confirmed_anonymous)
    expect(outcome.halted_callback).to eq(:authorize_admin)
    expect(outcome.status).to eq(302)
    expect(outcome.controller).to eq("KarstIdentityEvidenceController")
    expect(outcome.action).to eq("admin_document")
  end

  # The counterfactual triple, in one sweep: the pair of observations that
  # separates "this gate requires authentication" from "this gate refused
  # this user".
  it "produces anonymous / ordinary / admin observations that can be compared" do
    result = probe([Karst::Identity::ANONYMOUS, member, admin], path: "/identity_evidence/admin_document")
    anonymous, ordinary, privileged = result.outcomes

    expect([anonymous.identity.confirmation, anonymous.status, anonymous.halted_callback])
      .to eq([:confirmed_anonymous, 302, :authorize_admin])
    expect([ordinary.identity.confirmation, ordinary.status, ordinary.halted_callback])
      .to eq([:confirmed, 403, :authorize_admin])
    expect([privileged.identity.confirmation, privileged.status, privileged.halted_callback])
      .to eq([:confirmed, 200, nil])
    expect(ordinary.identity.observed.id).to eq(member.id)
    expect(privileged.identity.observed.id).to eq(admin.id)
  end

  # K -- isolation: a named probe must not leak into the anonymous one after
  # it.
  it "keeps an anonymous probe anonymous after a named probe in the same sweep" do
    result = probe([member, Karst::Identity::ANONYMOUS])

    expect(identity_of(result, 0).confirmation).to eq(:confirmed)
    expect(identity_of(result, 1).confirmation).to eq(:confirmed_anonymous)
    expect(identity_of(result, 1).observed).to be_nil
  end

  # L -- isolation: the second named probe must observe the second user.
  it "observes each named principal in turn, never a stale earlier one" do
    first = member
    second = other_member
    result = probe([first, second])

    expect(identity_of(result, 0).observed.id).to eq(first.id)
    expect(identity_of(result, 1).observed.id).to eq(second.id)
    expect(result.outcomes.map { |outcome| outcome.identity.confirmation }).to eq(%i[confirmed confirmed])
  end

  # M -- cleanup survives an exception, and the identity is still observed.
  it "still observes identity and still cleans up when the request raises" do
    result = probe([member], path: "/identity_evidence/boom")
    outcome = result.outcomes.first

    expect(outcome.exception_class).to eq("RuntimeError")
    expect(outcome.identity.confirmation).to eq(:confirmed)
    expect(@cleared).to eq(1)
  end

  # N -- and when it halts/redirects.
  it "still cleans up when the request halts and redirects" do
    probe([Karst::Identity::ANONYMOUS, member], path: "/identity_evidence/admin_document")

    # Once per probe: the anonymous probe runs the application's own clear
    # seam up front, the named one releases its identity afterwards.
    expect(@cleared).to eq(2)
  end

  # Timing: the identity that mattered is the one the gate saw, not the one
  # the request ended with.
  it "reports the identity the application had when the access decision was made" do
    admin
    result = probe([member], path: "/identity_evidence/volatile_document")
    evidence = identity_of(result)

    expect(evidence.observed_at).to eq(:halted_callback)
    expect(evidence.observed.id).to eq(member.id)
    expect(evidence.confirmation).to eq(:confirmed)
    expect(evidence.changed_during_request).to be(true)
  end

  describe "machine evidence" do
    before do
      Karst.config.principals = -> { KarstIdentityEvidencePrincipal.all }
      # Setup readiness (which CLI::Verification checks before any named
      # probe) also covers browser identity; unrelated to what is under test
      # here, but required to reach Access::Search at all.
      Karst.config.assume_browser_identity = ->(_request, _principal) {}
      Karst.config.clear_browser_identity = ->(_request) {}
    end

    after do
      Karst.config.assume_browser_identity = nil
      Karst.config.clear_browser_identity = nil
    end

    it "exposes an anonymous probe, and its runtime confirmation, through the shared evidence document" do
      admin
      document = Karst::CLI::Verification.new(path: "/identity_evidence/admin_document",
                                              identity: "anonymous").evidence

      expect(document[:schema_version]).to eq(2)
      expect(document[:probe]).to eq(identity: "anonymous")
      expect(document[:verified_usable]).to be(false)
      outcome = document[:sample][:outcomes].first
      expect(outcome[:halted_callback]).to eq("authorize_admin")
      expect(outcome[:controller]).to eq("KarstIdentityEvidenceController")
      expect(outcome.dig(:identities, 0, :confirmation)).to eq("confirmed_anonymous")
      expect(outcome.dig(:identities, 0, :requested)).to be_nil
      expect(document[:provenance]).to include(:karst_version, :rails_version, :observed_at)
    end

    it "publishes observed identity, not requested identity, for a verified usable outcome" do
      admin
      document = Karst::CLI::Verification.new(path: "/identity_evidence/admin_document").evidence

      expect(document[:verified_usable]).to be(true)
      expect(document[:verified_identity][:confirmation]).to eq("confirmed")
      expect(document[:verified_identity][:observed]).to eq(model: "KarstIdentityEvidencePrincipal", id: admin.id)
      expect(document).not_to have_key(:verified_principal)
    end

    it "publishes a requested-but-unconfirmed identity as unconfirmed, never as a principal that ran" do
      Karst.config.assume_identity = ->(_session, _principal) {}
      member
      document = Karst::CLI::Verification.new(path: "/identity_evidence/document").evidence
      identity = document[:sample][:outcomes].first[:identities].first

      expect(identity[:requested][:model]).to eq("KarstIdentityEvidencePrincipal")
      expect(identity[:observed]).to be_nil
      expect(identity[:confirmation]).to eq("absent")
    end
  end

  # P -- the pre-existing identity API keeps working exactly as before.
  it "leaves Identity.with's assume/clear contract unchanged" do
    session = ActionDispatch::Integration::Session.new(KarstTestApplication)
    assumed = []
    Karst.config.assume_identity = ->(_session, principal) { assumed << principal }

    Karst::Identity.with(session, member) { assumed << :inside }

    expect(assumed).to eq([member, :inside])
    expect(@cleared).to eq(1)
  end
end
# rubocop:enable Metrics/BlockLength
