# frozen_string_literal: true

require "spec_helper"
require "json"
require "ripper"
require "tmpdir"
require "rack/mock"
require "rack/test"
require "rack/session/cookie"
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
    # Karst::Web::Middleware is normally inserted by Karst::Railtie directly
    # into a booted Rails application's own compiled middleware stack, ahead
    # of that application's real session middleware -- so /karst reads and
    # writes the very same session the rest of the request goes through (see
    # spec/support/devise_application.rb for why that ordering matters).
    # Wrapping it explicitly around KarstTestApplication, as every other
    # example in this file does, leaves no session middleware underneath it
    # at all; that is fine for those examples, but the CSRF round trip below
    # genuinely needs a real, persisted session across two requests, so this
    # one test's own stack adds a plain Rack session in the same position a
    # real host application's session middleware would occupy.
    def stack
      @stack ||= Rack::Session::Cookie.new(Karst::Web::Middleware.new(KarstTestApplication),
                                           secret: "karst-operation-config-test-secret" * 2)
    end

    def analyze
      Rack::MockRequest.new(stack).post(
        "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                  input: "operation=access_sweep&method=GET&path=%2Foperation_reports%2F1"
      )
    end

    def browser
      @browser ||= Rack::Test::Session.new(Rack::MockSession.new(stack)).tap do |session|
        session.header("REMOTE_ADDR", "127.0.0.1")
      end
    end

    def csrf_token(body)
      body[/name="csrf_token" value="([^"]+)"/, 1]
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

    # The full test process loads other spec files' own fixture
    # ActiveRecord models too (PopulationDiscovery walks every one, not just
    # this file's), so counting raw Ripper.sexp calls would count their
    # source parses as well, unrelated to what this example resolves. This
    # counts only parses of source containing our own fixture class, which a
    # duplicate resolution of *this* operation would duplicate.
    def ripper_parses_of_fixture_source
      count = 0
      allow(Ripper).to receive(:sexp).and_wrap_original do |method, source|
        count += 1 if source.include?("KarstOperationPrincipal")
        method.call(source)
      end
      -> { count }
    end

    it "resolves configuration once however many users the page lists" do
      seed(members: 30, admins: 2)
      approve_admins
      parses = ripper_parses_of_fixture_source

      response = analyze

      expect(response.status).to eq(200)
      expect(response.body).to include("32 users tested", "Verified usable user")
      expect(evaluations.size).to eq(1)
      expect(Karst::Access::PopulationApprovals).to have_received(:load).once
      expect(parses.call).to eq(1)
    end

    # The one moment inline_population_candidates actually runs: no usable
    # outcome in the ordinary sample, so /karst goes on to look for unapproved
    # candidate populations to suggest. That extra work must reuse the same
    # approval read and model-source parse already done resolving the
    # snapshot, not repeat them.
    it "still resolves configuration once when the sample finds nothing and candidate populations are rendered" do
      seed(members: 5, admins: 0)
      parses = ripper_parses_of_fixture_source

      response = analyze

      expect(response.status).to eq(200)
      expect(response.body).to include("No verified usable user found", "admins")
      expect(evaluations.size).to eq(1)
      expect(Karst::Access::PopulationApprovals).to have_received(:load).once
      expect(parses.call).to eq(1)
    end

    # Approving a population necessarily resolves configuration twice: once
    # before the write, to validate the submission against what is currently
    # discoverable, and once after, so the render that follows reflects the
    # approval that was just saved -- never the state from before it. Each of
    # those two resolutions is itself one approval-file read and one
    # model-source parse, not several: see #inline_population_approval_result
    # and #call_owned in Karst::Web::Middleware.
    it "reads the approval file and parses model source exactly once per resolution, twice over the approve request" do
      # No admin exists yet, so both the ordinary sample and the submission
      # discovery below validate against a real, currently empty "admins"
      # candidate -- nothing here presupposes the row that makes the
      # retried population usable will show up later.
      seed(members: 5, admins: 0)
      first = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/operation_reports/1")

      allow(Karst::Access::PopulationApprovals).to receive(:load).and_call_original
      parses = ripper_parses_of_fixture_source

      # The admin Karst can only reach through the population it is about to
      # approve -- created only now, after the approval's own validation
      # already ran against an admin-less "admins" scope.
      KarstOperationPrincipal.create!(role: "admin")
      browser.header("Referer", "http://example.org/karst")
      approval = browser.post("/karst", operation: "approve_populations", csrf_token: csrf_token(first.body),
                                        method: "GET", path: "/operation_reports/1",
                                        population: ["default::KarstOperationPrincipal::admins"])
      browser.header("Referer", nil)

      expect(approval.status).to eq(200)
      expect(approval.body).to include("Verified usable user")
      # 3, not 4 or more: 1 for the ordinary sample above, 1 for the
      # approve request's own pre-write validation, and 1 more for the
      # fresh post-write render it triggers -- never a second read within
      # either single resolution.
      expect(Karst::Access::PopulationApprovals).to have_received(:load).exactly(3).times
      # Counted only from the approve request onward (see
      # #ripper_parses_of_fixture_source): 1 for its own pre-write
      # validation, 1 more for the fresh post-write render -- never a
      # second parse within either single resolution.
      expect(parses.call).to eq(2)
    end
  end
end
# rubocop:enable Metrics/BlockLength
