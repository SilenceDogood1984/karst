# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "development"

require "logger"
require "tmpdir"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "karst"

# A deliberately small, test-only Rails application with real routing and
# controllers -- used to prove Karst::Web::Badge against genuine Rack
# responses produced by a real ActionController dispatch (real
# process_action.action_controller notifications, real Content-Type/
# Content-Disposition/Content-Security-Policy headers) rather than
# hand-constructed Rack triples. `config.root` points at a fresh temp
# directory so all generated files are disposable.
BADGE_APP_ROOT = Dir.mktmpdir("karst-badge-app")

class BadgePagesController < ActionController::Base
  def show
    render html: "<!DOCTYPE html><html><head><title>Page</title></head>" \
                 "<body><h1>Page #{params[:id]}</h1></body></html>".html_safe
  end

  def data
    render json: { id: params[:id] }
  end

  def redirect
    redirect_to "/badge_pages/#{params[:id]}"
  end

  def stream
    render body: "<turbo-stream action=\"append\" target=\"x\"></turbo-stream>",
           content_type: "text/vnd.turbo-stream.html"
  end

  def download
    send_data "<html><body>export</body></html>", filename: "export.html", type: "text/html",
                                                  disposition: "attachment"
  end

  def csp
    response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self'"
    render html: "<!DOCTYPE html><html><body><h1>CSP page</h1></body></html>".html_safe
  end

  def fragment
    render html: "<turbo-frame id=\"x\">fragment</turbo-frame>".html_safe, layout: false
  end
end

class BadgeOtherController < ActionController::Base
  def show
    render html: "<!DOCTYPE html><html><body><h1>Other #{params[:id]}</h1></body></html>".html_safe
  end
end

class BadgeApplication < Rails::Application
  config.root = BADGE_APP_ROOT
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-badge-test-secret"
  config.hosts.clear if config.respond_to?(:hosts)
end

BadgeApplication.initialize!

BadgeApplication.routes.draw do
  get "/badge_pages/:id", to: "badge_pages#show"
  get "/badge_pages/:id/data", to: "badge_pages#data"
  get "/badge_pages/:id/redirect", to: "badge_pages#redirect"
  get "/badge_pages/:id/stream", to: "badge_pages#stream"
  get "/badge_pages/:id/download", to: "badge_pages#download"
  get "/badge_pages/:id/csp", to: "badge_pages#csp"
  get "/badge_pages/:id/fragment", to: "badge_pages#fragment"
  get "/others/:id", to: "badge_other#show"
end
