# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../support/test_application"
require "karst/web/middleware"

ActiveRecord::Schema.define do
  create_table :karst_access_principals, force: true do |table|
    table.string :behavior, null: false
    table.integer :visits, null: false, default: 0
  end
end

class KarstAccessPrincipal < ActiveRecord::Base
  scope :flagged, -> { where(behavior: "forbidden") }
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

  it "honors config.principal_populations end-to-end (via config.principal_sources), surfacing a minority " \
     "population's principal past a dominant population outside the recent candidate pool, within the same " \
     "global sweep limit" do
    KarstAccessPrincipal.delete_all
    minority = KarstAccessPrincipal.create!(behavior: "forbidden")
    300.times { KarstAccessPrincipal.create!(behavior: "ok") }
    Karst.config.principal_candidate_pool_size = 20
    Karst.config.principals = -> { KarstAccessPrincipal.all }
    Karst.config.principal_populations = { flagged: -> { KarstAccessPrincipal.flagged } }

    sampled = Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 25).call
    expect(sampled.principals.size).to be <= 25
    expect(sampled.principals.map(&:id)).to include(minority.id)
    expect(sampled.populations.map(&:name)).to eq([:flagged])
    expect(sampled.candidates.find { |c| c.principal.id == minority.id }.reasons).to include("population=flagged")

    result = Karst::Access::Sweep.new(path: "/documents/read/edit", principals: sampled.principals,
                                      application: KarstTestApplication).call

    expect(result.outcomes.map(&:status)).to include(403)
  ensure
    Karst.config.principal_candidate_pool_size = 1_000
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "serves the /karst/populations discovery page and finds a real, already-loaded application model" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst/populations", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(response.body).to include("Candidate scopes", "Available models", "KarstAccessPrincipal")
    expect(response.body).to include("flagged") # the scope defined on KarstAccessPrincipal above
  end

  it "falls through to the host application for a nonlocal request to /karst/populations" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst/populations", "REMOTE_ADDR" => "192.168.1.10")

    expect(response.body).not_to include("Candidate scopes", "Available models")
  end

  it "does not promote population configuration from the main access analysis section" do
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.get("/karst?method=GET&path=%2Fdocuments%2Fread%2Fedit", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.body).not_to include('href="/karst/populations"')
  end

  it "runs a guided population_sweep bounded to exactly one approved population, respecting access_sweep_limit" do
    KarstAccessPrincipal.delete_all
    200.times { KarstAccessPrincipal.create!(behavior: "ok") }
    minority = KarstAccessPrincipal.create!(behavior: "forbidden")
    Karst.config.principals = -> { KarstAccessPrincipal.all }
    Karst.config.principal_populations = { flagged: -> { KarstAccessPrincipal.flagged } }
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=population_sweep&population=flagged&method=GET&path=%2Fdocuments%2Fread%2Fedit"
    )

    expect(response.status).to eq(200)
    # Bounded to exactly the flagged population (1 record), not the 25-wide
    # default access_sweep_limit or the 201-row full principal universe.
    expect(response.body).to include("1 users tested", "KarstAccessPrincipal ##{minority.id}",
                                     "Halted callback: halt_for_access_behavior")
  ensure
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  it "fails a guided population_sweep against an unapproved population name safely, without raising" do
    Karst.config.principals = -> { KarstAccessPrincipal.all }
    Karst.config.principal_populations = { flagged: -> { KarstAccessPrincipal.flagged } }
    stack = Karst::Web::Middleware.new(KarstTestApplication)
    mock = Rack::MockRequest.new(stack)

    response = mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=population_sweep&population=not_approved&method=GET&path=%2Fdocuments%2Fread%2Fedit"
    )

    expect(response.status).to eq(200)
    expect(response.body).to include("Analysis unavailable")
  ensure
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
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
end
# rubocop:enable Metrics/BlockLength
