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

    head :ok
  end
  # rubocop:enable Metrics/AbcSize
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
end
# rubocop:enable Metrics/BlockLength
