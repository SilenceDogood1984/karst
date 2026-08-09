# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Observer to Catalog contract" do
  # Two independent subprocesses, mirroring how these two layers are actually
  # used: one process runs a real RSpec suite with Karst::Spec::Observer
  # installed against a real Rails app and writes the artifact; a second,
  # completely separate process then reads that artifact through
  # Karst::Spec::Catalog alone. The second process never requires rspec,
  # rails, active_record, or the observer -- proving Catalog's own claim that
  # reading an already-written artifact needs none of them.
  def fixture_suite_source
    <<~RUBY
      RSpec.describe "Catalog contract fixture" do
        include Rack::Test::Methods
        include ScenarioApplication.routes.url_helpers

        def app = ScenarioApplication

        it "denies admin access when signed out" do
          get admin_path
          expect(last_response.status).to eq(302)
        end

        it "denies a non-admin, then allows after switching to an admin principal" do
          post sign_in_path, "email" => "author@example.com", "password" => "secret"
          get admin_path
          expect(last_response).to be_redirect
          delete sign_out_path
          post sign_in_path, "email" => "admin@example.com", "password" => "secret"
          get admin_path
          expect(last_response.status).to eq(200)
        end

        it "exercises a dynamic route with id 1" do
          get thing_path(1)
          expect(last_response.status).to eq(200)
        end

        it "exercises a dynamic route with id 2" do
          get thing_path(2)
          expect(last_response.status).to eq(200)
        end
      end
    RUBY
  end

  # rubocop:disable Metrics/MethodLength
  def run_fixture_suite(output_path)
    harness = File.expand_path("../support/scenario_application", __dir__)

    script = <<~RUBY
      require "rspec/core"
      require #{harness.inspect}
      require "rack/test"

      Karst::Spec::Observer.install!(output: #{output_path.inspect})

      #{fixture_suite_source}

      exit(RSpec::Core::Runner.run([], $stderr, $stdout))
    RUBY

    Open3.capture2e(
      { "RAILS_ENV" => "test" },
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      script
    )
  end
  # rubocop:enable Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength
  def run_catalog_reader(output_path)
    script = <<~RUBY
      require "karst/spec/catalog"

      abort "RSpec should not be required to read the catalog" if defined?(RSpec)
      abort "Rails should not be required to read the catalog" if defined?(Rails)
      abort "ActiveRecord should not be required to read the catalog" if defined?(ActiveRecord)

      catalog = Karst::Spec::Catalog.load(path: #{output_path.inspect})
      abort "expected :ready, got \#{catalog.status.inspect}: \#{catalog.error}" unless catalog.status == :ready

      admin = catalog.scenarios_for(controller: "ScenarioAdminController", action: "show")
      abort "expected 3 admin scenarios, got \#{admin.size}" unless admin.size == 3
      abort "unexpected admin statuses: \#{admin.map(&:observed_status)}" unless admin.map(&:observed_status) == [302, 302, 200]
      abort "unexpected admin principal_before: \#{admin.map { |s| s.principal_before&.id }}" unless admin.map { |s| s.principal_before&.id } == [nil, 1, 2]
      abort "unexpected admin principal_after: \#{admin.map { |s| s.principal_after&.id }}" unless admin.map { |s| s.principal_after&.id } == [nil, 1, 2]
      abort "unexpected outcomes: \#{admin.map(&:example_outcome)}" unless admin.all? { |s| s.example_outcome == :passed }
      abort "unexpected admin names: \#{admin.map(&:name)}" unless admin.map(&:name) == [
        "denies admin access when signed out",
        "denies a non-admin, then allows after switching to an admin principal",
        "denies a non-admin, then allows after switching to an admin principal"
      ]

      things = catalog.scenarios_for(controller: "ScenarioThingsController", action: "show")
      abort "expected 2 dynamic-route scenarios, got \#{things.size}" unless things.size == 2
      abort "expected distinct observed paths" unless things.map(&:observed_path) == ["/things/1", "/things/2"]
      abort "expected one shared route pattern" unless things.map(&:route_pattern).uniq == ["/things/:id(.:format)"]

      puts "OK"
    RUBY

    Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script)
  end
  # rubocop:enable Metrics/MethodLength

  it "loads scenarios written by a real Observer run, through Catalog alone, with no RSpec/Rails/ActiveRecord loaded" do
    output_path = File.join(Dir.mktmpdir("karst-catalog-contract"), "scenarios.json")

    suite_output, suite_status = run_fixture_suite(output_path)
    raise "fixture suite failed:\n#{suite_output}" unless suite_status.success?

    reader_output, reader_status = run_catalog_reader(output_path)
    expect(reader_status).to be_success, reader_output
    expect(reader_output).to include("OK")
  end
end

# rubocop:enable Metrics/BlockLength
