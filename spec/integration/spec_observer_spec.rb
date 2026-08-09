# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

require "spec_helper"
require "karst"
require "open3"
require "rbconfig"
require "json"
require "tmpdir"

RSpec.describe "Karst RSpec scenario observer" do
  # The fixture suite runs in its own subprocess (mirroring the existing
  # rails_boot_spec/web_middleware_spec pattern): it boots a real Rails
  # application with real routing and Warden-based authentication, installs
  # the observer, runs a small RSpec suite against real HTTP requests, and
  # writes the resulting catalog to KARST_SCENARIOS_OUT. This spec never
  # constructs a RequestObservation/ExampleObservation by hand -- everything
  # asserted below came from genuine notification and Warden events.
  def run_fixture_suite
    harness = File.expand_path("../support/scenario_application", __dir__)
    output_path = File.join(Dir.mktmpdir("karst-spec-observer"), "scenarios.json")

    script = <<~RUBY
      require "rspec/core"
      require #{harness.inspect}
      require "rack/test"

      Karst::Spec::Observer.install!(output: #{output_path.inspect})

      RSpec.describe "Scenario catalog fixture" do
        include Rack::Test::Methods
        include ScenarioApplication.routes.url_helpers

        def app = ScenarioApplication

        it "exercises an anonymous route reached by a literal path" do
          get "/things"
          expect(last_response.status).to eq(200)
        end


        context "with explicit QA scenarios" do
          it "uses string metadata", karst: "Author with no books" do
            get "/things"
            expect(last_response.status).to eq(200)
          end

          it "uses structured metadata", karst: { name: "Admin" } do
            get "/things"
            expect(last_response.status).to eq(200)
          end

          it "allows a duplicate QA-facing name", karst: "Author with no books" do
            get thing_path(42)
            expect(last_response.status).to eq(200)
          end
        end

        it "exercises a route helper with a dynamic id segment" do
          get thing_path(42)
          expect(last_response.status).to eq(200)
        end

        it "signs in as setup before the real subject request" do
          post sign_in_path, "email" => "author@example.com", "password" => "secret"
          get dashboard_path
          expect(last_response.status).to eq(200)
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

        it "signs up within the very request that is the subject of the scenario" do
          post signup_path
          expect(last_response.status).to eq(302)
        end

        it "redirects with a sensitive token in the query string" do
          post password_resets_path
          expect(last_response.status).to eq(302)
        end

        it "issues only a JSON-format request" do
          get "/things.json"
          expect(last_response.status).to eq(200)
        end

        it "issues no HTTP request at all" do
          expect(1 + 1).to eq(2)
        end
      end

      exit(RSpec::Core::Runner.run([], $stderr, $stdout))
    RUBY

    output, status = Open3.capture2e(
      { "RAILS_ENV" => "test" },
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      script
    )

    [output, status, output_path]
  end

  def find_example(catalog, description_suffix)
    catalog.find { |example| example.fetch("full_description").end_with?(description_suffix) }
  end

  before(:context) do
    output, status, output_path = run_fixture_suite
    raise "fixture suite failed:\n#{output}" unless status.success?

    @catalog = JSON.parse(File.read(output_path))
  end

  it "runs the fixture suite successfully" do
    expect(@catalog).to be_an(Array)
  end

  describe "browser-facing filtering" do
    it "excludes an example that issued no HTTP request" do
      expect(find_example(@catalog, "issues no HTTP request at all")).to be_nil
    end

    it "excludes an example whose only request was JSON-format" do
      expect(find_example(@catalog, "issues only a JSON-format request")).to be_nil
    end

    it "includes every example that issued an HTML request" do
      [
        "exercises an anonymous route reached by a literal path",
        "exercises a route helper with a dynamic id segment",
        "signs in as setup before the real subject request",
        "denies a non-admin, then allows after switching to an admin principal",
        "signs up within the very request that is the subject of the scenario",
        "redirects with a sensitive token in the query string"
      ].each do |suffix|
        expect(find_example(@catalog, suffix)).not_to be_nil, "expected to find an example ending \"#{suffix}\""
      end
    end
  end

  describe "literal path, zero-config, anonymous" do
    it "records the route pattern, controller/action, and no principal transition" do
      example = find_example(@catalog, "exercises an anonymous route reached by a literal path")
      request = example.fetch("requests").first

      expect(example.fetch("requests").size).to eq(1)
      expect(request["method"]).to eq("GET")
      expect(request["path"]).to eq("/things")
      expect(request["route_pattern"]).to eq("/things(.:format)")
      expect(request["controller"]).to eq("ScenarioThingsController")
      expect(request["action"]).to eq("index")
      expect(request["format"]).to eq("html")
      expect(request["status"]).to eq(200)
      expect(request["principal_before"]).to be_nil
      expect(request["principal_after"]).to be_nil
      expect(request["principal_changed"]).to be(false)
      expect(example).to include("karst_explicit" => false, "karst_name" => nil)
    end
  end

  describe "explicit scenario metadata" do
    it "records string and structured names without replacing RSpec descriptions or identity" do
      string_example = find_example(@catalog, "uses string metadata")
      hash_example = find_example(@catalog, "uses structured metadata")

      expect(string_example).to include("karst_explicit" => true, "karst_name" => "Author with no books")
      expect(hash_example).to include("karst_explicit" => true, "karst_name" => "Admin")
      expect(string_example.fetch("description_parts")).to eq(
        ["Scenario catalog fixture", "with explicit QA scenarios", "uses string metadata"]
      )
      expect(string_example.fetch("full_description")).to end_with("with explicit QA scenarios uses string metadata")
      expect(string_example.fetch("example_id")).to match(/\[\d+:\d+:\d+\]\z/)
    end

    it "allows duplicate human-readable names while retaining distinct technical identities" do
      duplicates = @catalog.select { |example| example["karst_name"] == "Author with no books" }

      expect(duplicates.size).to eq(2)
      expect(duplicates.map { |example| example.fetch("example_id") }.uniq.size).to eq(2)
    end
  end

  describe "malformed scenario metadata" do
    def run_malformed_fixture(value_source)
      harness = File.expand_path("../support/scenario_application", __dir__)
      output_path = File.join(Dir.mktmpdir("karst-invalid-metadata"), "scenarios.json")
      script = <<~RUBY
        require "rspec/core"
        require #{harness.inspect}
        Karst::Spec::Observer.install!(output: #{output_path.inspect})
        RSpec.describe "invalid metadata" do
          it("fails fast", karst: #{value_source}) { raise "example body should not run" }
        end
        exit(RSpec::Core::Runner.run([], $stderr, $stdout))
      RUBY

      Open3.capture2e({ "RAILS_ENV" => "test" }, RbConfig.ruby,
                      "-I#{File.expand_path('../../lib', __dir__)}", "-e", script)
    end

    ["true", "123", "{}", '{ name: "" }', '{ setup: "anything" }'].each do |value_source|
      it "fails fast for karst: #{value_source}" do
        output, status = run_malformed_fixture(value_source)

        expect(status).not_to be_success
        expect(output).to include("Karst::Spec::InvalidMetadataError")
        expect(output).to include("expected a non-empty String or { name: non_empty_string }")
        expect(output).not_to include("example body should not run")
      end
    end
  end

  describe "route helper with a dynamic id" do
    it "recovers the parameterized route pattern rather than the literal id" do
      example = find_example(@catalog, "exercises a route helper with a dynamic id segment")
      request = example.fetch("requests").first

      expect(request["path"]).to eq("/things/42")
      expect(request["route_pattern"]).to eq("/things/:id(.:format)")
      expect(request["controller"]).to eq("ScenarioThingsController")
      expect(request["action"]).to eq("show")
    end
  end

  describe "principal transition is raw evidence, not a semantic role" do
    it "reports principal_before/after/changed for both requests, without labeling either as setup" do
      example = find_example(@catalog, "signs in as setup before the real subject request")
      sign_in_request, subject_request = example.fetch("requests")

      expect(sign_in_request).not_to have_key("role")
      expect(sign_in_request["controller"]).to eq("ScenarioSessionsController")
      expect(sign_in_request["principal_before"]).to be_nil
      expect(sign_in_request["principal_after"]).to eq({ "type" => "ScenarioUser", "id" => 1, "scope" => "default" })
      expect(sign_in_request["principal_changed"]).to be(true)

      expect(subject_request["controller"]).to eq("ScenarioDashboardController")
      expect(subject_request["action"]).to eq("show")
      expect(subject_request["status"]).to eq(200)
      expect(subject_request["principal_before"]).to eq({ "type" => "ScenarioUser", "id" => 1, "scope" => "default" })
      expect(subject_request["principal_after"]).to eq({ "type" => "ScenarioUser", "id" => 1, "scope" => "default" })
      expect(subject_request["principal_changed"]).to be(false)
    end
  end

  describe "a subject request that itself establishes a principal" do
    it "is recorded like any other request, not specially flagged as setup" do
      example = find_example(@catalog, "signs up within the very request that is the subject of the scenario")
      request = example.fetch("requests").first

      expect(example.fetch("requests").size).to eq(1)
      expect(request).not_to have_key("role")
      expect(request["controller"]).to eq("ScenarioSignupsController")
      expect(request["action"]).to eq("create")
      expect(request["principal_before"]).to be_nil
      expect(request["principal_after"]).to eq({ "type" => "ScenarioUser", "id" => 1, "scope" => "default" })
      expect(request["principal_changed"]).to be(true)
    end
  end

  describe "redirect locations never retain a query string" do
    it "strips a sensitive token from a redirect target before it reaches the artifact" do
      example = find_example(@catalog, "redirects with a sensitive token in the query string")
      request = example.fetch("requests").first

      expect(request["redirect_location"]).to eq("/reset-password/confirm")
      expect(request["redirect_location"]).not_to include("token")
      expect(request["redirect_location"]).not_to include("secret")
    end
  end

  describe "multiple requests and multiple principals within one example" do
    it "identifies the active principal at each request's own boundary, not just the first" do
      example = find_example(@catalog, "denies a non-admin, then allows after switching to an admin principal")
      requests = example.fetch("requests")

      expect(requests.size).to eq(5)
      expect(requests.map { |request| request["principal_changed"] }).to eq([true, false, true, true, false])

      denied = requests[1]
      expect(denied["controller"]).to eq("ScenarioAdminController")
      expect(denied["status"]).to eq(302)
      expect(denied["redirect_location"]).to eq("/dashboard")
      expect(denied["principal_after"]).to eq({ "type" => "ScenarioUser", "id" => 1, "scope" => "default" })

      allowed = requests[4]
      expect(allowed["controller"]).to eq("ScenarioAdminController")
      expect(allowed["status"]).to eq(200)
      expect(allowed["principal_after"]).to eq({ "type" => "ScenarioUser", "id" => 2, "scope" => "default" })
    end
  end

  describe "example identity and location" do
    it "reports a stable id, file/line, nested description, and outcome" do
      example = find_example(@catalog, "exercises an anonymous route reached by a literal path")

      expect(example.fetch("example_id")).to match(/\[\d+:\d+\]\z/)
      expect(example.fetch("file_path")).to be_a(String)
      expect(example.fetch("line_number")).to be_a(Integer)
      expect(example.fetch("description_parts").last).to eq("exercises an anonymous route reached by a literal path")
      expect(example.fetch("outcome")).to eq("passed")
    end
  end

  it "is deterministic: two independent fixture runs produce byte-identical JSON" do
    _, status_a, path_a = run_fixture_suite
    _, status_b, path_b = run_fixture_suite

    expect(status_a).to be_success
    expect(status_b).to be_success
    expect(File.read(path_a)).to eq(File.read(path_b))
  end

  # The fixture application above never requires active_record at all, and
  # ScenarioUsers is a plain in-memory Array -- a passing suite is itself the
  # proof that no database is needed to build the catalog.
end

# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
