# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "devise"
require "devise/orm/active_record"
require "karst"

# A second, independent real Rails::Application with the real `devise` and
# `warden` gems mounted -- deliberately never loaded in the same process as
# KarstDeviseApplication (spec/support/devise_application.rb) or any other
# Devise-mounted Rails::Application: two real Devise::Engine boots cannot
# safely share one process (see bin/test-rails and
# spec/integration/multi_devise_golden_path_integration_spec.rb, which is run
# in its own rspec invocation for exactly this reason).
#
# Registers *two* genuine Devise mappings with distinct Warden scopes, so the
# multi-model paths -- ambiguity detection, local /karst selection, per-model
# Warden scoping, `bin/rails karst:verify` -- are proven against the real
# `devise_for`/`Devise.mappings`/`Warden::Manager` machinery, not the
# `stub_const("Devise", ...)` doubles every other multi-source spec uses (see
# spec/identity/devise_golden_path_spec.rb and
# spec/integration/access_sweep_spec.rb's "resolving an ambiguous Devise
# setup" context).
class KarstMultiDeviseApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-multi-devise-integration-secret"
  config.hosts.clear
  config.active_support.deprecation = :stderr
  config.session_store :cookie_store, key: "_karst_multi_devise_integration"
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)

  initializer "karst.integration_harness" do
    Karst.configure { |configuration| configuration.enabled = true }
  end
end

# See spec/support/devise_application.rb for why Rails.env is flipped only
# for this one boot call.
original_rails_env = Rails.method(:env)
Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }
begin
  KarstMultiDeviseApplication.initialize!
ensure
  Rails.define_singleton_method(:env, original_rails_env)
end

# Schema-creation logging goes straight to $stdout by default, which is
# harmless under RSpec but would corrupt an MCP stdio protocol stream if
# this fixture were ever required inside a real karst:mcp subprocess (see
# spec/integration/mcp_stdio_multi_devise_spec.rb) -- suppressed the same
# way spec/integration/mcp_stdio_spec.rb's own fixture already does.
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :karst_multi_users, force: true do |t|
    t.string :email, null: false, default: ""
    t.string :encrypted_password, null: false, default: ""
    t.string :reset_password_token
    t.datetime :reset_password_sent_at
    t.datetime :remember_created_at
    t.timestamps null: false
  end
  add_index :karst_multi_users, :email, unique: true

  create_table :karst_multi_admins, force: true do |t|
    t.string :email, null: false, default: ""
    t.string :encrypted_password, null: false, default: ""
    t.string :reset_password_token
    t.datetime :reset_password_sent_at
    t.datetime :remember_created_at
    t.timestamps null: false
  end
  add_index :karst_multi_admins, :email, unique: true

  # A join table, not a plain boolean column, deliberately -- see
  # spec/support/devise_application.rb's identical KarstDeviseAdminGrant:
  # Access::PrincipalSampler stratifies boolean/enum columns into the
  # ordinary sample automatically, which would defeat the one spec this
  # table exists for (an Admin only reachable through an approved candidate
  # population).
  create_table :karst_multi_super_grants, force: true do |t|
    t.integer :karst_multi_admin_id, null: false
  end
end

class KarstMultiUser < ActiveRecord::Base
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable
end

class KarstMultiAdmin < ActiveRecord::Base
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable

  has_one :karst_multi_super_grant

  scope :super_admins, -> { joins(:karst_multi_super_grant) }
end

class KarstMultiSuperGrant < ActiveRecord::Base
  belongs_to :karst_multi_admin
end

# Devise's own DeviseController constantizes "ApplicationController" by Rails
# convention -- see spec/support/devise_application.rb.
class ApplicationController < ActionController::Base
end

# Requires only *a* signed-in KarstMultiUser -- no further authorization --
# so every probed user is reported as verified usable, proving the ordinary
# User-only source is tested with no Admin ever touching this route.
class KarstMultiUserSecretsController < ApplicationController
  before_action :authenticate_karst_multi_user!

  def show
    render plain: "user secret #{params[:id]}"
  end
end

# Requires an Admin signed in under the distinct :karst_multi_admin Warden
# scope. A KarstMultiUser probed here is never treated as authenticated for
# this route, even though it is a real, successfully signed-in Devise
# session under its own scope -- proving Karst assumes each principal under
# its own Devise/Warden scope rather than the single scope of whichever
# source happens to be configured first.
class KarstMultiAdminSecretsController < ApplicationController
  before_action :authenticate_karst_multi_admin!

  def show
    render plain: "admin secret #{params[:id]}"
  end
end

# Requires an Admin *and* a super grant -- the one route in this fixture an
# ordinary admin cannot reach, so an approved candidate population is the
# only way Access::Search finds a usable principal here (see
# spec/integration/multi_devise_golden_path_integration_spec.rb's population
# CLI test).
class KarstMultiSuperSecretsController < ApplicationController
  before_action :authenticate_karst_multi_admin!
  before_action :authorize_super_admin

  def show
    render plain: "super secret #{params[:id]}"
  end

  private

  def authorize_super_admin
    head :forbidden unless current_karst_multi_admin&.karst_multi_super_grant&.present?
  end
end

KarstMultiDeviseApplication.routes.draw do
  devise_for :karst_multi_users
  devise_for :karst_multi_admins
  get "/karst_multi_secrets/:id", to: "karst_multi_user_secrets#show"
  get "/karst_multi_admin_secrets/:id", to: "karst_multi_admin_secrets#show"
  get "/karst_multi_super_secrets/:id", to: "karst_multi_super_secrets#show"
end

# Forces Devise's session-serializer/Warden configuration to (re)run now that
# both mappings actually exist -- see spec/support/devise_application.rb for
# why this fixture-only ordering trap exists and why it must be forced here.
Devise.class_variable_set(:@@warden_configured, nil) # rubocop:disable Style/ClassVars
Devise.configure_warden!
