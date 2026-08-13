# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "rack/mock"
require "rack/test"
require_relative "../support/devise_application"
require "karst/web/middleware"
require "karst/cli/verification"

# The single most important product test in this suite: a conventional
# Devise application, with the real `devise` and `warden` gems (not the
# `stub_const("Devise", ...)` / `stub_const("Warden::Manager", ...)` doubles
# every other spec file uses), no Karst initializer, no Karst-authored
# routes or controller -- exactly what "gem install, boot, open /karst"
# promises. This is what caught every defect Access::ProbeApplication and
# Karst::Identity::WardenAdapter shipped with: nothing here mocks
# Access::Search, Access::Sweep, or identity resolution.
# rubocop:disable Metrics/BlockLength
RSpec.describe "Devise/Warden golden path, real gems, no Karst configuration" do
  around do |example|
    Dir.mktmpdir("karst-devise-golden-path") do |dir|
      @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
      example.run
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
    KarstDeviseAdminGrant.delete_all
    KarstDeviseUser.delete_all
  end

  def stack
    KarstDeviseApplication
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

  it "identifies the sole Devise model with no configuration at all" do
    response = mock.get("/karst", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(Karst::Identity.setup_state.status).to eq(:ready_automatic)
    expect(Karst::Identity.principal_sources.keys).to eq([:default])
    expect(Karst::Identity.principal_sources[:default].record_klass).to eq(KarstDeviseUser)
  end

  it "runs the real ordinary sample through the real Warden middleware, finds nothing usable, " \
     "discovers system_admins, and the developer approves + reruns + Test As + Stop Testing As -- " \
     "with zero persisted writes throughout" do
    # The admin is created *first* and everyone else after: Access::Sweep's
    # ordinary sample draws from the most recently created principals, so
    # this is what keeps the admin out of it -- exactly what makes the
    # candidate-population path below the only way to reach them, the same
    # as a real rare user would be.
    admin_user = KarstDeviseUser.create!(email: "root_admin@example.com", password: "password123!")
    KarstDeviseAdminGrant.create!(karst_devise_user: admin_user)
    27.times { |i| KarstDeviseUser.create!(email: "user#{i}@example.com", password: "password123!") }

    # 1. Ordinary sample: real Devise/Warden probes, all correctly
    # authenticated as themselves and correctly halted by the real
    # controller's own authorization check -- not
    # Karst::Identity::Unavailable, which is what every one of these
    # probes raised before Access::ProbeApplication wrapped a real
    # Warden::Manager into its own Rack stack.
    first = browser.post("/karst", operation: "access_sweep", method: "GET",
                                   path: "/karst_devise_imports/1")
    expect(first.status).to eq(200)
    expect(first.body).to include("No verified usable user found")
    expect(first.body).not_to include("Karst::Identity::Unavailable")
    expect(first.body).to include("403 Forbidden", "halted at authorize_admin")
    expect(first.body).to include("Database writes observed: 0")

    # 2. system_admins is discoverable (source parsed, never executed) but
    # not yet searched.
    expect(first.body).to include("Karst found application-defined user groups", "system_admins",
                                  "Approve selected and retry")
    expect(first.body).not_to include('href="/karst/populations"')

    # 3. Approve it locally -- no initializer edit or page navigation. The
    # same POST immediately reruns the same route analysis.
    browser.header("Referer", "http://example.org/karst")
    approval = browser.post("/karst", operation: "approve_populations", csrf_token: csrf_token(first.body),
                                      method: "GET", path: "/karst_devise_imports/1",
                                      population: ["default::KarstDeviseUser::system_admins"])
    browser.header("Referer", nil)
    expect(approval.status).to eq(200)
    expect(File).to exist(@approvals_path)
    expect(File.read(@approvals_path)).not_to include("root_admin@example.com")

    # 4. That automatic rerun succeeds with provenance and Test As ready.
    expect(approval.body).to include("Verified usable user", "root_admin@example.com",
                                     "population=system_admins", "Test as")

    # 5. Test As: a real browser session, through the real host middleware.
    sweep = browser.post("/karst", operation: "access_sweep", method: "GET",
                                   path: "/karst_devise_imports/1")
    token = csrf_token(sweep.body)
    expect(token).not_to be_nil
    browser.header("Accept", "application/json")
    browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: "KarstDeviseUser",
                           principal_id: admin_user.id, path: "/karst_devise_imports/1")
    expect(browser.last_response.status).to eq(200)
    expect(JSON.parse(browser.last_response.body)).to eq("location" => "/karst_devise_imports/1")

    tested_page = browser.get("/karst_devise_imports/1")
    expect(tested_page.status).to eq(200)
    expect(tested_page.body).to eq("import 1")

    # 6. Stop Testing As from a *plain* /karst visit (no ?path= query
    # string) -- exactly what a developer sees immediately after Test As
    # redirects them away, and exactly the case that used to raise (first a
    # 403, then a 500 NoMethodError) instead of clearing the identity.
    browser.header("Accept", nil)
    plain_panel = browser.get("/karst")
    expect(plain_panel.body).to include("Currently testing as an assumed user.")
    stop_token = csrf_token(plain_panel.body)

    stop_response = browser.post("/karst", operation: "stop_test_as", csrf_token: stop_token, path: "")
    expect(stop_response.status).to eq(303)

    after_stop = browser.get("/karst_devise_imports/1")
    expect(after_stop.status).to eq(302)
    expect(after_stop.headers["Location"]).to include("/karst_devise_users/sign_in")

    # 7. No probe, approval, or Test-As/Stop-Testing-As round trip left any
    # residual write in the application's own database.
    expect(KarstDeviseUser.count).to eq(28)
    expect(KarstDeviseAdminGrant.count).to eq(1)
  end

  it "enforces both same-origin and session CSRF checks on inline approval" do
    KarstDeviseUser.create!(email: "admin@example.com", password: "password123!")
    page = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/karst_devise_imports/1")
    token = csrf_token(page.body)
    params = { operation: "approve_populations", method: "GET", path: "/karst_devise_imports/1",
               population: ["default::KarstDeviseUser::system_admins"] }

    browser.header("Origin", "http://attacker.example")
    expect(browser.post("/karst", params.merge(csrf_token: token)).status).to eq(403)
    browser.header("Origin", "http://example.org")
    expect(browser.post("/karst", params.merge(csrf_token: "invalid")).status).to eq(403)
    expect(File).not_to exist(@approvals_path)
  ensure
    browser.header("Origin", nil)
  end

  it "matches CLI evidence to the panel's own result, with correct exit-code semantics and no PII in JSON" do
    admin_user = KarstDeviseUser.create!(email: "cli_admin@example.com", password: "password123!")
    KarstDeviseAdminGrant.create!(karst_devise_user: admin_user)
    26.times { |i| KarstDeviseUser.create!(email: "user#{i}@example.com", password: "password123!") }
    Karst::Access::PopulationApprovals.replace(
      [Karst::Access::PopulationApprovals::Entry.new(model_name: "KarstDeviseUser", method_name: "system_admins")]
    )

    output = StringIO.new
    exit_code = Karst::CLI::Verification.new(path: "/karst_devise_imports/1", output: output).call
    document = Karst::CLI::Verification.new(path: "/karst_devise_imports/1").evidence

    expect(exit_code).to eq(0)
    expect(document[:verified_usable]).to be(true)
    expect(document[:verified_principal]).to eq(model: "KarstDeviseUser", id: admin_user.id,
                                                label: "KarstDeviseUser ##{admin_user.id}")
    expect(document[:source]).to eq(type: :population, name: :system_admins)
    expect(JSON.generate(document)).not_to include("cli_admin@example.com")
  end

  def access_sweep_response
    mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=access_sweep&method=GET&path=%2Fkarst_devise_imports%2F1"
    )
  end
end
# rubocop:enable Metrics/BlockLength
