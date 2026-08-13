# frozen_string_literal: true

require "spec_helper"
require "json"
require "rack/mock"
require "rack/test"
require_relative "../support/rails8_auth_application"
require "karst/web/middleware"

# The fourth supported identity story, proven the same way the other three
# are (see spec/integration/devise_golden_path_integration_spec.rb and
# spec/integration/custom_auth_golden_path_integration_spec.rb): a real
# Rails::Application, real Web::Middleware, a real browser session -- here
# authenticated the way `bin/rails generate authentication` scaffolds in
# Rails 8 (a plain User/Session pair, ActiveSupport::CurrentAttributes, a
# signed permanent cookie), not Devise. Nothing here stubs Access::Search,
# Access::Sweep, or Karst::Identity.
#
# Unlike Devise, Rails' generated authentication registers itself nowhere
# Karst could safely read (no equivalent of Devise.mappings), so this spec
# also proves the *documented* configuration in
# docs/rails8-authentication.md -- not an inferred one -- is the complete
# minimum an application built this way needs.
# rubocop:disable Metrics/BlockLength
RSpec.describe "Rails 8 generated authentication golden path, real Rails, no Devise" do
  around do |example|
    Dir.mktmpdir("karst-rails8-auth-golden-path") do |dir|
      @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
      example.run
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
    KarstRails8AuthAdminGrant.delete_all
    KarstRails8AuthSession.delete_all
    KarstRails8AuthUser.delete_all
  end

  after do
    Karst.config.principals = nil
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
    Karst.config.assume_browser_identity = nil
    Karst.config.clear_browser_identity = nil
  end

  def stack
    KarstRails8AuthApplication
  end

  def mock
    Rack::MockRequest.new(stack)
  end

  def browser
    @browser ||= Rack::Test::Session.new(Rack::MockSession.new(stack)).tap do |session|
      session.header("REMOTE_ADDR", "127.0.0.1")
    end
  end

  def csrf_token(body)
    body[/name="csrf_token" value="([^"]+)"/, 1]
  end

  # Exactly the recipe docs/rails8-authentication.md documents -- the
  # "developer followed the recipe" step of the acceptance journey. Karst
  # cannot infer any of this automatically: Rails' generated authentication
  # has no framework registry equivalent to Devise.mappings.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def configure_karst_for_rails8_auth!
    Karst.config.principals = -> { KarstRails8AuthUser.all }

    Karst.config.assume_identity = lambda do |session, principal|
      descriptor = Karst::Identity.describe(principal)
      session.post "/karst_test_login", params: { principal_type: descriptor.model_name, principal_id: descriptor.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/karst_test_logout" }

    Karst.config.assume_browser_identity = lambda do |request, principal|
      rails_request = ActionDispatch::Request.new(request.env)
      probe_session = principal.sessions.create!(user_agent: "Karst Test As", ip_address: "127.0.0.1")
      rails_request.cookie_jar.signed.permanent[:session_id] =
        { value: probe_session.id, httponly: true, same_site: :lax }
    end
    Karst.config.clear_browser_identity = lambda do |request|
      rails_request = ActionDispatch::Request.new(request.env)
      KarstRails8AuthSession.find_by(id: rails_request.cookie_jar.signed[:session_id])&.destroy
      rails_request.cookie_jar.delete(:session_id)
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  it "explains, with no Karst configuration at all, that automatic authentication cannot be determined -- " \
     "Rails' generated authentication has no registry Karst can safely infer from, unlike Devise" do
    response = mock.get("/karst", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(Karst::Identity.setup_state.status).to eq(:unavailable)
    expect(response.body).to include("Karst couldn't determine how this app authenticates users")
  end

  it "runs the real ordinary sample through the real Authentication concern, finds nothing usable, " \
     "discovers system_admins, and the developer approves + reruns + Test As + Stop Testing As -- " \
     "with every write rolled back and no residual write in the application's database" do
    configure_karst_for_rails8_auth!
    expect(Karst::Identity.setup_state.status).to eq(:ready_explicit)

    # The admin is created first and everyone else after: Access::Sweep's
    # ordinary sample draws from the most recently created principals, so
    # this is what keeps the admin out of it -- exactly what makes the
    # candidate-population path below the only way to reach them.
    admin_user = KarstRails8AuthUser.create!(email_address: "root_admin@example.com", password_digest: "x")
    KarstRails8AuthAdminGrant.create!(karst_rails8_auth_user: admin_user)
    27.times { |i| KarstRails8AuthUser.create!(email_address: "user#{i}@example.com", password_digest: "x") }

    # 1. Ordinary sample: real probes through the real signed-cookie session
    # resume path, each correctly authenticated as themselves and correctly
    # halted by the real controller's own authorization check. Unlike the
    # Devise/Warden and plain-session-hash golden paths, this is honestly
    # NOT zero-write evidence: Rails' generated auth persists a `Session`
    # row per sign-in, so assume_identity/clear_identity's own login/logout
    # (not the probed route) insert and delete that row on every probe --
    # observed and reported like any other write, and rolled back like any
    # other write (see the residual-count assertions below).
    first = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/reports/1")
    expect(first.status).to eq(200)
    expect(first.body).to include("No verified usable user found")
    expect(first.body).to include("403 Forbidden", "halted at authorize_admin")
    expect(first.body).to include("⚠ Database writes observed during 25 probes.")

    # 2. system_admins is discoverable (source parsed, never executed) but
    # not yet searched.
    expect(first.body).to include("Karst found application-defined user groups", "system_admins",
                                  "Approve selected and retry")

    # 3. Approve it locally -- no initializer edit or page navigation. The
    # same POST immediately reruns the same route analysis.
    browser.header("Referer", "http://example.org/karst")
    approval = browser.post("/karst", operation: "approve_populations", csrf_token: csrf_token(first.body),
                                      method: "GET", path: "/reports/1",
                                      population: ["default::KarstRails8AuthUser::system_admins"])
    browser.header("Referer", nil)
    expect(approval.status).to eq(200)
    expect(File).to exist(@approvals_path)
    expect(File.read(@approvals_path)).not_to include("root_admin@example.com")

    # 4. That automatic rerun succeeds with provenance and Test As ready.
    # No config.principal_label is configured (not part of the minimum
    # recipe), so Karst's own evidence labels the principal "Model #id"
    # rather than by email -- unlike the Devise golden path, which gets a
    # recognizable email label for free from Devise's own declared
    # authentication_keys (see docs/advanced-configuration.md).
    expect(approval.body).to include("Verified usable user", "KarstRails8AuthUser ##{admin_user.id}",
                                     "population=system_admins", "Test as")

    # 5. Test As: a real browser session, through the real host middleware
    # and the real Authentication concern's signed cookie.
    sweep = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/reports/1")
    token = csrf_token(sweep.body)
    expect(token).not_to be_nil
    browser.header("Accept", "application/json")
    browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: "KarstRails8AuthUser",
                           principal_id: admin_user.id, path: "/reports/1")
    expect(browser.last_response.status).to eq(200)
    expect(JSON.parse(browser.last_response.body)).to eq("location" => "/reports/1")

    tested_page = browser.get("/reports/1")
    expect(tested_page.status).to eq(200)
    expect(tested_page.body).to eq("report 1 for root_admin@example.com")

    # 6. Stop Testing As from a plain /karst visit (no ?path= query string).
    browser.header("Accept", nil)
    plain_panel = browser.get("/karst")
    expect(plain_panel.body).to include("Currently testing as an assumed user.")
    stop_token = csrf_token(plain_panel.body)

    stop_response = browser.post("/karst", operation: "stop_test_as", csrf_token: stop_token, path: "")
    expect(stop_response.status).to eq(303)

    after_stop = browser.get("/reports/1")
    expect(after_stop.status).to eq(302)
    expect(after_stop.headers["Location"]).to include("/session/new")

    # 7. No probe, approval, or Test-As/Stop-Testing-As round trip left any
    # residual write in the application's own database -- the Session row
    # Test As created is gone, along with everything else.
    expect(KarstRails8AuthUser.count).to eq(28)
    expect(KarstRails8AuthAdminGrant.count).to eq(1)
    expect(KarstRails8AuthSession.count).to eq(0)
  end

  it "observes, but never persists, the Session row assume_identity/clear_identity's own login/logout " \
     "create -- rolled back inside Access::Sweep's same-connection transaction along with everything else" do
    configure_karst_for_rails8_auth!
    reachable = KarstRails8AuthUser.create!(email_address: "reachable@example.com", password_digest: "x")
    KarstRails8AuthAdminGrant.create!(karst_rails8_auth_user: reachable)

    analysis = mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=access_sweep&method=GET&path=%2Freports%2F1"
    )

    expect(analysis.body).to include("Verified usable user", "KarstRails8AuthUser ##{reachable.id}")
    # The two writes are the probe login's Session#create! and logout's
    # Session#destroy -- not the (read-only) restricted route itself.
    expect(analysis.body).to include("2 database writes observed")
    expect(KarstRails8AuthSession.count).to eq(0)
  end
end
# rubocop:enable Metrics/BlockLength
