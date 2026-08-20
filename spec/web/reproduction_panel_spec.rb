# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/panel"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst::Web::Panel request reproduction" do
  def render(params: {}, reproduction: nil, csrf_token: "token")
    Karst::Web::Panel.render(params: params, reproduction: reproduction, csrf_token: csrf_token).last.join
  end

  let(:route) { { "method" => "POST", "path" => "/api/v1/inspections" } }

  let(:document) do
    {
      schema_version: 1,
      request: {
        method: "POST", path: "/api/v1/inspections", url: "http://localhost:3000/api/v1/inspections",
        query_params: {}, route_params: {}, content_type: "application/json", body_format: "json",
        body: { "serial_number" => "ABC123", "passcode" => "<FILTERED>" },
        headers: { "Authorization" => "<AUTH_TOKEN>", "Content-Type" => "application/json" }
      },
      identity: { mechanism: "karst_assumed_identity", assumed: { model: "User", id: 27, label: "User #27" },
                  reason: nil, note: "..." },
      execution: { controller: "Api::V1::InspectionsController", action: "create", halted_callback: nil,
                   exception_class: nil, writes_observed: true, write_count: 2,
                   database_rollback_attempted: true },
      response: { status: 201, content_type: "application/json", redirect: nil },
      unobserved: [],
      isolation: { database: "same_connection_rollback_attempted",
                   not_isolated: ["background jobs", "mail"] },
      reproduce: { curl: "curl -X POST 'http://localhost:3000/api/v1/inspections'" },
      summary: { elapsed_ms: 12.0 }
    }
  end

  it "offers reproduction once a URL is selected, collapsed until a developer opens it" do
    html = render(params: route)

    expect(html).to include("Reproduce request")
    expect(html).to include('name="operation" value="reproduce_request"')
    expect(html).to include("<details><summary><strong>Reproduce request</strong>")
  end

  it "points a non-GET route at reproduction, since access analysis stays GET-only" do
    expect(render(params: route)).to include("Access analysis is available for GET routes only")
  end

  it "shows nothing at all before a URL is selected" do
    expect(render).not_to include("Reproduce request")
  end

  # Reproduction issues one real request that may write, enqueue, and send
  # mail. Without a CSRF token there is no way to protect that, so the form
  # is not offered rather than offered unprotected.
  it "does not offer the form without a CSRF token to protect it" do
    expect(render(params: route, csrf_token: nil)).not_to include("reproduce_request")
  end

  it "carries the CSRF token into the form" do
    expect(render(params: route)).to include('name="csrf_token" value="token"')
  end

  it "says out loud what same-connection rollback does not isolate" do
    html = render(params: route)

    expect(html).to include("jobs, mail, outbound HTTP, files, and other connections are not")
  end

  describe "a rendered recipe" do
    it "shows the request, execution, response, effects, and a copyable cURL command" do
      html = render(params: route, reproduction: document)

      expect(html).to include("POST /api/v1/inspections")
      expect(html).to include("Api::V1::InspectionsController#create")
      expect(html).to include("201 Created")
      expect(html).to include("2 database writes")
      expect(html).to include("<pre><code>curl -X POST")
    end

    it "opens the section automatically once there is a result to read" do
      expect(render(params: route, reproduction: document)).to include("<details open>")
    end

    it "marks redacted values visibly, so observed and redacted never blur together" do
      html = render(params: route, reproduction: document)

      expect(html).to include('<dd><span class="redacted">&lt;AUTH_TOKEN&gt;</span></dd>')
      expect(html).to include("&quot;passcode&quot;: &quot;&lt;FILTERED&gt;&quot;")
      expect(html).to include("<dd>application/json</dd>")
    end

    it "says Karst did not observe how an external client authenticates" do
      expect(render(params: route, reproduction: document))
        .to include("did not observe how an external client authenticates")
    end

    it "reports a halted callback as observed evidence, without explaining it" do
      document[:execution][:halted_callback] = "authenticate_api_key!"

      html = render(params: route, reproduction: document)

      expect(html).to include("Halted at authenticate_api_key!")
      expect(html).not_to include("because")
    end

    it "names what Karst could not observe instead of leaving a blank" do
      document[:execution][:controller] = nil
      document[:response][:status] = nil
      document[:unobserved] = %w[controller action status]

      html = render(params: route, reproduction: document)

      expect(html).to include("no controller dispatched")
      expect(html).to include("No response observed.")
      expect(html).to include("Not observed")
    end

    it "declines to echo a body it could not parse" do
      document[:request][:body_format] = "opaque"
      document[:request][:body] = {}

      expect(render(params: route, reproduction: document)).to include("could not parse as JSON or form data")
    end

    it "escapes every value it renders into the document" do
      document[:execution][:controller] = "<script>alert(1)</script>"
      document[:reproduce][:curl] = "curl '<script>'"

      recipe = render(params: route, reproduction: document)[%r{<div class="recipe">.*</div>}m]

      expect(recipe).not_to include("<script>")
      expect(recipe).to include("&lt;script&gt;")
    end

    it "renders a Karst error as an alert rather than a half-built recipe" do
      html = render(params: route,
                    reproduction: { schema_version: 1,
                                    error: { type: "input_error", message: "target must be a local path" } })

      expect(html).to include("target must be a local path")
      expect(html).not_to include("<pre><code>curl")
    end
  end
end
# rubocop:enable Metrics/BlockLength
