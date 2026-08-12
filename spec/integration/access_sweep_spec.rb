# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "uri"
require "rack/mock"
require_relative "../support/test_application"
require "karst/web/middleware"
require "karst/cli/verification"

ActiveRecord::Schema.define do
  create_table :karst_access_principals, force: true do |table|
    table.string :behavior, null: false
    table.integer :visits, null: false, default: 0
  end
end

class KarstAccessPrincipal < ActiveRecord::Base
  scope :flagged, -> { where(behavior: "forbidden") }
  scope :working, -> { where(behavior: "ok") }
end

# A second, distinct Ruby class Devise could map -- deliberately backed by
# the same table as KarstAccessPrincipal (no new migration needed) since
# only the class identity, never any data of its own, matters to the
# selection tests below.
class KarstAccessSecondaryPrincipal < ActiveRecord::Base
  self.table_name = "karst_access_principals"
end

class KarstAccessFixtureController < ActionController::Base
  class << self
    attr_accessor :request_hosts
  end
  self.request_hosts = []

  before_action :mark_controller_execution, only: :document
  before_action :halt_for_access_behavior, only: :document
  before_action { self.class.request_hosts << request.host }

  def login
    session[:karst_principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:karst_principal_id)
    head :no_content
  end

  def document
    principal = KarstAccessPrincipal.find_by(id: session[:karst_principal_id])
    return head(:unauthorized) unless principal

    raise "fixture detail must not escape" if principal.behavior == "raise"

    render plain: "#{session[:before_action]}:#{principal.behavior}"
  end

  private

  def mark_controller_execution
    session[:before_action] = "before_action_ran"
    principal = KarstAccessPrincipal.find_by(id: session[:karst_principal_id])
    principal&.update!(visits: principal.visits + 1) if params[:id] == "write"
  end

  def halt_for_access_behavior
    behavior = KarstAccessPrincipal.find_by(id: session[:karst_principal_id])&.behavior
    return redirect_to("/login?secret=hidden") if behavior == "redirect"

    head(:forbidden) if behavior == "forbidden"
  end
end

KarstTestApplication.routes.draw do
  post "/karst_access/login", to: "karst_access_fixture#login"
  delete "/karst_access/logout", to: "karst_access_fixture#logout"
  get "/documents/:id/edit", to: "karst_access_fixture#document"
end

# rubocop:disable Metrics/BlockLength
RSpec.describe "bounded access sweep Rails integration" do
  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstAccessPrincipal.delete_all
    %w[ok redirect forbidden raise].each { |behavior| KarstAccessPrincipal.create!(behavior: behavior) }
    KarstAccessFixtureController.request_hosts = []
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/karst_access/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/karst_access/logout" }
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
  end

  # config.enabled must gate every adapter that ultimately runs a real
  # Access::Sweep, not only the /karst middleware -- see
  # spec/integration/web_middleware_spec.rb for the panel/badge side of this
  # same contract.
  describe "config.enabled" do
    before do
      KarstAccessPrincipal.create!(behavior: "ok")
      Karst.config.principals = -> { KarstAccessPrincipal.all }
      # Probe hooks alone leave setup_state :unavailable (browser identity is
      # also required for a "ready" status) -- that is a real, independent
      # setup requirement CLI::Verification checks before it ever reaches
      # Access::Sweep. Configuring both here isolates config.enabled as the
      # one thing under test, rather than conflating it with setup readiness.
      Karst.config.assume_browser_identity = ->(_request, _principal) {}
      Karst.config.clear_browser_identity = ->(_request) {}
      Karst.config.enabled = false
    end

    after do
      Karst.config.principals = nil
      Karst.config.assume_browser_identity = nil
      Karst.config.clear_browser_identity = nil
    end

    it "refuses a direct Access::Sweep run" do
      expect do
        Karst::Access::Sweep.new(path: "/documents/read/edit", principals: KarstAccessPrincipal.all,
                                 application: KarstTestApplication).call
      end
        .to raise_error(Karst::Access::Unavailable, /disabled/)
    end

    it "reports a setup error, exit code 2, from bin/rails karst:verify" do
      output = StringIO.new

      code = Karst::CLI::Verification.new(path: "/documents/read/edit", output: output).call

      expect(code).to eq(2)
      expect(output.string).to include("disabled")
    end

    it "reports a structured error, never a crash, from the shared --json/MCP evidence document" do
      document = Karst::CLI::Verification.new(path: "/documents/read/edit").evidence

      expect(document[:error][:message]).to match(/disabled/)
    end
  end

  it "observes exact resource outcomes with fresh sessions and rolls back database writes" do
    principals = KarstAccessPrincipal.order(:id)
    result = Karst::Access::Sweep.new(path: "/documents/write/edit?token=discarded",
                                      principals: principals, application: KarstTestApplication).call

    expect(result.path).to eq("/documents/write/edit")
    expect(result.outcomes.map(&:status)).to eq([200, 302, 403, nil])
    expect(result.outcomes[1].redirect).to eq("http://karst-probe.example/login")
    expect(result.outcomes[3].exception_class).to eq("RuntimeError")
    expect(result.outcomes.map(&:halted_callback)).to eq([nil, :halt_for_access_behavior,
                                                          :halt_for_access_behavior, nil])
    expect(result.outcomes.map(&:writes_observed)).to all(be(true))
    expect(KarstAccessPrincipal.order(:id).pluck(:visits)).to eq([0, 0, 0, 0])
  end

  it "feeds PrincipalSampler's representative candidates into Sweep, surfacing a minority state first-N misses" do
    KarstAccessPrincipal.delete_all
    30.times { KarstAccessPrincipal.create!(behavior: "ok") }
    minority = KarstAccessPrincipal.create!(behavior: "forbidden")

    naive_first_25_ids = KarstAccessPrincipal.order(:id).limit(25).pluck(:id)
    expect(naive_first_25_ids).not_to include(minority.id)

    expect(Karst::Access::PrincipalSampler.representative_capable?(KarstAccessPrincipal.all)).to be(true)
    expect(Karst::Access::PrincipalSampler.representative_capable?([1, 2, 3])).to be(false)

    sampled = Karst::Access::PrincipalSampler.new(source: KarstAccessPrincipal.all, limit: 25).call
    expect(sampled.strategy).to eq(:representative)
    expect(sampled.principals.map(&:id)).to include(minority.id)

    result = Karst::Access::Sweep.new(path: "/documents/read/edit", principals: sampled.principals,
                                      application: KarstTestApplication).call

    expect(result.outcomes.map(&:status)).to include(403)
  end

  it "bounds representative sampling to a recent candidate pool and reports it truthfully, without losing " \
     "resolution of an older allowed principal" do
    KarstAccessPrincipal.delete_all
    total = 600
    pool_size = 50
    Karst.config.principal_candidate_pool_size = pool_size
    Karst.config.principals = -> { KarstAccessPrincipal.all }

    old_principal = KarstAccessPrincipal.create!(behavior: "ok")
    (total - 1).times { KarstAccessPrincipal.create!(behavior: "ok") }
    recent_minority = KarstAccessPrincipal.create!(behavior: "forbidden")

    # No created_at column exists on this fixture, so the pool falls back to
    # primary-key descending order -- the most-recently-inserted (highest
    # id) rows, which is exactly where recent_minority lands.
    expected_pool_ids = KarstAccessPrincipal.order(id: :desc).limit(pool_size).pluck(:id)
    expect(expected_pool_ids).not_to include(old_principal.id)

    sampled = Karst::Access::PrincipalSampler.new(source: KarstAccessPrincipal.all, limit: 25).call
    expect(sampled.candidate_pool_size).to eq(pool_size)
    expect(sampled.principals.map(&:id) - expected_pool_ids).to be_empty
    expect(sampled.principals.map(&:id)).to include(recent_minority.id)

    result = Karst::Access::Sweep.new(path: "/documents/read/edit", principals: sampled.principals,
                                      candidate_pool_size: sampled.candidate_pool_size,
                                      application: KarstTestApplication).call
    expect(result.candidate_pool_size).to eq(pool_size)

    # config.principals remains the complete allowed universe: an old
    # principal outside the sampling pool is still resolvable.
    expect(Karst::Identity.resolve(model_name: "KarstAccessPrincipal", id: old_principal.id)).to eq(old_principal)
  ensure
    Karst.config.principal_candidate_pool_size = 1_000
    Karst.config.principals = nil
  end

  it "reaches a population's user that falls outside the recent candidate pool, end-to-end through Search" do
    KarstAccessPrincipal.delete_all
    # Created first, so it is the oldest row and cannot appear in a pool of
    # the 20 most recent -- exactly the case generic sampling cannot reach.
    outside_pool = KarstAccessPrincipal.create!(behavior: "ok")
    300.times { KarstAccessPrincipal.create!(behavior: "forbidden") }
    Karst.config.principal_candidate_pool_size = 20
    Karst.config.access_sweep_limit = 3
    Karst.config.principals = -> { KarstAccessPrincipal.all }
    Karst.config.principal_populations = { working: -> { KarstAccessPrincipal.where(behavior: "ok") } }

    result = Karst::Access::Search.new(path: "/documents/read/edit", sources: Karst::Identity.principal_sources,
                                       application: KarstTestApplication).call

    # Stage one: only recent users, none usable, and never the population's.
    expect(result.initial.outcomes.map(&:status).uniq).to eq([403])
    expect(result.initial.outcomes.map { |outcome| outcome.principal.id }).not_to include(outside_pool.id)

    # Stage two: the configured population queries the full relation.
    attempt = result.attempts.first
    expect(attempt.state).to eq(:usable)
    expect(attempt.result.outcomes.map { |outcome| outcome.principal.id }).to eq([outside_pool.id])
    expect(attempt.result.outcomes.flat_map(&:sampling_reasons)).to eq(["population=working"])

    # config.principals remains the complete allowed universe.
    expect(Karst::Identity.resolve(model_name: "KarstAccessPrincipal", id: outside_pool.id)).to eq(outside_pool)
  ensure
    Karst.config.principal_candidate_pool_size = 1_000
    Karst.config.access_sweep_limit = 25
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "serves the /karst/populations discovery page and finds a real, already-loaded application model" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst/populations", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(response.body).to include("Candidate groups", "Available models", "KarstAccessPrincipal")
    expect(response.body).to include("flagged") # the scope defined on KarstAccessPrincipal above
  end

  it "falls through to the host application for a nonlocal request to /karst/populations" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst/populations", "REMOTE_ADDR" => "192.168.1.10")

    expect(response.body).not_to include("Candidate groups", "Available models")
  end

  it "does not promote population configuration from the main access analysis section" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst?method=GET&path=%2Fdocuments%2Fread%2Fedit", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.body).not_to include('href="/karst/populations"')
  end

  def access_sweep_response
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    Rack::MockRequest.new(stack).post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=access_sweep&method=GET&path=%2Fdocuments%2Fread%2Fedit"
    )
  end

  it "automatically retries an approved population once the ordinary sample finds no usable user" do
    KarstAccessPrincipal.delete_all
    5.times { KarstAccessPrincipal.create!(behavior: "forbidden") }
    usable = KarstAccessPrincipal.create!(behavior: "ok")
    Karst.config.access_sweep_limit = 3
    Karst.config.principals = -> { KarstAccessPrincipal.where(behavior: "forbidden") }
    Karst.config.principal_populations = { working: -> { KarstAccessPrincipal.where(behavior: "ok") } }

    response = access_sweep_response

    expect(response.status).to eq(200)
    expect(response.body).to include("Ordinary sample", "3 users tested",
                                     "halted at halt_for_access_behavior")
    expect(response.body).to include("Candidate populations", "working",
                                     "KarstAccessPrincipal ##{usable.id} → 200 OK ✓")
    expect(response.body).to include("<h2>Verified usable user</h2>")
  ensure
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "retains grouped observed evidence from every population when none of them succeeds" do
    KarstAccessPrincipal.delete_all
    3.times { KarstAccessPrincipal.create!(behavior: "forbidden") }
    KarstAccessPrincipal.create!(behavior: "redirect")
    Karst.config.access_sweep_limit = 2
    Karst.config.principals = -> { KarstAccessPrincipal.where(behavior: "forbidden") }
    Karst.config.principal_populations = { redirected: -> { KarstAccessPrincipal.where(behavior: "redirect") },
                                           missing: -> { KarstAccessPrincipal.where(behavior: "nobody") } }

    response = access_sweep_response

    expect(response.status).to eq(200)
    expect(response.body).to include("<h2>No verified usable user found</h2>")
    expect(response.body).to include("redirected", "1 user tested<br>none verified usable")
    expect(response.body).to include("missing", "no matching records")
  ensure
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "never evaluates any population when the ordinary sample already found a usable user" do
    KarstAccessPrincipal.delete_all
    KarstAccessPrincipal.create!(behavior: "ok")
    flagged = KarstAccessPrincipal.create!(behavior: "forbidden")
    Karst.config.principals = -> { KarstAccessPrincipal.where(behavior: "ok") }
    Karst.config.principal_populations = { flagged: -> { KarstAccessPrincipal.flagged } }

    response = access_sweep_response

    expect(response.status).to eq(200)
    expect(response.body).to include("<h2>Verified usable user</h2>")
    expect(response.body).not_to include("Candidate populations", "KarstAccessPrincipal ##{flagged.id}")
  ensure
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "never automatically executes a discoverable scope that was never configured as a population" do
    KarstAccessPrincipal.delete_all
    2.times { KarstAccessPrincipal.create!(behavior: "forbidden") }
    KarstAccessPrincipal.create!(behavior: "ok")
    Karst.config.access_sweep_limit = 2
    Karst.config.principals = -> { KarstAccessPrincipal.where(behavior: "forbidden") }

    response = access_sweep_response

    # KarstAccessPrincipal.flagged is discoverable at /karst/populations, and
    # a usable "ok" record exists, but nothing unconfigured is ever run.
    expect(response.status).to eq(200)
    expect(response.body).to include("<h2>No verified usable user found</h2>")
    expect(response.body).not_to include("Candidate populations")
  ensure
    Karst.config.principals = nil
  end

  it "bypasses non-reentrant host middleware at the route dispatch boundary" do
    principal = KarstAccessPrincipal.find_by!(behavior: "ok")
    calls_before = KarstNonReentrantMiddleware.calls

    nested = ActionDispatch::Integration::Session.new(KarstTestApplication)
    nested.host!("karst-probe.example")
    begin
      Thread.current[:karst_host_middleware_active] = true
      nested.get("/documents/read/edit")
    ensure
      Thread.current[:karst_host_middleware_active] = false
    end
    expect(nested.response).to have_attributes(status: 500)

    result = Karst::Access::Sweep.new(path: "/documents/read/edit", principals: [principal],
                                      application: KarstTestApplication).call

    expect(result.outcomes.first).to have_attributes(status: 200, exception_class: nil)
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before)

    probe = ActionDispatch::Integration::Session.new(Karst::Access::ProbeApplication.for(KarstTestApplication))
    probe.post("/karst_access/login", params: { id: principal.id })
    probe.get("/documents/read/edit")
    expect(probe.response.body).to eq("before_action_ran:ok")
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before)

    browser = ActionDispatch::Integration::Session.new(KarstTestApplication)
    browser.host!("karst-probe.example")
    browser.get("/documents/read/edit")
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before + 1)
  end

  it "uses an authorized host and executes custom login and logout through the minimal stack" do
    principal = KarstAccessPrincipal.find_by!(behavior: "ok")
    calls_before = KarstNonReentrantMiddleware.calls

    blocked_browser = ActionDispatch::Integration::Session.new(KarstTestApplication)
    blocked_browser.host!("attacker.example")
    blocked_browser.get("/documents/read/edit")
    expect(blocked_browser.response.status).to eq(403)

    result = Karst::Access::Sweep.new(path: "/documents/read/edit", principals: [principal],
                                      application: KarstTestApplication).call

    expect(result.outcomes.first).to have_attributes(status: 200, exception_class: nil)
    expect(KarstAccessFixtureController.request_hosts).to eq(Array.new(3, "karst-probe.example"))
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before)

    probe = Karst::Access::ProbeApplication.for(KarstTestApplication)
    session = ActionDispatch::Integration::Session.new(probe)
    session.host!("karst-probe.example")
    Karst::Identity.with(session, principal) do
      session.get("/documents/read/edit")
      expect(session.response.status).to eq(200)
    end
    session.get("/documents/read/edit")
    expect(session.response.status).to eq(401)
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before)
  end

  # The whole point of the local approval workflow: a developer who has
  # edited no Ruby configuration at all goes from "no verified usable user"
  # to an automatically searched candidate population, entirely through
  # /karst.
  describe "approving a discovered candidate group at /karst/populations" do
    let(:origin) { "http://example.org" }

    around do |example|
      Dir.mktmpdir("karst-approval-integration") do |dir|
        @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
        example.run
      end
    end

    before do
      allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
      KarstAccessPrincipal.delete_all
      3.times { KarstAccessPrincipal.create!(behavior: "forbidden") }
      Karst.config.access_sweep_limit = 3
      Karst.config.principals = -> { KarstAccessPrincipal.where(behavior: "forbidden") }
    end

    after do
      Karst.config.principals = nil
      Karst.config.access_sweep_limit = 25
    end

    def populations_post(input, origin_header: origin)
      stack = Karst::Web::Middleware.new(KarstTestApplication)
      env = { "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
              input: input }
      env["HTTP_ORIGIN"] = origin_header if origin_header
      Rack::MockRequest.new(stack).post("/karst/populations", **env)
    end

    def approve_working
      populations_post("save_approvals=1&population[]=KarstAccessPrincipal::working")
    end

    it "persists an approval as data a developer can read, without touching any initializer" do
      response = approve_working

      expect(response.status).to eq(200)
      expect(response.body).to include("Approvals saved.", "Approved (1)")
      expect(JSON.parse(File.read(@approvals_path)))
        .to eq("version" => 1,
               "approved" => [{ "model" => "KarstAccessPrincipal", "scope" => "working" }])
      expect(Karst.config.principal_populations).to eq({})
    end

    it "searches the approved group automatically on the next analysis, with no Ruby configured" do
      usable = KarstAccessPrincipal.create!(behavior: "ok")
      approve_working

      response = access_sweep_response

      expect(response.body).to include("Candidate populations", "working",
                                       "KarstAccessPrincipal ##{usable.id} → 200 OK ✓")
      expect(response.body).to include("<h2>Verified usable user</h2>")
    end

    it "never executes a discovered group that has not been approved" do
      KarstAccessPrincipal.create!(behavior: "ok")

      response = access_sweep_response

      expect(response.body).to include("<h2>No verified usable user found</h2>")
      expect(response.body).not_to include("Candidate populations")
    end

    it "offers inline approval only once an analysis found nothing usable" do
      KarstAccessPrincipal.create!(behavior: "ok")

      expect(access_sweep_response.body)
        .to include("application-defined user groups for this principal source", "working",
                    "Approve selected and retry")
      expect(access_sweep_response.body).not_to include('href="/karst/populations"')
    end

    it "stops searching a group as soon as it is unapproved" do
      usable = KarstAccessPrincipal.create!(behavior: "ok")
      approve_working
      expect(access_sweep_response.body).to include("KarstAccessPrincipal ##{usable.id} → 200 OK ✓")

      populations_post("save_approvals=1")

      expect(JSON.parse(File.read(@approvals_path))["approved"]).to eq([])
      expect(access_sweep_response.body).to include("<h2>No verified usable user found</h2>")
      expect(access_sweep_response.body).not_to include("Candidate populations")
    end

    it "keeps every retry bound intact for an approved group" do
      6.times { KarstAccessPrincipal.create!(behavior: "ok") }
      Karst.config.population_retry_limit = 2
      approve_working

      response = access_sweep_response

      # 3 sampled (access_sweep_limit) + exactly population_retry_limit
      # probed from the approved group, out of the 6 rows it matches.
      expect(response.body).to include("3 initial · 2 candidate population · 5 total")
    ensure
      Karst.config.population_retry_limit = 3
    end

    it "refuses an approval submitted from another origin" do
      response = populations_post("save_approvals=1&population[]=KarstAccessPrincipal::working",
                                  origin_header: "http://attacker.example")

      expect(response.status).to eq(403)
      expect(File.exist?(@approvals_path)).to be(false)
    end

    it "approves nothing that current discovery does not itself list" do
      populations_post("save_approvals=1&population[]=KarstAccessPrincipal::destroy_all")

      expect(JSON.parse(File.read(@approvals_path))["approved"]).to eq([])
    end

    it "reports an approval whose scope no longer exists instead of executing anything" do
      Karst::Access::PopulationApprovals.replace(
        [Karst::Access::PopulationApprovals::Entry.new(model_name: "KarstAccessPrincipal",
                                                       method_name: "removed_scope")]
      )
      KarstAccessPrincipal.create!(behavior: "ok")

      page = Rack::MockRequest.new(Karst::Web::Middleware.new(KarstTestApplication))
                              .get("/karst/populations", "REMOTE_ADDR" => "127.0.0.1")

      expect(page.body).to include("removed_scope", "no longer a discovered scope on this model — not used")
      expect(access_sweep_response.body).not_to include("Candidate populations")
    end
  end

  # The same "developer never edits Ruby" workflow as approving a candidate
  # population, one refusal boundary earlier: several Devise models detected
  # and nothing explicit configured. Selecting which to test happens right
  # at /karst, with no initializer required.
  describe "resolving an ambiguous Devise setup at /karst" do
    let(:origin) { "http://example.org" }

    around do |example|
      Dir.mktmpdir("karst-principal-selection-integration") do |dir|
        @selection_path = File.join(dir, "tmp/karst/principal_source_selection.json")
        example.run
      end
    end

    before do
      allow(Karst::Access::PrincipalSourceSelection).to receive(:path).and_return(@selection_path)
      stub_const("Devise", Module.new)
      mapping = Struct.new(:to, :name)
      allow(Devise).to receive(:mappings).and_return(
        member: mapping.new(KarstAccessPrincipal, :member),
        admin: mapping.new(KarstAccessSecondaryPrincipal, :admin)
      )
      stub_const("Warden::Manager", Class.new)
    end

    after { Karst.config.principal_sources = nil }

    def select_post(fields, origin_header: origin)
      stack = Karst::Web::Middleware.new(KarstTestApplication)
      pairs = [%w[operation select_principal_sources], *fields.map { |name| ["principal[]", name] }]
      input = URI.encode_www_form(pairs)
      env = { "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: input }
      env["HTTP_ORIGIN"] = origin_header if origin_header
      Rack::MockRequest.new(stack).post("/karst?method=GET&path=%2Fdocuments", **env)
    end

    def karst_page
      Rack::MockRequest.new(Karst::Web::Middleware.new(KarstTestApplication))
                       .get("/karst?method=GET&path=%2Fdocuments", "REMOTE_ADDR" => "127.0.0.1")
    end

    def selected_names
      JSON.parse(File.read(@selection_path))["selected"]
    end

    it "offers every Devise-detected model as a checkbox, with none preselected until saved" do
      page = karst_page

      expect(page.body).to include("Karst found 2 user types", "KarstAccessPrincipal", "KarstAccessSecondaryPrincipal")
      expect(page.body).not_to include(" checked")
    end

    it "selects only one of several Devise-detected models" do
      response = select_post(["KarstAccessPrincipal"])

      expect(response.status).to eq(200)
      expect(response.body).to include("Selection saved.")
      expect(selected_names).to eq(["KarstAccessPrincipal"])
      expect(Karst.config.principal_sources.keys).to eq([:member])
    end

    it "selects only the other of several Devise-detected models" do
      select_post(["KarstAccessSecondaryPrincipal"])

      expect(selected_names).to eq(["KarstAccessSecondaryPrincipal"])
      expect(Karst.config.principal_sources.keys).to eq([:admin])
    end

    it "selects both models, keeping each as its own independently queryable source" do
      select_post(%w[KarstAccessPrincipal KarstAccessSecondaryPrincipal])

      expect(selected_names).to contain_exactly("KarstAccessPrincipal", "KarstAccessSecondaryPrincipal")
      sources = Karst.config.principal_sources
      expect(sources.keys).to contain_exactly(:member, :admin)
      expect(sources[:member].record_klass).to eq(KarstAccessPrincipal)
      expect(sources[:admin].record_klass).to eq(KarstAccessSecondaryPrincipal)
    end

    it "never persists a submitted name Devise itself does not currently map" do
      select_post(["KarstAccessPrincipal", "System::Admin"])

      expect(selected_names).to eq(["KarstAccessPrincipal"])
    end

    it "refuses a selection submitted from another origin, without writing anything" do
      response = select_post(["KarstAccessPrincipal"], origin_header: "http://attacker.example")

      expect(response.status).to eq(403)
      expect(File.exist?(@selection_path)).to be(false)
    end

    it "falls back to ambiguous again once a selected mapping is no longer reported by Devise" do
      select_post(%w[KarstAccessPrincipal KarstAccessSecondaryPrincipal])
      expect(Karst.config.principal_sources.keys).to contain_exactly(:member, :admin)

      allow(Devise).to receive(:mappings).and_return({})

      expect(Karst.config.principal_sources).to be_nil
      expect(Karst::Identity.setup_state.status).to eq(:unavailable)
      expect(karst_page.body).to include("couldn't determine how this app authenticates")
    end

    it "keeps an explicit config.principal_sources ahead of a saved local selection" do
      select_post(["KarstAccessPrincipal"])

      Karst.config.principal_sources = { explicit: -> { KarstAccessSecondaryPrincipal.all } }

      expect(Karst.config.principal_sources.keys).to eq([:explicit])
    end
  end
end
# rubocop:enable Metrics/BlockLength
