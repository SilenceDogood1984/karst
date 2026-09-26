# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../support/test_application"
require "karst/cli/verification"
require "karst/cli/reproduction"

ActiveRecord::Schema.define do
  create_table :karst_existing_record_as_principals, force: true do |table|
    table.string :role, null: false, default: "member"
  end
end

class KarstExistingRecordAsPrincipal < ActiveRecord::Base; end

# A conventional custom-authentication controller, exactly like the ones
# spec/integration/identity_evidence_spec.rb and
# spec/integration/reproduction_identity_spec.rb use: one before_action
# resolves the principal from the session, another makes the access
# decision. Nothing here knows Karst exists.
class KarstExistingRecordAsController < ActionController::Base
  before_action :set_current_principal
  before_action :authorize_admin, only: :admin_document

  attr_reader :current_principal

  def login
    session[:principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:principal_id)
    head :no_content
  end

  def document
    render plain: "document for #{@current_principal&.id.inspect}"
  end

  def admin_document
    render plain: "admin document"
  end

  private

  def set_current_principal
    @current_principal = KarstExistingRecordAsPrincipal.find_by(id: session[:principal_id])
  end

  def authorize_admin
    return head(:unauthorized) if @current_principal.nil?

    head(:forbidden) unless @current_principal.role == "admin"
  end
end

# Added directly through the mapper, not .draw, for the reason
# mcp_server_spec.rb documents at length: .draw clears the whole route set
# first, so a second spec file drawing on the one shared KarstTestApplication
# would silently delete another file's routes.
KarstTestApplication.routes.send(:eval_block, proc {
  post "/existing_record_as/login", to: "karst_existing_record_as#login"
  delete "/existing_record_as/logout", to: "karst_existing_record_as#logout"
  get "/existing_record_as/document", to: "karst_existing_record_as#document"
  get "/existing_record_as/admin_document", to: "karst_existing_record_as#admin_document"
})

# End-to-end coverage for the human-only `--as MODEL:ID` principal selector
# (Karst::CLI::PrincipalReference), exercised through the same shared
# Karst::CLI::Verification/Karst::CLI::Reproduction adapters the
# karst:verify/karst:reproduce commands use. See also spec/cli/verification_spec.rb
# and spec/cli/principal_reference_spec.rb for the mocked unit coverage of
# the same behavior.
# rubocop:disable Metrics/BlockLength
RSpec.describe "--as: running a probe as one specific existing principal" do
  let(:member) { KarstExistingRecordAsPrincipal.create!(role: "member") }
  let(:admin) { KarstExistingRecordAsPrincipal.create!(role: "admin") }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstExistingRecordAsPrincipal.delete_all
    Karst.config.principals = -> { KarstExistingRecordAsPrincipal.all }
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/existing_record_as/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/existing_record_as/logout" }
    Karst.config.observe_identity = ->(context) { context.controller&.current_principal }
    # Verification#validate_setup! (unlike Reproduction, which never calls
    # it) requires a complete identity setup, browser hooks included, before
    # it will run at all -- see Karst::Identity.setup_state. These are never
    # exercised by anything below; they only need to exist.
    Karst.config.assume_browser_identity = ->(_request, _principal) {}
    Karst.config.clear_browser_identity = ->(_request) {}
  end

  after do
    %i[assume_identity clear_identity observe_identity principals
       assume_browser_identity clear_browser_identity].each do |hook|
      Karst.config.public_send("#{hook}=", nil)
    end
  end

  describe "bin/rails karst:verify --as (Karst::CLI::Verification)" do
    it "A: resolves an allowed configured principal and verifies exactly that one, not a sample" do
      member
      document = Karst::CLI::Verification.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:#{member.id}"
      ).evidence

      expect(document[:probe]).to eq(identity: "specific_principal")
      expect(document[:verified_usable]).to be(true)
      expect(document[:verified_identity][:requested]).to include(id: member.id)
      expect(document[:verified_identity][:confirmation]).to eq("confirmed")
      expect(document[:populations]).to eq([])
      expect(document[:sample][:outcomes].size).to eq(1)
    end

    it "B: fails cleanly on an unknown id, never silently sampling instead" do
      member
      unknown_id = member.id + 1000
      document = Karst::CLI::Verification.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:#{unknown_id}"
      ).evidence

      expect(document[:error]).to include(type: "input_error")
      expect(document[:error][:message]).to match(/did not resolve/)
    end

    it "C: refuses a principal outside the configured source's own scope" do
      out_of_scope = admin
      Karst.config.principals = -> { KarstExistingRecordAsPrincipal.where(role: "member") }

      document = Karst::CLI::Verification.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:#{out_of_scope.id}"
      ).evidence

      expect(document[:error]).to include(type: "input_error")
      expect(document[:error][:message]).to match(/did not resolve/)
    end

    it "refuses combining --anonymous and --as instead of picking one silently" do
      expect do
        Karst::CLI::Verification.new(path: "/existing_record_as/document", identity: "anonymous", as: "User:1")
      end.to raise_error(ArgumentError, /cannot be combined/)
    end

    it "I: still refuses to run outside development, exactly like the ordinary sample" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      document = Karst::CLI::Verification.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:#{member.id}"
      ).evidence

      expect(document[:error][:message]).to match(/development-only/)
    end
  end

  describe "bin/rails karst:reproduce --as (Karst::CLI::Reproduction)" do
    it "G: sends the one request as exactly the requested principal, runtime-confirmed" do
      document = Karst::CLI::Reproduction.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:#{member.id}"
      ).evidence

      expect(document[:identity][:requested]).to include(id: member.id)
      expect(document[:identity][:observed]).to include(id: member.id)
      expect(document[:identity][:confirmation]).to eq("confirmed")
      expect(document[:response][:status]).to eq(200)
    end

    it "fails cleanly, never falling back to anonymous, when the reference does not resolve" do
      document = Karst::CLI::Reproduction.new(
        path: "/existing_record_as/document", as: "KarstExistingRecordAsPrincipal:999999"
      ).evidence

      expect(document[:error]).to include(type: "input_error")
      expect(document[:error][:message]).to match(/did not resolve/)
    end

    it "refuses combining --anonymous and --as instead of picking one silently" do
      expect do
        Karst::CLI::Reproduction.new(path: "/existing_record_as/document", anonymous: true, as: "User:1")
      end.to raise_error(ArgumentError, /cannot be combined/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
