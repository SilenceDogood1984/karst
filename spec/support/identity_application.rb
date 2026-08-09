# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
# Load only the Rails application and controller integration required by this
# fixture. In particular, do not require rails/all or active_record/railtie:
# this test exercises cookie-backed session identity and has no database.
require "rails"
require "action_controller/railtie"
require "karst"

class KarstIdentityApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-identity-integration-secret"
  config.hosts.clear
  config.action_controller.allow_forgery_protection = false
end

class KarstIdentityController < ActionController::Base
  def login
    session[:user_id] = params[:user_id]
    head :no_content
  end

  def logout
    session.delete(:user_id)
    head :no_content
  end

  def protected_page
    head(session[:user_id].present? ? :ok : :unauthorized)
  end
end

KarstIdentityApplication.initialize!

KarstIdentityApplication.routes.draw do
  post "/karst_test_login", to: "karst_identity#login"
  delete "/karst_test_logout", to: "karst_identity#logout"
  get "/protected", to: "karst_identity#protected_page"
end
