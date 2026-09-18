# frozen_string_literal: true

require "spec_helper"
require "active_support/notifications"
require_relative "../support/test_application"
require "karst/reproduction/exercise"
require "karst/cli/reproduction"

ActiveRecord::Schema.define do
  create_table :karst_reproduction_identity_principals, force: true do |table|
    table.string :role, null: false, default: "member"
  end
end

class KarstReproductionIdentityPrincipal < ActiveRecord::Base; end

# A conventional custom-authentication controller, exactly like the one
# spec/integration/identity_evidence_spec.rb uses for Access::Sweep: one
# before_action resolves the principal from the session, a later one makes
# the access decision. Nothing here knows Karst exists.
class KarstReproductionIdentityController < ActionController::Base
  before_action :set_current_principal
  before_action :authorize_admin, only: :admin_document

  # Public so config.observe_identity can read what the application itself
  # resolved.
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

  def boom
    raise "fixture exploded"
  end

  private

  def set_current_principal
    @current_principal = KarstReproductionIdentityPrincipal.find_by(id: session[:principal_id])
  end

  def authorize_admin
    return head(:unauthorized) if @current_principal.nil?

    head(:forbidden) unless @current_principal.role == "admin"
  end
end

# Added directly through the mapper, not .draw, for the reason
# mcp_server_spec.rb documents at length: .draw clears the whole route set
# first, so a second spec file drawing on the one shared KarstTestApplication
# silently deletes the first file's routes.
KarstTestApplication.routes.send(:eval_block, proc {
  post "/reproduction_identity/login", to: "karst_reproduction_identity#login"
  delete "/reproduction_identity/logout", to: "karst_reproduction_identity#logout"
  get "/reproduction_identity/document", to: "karst_reproduction_identity#document"
  get "/reproduction_identity/admin_document", to: "karst_reproduction_identity#admin_document"
  get "/reproduction_identity/boom", to: "karst_reproduction_identity#boom"
})

# Reproduction::Exercise adopts the exact identity lifecycle
# Access::IdentityProbe/Identity::Evidence gives Access::Sweep (see PR #73);
# these are the same confirmation scenarios spec/integration/
# identity_evidence_spec.rb exercises for Sweep, run instead through one
# reproduced request.
# rubocop:disable Metrics/BlockLength
RSpec.describe "request reproduction identity evidence" do
  let(:member) { KarstReproductionIdentityPrincipal.create!(role: "member") }
  let(:admin) { KarstReproductionIdentityPrincipal.create!(role: "admin") }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstReproductionIdentityPrincipal.delete_all
    @cleared = 0
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/reproduction_identity/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = lambda do |session|
      @cleared += 1
      session.delete "/reproduction_identity/logout"
    end
    # The application's own runtime principal, read off the controller that
    # actually processed the request -- exactly the seam identity_evidence_spec
    # uses for Access::Sweep.
    Karst.config.observe_identity = ->(context) { context.controller&.current_principal }
  end

  after do
    %i[assume_identity clear_identity observe_identity principals].each do |hook|
      Karst.config.public_send("#{hook}=", nil)
    end
  end

  def exercise(path:, principal: Karst::Identity::ANONYMOUS)
    Karst::Reproduction::Exercise.new(path: path, principal: principal, application: KarstTestApplication).call
  end

  it "confirms a named identity the application actually resolved" do
    observation = exercise(path: "/reproduction_identity/document", principal: member)
    evidence = observation.identity

    expect(evidence.requested.id).to eq(member.id)
    expect(evidence.observed.id).to eq(member.id)
    expect(evidence.confirmation).to eq(:confirmed)
  end

  it "reports absent when Karst's identity setup did not take" do
    Karst.config.assume_identity = ->(_session, _principal) {} # establishes nothing
    observation = exercise(path: "/reproduction_identity/document", principal: member)
    evidence = observation.identity

    expect(evidence.requested.id).to eq(member.id)
    expect(evidence.observed).to be_nil
    expect(evidence.confirmation).to eq(:absent)
  end

  it "reports a mismatch when the application resolved a different principal than requested" do
    impostor = admin
    Karst.config.assume_identity = lambda do |session, _principal|
      session.post "/reproduction_identity/login", params: { id: impostor.id }
    end
    observation = exercise(path: "/reproduction_identity/document", principal: member)
    evidence = observation.identity

    expect(evidence.requested.id).to eq(member.id)
    expect(evidence.observed.id).to eq(impostor.id)
    expect(evidence.confirmation).to eq(:mismatch)
  end

  it "confirms a genuinely anonymous probe -- not merely one Karst assumed nothing for" do
    member
    observation = exercise(path: "/reproduction_identity/document")
    evidence = observation.identity

    expect(evidence.requested).to be_nil
    expect(evidence.observed).to be_nil
    expect(evidence.confirmation).to eq(:confirmed_anonymous)
    expect(evidence.establishment).to eq(:cleared)
  end

  it "reports a stale principal surviving an anonymous probe as contaminated, never as anonymous" do
    stale = member
    Karst.config.observe_identity = ->(_context) { stale }
    observation = exercise(path: "/reproduction_identity/document")
    evidence = observation.identity

    expect(evidence.requested).to be_nil
    expect(evidence.observed.id).to eq(stale.id)
    expect(evidence.confirmation).to eq(:contaminated)
    expect(evidence.confirmed?).to be(false)
  end

  it "reports unobservable, never the requested identity, when no observation seam is configured" do
    Karst.config.observe_identity = nil
    observation = exercise(path: "/reproduction_identity/document", principal: member)
    evidence = observation.identity

    expect(evidence.confirmation).to eq(:unobservable)
    expect(evidence.confirmed?).to be(false)
    expect(evidence.observation_error).to be_a(String)
  end

  it "captures identity at the halted callback, preferring halt-time evidence for the reported identity" do
    observation = exercise(path: "/reproduction_identity/admin_document", principal: member)

    expect(observation.halted_callback).to eq("authorize_admin")
    expect(observation.identity.observed_at).to eq(:halted_callback)
    expect(observation.identity.confirmation).to eq(:confirmed)
    expect(observation.identity.observed.id).to eq(member.id)
  end

  it "still observes identity and still cleans up when the request raises" do
    observation = exercise(path: "/reproduction_identity/boom", principal: member)

    expect(observation.exception_class).to eq("RuntimeError")
    expect(observation.identity.confirmation).to eq(:confirmed)
    expect(@cleared).to eq(1)
  end

  it "still cleans up when the request halts" do
    exercise(path: "/reproduction_identity/admin_document", principal: member)

    expect(@cleared).to eq(1)
  end

  # sql.active_record, halted_callback.action_controller, and
  # process_action.action_controller notifications are process-wide;
  # without a thread guard, a concurrent request in a real development
  # server would contaminate this reproduction's own write count, halted
  # callback, and identity evidence.
  it "ignores sql.active_record and halted_callback.action_controller notifications from another thread" do
    stop = false
    intruder = Thread.new do
      until stop
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "INSERT INTO nowhere VALUES (1)")
        ActiveSupport::Notifications.instrument("halted_callback.action_controller", filter: :intruder_filter)
      end
    end

    observation = exercise(path: "/reproduction_identity/document", principal: member)
    stop = true
    intruder.join

    expect(observation.write_count).to eq(0)
    expect(observation.halted_callback).to be_nil
    expect(observation.identity.confirmation).to eq(:confirmed)
    expect(observation.identity.observed.id).to eq(member.id)
  end

  describe "the shared evidence document never presents requested identity as observed" do
    it "keeps requested and observed distinct in JSON when the application resolved a different principal" do
      impostor = admin
      Karst.config.assume_identity = lambda do |session, _principal|
        session.post "/reproduction_identity/login", params: { id: impostor.id }
      end
      Karst.config.principals = -> { KarstReproductionIdentityPrincipal.where(id: member.id) }

      document = Karst::CLI::Reproduction.new(path: "/reproduction_identity/document").evidence
      label = "KarstReproductionIdentityPrincipal ##{member.id}"

      expect(document[:identity][:requested]).to eq(model: "KarstReproductionIdentityPrincipal", id: member.id,
                                                    label: label)
      expect(document[:identity][:observed]).to eq(model: "KarstReproductionIdentityPrincipal", id: impostor.id)
      expect(document[:identity][:confirmation]).to eq("mismatch")
    end

    it "never labels an absent identity as though the requested user ran" do
      Karst.config.assume_identity = ->(_session, _principal) {}
      Karst.config.principals = -> { KarstReproductionIdentityPrincipal.where(id: member.id) }

      document = Karst::CLI::Reproduction.new(path: "/reproduction_identity/document").evidence

      expect(document[:identity][:requested]).not_to be_nil
      expect(document[:identity][:observed]).to be_nil
      expect(document[:identity][:confirmation]).to eq("absent")
      expect(JSON.generate(document)).not_to match(/"confirmation":"confirmed"/)
    end

    it "exposes the same requested/observed/confirmation contract through the MCP reproduce_request tool" do
      require "karst/mcp/reproduce_request_tool"
      Karst.config.principals = -> { KarstReproductionIdentityPrincipal.where(id: member.id) }

      response = Karst::Mcp::ReproduceRequestTool.call(path: "/reproduction_identity/document")
      document = JSON.parse(response.content.first[:text], symbolize_names: true)

      expect(document[:identity]).to include(:requested, :observed, :confirmation)
      expect(document[:identity][:confirmation]).to eq("confirmed")
      expect(document[:identity][:observed][:id]).to eq(member.id)
    end
  end
end
# rubocop:enable Metrics/BlockLength
