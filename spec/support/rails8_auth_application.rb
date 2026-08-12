# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "karst"

# A real Rails::Application authenticated the way `bin/rails generate
# authentication` scaffolds in Rails 8 -- a plain `User`/`Session` pair, an
# ActiveSupport::CurrentAttributes `Current` class, and an `Authentication`
# concern that resumes a session from a signed, permanent `session_id`
# cookie. No Devise, no Warden, and (at require time) no Karst
# configuration at all: unlike Devise, Rails' generated authentication
# registers itself nowhere Karst could safely read, so this is the fourth
# supported identity story, proven the same way as the other three -- see
# spec/support/devise_application.rb (single Devise model, zero config),
# spec/support/multi_devise_application.rb (several Devise models, one
# local /karst selection), and spec/support/custom_auth_application.rb
# (generic custom session authentication). The identity hooks below are
# exactly what docs/rails8-authentication.md documents -- this fixture
# reproduces the generator's own files (Current, the Authentication
# concern, start_new_session_for/terminate_session) rather than inventing
# a different shape, and Karst never inspects any of it to infer
# configuration. `has_secure_password`/bcrypt is intentionally omitted:
# Karst's identity hooks never authenticate by password, so it would add a
# dependency with no acceptance value. See
# spec/integration/rails8_auth_golden_path_integration_spec.rb.
class KarstRails8AuthApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "karst-rails8-auth-integration-secret"
  config.hosts.clear
  config.session_store :cookie_store, key: "_karst_rails8_auth_integration"
  config.paths["config/database"] = File.expand_path("database.yml", __dir__)
end

# See spec/support/custom_auth_application.rb for why both the boot call and
# the routes draw below need Rails.env flipped to development.
original_rails_env = Rails.method(:env)
Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }
begin
  KarstRails8AuthApplication.initialize!

  ActiveRecord::Migration.verbose = false
  ActiveRecord::Schema.define do
    create_table :karst_rails8_auth_users, force: true do |t|
      t.string :email_address, null: false, default: ""
      t.string :password_digest, null: false, default: ""
      t.timestamps null: false
    end
    add_index :karst_rails8_auth_users, :email_address, unique: true

    create_table :karst_rails8_auth_sessions, force: true do |t|
      t.integer :karst_rails8_auth_user_id, null: false
      t.string :ip_address
      t.string :user_agent
      t.timestamps null: false
    end

    # Deliberately its own table rather than a boolean column on the user --
    # see spec/support/devise_application.rb for why: Access::PrincipalSampler
    # already stratifies boolean/enum columns into the ordinary sample
    # automatically, which would let the privileged user show up there and
    # never exercise the candidate-population search path this spec proves.
    create_table :karst_rails8_auth_admin_grants, force: true do |t|
      t.integer :karst_rails8_auth_user_id, null: false
    end
  end

  # -- app/models/current.rb, verbatim shape of the Rails 8 generator output.
  class Current < ActiveSupport::CurrentAttributes
    attribute :session
    delegate :user, to: :session, allow_nil: true
  end

  # -- app/models/user.rb
  class KarstRails8AuthUser < ActiveRecord::Base
    has_many :sessions, class_name: "KarstRails8AuthSession", foreign_key: :karst_rails8_auth_user_id,
                        dependent: :destroy
    has_one :karst_rails8_auth_admin_grant

    scope :system_admins, -> { joins(:karst_rails8_auth_admin_grant) }

    def system_admin?
      karst_rails8_auth_admin_grant.present?
    end
  end

  # -- app/models/session.rb
  class KarstRails8AuthSession < ActiveRecord::Base
    belongs_to :user, class_name: "KarstRails8AuthUser", foreign_key: :karst_rails8_auth_user_id
  end

  class KarstRails8AuthAdminGrant < ActiveRecord::Base
    belongs_to :karst_rails8_auth_user
  end

  # -- app/controllers/concerns/authentication.rb, verbatim shape of the
  # Rails 8 generator output (Session/Password reset-mailer pieces omitted:
  # Karst's identity hooks never touch them).
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :require_authentication
      helper_method :authenticated?
    end

    class_methods do
      def allow_unauthenticated_access(**options)
        skip_before_action :require_authentication, **options
      end
    end

    private

    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      KarstRails8AuthSession.find_by(id: cookies.signed[:session_id])
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |new_session|
        Current.session = new_session
        cookies.signed.permanent[:session_id] = { value: new_session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
  end

  # -- app/controllers/application_controller.rb
  class ApplicationController < ActionController::Base
    include Authentication
  end

  # -- app/controllers/sessions_controller.rb, trimmed to what routing needs
  # (new_session_path must resolve; the real password-based #create is
  # irrelevant to Karst, which never signs a probe in through a login form).
  class SessionsController < ApplicationController
    allow_unauthenticated_access

    def new
      head :ok
    end
  end

  # The completed version of the generator's own scaffold (see
  # lib/generators/karst/install/templates/karst_identity_controller.rb) --
  # the same Karst::Identity.resolve boundary the generated TODOs guard,
  # calling this host's own real start_new_session_for/terminate_session
  # instead of raising NotImplementedError. Only #create skips
  # require_authentication, exactly like the generated SessionsController
  # only skips it for :new/:create -- logging a probe identity out still
  # requires one to already be signed in, same as a real user's logout.
  class KarstIdentityController < ApplicationController
    allow_unauthenticated_access only: :create
    skip_before_action :verify_authenticity_token, raise: false

    def create
      principal = Karst::Identity.resolve(model_name: params[:principal_type], id: params[:principal_id])
      return head(:forbidden) unless principal

      start_new_session_for(principal)
      head :no_content
    end

    def destroy
      terminate_session
      head :no_content
    end
  end

  class KarstRails8AuthReportsController < ApplicationController
    before_action :authorize_admin

    def show
      render plain: "report #{params[:id]} for #{Current.user.email_address}"
    end

    private

    def authorize_admin
      head :forbidden unless Current.user&.system_admin?
    end
  end

  KarstRails8AuthApplication.routes.draw do
    resource :session, only: %i[new]
    if Rails.env.development?
      post   "/karst_test_login",  to: "karst_identity#create"
      delete "/karst_test_logout", to: "karst_identity#destroy"
    end
    get "/reports/:id", to: "karst_rails8_auth_reports#show"
  end
ensure
  Rails.define_singleton_method(:env, original_rails_env)
end
