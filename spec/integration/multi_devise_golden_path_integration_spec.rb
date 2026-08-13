# frozen_string_literal: true

require "spec_helper"
require "json"
require "rack/mock"
require "rack/test"
require_relative "../support/multi_devise_application"
require "karst/web/middleware"
require "karst/cli/verification"

# The multi-model counterpart to
# spec/integration/devise_golden_path_integration_spec.rb: two genuine Devise
# mappings (KarstMultiUser, KarstMultiAdmin), the real `devise` and `warden`
# gems, no Karst initializer, no config.principals/config.principal_sources,
# and no principal-source selection file at boot. Nothing here stubs
# Devise.mappings, Warden::Manager, Access::Search, Access::Sweep, or
# Karst::Identity -- only Karst's own local-state files (see spec_helper.rb's
# process-wide isolation for both) are ever pointed at a temp directory.
#
# Run in its own rspec process (see bin/test-rails and
# .github/workflows/ci.yml): a second real-Devise Rails::Application boot in
# the same process as spec/support/devise_application.rb's
# KarstDeviseApplication is unsafe, for the same reason those two already
# never share a process.
# rubocop:disable Metrics/BlockLength
RSpec.describe "multi-Devise golden path, real gems, no Karst configuration" do
  around do |example|
    Dir.mktmpdir("karst-multi-devise-golden-path") do |dir|
      @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
      @selection_path = File.join(dir, "tmp/karst/principal_source_selection.json")
      example.run
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
    allow(Karst::Access::PrincipalSourceSelection).to receive(:path).and_return(@selection_path)
    KarstMultiUser.delete_all
    KarstMultiAdmin.delete_all
    Karst.config.access_sweep_limit = 25
  end

  after { Karst.config.access_sweep_limit = 25 }

  def stack
    KarstMultiDeviseApplication
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

  def select_sources(*model_names)
    input = URI.encode_www_form(
      [%w[operation select_principal_sources], *model_names.map { |name| ["principal[]", name] }]
    )
    mock.post("/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                        "HTTP_ORIGIN" => "http://example.org", input: input)
  end

  def access_sweep_response(path)
    mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=access_sweep&method=GET&path=#{CGI.escape(path)}"
    )
  end

  def user!(**attrs)
    KarstMultiUser.create!(email: "#{SecureRandom.hex(6)}@example.com", password: "password123!", **attrs)
  end

  def admin!(**attrs)
    KarstMultiAdmin.create!(email: "#{SecureRandom.hex(6)}@example.com", password: "password123!", **attrs)
  end

  it "detects ambiguity immediately at /karst, offering both real Devise models with no route selected" do
    response = mock.get("/karst", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(Karst::Identity.setup_state.status).to eq(:ambiguous)
    expect(response.body).to include("Karst found 2 user types")
    expect(response.body).to include('value="KarstMultiAdmin"', 'value="KarstMultiUser"')
    expect(response.body).not_to include(" checked")
  end

  it "saves a local User-only selection, persisted with no Ruby configuration, and analyzes only Users " \
     "under the correct :karst_multi_user Warden scope, end to end through Test As and Stop Testing As" do
    save = select_sources("KarstMultiUser")
    expect(save.body).to include("Selection saved.")
    expect(JSON.parse(File.read(@selection_path))["selected"]).to eq(["KarstMultiUser"])
    expect(Karst::Identity.principal_sources.keys).to eq([:karst_multi_user])

    reachable_user = user!
    2.times { user! }
    3.times { admin! }

    analysis = access_sweep_response("/karst_multi_secrets/1")
    expect(analysis.body).to include("Verified usable user")
    expect(analysis.body).to include("3 users tested")
    expect(analysis.body).not_to include("KarstMultiAdmin")

    sweep = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/karst_multi_secrets/1")
    token = csrf_token(sweep.body)
    browser.header("Accept", "application/json")
    browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: "KarstMultiUser",
                           principal_id: reachable_user.id, path: "/karst_multi_secrets/1")
    expect(browser.last_response.status).to eq(200)

    tested_page = browser.get("/karst_multi_secrets/1")
    expect(tested_page.status).to eq(200)
    expect(tested_page.body).to eq("user secret 1")

    browser.header("Accept", nil)
    plain_panel = browser.get("/karst")
    expect(plain_panel.body).to include("Currently testing as an assumed user.")
    stop_token = csrf_token(plain_panel.body)
    stop_response = browser.post("/karst", operation: "stop_test_as", csrf_token: stop_token, path: "")
    expect(stop_response.status).to eq(303)

    after_stop = browser.get("/karst_multi_secrets/1")
    expect(after_stop.status).to eq(302)
    expect(after_stop.headers["Location"]).to include("/karst_multi_users/sign_in")
  end

  it "switches the local selection to Admin only, testing Admins under :karst_multi_admin and no longer " \
     "touching any User" do
    select_sources("KarstMultiUser")
    reachable_admin = admin!
    2.times { admin! }
    5.times { user! }

    switch = select_sources("KarstMultiAdmin")
    expect(switch.body).to include("Selection saved.")
    expect(Karst::Identity.principal_sources.keys).to eq([:karst_multi_admin])

    analysis = access_sweep_response("/karst_multi_admin_secrets/1")
    expect(analysis.body).to include("Verified usable user")
    expect(analysis.body).to include("3 users tested")
    expect(analysis.body).not_to include("KarstMultiUser")

    sweep = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/karst_multi_admin_secrets/1")
    token = csrf_token(sweep.body)
    browser.header("Accept", "application/json")
    browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: "KarstMultiAdmin",
                           principal_id: reachable_admin.id, path: "/karst_multi_admin_secrets/1")
    expect(browser.last_response.status).to eq(200)
    tested_page = browser.get("/karst_multi_admin_secrets/1")
    expect(tested_page.status).to eq(200)
    expect(tested_page.body).to eq("admin secret 1")
  end

  it "selecting both models keeps them as two independently queryable sources -- never conflating a " \
     "User and an Admin that share the same numeric id -- keeps the overall sweep limit global rather " \
     "than multiplying per model, and authenticates every probed principal under its own Devise/Warden " \
     "scope" do
    select_sources("KarstMultiUser", "KarstMultiAdmin")

    matched_user = user!
    matched_admin = KarstMultiAdmin.create!(id: matched_user.id, email: "shared-id-admin@example.com",
                                            password: "password123!")

    sources = Karst::Identity.principal_sources
    expect(sources.keys).to contain_exactly(:karst_multi_user, :karst_multi_admin)
    expect(sources[:karst_multi_user].record_klass).to eq(KarstMultiUser)
    expect(sources[:karst_multi_admin].record_klass).to eq(KarstMultiAdmin)

    resolved_user = Karst::Identity.resolve(model_name: "KarstMultiUser", id: matched_user.id)
    resolved_admin = Karst::Identity.resolve(model_name: "KarstMultiAdmin", id: matched_user.id)
    expect(resolved_user).to eq(matched_user)
    expect(resolved_admin).to eq(matched_admin)
    expect(resolved_user.id).to eq(resolved_admin.id)

    # A route that requires the Admin scope: probing the User half of the
    # same numeric id must authenticate it under its own :karst_multi_user
    # scope (a real, successful Devise sign-in) and still be refused here,
    # never mistaken for the Admin with the same id -- while the Admin half
    # succeeds under its own :karst_multi_admin scope.
    result = Karst::Access::Sweep.new(path: "/karst_multi_admin_secrets/#{matched_admin.id}",
                                      principals: [matched_user, matched_admin],
                                      application: KarstMultiDeviseApplication).call

    user_outcome = result.outcomes.find { |o| o.principal.model_name == "KarstMultiUser" }
    admin_outcome = result.outcomes.find { |o| o.principal.model_name == "KarstMultiAdmin" }
    expect(user_outcome.status).to eq(302)
    expect(user_outcome.redirect).to include("/karst_multi_admins/sign_in")
    expect(admin_outcome.status).to eq(200)

    # The global access_sweep_limit is not multiplied per selected model: a
    # limit of 4 with both sources selected still tests 4 principals total,
    # not 4 from each -- see the identical assertion in
    # spec/access/multi_principal_source_spec.rb for the underlying
    # PrincipalSelection unit behavior this exercises end to end.
    Karst.config.access_sweep_limit = 4
    9.times { user! }
    9.times { admin! }
    sweep = access_sweep_response("/karst_multi_admin_secrets/#{matched_admin.id}")
    expect(sweep.body).to include("4 initial · 0 candidate population · 4 total")
  end

  it "drops a stale stored model selection the moment Devise no longer maps it, never constantizing the " \
     "stored name" do
    select_sources("KarstMultiUser", "KarstMultiAdmin")
    expect(Karst::Identity.principal_sources.keys).to contain_exactly(:karst_multi_user, :karst_multi_admin)

    removed = Devise.mappings.delete(:karst_multi_admin)
    begin
      expect(Karst::Access::SelectedPrincipalSources.mappings.map { |m| m.model.name }).to eq(["KarstMultiUser"])
      # Only one real Devise mapping remains, so Karst falls back to plain
      # automatic single-model inference rather than trusting the now-stale
      # two-model selection: KarstMultiAdmin is dropped and never
      # constantized, and the survivor is still exactly KarstMultiUser under
      # its own scope (the effective source key becoming :default rather
      # than :karst_multi_user is cosmetic -- see Configuration#principal_sources).
      sources = Karst::Identity.principal_sources
      expect(sources.values.map(&:record_klass)).to eq([KarstMultiUser])
      expect(Karst::Identity.setup_state.status).not_to eq(:ambiguous)
    ensure
      Devise.mappings[:karst_multi_admin] = removed
    end

    expect(Karst::Identity.principal_sources.keys).to contain_exactly(:karst_multi_user, :karst_multi_admin)
  end

  it "never selects a name Devise has no mapping for at all, even when the file holds a real constant" do
    Karst::Access::PrincipalSourceSelection.replace(["Object"])

    expect(Karst::Identity.setup_state.status).to eq(:ambiguous)
    expect(Karst::Access::SelectedPrincipalSources.mappings).to eq([])
  end

  it "lets explicit config.principals override a saved local selection" do
    select_sources("KarstMultiUser", "KarstMultiAdmin")
    only_user = user!
    Karst.config.principals = -> { KarstMultiUser.where(id: only_user.id) }

    expect(Karst::Identity.principal_sources.keys).to eq([:default])
    expect(Karst::Identity.principal_sources[:default].record_klass).to eq(KarstMultiUser)
  ensure
    Karst.config.principals = nil
  end

  it "lets explicit config.principal_sources override a saved local selection" do
    select_sources("KarstMultiUser", "KarstMultiAdmin")
    Karst.config.principal_sources = { explicit: -> { KarstMultiUser.all } }

    expect(Karst::Identity.principal_sources.keys).to eq([:explicit])
  ensure
    Karst.config.principal_sources = nil
  end

  describe "bin/rails karst:verify against this same host, through Karst::CLI::Verification" do
    def cli_evidence(path)
      Karst::CLI::Verification.new(path: path).evidence
    end

    it "produces an actionable setup error, exit code 2, when no source is selected" do
      output = StringIO.new
      exit_code = Karst::CLI::Verification.new(path: "/karst_multi_secrets/1", output: output).call

      expect(exit_code).to eq(2)
      expect(output.string).to include("Karst detected multiple Devise models")
      expect(cli_evidence("/karst_multi_secrets/1")[:error][:type]).to eq("configuration_error")
    end

    it "refuses to execute when config.enabled is false, the same off switch /karst and MCP honor" do
      select_sources("KarstMultiUser")
      user!
      Karst.config.enabled = false

      output = StringIO.new
      exit_code = Karst::CLI::Verification.new(path: "/karst_multi_secrets/1", output: output).call

      expect(exit_code).to eq(2)
      expect(output.string).to match(/disabled/)
      expect(cli_evidence("/karst_multi_secrets/1")[:error][:message]).to match(/disabled/)
    ensure
      Karst.config.enabled = true
    end

    it "uses the User source once User is selected, matching the panel's own evidence" do
      select_sources("KarstMultiUser")
      3.times { user! }

      document = cli_evidence("/karst_multi_secrets/1")

      expect(document[:verified_usable]).to be(true)
      expect(document[:verified_principal][:model]).to eq("KarstMultiUser")
      expect(document[:sample][:users_tested]).to eq(3)
    end

    it "uses the Admin source once Admin is selected" do
      select_sources("KarstMultiAdmin")
      2.times { admin! }

      document = cli_evidence("/karst_multi_admin_secrets/1")

      expect(document[:verified_usable]).to be(true)
      expect(document[:verified_principal][:model]).to eq("KarstMultiAdmin")
    end

    it "bounds a multi-source search to the same global access_sweep_limit when both are selected" do
      Karst.config.access_sweep_limit = 5
      select_sources("KarstMultiUser", "KarstMultiAdmin")
      4.times { user! }
      4.times { admin! }

      document = cli_evidence("/karst_multi_admin_secrets/1")

      expect(document[:sample][:users_tested]).to eq(5)
      tested_models = document[:sample][:outcomes].flat_map { |o| o[:principals] }.map { |p| p[:model] }.uniq
      expect(tested_models).to contain_exactly("KarstMultiUser", "KarstMultiAdmin")
    end

    it "finds an admin only reachable through an approved candidate population, for the selected model" do
      select_sources("KarstMultiAdmin")
      rare_admin = admin!
      KarstMultiSuperGrant.create!(karst_multi_admin: rare_admin)
      27.times { admin! }
      Karst::Access::PopulationApprovals.replace(
        [Karst::Access::PopulationApprovals::Entry.new(model_name: "KarstMultiAdmin", method_name: "super_admins")]
      )
      Karst.config.access_sweep_limit = 3

      document = cli_evidence("/karst_multi_super_secrets/#{rare_admin.id}")

      expect(document[:source]).to eq(type: :population, name: :super_admins)
      expect(document[:verified_principal]).to eq(model: "KarstMultiAdmin", id: rare_admin.id,
                                                  label: "KarstMultiAdmin ##{rare_admin.id}")
    ensure
      Karst.config.access_sweep_limit = 25
    end

    it "never lets an inferred login identifier leak into the JSON evidence" do
      select_sources("KarstMultiUser")
      reachable = user!(email: "should-not-leak@example.com")

      document = cli_evidence("/karst_multi_secrets/1")

      expect(JSON.generate(document)).not_to include("should-not-leak@example.com")
      expect(document[:verified_principal][:label]).to eq("KarstMultiUser ##{reachable.id}")
    end
  end
end
# rubocop:enable Metrics/BlockLength
