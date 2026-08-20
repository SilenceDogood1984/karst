# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "rack/mock"
require_relative "../support/test_application"
require "karst/web/middleware"
require "karst/cli/reproduction"

ActiveRecord::Schema.define do
  create_table :karst_reproduction_devices, force: true do |table|
    table.string :serial_number, null: false
    table.string :status
  end
end

class KarstReproductionDevice < ActiveRecord::Base; end

# Stands in for the "an external system POSTs to our API" story: one gate
# that halts on a header Karst never sends by itself, one create that
# writes, and one route whose parameter is itself a credential.
class KarstReproductionFixtureController < ActionController::Base
  before_action :authenticate_api_key!, only: :create

  def index
    render json: { status: params[:status] }
  end

  def create
    KarstReproductionDevice.create!(serial_number: params[:serial_number], status: params[:status])
    render json: { created: true }, status: :created
  end

  def reset
    render json: { token: params[:token] }
  end

  private

  def authenticate_api_key!
    head :unauthorized unless request.headers["Authorization"] == "Bearer real-key"
  end
end

# Added directly through the mapper, not .draw, for the reason
# mcp_server_spec.rb documents at length: .draw clears the whole route set
# first, so a second spec file drawing on the one shared KarstTestApplication
# silently deletes the first file's routes.
KarstTestApplication.routes.send(:eval_block, proc {
  get "/karst_api/inspections", to: "karst_reproduction_fixture#index"
  post "/karst_api/inspections", to: "karst_reproduction_fixture#create"
  get "/karst_api/reset/:token", to: "karst_reproduction_fixture#reset"
})

# rubocop:disable Metrics/BlockLength
RSpec.describe "request reproduction Rails integration" do
  let(:json) { "application/json" }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstReproductionDevice.delete_all
    @original_filters = KarstTestApplication.config.filter_parameters
    KarstTestApplication.config.filter_parameters = [:passcode]
  end

  after { KarstTestApplication.config.filter_parameters = @original_filters }

  def exercise(path:, http_method: "GET", body: nil, content_type: nil, headers: {})
    Karst::Reproduction::Exercise.new(path: path, http_method: http_method, body: body,
                                      content_type: content_type, headers: headers,
                                      application: KarstTestApplication).call
  end

  describe "GET reproduction" do
    it "observes the dispatched controller, response, and query parameters" do
      observation = exercise(path: "/karst_api/inspections?status=passed")

      expect(observation.http_method).to eq("GET")
      expect(observation.url_path).to eq("/karst_api/inspections")
      expect(observation.query_params).to eq("status" => "passed")
      expect(observation.controller).to eq("KarstReproductionFixtureController")
      expect(observation.action).to eq("index")
      expect(observation.status).to eq(200)
      expect(observation.response_content_type).to include("application/json")
      expect(observation.body_representation).to eq(:none)
      expect(observation.unobserved).to be_empty
    end

    it "renders a cURL command with no method flag and no body" do
      command = Karst::Reproduction::Curl.render(exercise(path: "/karst_api/inspections?status=passed"))

      expect(command).to eq("curl 'http://localhost:3000/karst_api/inspections?status=passed'")
    end

    it "observes route parameters from the router that actually dispatched" do
      observation = exercise(path: "/karst_api/reset/plain-value")

      expect(observation.route_params).to eq("token" => "<FILTERED>")
      expect(observation.unobserved).not_to include("route_params")
    end
  end

  describe "POST JSON reproduction" do
    let(:payload) { JSON.generate(serial_number: "ABC123", status: "passed") }

    it "reaches the observed authentication gate and reports it without inferring why" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST",
                             body: payload, content_type: json)

      expect(observation.status).to eq(401)
      expect(observation.halted_callback).to eq("authenticate_api_key!")
      expect(observation.controller).to eq("KarstReproductionFixtureController")
      expect(observation.action).to eq("create")
    end

    it "observes the create, and rolls the write back on the same connection" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST", body: payload,
                             content_type: json, headers: { "Authorization" => "Bearer real-key" })

      expect(observation.status).to eq(201)
      expect(observation.halted_callback).to be_nil
      expect(observation.writes_observed).to be(true)
      expect(observation.write_count).to be >= 1
      expect(observation.database_rollback_attempted).to be(true)
      expect(KarstReproductionDevice.count).to eq(0)
    end

    it "builds a runnable cURL command carrying the body it actually sent" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST", body: payload,
                             content_type: json, headers: { "Authorization" => "Bearer real-key" })

      command = Karst::Reproduction::Curl.render(observation)

      expect(command).to include("curl -X POST 'http://localhost:3000/karst_api/inspections'")
      expect(command).to include("-H 'Authorization: <AUTH_TOKEN>'")
      expect(command).to include("-H 'Content-Type: application/json'")
      expect(command).to include(%("serial_number": "ABC123"))
      expect(command).not_to include("real-key")
    end
  end

  describe "form-encoded reproduction" do
    it "parses and sanitizes a form body" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST",
                             body: "serial_number=ABC123&passcode=hunter2&api_key=leak",
                             content_type: "application/x-www-form-urlencoded",
                             headers: { "Authorization" => "Bearer real-key" })

      expect(observation.body_representation).to eq(:form)
      expect(observation.body_params).to eq("serial_number" => "ABC123", "passcode" => "<FILTERED>",
                                            "api_key" => "<FILTERED>")
    end
  end

  describe "redaction" do
    it "masks a parameter the host application's own filter_parameters covers" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST",
                             body: JSON.generate(serial_number: "ABC123", passcode: "hunter2"),
                             content_type: json, headers: { "Authorization" => "Bearer real-key" })

      expect(observation.body_params["passcode"]).to eq("<FILTERED>")
      expect(observation.body_params["serial_number"]).to eq("ABC123")
      expect(JSON.generate(observation.body_params)).not_to include("hunter2")
    end

    it "never echoes a cookie, an authorization header, or an API key header" do
      observation = exercise(path: "/karst_api/inspections",
                             headers: { "Authorization" => "Bearer real-key",
                                        "Cookie" => "_session=abcd",
                                        "X-Api-Key" => "sk-live-123" })

      expect(observation.headers).to include("Authorization" => "<AUTH_TOKEN>",
                                             "Cookie" => "<SESSION_COOKIE>",
                                             "X-Api-Key" => "<API_KEY>")
      command = Karst::Reproduction::Curl.render(observation)
      expect(command).not_to include("real-key", "abcd", "sk-live-123")
    end

    it "substitutes a redacted route parameter back into the path it still appears in" do
      observation = exercise(path: "/karst_api/reset/s3cret-token")

      expect(observation.url_path).to eq("/karst_api/reset/<TOKEN>")
      expect(Karst::Reproduction::Curl.render(observation)).not_to include("s3cret-token")
    end
  end

  describe "information Karst could not observe" do
    it "reports an unrouted path as unobserved rather than filling anything in" do
      observation = exercise(path: "/karst_api/does-not-exist")

      expect(observation.controller).to be_nil
      expect(observation.action).to be_nil
      expect(observation.unobserved).to include("controller", "action", "route_params")
      expect(observation.status).to(satisfy { |status| status.nil? || status == 404 })
    end

    it "declines to echo a body it could not parse, while still sending it" do
      observation = exercise(path: "/karst_api/inspections", http_method: "POST",
                             body: "<xml>secret</xml>", content_type: "application/xml",
                             headers: { "Authorization" => "Bearer real-key" })

      expect(observation.body_representation).to eq(:opaque)
      expect(observation.body_params).to eq({})
      command = Karst::Reproduction::Curl.render(observation)
      expect(command).to include("-d '<BODY>'")
      expect(command).not_to include("secret")
    end
  end

  describe "the shared evidence document" do
    it "is the same document the CLI prints, the MCP tool returns, and the panel renders" do
      document = Karst::CLI::Reproduction.new(
        path: "/karst_api/inspections", http_method: "POST",
        body: JSON.generate(serial_number: "ABC123", passcode: "hunter2"), content_type: json,
        headers: { "Authorization" => "Bearer real-key" }, anonymous: true
      ).evidence

      expect(document[:schema_version]).to eq(1)
      expect(document[:request][:method]).to eq("POST")
      expect(document[:request][:body]["passcode"]).to eq("<FILTERED>")
      expect(document[:execution][:controller]).to eq("KarstReproductionFixtureController")
      expect(document[:response][:status]).to eq(201)
      expect(document[:identity][:mechanism]).to eq("anonymous")
      expect(document[:isolation][:not_isolated]).to include("background jobs")
      expect(document[:reproduce][:curl]).to include("-X POST")
      expect(JSON.generate(document)).not_to include("hunter2", "real-key")
    end

    it "reports a structured error, never a crash, for a non-local target" do
      document = Karst::CLI::Reproduction.new(path: "https://example.com/steal", anonymous: true).evidence

      expect(document[:error][:type]).to eq("input_error")
      expect(document[:error][:message]).to match(/local application path/)
    end

    it "exits 0 and prints a QA recipe from the CLI adapter" do
      output = StringIO.new

      code = Karst::CLI::Reproduction.new(path: "/karst_api/inspections", anonymous: true, output: output).call

      expect(code).to eq(0)
      expect(output.string).to include("Observed execution", "KarstReproductionFixtureController#index",
                                       "Reproduce", "curl")
    end
  end

  # Reproduction issues one real request that may write, enqueue, and send
  # mail, so /karst protects it exactly like the operations that write local
  # state -- same-origin plus Karst's own CSRF token -- rather than like the
  # read-only access sweep.
  describe "the /karst surface" do
    let(:origin) { "http://example.org" }
    let(:token) { "a" * 64 }

    def post_reproduce(fields, origin_header: origin, csrf: token, session: { "karst.csrf_token" => token })
      stack = Karst::Web::Middleware.new(KarstTestApplication)
      input = URI.encode_www_form({ "operation" => "reproduce_request", "csrf_token" => csrf }.merge(fields))
      env = { "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
              "rack.session" => session, input: input }
      env["HTTP_ORIGIN"] = origin_header if origin_header
      Rack::MockRequest.new(stack).post("/karst", **env)
    end

    it "renders the recipe, including a copyable cURL command, in the panel" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections?status=passed" })

      expect(response.status).to eq(200)
      expect(response.body).to include("KarstReproductionFixtureController#index", "200 OK")
      expect(response.body).to include("curl &#39;http://example.org/karst_api/inspections?status=passed&#39;")
    end

    it "builds the command against the developer's own origin, never an invented host" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections" })

      expect(response.body).to include("http://example.org/karst_api/inspections")
      expect(response.body).not_to include("localhost:3000")
    end

    it "sends a JSON body and reports the observed gate that halted it" do
      response = post_reproduce({ "method" => "POST", "path" => "/karst_api/inspections",
                                  "content_type" => json, "body" => JSON.generate(serial_number: "ABC123") })

      expect(response.body).to include("Halted at authenticate_api_key!", "401 Unauthorized")
    end

    # The form's own textareas echo what the developer just typed, exactly
    # as any form does. What must never carry a credential is the part Karst
    # *generates* -- the recipe and its cURL command, the things that get
    # copied into a ticket.
    it "never puts a credential into the recipe it generates" do
      response = post_reproduce({ "method" => "POST", "path" => "/karst_api/inspections",
                                  "content_type" => json,
                                  "body" => JSON.generate(serial_number: "ABC123", passcode: "hunter2"),
                                  "headers" => "Authorization: Bearer real-key" })

      recipe = response.body[%r{<div class="recipe">.*</div>}m]

      expect(recipe).to include("201 Created", "&lt;AUTH_TOKEN&gt;", "&lt;FILTERED&gt;")
      expect(recipe).not_to include("real-key")
      expect(recipe).not_to include("hunter2")
    end

    it "refuses a request without Karst's own CSRF token" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections" }, csrf: "wrong")

      expect(response.status).to eq(403)
      expect(KarstReproductionDevice.count).to eq(0)
    end

    it "refuses a cross-origin request even with a valid token" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections" },
                                origin_header: "http://evil.example")

      expect(response.status).to eq(403)
    end

    it "reports an unreadable header line as an input error rather than dropping it silently" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections",
                                  "headers" => "not-a-header-line" })

      expect(response.body).to include("expected one header per line")
    end

    it "refuses a header name that would rewrite the request environment itself" do
      response = post_reproduce({ "method" => "GET", "path" => "/karst_api/inspections",
                                  "headers" => "rack.session: forged" })

      expect(response.body).to include("is not a request header name")
    end

    it "reports a non-local target as an input error rather than issuing it" do
      response = post_reproduce({ "method" => "GET", "path" => "https://evil.example/steal" })

      expect(response.body).to include("local application path")
    end
  end

  describe "config.enabled" do
    before { Karst.config.enabled = false }

    it "refuses to issue the request at all" do
      expect { exercise(path: "/karst_api/inspections") }
        .to raise_error(Karst::Access::Unavailable, /disabled/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
