# frozen_string_literal: true

require "spec_helper"
require "json"
require "ripper"
require "tmpdir"
require "rack/mock"
require_relative "../support/test_application"
require "karst/web/middleware"
require "karst/cli/verification"

ActiveRecord::Schema.define do
  create_table :karst_operation_principals, force: true do |table|
    table.string :role, null: false, default: "member"
  end
end

class KarstOperationPrincipal < ActiveRecord::Base
  scope :admins, -> { where(role: "admin") }
end

class KarstOperationFixtureController < ActionController::Base
  before_action :require_admin, only: :show

  def login
    session[:karst_operation_principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:karst_operation_principal_id)
    head :no_content
  end

  def show
    render plain: "report"
  end

  private

  def require_admin
    principal = KarstOperationPrincipal.find_by(id: session[:karst_operation_principal_id])
    head(:forbidden) unless principal&.role == "admin"
  end
end

# Added through the mapper rather than .draw -- see mcp_server_spec.rb.
KarstTestApplication.routes.send(:eval_block, proc {
  post "/karst_operation/login", to: "karst_operation_fixture#login"
  delete "/karst_operation/logout", to: "karst_operation_fixture#logout"
  get "/operation_reports/:id", to: "karst_operation_fixture#show"
})

# One high-level Karst operation -- a karst:verify run (and so an MCP
# verify_access call, which is the same adapter), or one /karst request --
# resolves the effective identity configuration once: one approval-file
# read, one model-source parse, one evaluation of the application's own
# principal source callable. None of that may scale with the number of
# users probed, and none of it may outlive the operation.
# rubocop:disable Metrics/BlockLength
RSpec.describe "operation-scoped configuration resolution" do
  around do |example|
    Dir.mktmpdir("karst-operation-config") do |dir|
      @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
      example.run
    end
  end

  let(:evaluations) { [] }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
    allow(Karst::Access::PopulationApprovals).to receive(:load).and_call_original
    allow(Ripper).to receive(:sexp).and_call_original
    KarstOperationPrincipal.delete_all
    calls = evaluations
    Karst.config.principals = lambda do
      calls << :principals
      KarstOperationPrincipal.all
    end
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/karst_operation/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/karst_operation/logout" }
    Karst.config.observe_identity = lambda do |context|
      KarstOperationPrincipal.find_by(id: context.request.session[:karst_operation_principal_id])
    end
    Karst.config.assume_browser_identity = ->(_request, _principal) {}
    Karst.config.clear_browser_identity = ->(_request) {}
    Karst.config.access_sweep_limit = 50
  end

  def seed(members:, admins:)
    members.times { KarstOperationPrincipal.create!(role: "member") }
    admins.times { KarstOperationPrincipal.create!(role: "admin") }
  end

  def approve_admins
    Karst::Access::PopulationApprovals.replace(
      [Karst::Access::PopulationApprovals::Entry.new(model_name: "KarstOperationPrincipal", method_name: "admins")]
    )
  end

  def verify
    Karst::CLI::Verification.new(path: "/operation_reports/1").evidence
  end

  describe "bin/rails karst:verify (and MCP verify_access)" do
    it "evaluates the principal source callable, reads approvals, and parses model source once per operation" do
      seed(members: 30, admins: 1)
      approve_admins

      document = verify

      expect(document.dig(:sample, :users_tested)).to eq(31)
      expect(evaluations.size).to eq(1)
      expect(Karst::Access::PopulationApprovals).to have_received(:load).once
      expect(Ripper).to have_received(:sexp).once
    end

    it "does the same configuration work for 3 users as for 40" do
      approve_admins
      seed(members: 2, admins: 1)
      verify
      small = evaluations.size

      KarstOperationPrincipal.delete_all
      evaluations.clear
      seed(members: 39, admins: 1)
      verify

      expect([small, evaluations.size]).to eq([1, 1])
    end

    it "lets a later operation see configuration changed after an earlier one" do
      seed(members: 3, admins: 1)
      Karst.config.principals = -> { KarstOperationPrincipal.where(role: "member") }

      first = verify
      approve_admins
      second = verify

      expect(first[:verified_usable]).to be(false)
      expect(first[:populations]).to eq([])
      expect(second[:verified_usable]).to be(true)
      expect(second[:source]).to eq(type: :population, name: :admins)
    end

    it "evaluates a replaced principal source callable in the next operation, not the old one" do
      seed(members: 2, admins: 0)
      verify
      replacement = []
      Karst.config.principals = lambda do
        replacement << :principals
        KarstOperationPrincipal.all
      end

      verify

      expect([evaluations.size, replacement.size]).to eq([1, 1])
    end
  end

  describe "one /karst request" do
    def analyze
      stack = Karst::Web::Middleware.new(KarstTestApplication)
      Rack::MockRequest.new(stack).post(
        "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                  input: "operation=access_sweep&method=GET&path=%2Foperation_reports%2F1"
      )
    end

    # Devise-shaped metadata and no explicit browser hooks: whether Test As
    # is offered is then inferred from the effective principal sources --
    # which used to be re-resolved for every user the page listed.
    before do
      Karst.config.assume_browser_identity = nil
      Karst.config.clear_browser_identity = nil
      stub_const("Warden::Manager", Class.new)
      stub_const("Devise", Module.new)
      mapping = Struct.new(:to, :name)
      allow(Devise).to receive(:mappings).and_return(karst_operation: mapping.new(KarstOperationPrincipal, :user))
    end

    it "resolves configuration once however many users the page lists" do
      seed(members: 30, admins: 2)
      approve_admins

      response = analyze

      expect(response.status).to eq(200)
      expect(response.body).to include("32 users tested", "Verified usable user")
      expect(evaluations.size).to eq(1)
      expect(Karst::Access::PopulationApprovals).to have_received(:load).once
      expect(Ripper).to have_received(:sexp).once
    end
  end
end
# rubocop:enable Metrics/BlockLength
