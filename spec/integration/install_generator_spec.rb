# frozen_string_literal: true

# A generator only needs Thor and Rails::Generators loaded, not a booted
# Rails::Application, so this spec exercises `karst:install` directly
# against a scratch directory. It still lives in spec/integration (rather
# than at the top level) so it runs, like every other file here, against
# the full Ruby 2.7 / Rails 6.1 compatibility floor as well as every other
# supported Rails version -- see CONTRIBUTING.md.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "stringio"
require "open3"
require "rbconfig"
# Rails 6.1 / Ruby 2.7 needs "logger" required before "active_support" is
# pulled in transitively -- see Karst::Subscription's own require ordering
# and ARCHITECTURE.md's "No scattered version checks" section.
require "logger"
require "rails/generators"
require_relative "../../lib/generators/karst/install/install_generator"

# rubocop:disable Metrics/BlockLength
RSpec.describe "karst:install generator" do
  let(:destination_root) { Dir.mktmpdir("karst-install-generator") }

  after { FileUtils.remove_entry(destination_root) }

  def seed_routes_file
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
      end
    RUBY
  end

  def run_generator
    generator = Karst::Generators::InstallGenerator.new([], {}, destination_root: destination_root)
    original_stdout = $stdout
    $stdout = StringIO.new
    generator.invoke_all
    $stdout.string
  ensure
    $stdout = original_stdout
  end

  def read(relative_path)
    File.read(File.join(destination_root, relative_path))
  end

  def generated_file?(relative_path)
    File.exist?(File.join(destination_root, relative_path))
  end

  it "resolves to the conventional bin/rails generate karst:install namespace" do
    expect(Karst::Generators::InstallGenerator.namespace).to eq("karst:install")
  end

  it "creates the initializer and the development-only identity controller" do
    seed_routes_file
    run_generator

    expect(generated_file?("config/initializers/karst.rb")).to be(true)
    expect(generated_file?("app/controllers/karst_identity_controller.rb")).to be(true)
  end

  describe "the generated initializer" do
    before do
      seed_routes_file
      run_generator
    end

    it "documents every required hook as a placeholder" do
      content = read("config/initializers/karst.rb")

      expect(content).to include("Karst.configure do |config|")
      %w[principals assume_identity clear_identity assume_browser_identity
         clear_browser_identity].each do |hook|
        expect(content).to include("config.#{hook}")
      end
    end

    it "leaves every hook commented out instead of active by default" do
      content = read("config/initializers/karst.rb")
      active_lines = content.lines.reject { |line| line.strip.start_with?("#") || line.strip.empty? }

      expect(active_lines.join).to eq("Karst.configure do |config|\nend\n")
    end

    it "promotes populations without generating legacy dimension setup" do
      content = read("config/initializers/karst.rb")

      expect(content).to include("config.principal_populations")
      expect(content).not_to include("config.principal_dimensions")
      expect(content).not_to include("dimensions:")
    end

    it "does not assume a host-specific session key" do
      content = read("config/initializers/karst.rb")

      expect(content).not_to include("session_token")
    end
  end

  describe "the generated identity controller" do
    before do
      seed_routes_file
      run_generator
    end

    it "is explicitly named and documents why the probe session needs it" do
      content = read("app/controllers/karst_identity_controller.rb")

      expect(content).to include("class KarstIdentityController < ApplicationController")
      expect(content).to include("skip_before_action :verify_authenticity_token, raise: false")
      expect(content).to include("TODO")
    end

    def not_configured_raise(action)
      format(
        'raise NotImplementedError, "KarstIdentityController#%<action>s has not been configured for this ' \
        'application yet"', action: action
      )
    end

    def executable_lines(body)
      body.lines.map(&:strip).reject { |line| line.start_with?("#") || line.empty? }
    end

    it "raises instead of silently implementing a fake generic authentication mechanism" do
      content = read("app/controllers/karst_identity_controller.rb")

      destroy_body = content[/def destroy\n(.*?)\n  end/m, 1]
      expect(executable_lines(destroy_body)).to eq([not_configured_raise("destroy")])

      create_body = content[/def create\n(.*?)\n  end/m, 1]
      expect(executable_lines(create_body)).to eq(
        [
          "principal = resolve_principal",
          "return head(:forbidden) unless principal",
          not_configured_raise("create")
        ]
      )
    end

    it "resolves the submitted principal strictly through Karst::Identity.resolve, never Model.find" do
      content = read("app/controllers/karst_identity_controller.rb")
      # Executable (non-comment) lines only: the surrounding documentation
      # is allowed, and expected, to name the unsafe pattern in prose while
      # warning against it -- only real code is checked here.
      code_lines = content.lines.reject { |line| line.strip.start_with?("#") || line.strip.empty? }.join

      expect(code_lines).to include(
        "Karst::Identity.resolve(model_name: params[:principal_type], id: params[:principal_id])"
      )
      expect(code_lines).not_to match(/\.find\(params\[:principal_id\]\)/)
      expect(code_lines).not_to include("constantize")
    end
  end

  describe "development-only routes" do
    it "wraps the routes in a Rails.env.development? guard, matching the documented shape" do
      seed_routes_file
      run_generator

      routes = read("config/routes.rb")
      expect(routes).to include("if Rails.env.development?")
      expect(routes).to include('post   "/karst_test_login",  to: "karst_identity#create"')
      expect(routes).to include('delete "/karst_test_logout", to: "karst_identity#destroy"')
    end
  end

  describe "running the generator twice" do
    before do
      seed_routes_file
      run_generator
    end

    it "does not duplicate routes or corrupt already-generated files" do
      first_run_routes = read("config/routes.rb")
      first_run_initializer = read("config/initializers/karst.rb")
      first_run_controller = read("app/controllers/karst_identity_controller.rb")

      expect { run_generator }.not_to raise_error

      second_run_routes = read("config/routes.rb")
      expect(second_run_routes).to eq(first_run_routes)
      # A real regression check on the development route block itself, not
      # just a byte-for-byte diff: neither the guard nor either route line
      # is duplicated by a second run.
      expect(second_run_routes.scan("if Rails.env.development?").size).to eq(1)
      expect(second_run_routes.scan("karst_test_login").size).to eq(1)
      expect(second_run_routes.scan("karst_test_logout").size).to eq(1)
      expect(read("config/initializers/karst.rb")).to eq(first_run_initializer)
      expect(read("app/controllers/karst_identity_controller.rb")).to eq(first_run_controller)
    end

    it "still runs a third time without further change (not merely once-repeatable)" do
      run_generator
      stable_routes = read("config/routes.rb")

      run_generator

      expect(read("config/routes.rb")).to eq(stable_routes)
      expect(read("config/routes.rb").scan("karst_test_login").size).to eq(1)
    end
  end

  describe "the generated controller's principal resolution, exercised at runtime" do
    # This boots a real, minimal Rails::Application in a fresh process and
    # requires the exact controller file the generator wrote to disk --
    # proving the generated resolve_principal helper actually enforces
    # config.principals, not merely that its source text looks right.
    it "accepts only a principal already yielded by config.principals" do
      seed_routes_file
      run_generator
      controller_path = File.join(destination_root, "app/controllers/karst_identity_controller.rb")

      script = <<~RUBY
        require "logger"
        require "rails"
        require "action_controller/railtie"
        require "karst"

        class KarstInstallRuntimeApplication < Rails::Application
          config.eager_load = false
          config.logger = Logger.new(nil)
          config.secret_key_base = "karst-install-generator-runtime-secret"
          config.hosts.clear if config.respond_to?(:hosts)
        end

        class ApplicationController < ActionController::Base
        end

        require #{controller_path.inspect}

        RuntimePrincipal = Struct.new(:id)
        allowed = [RuntimePrincipal.new(1), RuntimePrincipal.new(2)]
        Karst.configure { |config| config.principals = -> { allowed } }

        KarstInstallRuntimeApplication.initialize!
        KarstInstallRuntimeApplication.routes.draw do
          post "/karst_test_login", to: "karst_identity#create"
        end

        session = ActionDispatch::Integration::Session.new(KarstInstallRuntimeApplication)

        session.post("/karst_test_login", params: { principal_type: "RuntimePrincipal", principal_id: 1 })
        unless session.response.status == 500
          abort "in-scope principal did not reach the generated TODO (500): got \#{session.response.status}"
        end

        session.post("/karst_test_login", params: { principal_type: "RuntimePrincipal", principal_id: 999 })
        unless session.response.status == 403
          abort "an id outside config.principals was not rejected: got \#{session.response.status}"
        end

        session.post("/karst_test_login", params: { principal_type: "SomethingElse", principal_id: 1 })
        unless session.response.status == 403
          abort "a mismatched principal_type was not rejected: got \#{session.response.status}"
        end
      RUBY

      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test" },
        RbConfig.ruby,
        "-I#{File.expand_path('../../lib', __dir__)}",
        "-e",
        script
      )

      expect(status).to be_success, output
    end
  end

  it "prints post-install next steps without claiming installation is already complete" do
    seed_routes_file
    output = run_generator

    expect(output).to include("Karst installed.")
    expect(output).to include("config/initializers/karst.rb")
    expect(output).to include("app/controllers/karst_identity_controller.rb")
    expect(output).to include("TODOs")
  end
end
# rubocop:enable Metrics/BlockLength
