# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "devise"
require "devise/orm/active_record"
require "karst"

# A real Rails::Application with the real `devise` and `warden` gems mounted
# -- not the stubbed `Devise`/`Warden::Manager` constants every other spec
# file in this suite uses. Devise's own Railtie inserts the real
# Warden::Manager into this application's actual compiled middleware stack
# exactly as it would in a host application, which is the one thing a
# stubbed Devise/Warden pair can never exercise: whether
# Karst::Access::ProbeApplication's own, separate, minimal Rack stack can
# authenticate a principal through that real middleware. See
# spec/integration/devise_golden_path_integration_spec.rb.
class KarstDeviseApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-devise-integration-secret"
  config.hosts.clear
  config.active_support.deprecation = :stderr
  config.session_store :cookie_store, key: "_karst_devise_integration"
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)

  initializer "karst.integration_harness" do
    Karst.configure { |configuration| configuration.enabled = true }
  end
end

# Karst::Railtie only inserts Web::Middleware into an application's own
# compiled middleware stack (before: :build_middleware_stack) when
# Rails.env.development? at boot -- exactly the condition a real `bin/rails
# server` run satisfies. Booting under RSpec's own "test" environment would
# skip that insertion, leaving /karst with no Rack session underneath it
# (Web::Middleware would then have to be wrapped externally, ahead of a
# *separate* session middleware, which -- unlike a real host application --
# would not be the same session Devise/Warden authenticate the rest of the
# request through). Flipping Rails.env only for this one boot call, then
# restoring it immediately after, reproduces the real insertion point
# without leaking a permanently "development" Rails.env into any other spec
# file sharing this process.
original_rails_env = Rails.method(:env)
Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }
begin
  KarstDeviseApplication.initialize!
ensure
  Rails.define_singleton_method(:env, original_rails_env)
end

# Models must be defined only after Rails::Application#initialize! has run:
# the `devise` class macro is added to ActiveRecord::Base through Devise's
# own ActiveSupport.on_load(:active_record) hook, which Devise::Engine's
# initializers register but do not fire until this application actually
# initializes.
#
# Schema-creation logging goes straight to $stdout by default -- harmless
# under RSpec, but this fixture is exactly the shape a future MCP-over-real-
# Devise subprocess spec would reuse, where that output would corrupt the
# stdio protocol stream (see spec/support/multi_devise_application.rb).
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :karst_devise_users, force: true do |t|
    t.string :email, null: false, default: ""
    t.string :encrypted_password, null: false, default: ""
    t.string :reset_password_token
    t.datetime :reset_password_sent_at
    t.datetime :remember_created_at
    t.timestamps null: false
  end
  add_index :karst_devise_users, :email, unique: true

  create_table :karst_devise_admin_grants, force: true do |t|
    t.integer :karst_devise_user_id, null: false
  end
end

class KarstDeviseUser < ActiveRecord::Base
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable

  has_one :karst_devise_admin_grant

  # Deliberately not a plain boolean column: Access::PrincipalSampler
  # stratifies boolean/enum columns into the ordinary sample automatically
  # (by design -- see ARCHITECTURE.md), so a plain boolean admin flag would
  # already show up in the recent-N sample and never exercise the
  # candidate-population path this spec is built to prove.
  scope :system_admins, -> { joins(:karst_devise_admin_grant) }

  def system_admin?
    karst_devise_admin_grant.present?
  end
end

class KarstDeviseAdminGrant < ActiveRecord::Base
  self.table_name = "karst_devise_admin_grants"
  belongs_to :karst_devise_user
end

# Devise's own DeviseController (used internally by #devise_controller?, in
# turn used by #authenticate_karst_devise_user!) constantizes
# "ApplicationController" by Rails convention -- every real host application
# has one, so this fixture needs one too.
class ApplicationController < ActionController::Base
end

class KarstDeviseImportsController < ApplicationController
  before_action :authenticate_karst_devise_user!
  before_action :authorize_admin

  def show
    render plain: "import #{params[:id]}"
  end

  private

  def authorize_admin
    head :forbidden unless current_karst_devise_user&.system_admin?
  end
end

KarstDeviseApplication.routes.draw do
  devise_for :karst_devise_users
  get "/karst_devise_imports/:id", to: "karst_devise_imports#show"
end

# KarstDeviseApplication.initialize! above already triggered one routes
# finalize -- with zero routes drawn yet, since draw happens here, after
# initialize -- and Devise's own finalize_with_devise! hook
# (ActionDispatch::Routing::RouteSet#finalize!) memoizes
# @@warden_configured permanently the first time it runs, regardless of how
# many mappings it saw. A real host application never hits this: its
# config/routes.rb (with devise_for already inside it) loads once, lazily,
# the first time anything touches its routes, which is always after
# `devise_for` has already run. This fixture draws routes as an explicit
# second step for clarity, so it has to force that memoized guard to run
# again now that Devise.mappings is actually populated -- otherwise no
# session serializer is ever registered for :karst_devise_user, and Warden
# falls back to Marshal-dumping the raw ActiveRecord principal straight into
# the session cookie (a multi-KB CookieOverflow, not a security-relevant
# difference from a real app, just a test-fixture-only ordering trap).
Devise.class_variable_set(:@@warden_configured, nil) # rubocop:disable Style/ClassVars
Devise.configure_warden!
