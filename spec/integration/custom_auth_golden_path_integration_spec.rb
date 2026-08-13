# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "stringio"
require "rack/mock"
require "rack/test"
# Rails 6.1 / Ruby 2.7 needs "logger" required before "active_support" is
# pulled in transitively -- see lib/karst.rb's own require ordering and
# spec/integration/install_generator_spec.rb, which needs the identical fix
# for the identical reason (both require "rails/generators").
require "logger"
require "rails/generators"
require_relative "../../lib/generators/karst/install/install_generator"
require_relative "../support/custom_auth_application"
require "karst/web/middleware"

# The third supported identity story, proven the same way PR #59 proved the
# first (spec/integration/devise_golden_path_integration_spec.rb): a real
# Rails::Application, real Web::Middleware, a real browser session -- here
# with ordinary custom `session[:account_id]` authentication and no Devise
# at all. Nothing here stubs Access::Search, Access::Sweep, or
# Karst::Identity.
# rubocop:disable Metrics/BlockLength
RSpec.describe "custom (non-Devise) authentication golden path, real gems" do
  around do |example|
    Dir.mktmpdir("karst-custom-auth-golden-path") do |dir|
      @approvals_path = File.join(dir, "tmp/karst/approved_populations.json")
      @selection_path = File.join(dir, "tmp/karst/principal_source_selection.json")
      example.run
    end
  end

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(Karst::Access::PopulationApprovals).to receive(:path).and_return(@approvals_path)
    allow(Karst::Access::PrincipalSourceSelection).to receive(:path).and_return(@selection_path)
    KarstCustomAuthAccount.delete_all
  end

  after do
    Karst.config.principals = nil
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
    Karst.config.assume_browser_identity = nil
    Karst.config.clear_browser_identity = nil
  end

  def stack
    KarstCustomAuthApplication
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

  def access_sweep_response(path)
    mock.post(
      "/karst", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
                input: "operation=access_sweep&method=GET&path=#{CGI.escape(path)}"
    )
  end

  it "explains, with no Karst configuration at all, that automatic authentication cannot be determined, " \
     "and points to the custom-authentication escape hatch" do
    response = mock.get("/karst", "REMOTE_ADDR" => "127.0.0.1")

    expect(response.status).to eq(200)
    expect(Karst::Identity.setup_state.status).to eq(:unavailable)
    expect(response.body).to include("Karst couldn't determine how this app authenticates users")
    expect(response.body).to include("Set up custom authentication")
  end

  it "runs the real karst:install generator against this host, producing a compact, development-only, " \
     "idempotent scaffold" do
    destination_root = Dir.mktmpdir("karst-custom-auth-generator")
    begin
      FileUtils.mkdir_p(File.join(destination_root, "config"))
      File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

      run_generator = lambda do
        original_stdout = $stdout
        $stdout = StringIO.new
        Karst::Generators::InstallGenerator.new([], {}, destination_root: destination_root).invoke_all
      ensure
        $stdout = original_stdout
      end
      run_generator.call
      first_run_routes = File.read(File.join(destination_root, "config/routes.rb"))
      run_generator.call # idempotency: a second real run must change nothing

      initializer = File.read(File.join(destination_root, "config/initializers/karst.rb"))
      controller = File.read(File.join(destination_root, "app/controllers/karst_identity_controller.rb"))
      routes = File.read(File.join(destination_root, "config/routes.rb"))

      expect(initializer.lines.size).to be < 30
      expect(controller.lines.size).to be < 30
      expect(controller).to include("TODO")
      expect(routes).to eq(first_run_routes)
      expect(routes).to include("if Rails.env.development?")
      expect(routes.scan("if Rails.env.development?").size).to eq(1)
    ensure
      FileUtils.remove_entry(destination_root)
    end
  end

  it "completing the generated TODOs with this host's real session[:account_id] semantics makes the " \
     "full /karst journey work end to end -- analysis establishes a real identity in the isolated probe " \
     "request, Test As and Stop Testing As work in a real browser session, every probe database write " \
     "is rolled back, and no password or token is ever passed to Karst" do
    # Exactly the shape docs/advanced-configuration.md and the generated
    # karst.rb initializer document -- the "developer completed the TODOs"
    # step of the acceptance journey.
    Karst.config.principals = -> { KarstCustomAuthAccount.active }
    Karst.config.assume_identity = lambda do |session, principal|
      descriptor = Karst::Identity.describe(principal)
      session.post "/karst_test_login", params: { principal_type: descriptor.model_name, principal_id: descriptor.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/karst_test_logout" }
    Karst.config.assume_browser_identity = ->(request, principal) { request.session[:account_id] = principal.id }
    Karst.config.clear_browser_identity = ->(request) { request.session.delete(:account_id) }

    expect(Karst::Identity.setup_state.status).to eq(:ready_explicit)

    reachable = KarstCustomAuthAccount.create!(email: "reachable@example.com", active: true)
    2.times { |i| KarstCustomAuthAccount.create!(email: "user#{i}@example.com", active: true) }

    analysis = access_sweep_response("/secrets/1")
    expect(analysis.body).to include("Verified usable user", "KarstCustomAuthAccount ##{reachable.id}")
    expect(analysis.body).to include("Database writes observed: 0")

    sweep = browser.post("/karst", operation: "access_sweep", method: "GET", path: "/secrets/1")
    token = csrf_token(sweep.body)
    browser.header("Accept", "application/json")
    browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: "KarstCustomAuthAccount",
                           principal_id: reachable.id, path: "/secrets/1")
    expect(browser.last_response.status).to eq(200)

    tested_page = browser.get("/secrets/1")
    expect(tested_page.status).to eq(200)
    expect(tested_page.body).to include("reachable@example.com")

    browser.header("Accept", nil)
    plain_panel = browser.get("/karst")
    expect(plain_panel.body).to include("Currently testing as an assumed user.")
    stop_token = csrf_token(plain_panel.body)
    stop_response = browser.post("/karst", operation: "stop_test_as", csrf_token: stop_token, path: "")
    expect(stop_response.status).to eq(303)

    after_stop = browser.get("/secrets/1")
    expect(after_stop.status).to eq(401)

    # No probe or Test-As/Stop-Testing-As round trip left a residual write.
    expect(KarstCustomAuthAccount.count).to eq(3)
  end

  it "never passes a password or token to Karst -- Test As resolves strictly through an id, exactly like " \
     "the generated controller's own resolve_principal boundary" do
    Karst.config.principals = -> { KarstCustomAuthAccount.active }
    account = KarstCustomAuthAccount.create!(email: "resolved@example.com", active: true)

    resolved = Karst::Identity.resolve(model_name: "KarstCustomAuthAccount", id: account.id)

    expect(resolved).to eq(account)
    expect(resolved).not_to respond_to(:password)
  end
end
# rubocop:enable Metrics/BlockLength
