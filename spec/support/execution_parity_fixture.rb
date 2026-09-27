# frozen_string_literal: true

require_relative "test_application"

# A realistic authenticated route set on the shared KarstTestApplication,
# shaped like `bin/rails generate authentication`: signing in persists a
# session row (an INSERT), signing out destroys it (a DELETE), and every
# protected request resumes identity from a signed cookie. That shape is the
# one that makes identity setup/teardown do real database work -- exactly
# what a target request's own write evidence must never absorb.
#
# Guarded by `defined?` for the same reason spec/integration/
# target_scoped_evidence_spec.rb explains: RSpec `load`s spec files, so a
# fixture reached twice would redefine routes and schema.
unless defined?(KarstParityController)
  ActiveRecord::Schema.define do
    create_table :karst_parity_principals, force: true do |table|
      table.string :role, null: false, default: "member"
      table.integer :visits, null: false, default: 0
    end

    create_table :karst_parity_sessions, force: true do |table|
      table.integer :karst_parity_principal_id, null: false
    end
  end

  class KarstParityPrincipal < ActiveRecord::Base; end

  class KarstParitySession < ActiveRecord::Base
    belongs_to :principal, class_name: "KarstParityPrincipal", foreign_key: :karst_parity_principal_id
  end

  class KarstParityController < ActionController::Base
    skip_before_action :verify_authenticity_token, raise: false
    before_action :resume_session
    before_action :require_authentication, except: %i[login logout public_page]
    before_action :authorize_admin, only: :admin_page
    before_action :closed_for_maintenance, only: :maintenance_page

    # Public so config.observe_identity can read what the application itself
    # resolved.
    attr_reader :current_principal

    # The identity seam's sign-in: one INSERT. A principal whose role is
    # "unloginable" writes its session row and then fails, so identity setup
    # both writes and breaks.
    def login
      principal = KarstParityPrincipal.find(params[:id])
      record = KarstParitySession.create!(karst_parity_principal_id: principal.id)
      raise "sign-in broke after writing" if principal.role == "unloginable"

      cookies.signed[:karst_parity_session] = record.id
      head :no_content
    end

    # The identity seam's sign-out: one DELETE when a session exists.
    def logout
      KarstParitySession.find_by(id: cookies.signed[:karst_parity_session])&.destroy
      cookies.delete(:karst_parity_session)
      head :no_content
    end

    def public_page
      render plain: "public"
    end

    def member_page
      render plain: "member"
    end

    def admin_page
      render plain: "admin"
    end

    def maintenance_page
      render plain: "unreachable"
    end

    def write_page
      @current_principal.update!(visits: @current_principal.visits + 1)
      render plain: "wrote"
    end

    def boom
      raise "parity target exploded"
    end

    def redirect_page
      redirect_to "/parity/public?from=redirect"
    end

    def show
      render plain: "item #{params[:id]}"
    end

    def create
      KarstParityPrincipal.create!(role: params[:role].to_s)
      head :created
    end

    private

    def resume_session
      @current_principal = KarstParitySession.find_by(id: cookies.signed[:karst_parity_session])&.principal
    end

    def require_authentication
      head :unauthorized unless @current_principal
    end

    def authorize_admin
      head :forbidden unless @current_principal.role == "admin"
    end

    def closed_for_maintenance
      head :service_unavailable
    end
  end

  # Added through the mapper, not .draw, for the reason mcp_server_spec.rb
  # documents: .draw clears the route set every other spec file shares.
  # A lazily loaded route set (Rails 8) is loaded first: its first load
  # clears whatever was evaluated into it beforehand, so a spec that happens
  # to run this file alone would otherwise route nothing.
  KarstTestApplication.reload_routes_unless_loaded if KarstTestApplication.respond_to?(:reload_routes_unless_loaded)
  KarstTestApplication.routes.send(:eval_block, proc {
    post "/parity/login", to: "karst_parity#login"
    delete "/parity/logout", to: "karst_parity#logout"
    get "/parity/public", to: "karst_parity#public_page"
    get "/parity/member", to: "karst_parity#member_page"
    get "/parity/admin", to: "karst_parity#admin_page"
    get "/parity/maintenance", to: "karst_parity#maintenance_page"
    get "/parity/write", to: "karst_parity#write_page"
    get "/parity/boom", to: "karst_parity#boom"
    get "/parity/redirect", to: "karst_parity#redirect_page"
    get "/parity/items/:id", to: "karst_parity#show"
    post "/parity/items", to: "karst_parity#create"
  })
end

# The identity seams exactly as docs/rails8-authentication.md documents them
# for this shape of application.
module KarstParityIdentity
  module_function

  def configure!
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/parity/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/parity/logout" }
    Karst.config.observe_identity = ->(context) { context.controller&.current_principal }
  end

  def reset!
    %i[assume_identity clear_identity observe_identity].each { |hook| Karst.config.public_send("#{hook}=", nil) }
  end
end
