# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "warden"
require "karst"
require "karst/spec/observer"

# A deliberately small, test-only Rails application with real routing,
# controllers, and Warden-based authentication -- used to prove Karst's RSpec
# scenario observer against genuine HTTP/Warden behavior rather than
# synthetic notifications. Users are plain in-memory structs: Warden and
# Karst's observer only ever need `#id` and `#class.name`, never anything
# ActiveRecord-specific.
ScenarioUser = Struct.new(:id, :email, :role)

module ScenarioUsers
  ALL = [
    ScenarioUser.new(1, "author@example.com", "author"),
    ScenarioUser.new(2, "admin@example.com", "admin")
  ].freeze

  def self.find(id) = ALL.find { |user| user.id.to_s == id.to_s }
  def self.find_by_email(email) = ALL.find { |user| user.email == email }
end

Warden::Manager.serialize_into_session(&:id)
Warden::Manager.serialize_from_session { |id| ScenarioUsers.find(id) }

Warden::Strategies.add(:scenario_password) do
  def valid? = params["email"] && params["password"]

  def authenticate!
    user = ScenarioUsers.find_by_email(params["email"])
    user && params["password"] == "secret" ? success!(user) : fail!("invalid credentials")
  end
end

class ScenarioApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-scenario-observer-test-secret"
  config.hosts.clear if config.respond_to?(:hosts)
  config.session_store :cookie_store, key: "_karst_scenario_test"
  config.middleware.use Warden::Manager do |manager|
    manager.default_strategies :scenario_password
    manager.failure_app = ->(_env) { [401, { "content-type" => "text/plain" }, ["unauthorized"]] }
  end
end

ScenarioApplication.initialize!

ScenarioApplication.routes.draw do
  post "/sign-in", to: "scenario_sessions#create", as: :sign_in
  delete "/sign-out", to: "scenario_sessions#destroy", as: :sign_out
  get "/dashboard", to: "scenario_dashboard#show", as: :dashboard
  get "/admin", to: "scenario_admin#show", as: :admin
  get "/things", to: "scenario_things#index", as: :things
  get "/things/:id", to: "scenario_things#show", as: :thing
  post "/signup", to: "scenario_signups#create", as: :signup
  post "/password-resets", to: "scenario_password_resets#create", as: :password_resets
end

class ScenarioSessionsController < ActionController::Base
  def create
    request.env["warden"].authenticate(:scenario_password)
    redirect_to(request.env["warden"].user ? dashboard_path : sign_in_path)
  end

  def destroy
    request.env["warden"].user # forces the fetch a real before_action-guarded app would already have done
    request.env["warden"].logout
    redirect_to "/"
  end
end

class ScenarioDashboardController < ActionController::Base
  def show
    user = request.env["warden"].user
    return redirect_to(sign_in_path) unless user

    render plain: "Dashboard for #{user.email}"
  end
end

class ScenarioAdminController < ActionController::Base
  def show
    user = request.env["warden"].user
    return redirect_to(sign_in_path) unless user
    return redirect_to(dashboard_path) unless user.role == "admin"

    render plain: "Admin"
  end
end

class ScenarioSignupsController < ActionController::Base
  # Establishes a Warden principal directly within what is, for this
  # example, the actual subject request under test -- not a prior sign-in
  # step. Proves the observer never treats "this request changed the
  # principal" as a signal that the request is setup/plumbing.
  def create
    request.env["warden"].set_user(ScenarioUsers.find_by_email("author@example.com"), scope: :default)
    redirect_to dashboard_path
  end
end

class ScenarioPasswordResetsController < ActionController::Base
  # The token here stands in for anything sensitive a redirect target might
  # carry (password reset, OAuth callback, signed URL).
  def create
    redirect_to "/reset-password/confirm?token=secret-value-123"
  end
end

class ScenarioThingsController < ActionController::Base
  def index
    render plain: "Things index"
  end

  def show
    render plain: "Thing #{params[:id]}"
  end
end
