# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "karst"
require "karst/spec/catalog"
require "karst/spec/principal"
require "karst/spec/request_observation"
require "karst/spec/example_observation"
require "karst/spec/reporter"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Spec::Catalog do
  # Builds fixtures the same way Karst::Spec::Observer would: real
  # RequestObservation/ExampleObservation instances serialized by the real
  # Reporter, so these specs exercise Catalog against the artifact format the
  # observer actually produces rather than a hand-invented schema.
  # rubocop:disable Metrics/ParameterLists
  def request(sequence:, controller:, action:, http_method: "GET", format: "html", status: 200,
              redirect_location: nil, principal_before: nil, principal_after: nil,
              route_pattern: "/x(.:format)", path: "/x")
    Karst::Spec::RequestObservation.new(
      sequence: sequence, http_method: http_method, path: path, route_pattern: route_pattern,
      controller: controller, action: action, format: format, status: status, redirect_location: redirect_location,
      principal_before: principal_before, principal_after: principal_after,
      principal_changed: principal_before != principal_after
    )
  end
  # rubocop:enable Metrics/ParameterLists

  # rubocop:disable Metrics/ParameterLists
  def example(file_path:, line_number:, description:, requests:, outcome: :passed, description_parts: nil)
    Karst::Spec::ExampleObservation.new(
      example_id: "./#{file_path}[1:#{line_number}]", file_path: file_path, line_number: line_number,
      spec_type: :request, description_parts: description_parts || ["Group", description],
      full_description: "Group #{description}", outcome: outcome, requests: requests
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def write_artifact(examples)
    reporter = Karst::Spec::Reporter.new
    examples.each { |recorded| reporter.record(recorded) }
    dir = Dir.mktmpdir("karst-catalog-spec")
    path = File.join(dir, "scenarios.json")
    reporter.write(path)
    path
  end

  def catalog_for(examples)
    described_class.load(path: write_artifact(examples))
  end

  it "cannot be constructed directly" do
    expect { described_class.new(:ready, [], nil) }.to raise_error(NoMethodError, /private method/)
  end

  describe "missing artifact" do
    it "reports :missing with no scenarios and no error" do
      Dir.mktmpdir do |dir|
        catalog = described_class.load(path: File.join(dir, "nope", "scenarios.json"))

        expect(catalog.status).to eq(:missing)
        expect(catalog).not_to be_ready
        expect(catalog.scenarios).to eq([])
        expect(catalog.error).to be_nil
        expect(catalog.scenarios_for(controller: "X", action: "show")).to eq([])
      end
    end
  end

  describe "malformed artifact" do
    it "reports :invalid for a zero-byte file, distinct from a valid empty array" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        File.write(path, "")
        catalog = described_class.load(path: path)

        expect(catalog.status).to eq(:invalid)
        expect(catalog.error).to match(/empty/)
        expect(catalog.scenarios).to eq([])
      end
    end

    it "reports :invalid for unparseable JSON" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        File.write(path, "{not json")
        catalog = described_class.load(path: path)

        expect(catalog.status).to eq(:invalid)
        expect(catalog.error).to match(/not valid JSON/)
      end
    end

    it "reports :invalid when the top-level shape is not an array (incompatible schema)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        File.write(path, JSON.generate({ "schema" => "v2", "examples" => [] }))
        catalog = described_class.load(path: path)

        expect(catalog.status).to eq(:invalid)
        expect(catalog.error).to match(/not a JSON array/)
      end
    end
  end

  describe "empty coverage" do
    it "is :ready with zero scenarios for a valid, empty artifact -- distinct from :missing" do
      catalog = catalog_for([])

      expect(catalog.status).to eq(:ready)
      expect(catalog).to be_ready
      expect(catalog.scenarios).to eq([])
      expect(catalog.scenarios_for(controller: "X", action: "show")).to eq([])
    end
  end

  describe "one scenario, with an authenticated principal" do
    it "is returned by controller/action carrying every observed field" do
      principal = Karst::Spec::Principal.new(type: "User", id: 7, scope: "default")
      recorded = example(
        file_path: "spec/a_spec.rb", line_number: 4, description: "shows the thing",
        requests: [request(sequence: 0, controller: "XController", action: "show", status: 200,
                           principal_before: principal, principal_after: principal,
                           route_pattern: "/x/:id(.:format)", path: "/x/1")]
      )
      catalog = catalog_for([recorded])
      scenarios = catalog.scenarios_for(controller: "XController", action: "show")

      expect(scenarios.size).to eq(1)
      scenario = scenarios.first
      expect(scenario).to be_frozen
      expect(scenario.name).to eq("shows the thing")
      expect(scenario.http_method).to eq("GET")
      expect(scenario.route_pattern).to eq("/x/:id(.:format)")
      expect(scenario.observed_path).to eq("/x/1")
      expect(scenario.observed_status).to eq(200)
      expect(scenario.observed_redirect).to be_nil
      expect(scenario.principal).to eq(principal)
      expect(scenario.principal_changed).to be(false)
      expect(scenario.example_outcome).to eq(:passed)
      expect(scenario).to be_passed
    end
  end

  describe "anonymous principal" do
    it "has a nil principal and no transition" do
      recorded = example(file_path: "spec/a_spec.rb", line_number: 1, description: "shows a public page",
                         requests: [request(sequence: 0, controller: "PublicController", action: "index")])
      catalog = catalog_for([recorded])
      scenario = catalog.scenarios_for(controller: "PublicController", action: "index").first

      expect(scenario.principal).to be_nil
      expect(scenario.principal_changed).to be(false)
    end
  end

  describe "a principal-changing request" do
    it "carries the principal active before the request, plus principal_changed, without a setup/subject label" do
      principal = Karst::Spec::Principal.new(type: "User", id: 3, scope: "default")
      recorded = example(
        file_path: "spec/a_spec.rb", line_number: 1, description: "signs up and lands on the dashboard",
        requests: [request(sequence: 0, controller: "SignupsController", action: "create", status: 302,
                           redirect_location: "/dashboard", principal_before: nil, principal_after: principal)]
      )
      catalog = catalog_for([recorded])
      scenario = catalog.scenarios_for(controller: "SignupsController", action: "create").first

      expect(scenario.principal).to be_nil
      expect(scenario.principal_changed).to be(true)
      expect(scenario.observed_status).to eq(302)
      expect(scenario.observed_redirect).to eq("/dashboard")
    end
  end

  describe "multiple scenarios for the same route" do
    it "returns every scenario for that controller/action, in deterministic order" do
      denied = example(file_path: "spec/a_spec.rb", line_number: 1, description: "denies a reader",
                       requests: [request(sequence: 0, controller: "XController", action: "index", status: 302,
                                          redirect_location: "/sign-in")])
      allowed = example(file_path: "spec/a_spec.rb", line_number: 5, description: "allows an author",
                        requests: [request(sequence: 0, controller: "XController", action: "index", status: 200)])
      catalog = catalog_for([allowed, denied])

      scenarios = catalog.scenarios_for(controller: "XController", action: "index")
      expect(scenarios.map(&:name)).to eq(["denies a reader", "allows an author"])
      expect(scenarios.map(&:observed_status)).to eq([302, 200])
    end
  end

  describe "the same controller/action across multiple HTTP methods" do
    it "returns every method when unfiltered, and only the matching method when filtered" do
      form = example(file_path: "spec/a_spec.rb", line_number: 1, description: "renders the form",
                     requests: [request(sequence: 0, http_method: "GET",
                                        controller: "SignupsController", action: "create")])
      submit = example(file_path: "spec/a_spec.rb", line_number: 2, description: "creates the account",
                       requests: [request(sequence: 0, http_method: "POST",
                                          controller: "SignupsController", action: "create")])
      catalog = catalog_for([form, submit])

      expect(catalog.scenarios_for(controller: "SignupsController", action: "create").size).to eq(2)
      expect(catalog.scenarios_for(controller: "SignupsController", action: "create", http_method: "get").map(&:name))
        .to eq(["renders the form"])
      expect(catalog.scenarios_for(controller: "SignupsController", action: "create", http_method: "POST").map(&:name))
        .to eq(["creates the account"])
    end
  end

  describe "dynamic route segments" do
    it "indexes by controller/action, so different literal ids still land in one bucket" do
      thing_one = example(file_path: "spec/a_spec.rb", line_number: 1, description: "shows thing 1",
                          requests: [request(sequence: 0, controller: "ThingsController", action: "show",
                                             route_pattern: "/things/:id(.:format)", path: "/things/1")])
      thing_two = example(file_path: "spec/a_spec.rb", line_number: 2, description: "shows thing 2",
                          requests: [request(sequence: 0, controller: "ThingsController", action: "show",
                                             route_pattern: "/things/:id(.:format)", path: "/things/991")])
      catalog = catalog_for([thing_one, thing_two])

      scenarios = catalog.scenarios_for(controller: "ThingsController", action: "show")
      expect(scenarios.map(&:observed_path)).to eq(["/things/1", "/things/991"])
      expect(scenarios.map(&:route_pattern).uniq).to eq(["/things/:id(.:format)"])
    end
  end

  describe "one example producing multiple scenarios" do
    it "produces one scenario per browser-facing request, in sequence order, sharing one example_id" do
      recorded = example(
        file_path: "spec/a_spec.rb", line_number: 1, description: "denies then allows",
        requests: [
          request(sequence: 0, controller: "AdminController", action: "show", status: 302,
                  redirect_location: "/dashboard"),
          request(sequence: 1, controller: "SessionsController", action: "destroy", status: 302,
                  redirect_location: "/"),
          request(sequence: 2, controller: "AdminController", action: "show", status: 200)
        ]
      )
      catalog = catalog_for([recorded])

      admin_scenarios = catalog.scenarios_for(controller: "AdminController", action: "show")
      expect(admin_scenarios.size).to eq(2)
      expect(admin_scenarios.map(&:observed_status)).to eq([302, 200])
      expect(admin_scenarios.map(&:sequence)).to eq([0, 2])
      expect(admin_scenarios.map(&:example_id).uniq.size).to eq(1)
    end
  end

  describe "failed and pending examples" do
    it "still appear in the catalog, flagged by example_outcome rather than silently dropped" do
      failed = example(file_path: "spec/a_spec.rb", line_number: 1, outcome: :failed,
                       description: "expected 200",
                       requests: [request(sequence: 0, controller: "XController", action: "show", status: 500)])
      pending = example(file_path: "spec/a_spec.rb", line_number: 2, outcome: :pending,
                        description: "not yet implemented",
                        requests: [request(sequence: 0, controller: "XController", action: "show", status: 200)])
      catalog = catalog_for([failed, pending])

      scenarios = catalog.scenarios_for(controller: "XController", action: "show")
      expect(scenarios.map(&:example_outcome)).to eq(%i[failed pending])
      expect(scenarios.map(&:passed?)).to eq([false, false])
    end
  end

  describe "deterministic ordering" do
    it "orders passed before failed/pending, then file path, then line number" do
      other_file = example(file_path: "spec/b_spec.rb", line_number: 1, description: "b1",
                           requests: [request(sequence: 0, controller: "XController", action: "show")])
      later_line = example(file_path: "spec/a_spec.rb", line_number: 20, description: "a20",
                           requests: [request(sequence: 0, controller: "XController", action: "show")])
      failed_early_line = example(file_path: "spec/a_spec.rb", line_number: 5, description: "a5-failed",
                                  outcome: :failed,
                                  requests: [request(sequence: 0, controller: "XController", action: "show")])
      passed_early_line = example(file_path: "spec/a_spec.rb", line_number: 5, description: "a5-passed",
                                  requests: [request(sequence: 0, controller: "XController", action: "show")])
      catalog = catalog_for([other_file, later_line, failed_early_line, passed_early_line])

      names = catalog.scenarios_for(controller: "XController", action: "show").map(&:name)
      expect(names).to eq(%w[a5-passed a20 b1 a5-failed])
    end

    it "is stable across repeated loads of an unchanged artifact" do
      path = write_artifact([
                              example(file_path: "spec/a_spec.rb", line_number: 1, description: "one",
                                      requests: [request(sequence: 0, controller: "XController", action: "show")]),
                              example(file_path: "spec/a_spec.rb", line_number: 2, description: "two",
                                      requests: [request(sequence: 0, controller: "XController", action: "show")])
                            ])

      first = described_class.load(path: path).scenarios_for(controller: "XController", action: "show").map(&:name)
      second = described_class.load(path: path).scenarios_for(controller: "XController", action: "show").map(&:name)

      expect(first).to eq(second)
    end
  end

  describe "invalid individual records" do
    it "skips malformed entries but keeps the artifact :ready and keeps valid scenarios" do
      good_request = {
        "sequence" => 0, "method" => "GET", "path" => "/x", "route_pattern" => "/x(.:format)",
        "controller" => "XController", "action" => "show", "format" => "html", "status" => 200,
        "redirect_location" => nil, "principal_before" => nil, "principal_after" => nil, "principal_changed" => false
      }
      good_example = {
        "example_id" => "id1", "file_path" => "spec/a_spec.rb", "line_number" => 1, "spec_type" => "request",
        "description_parts" => ["a"], "full_description" => "a", "outcome" => "passed", "requests" => [good_request]
      }

      raw = JSON.generate(
        [
          good_example,
          "not a hash",
          good_example.merge("requests" => "not an array"),
          good_example.merge("file_path" => nil),
          good_example.merge("requests" => [good_request.merge("controller" => nil)]),
          good_example.merge("requests" => [good_request.merge("format" => "json")]),
          good_example.merge("requests" => [good_request.merge("sequence" => "zero")])
        ]
      )

      Dir.mktmpdir do |dir|
        path = File.join(dir, "scenarios.json")
        File.write(path, raw)
        catalog = described_class.load(path: path)

        expect(catalog.status).to eq(:ready)
        expect(catalog.scenarios.size).to eq(1)
        expect(catalog.scenarios.first.controller).to eq("XController")
      end
    end
  end

  describe ".default_path" do
    it "defaults to tmp/karst/scenarios.json when Rails is not loaded" do
      expect(described_class.default_path).to eq(File.join("tmp", "karst", "scenarios.json"))
    end

    it "resolves under Rails.root when Rails is loaded" do
      stub_const("Rails", Module.new)
      Rails.define_singleton_method(:root) { "/app" }

      expect(described_class.default_path).to eq(File.join("/app", "tmp", "karst", "scenarios.json"))
    end
  end
end
# rubocop:enable Metrics/BlockLength
