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

    it "raises instead of silently implementing a fake generic authentication mechanism" do
      content = read("app/controllers/karst_identity_controller.rb")

      %w[create destroy].each do |action|
        body = content[/def #{action}\n(.*?)\n  end/m, 1]
        executable_lines = body.lines.map(&:strip).reject { |line| line.start_with?("#") || line.empty? }

        expected = format(
          'raise NotImplementedError, "KarstIdentityController#%<action>s has not been configured for this ' \
          'application yet"', action: action
        )
        expect(executable_lines).to eq([expected])
      end
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

      expect(read("config/routes.rb")).to eq(first_run_routes)
      expect(read("config/routes.rb").scan("karst_test_login").size).to eq(1)
      expect(read("config/initializers/karst.rb")).to eq(first_run_initializer)
      expect(read("app/controllers/karst_identity_controller.rb")).to eq(first_run_controller)
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
