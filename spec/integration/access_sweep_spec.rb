# frozen_string_literal: true

require "spec_helper"
require_relative "../support/test_application"

ActiveRecord::Schema.define do
  create_table :karst_access_principals, force: true do |table|
    table.string :behavior, null: false
    table.integer :visits, null: false, default: 0
  end
end

class KarstAccessPrincipal < ActiveRecord::Base
end

class KarstAccessFixtureController < ActionController::Base
  before_action :mark_controller_execution, only: :document

  def login
    session[:karst_principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:karst_principal_id)
    head :no_content
  end

  # rubocop:disable Metrics/AbcSize
  def document
    principal = KarstAccessPrincipal.find(session[:karst_principal_id])
    principal.update!(visits: principal.visits + 1) if params[:id] == "write"
    return redirect_to("/login?secret=hidden") if principal.behavior == "redirect"
    return head(:forbidden) if principal.behavior == "forbidden"
    raise "fixture detail must not escape" if principal.behavior == "raise"

    render plain: "#{session[:before_action]}:#{principal.behavior}"
  end
  # rubocop:enable Metrics/AbcSize

  private

  def mark_controller_execution
    session[:before_action] = "before_action_ran"
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
    expect(result.outcomes[1].redirect).to eq("http://www.example.com/login")
    expect(result.outcomes[3].exception_class).to eq("RuntimeError")
    expect(result.outcomes.map(&:writes_observed)).to all(be(true))
    expect(KarstAccessPrincipal.order(:id).pluck(:visits)).to eq([0, 0, 0, 0])
  end

  it "bypasses non-reentrant host middleware at the route dispatch boundary" do
    principal = KarstAccessPrincipal.find_by!(behavior: "ok")
    calls_before = KarstNonReentrantMiddleware.calls

    nested = ActionDispatch::Integration::Session.new(KarstTestApplication)
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
    browser.get("/documents/read/edit")
    expect(KarstNonReentrantMiddleware.calls).to eq(calls_before + 1)
  end
end
# rubocop:enable Metrics/BlockLength
