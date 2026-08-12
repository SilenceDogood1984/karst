# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "karst"

# A real Rails::Application with ordinary custom session authentication
# (`session[:account_id]`) -- no Devise, no Warden, and (at require time) no
# Karst configuration at all. This is the third of the three supported
# identity stories -- see spec/support/devise_application.rb (single Devise
# model, zero config) and spec/support/multi_devise_application.rb (several
# Devise models, one local /karst selection) -- proven the same way: real
# Rails::Application, real Web::Middleware insertion, real browser session,
# nothing about Karst::Identity or Access::Search stubbed. See
# spec/integration/custom_auth_golden_path_integration_spec.rb.
class KarstCustomAuthApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-custom-auth-integration-secret"
  config.hosts.clear
  config.session_store :cookie_store, key: "_karst_custom_auth_integration"
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)
end

# Karst::Railtie only inserts Web::Middleware when Rails.env.development? at
# boot, and the generated `if Rails.env.development?` route guard below (see
# lib/generators/karst/install/install_generator.rb::DEVELOPMENT_ROUTES,
# reproduced verbatim here) is evaluated once, at routes.draw time -- so both
# the application boot *and* the routes draw need Rails.env flipped, unlike
# spec/support/devise_application.rb where only the boot call does.
original_rails_env = Rails.method(:env)
Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }
begin
  KarstCustomAuthApplication.initialize!

  ActiveRecord::Migration.verbose = false
  ActiveRecord::Schema.define do
    create_table :karst_custom_auth_accounts, force: true do |t|
      t.string :email, null: false, default: ""
      t.boolean :active, null: false, default: true
    end
  end

  class KarstCustomAuthAccount < ActiveRecord::Base
    scope :active, -> { where(active: true) }
  end

  class ApplicationController < ActionController::Base
    def current_account
      @current_account ||= KarstCustomAuthAccount.find_by(id: session[:account_id])
    end
  end

  # The *completed* version of the generator's own scaffold (see
  # lib/generators/karst/install/templates/karst_identity_controller.rb) --
  # the same Karst::Identity.resolve boundary the generated TODOs guard,
  # with this host's real session[:account_id] semantics filled in instead
  # of `raise NotImplementedError`. config.assume_identity/clear_identity
  # (configured by the spec, standing in for a developer completing the
  # generated karst.rb initializer) post to exactly the routes the
  # generator itself wires up below.
  class KarstIdentityController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      principal = Karst::Identity.resolve(model_name: params[:principal_type], id: params[:principal_id])
      return head(:forbidden) unless principal

      session[:account_id] = principal.id
      head :no_content
    end

    def destroy
      session.delete(:account_id)
      head :no_content
    end
  end

  class KarstCustomAuthSecretsController < ApplicationController
    before_action :require_account

    def show
      render plain: "secret #{params[:id]} for #{current_account.email}"
    end

    private

    def require_account
      head :unauthorized unless current_account
    end
  end

  KarstCustomAuthApplication.routes.draw do
    if Rails.env.development?
      post   "/karst_test_login",  to: "karst_identity#create"
      delete "/karst_test_logout", to: "karst_identity#destroy"
    end
    get "/secrets/:id", to: "karst_custom_auth_secrets#show"
  end
ensure
  Rails.define_singleton_method(:env, original_rails_env)
end
