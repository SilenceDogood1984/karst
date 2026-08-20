# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/reproduction/curl"
require "shellwords"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Reproduction::Curl do
  def observation(**overrides)
    defaults = {
      http_method: "GET", url_path: "/api/v1/inspections", query_params: {}, route_params: {},
      body_params: {}, body_representation: :none, content_type: nil, headers: {}, controller: nil,
      action: nil, status: 200, response_content_type: "application/json", redirect: nil,
      halted_callback: nil, exception_class: nil, writes_observed: false, write_count: 0,
      database_rollback_attempted: true, elapsed_ms: 1.0, principal: nil, unobserved: []
    }
    Karst::Reproduction::Observation.new(**defaults, **overrides)
  end

  it "omits -X for GET, which curl already implies" do
    expect(described_class.render(observation)).to eq("curl 'http://localhost:3000/api/v1/inspections'")
  end

  it "spells out any other method" do
    expect(described_class.render(observation(http_method: "DELETE")))
      .to eq("curl -X DELETE 'http://localhost:3000/api/v1/inspections'")
  end

  it "appends query parameters, including nested ones, to the URL" do
    command = described_class.render(observation(query_params: { "status" => "passed",
                                                                 "filter" => { "since" => "2026-01-01" } }))

    expect(command).to eq("curl 'http://localhost:3000/api/v1/inspections?status=passed&filter[since]=2026-01-01'")
  end

  it "renders a JSON body as pretty JSON on its own continuation line" do
    command = described_class.render(observation(
                                       http_method: "POST", body_representation: :json,
                                       content_type: "application/json",
                                       headers: { "Content-Type" => "application/json" },
                                       body_params: { "serial_number" => "ABC123", "status" => "passed" }
                                     ))

    expect(command).to eq(<<~CURL.strip)
      curl -X POST 'http://localhost:3000/api/v1/inspections' \\
        -H 'Content-Type: application/json' \\
        -d '{
        "serial_number": "ABC123",
        "status": "passed"
      }'
    CURL
  end

  it "renders a form body as an encoded query string" do
    command = described_class.render(observation(http_method: "POST", body_representation: :form,
                                                 body_params: { "serial_number" => "ABC 123" }))

    expect(command).to include("-d 'serial_number=ABC+123'")
  end

  it "stands a body it could not parse in for the real one, rather than echoing it" do
    command = described_class.render(observation(http_method: "POST", body_representation: :opaque))

    expect(command).to include("-d '<BODY>'")
  end

  it "carries redaction placeholders straight into the command" do
    command = described_class.render(observation(headers: { "Authorization" => "<AUTH_TOKEN>" }))

    expect(command).to include("-H 'Authorization: <AUTH_TOKEN>'")
  end

  # The real contract is not "looks escaped" but "a shell parses this back
  # into exactly the bytes Karst meant", so the assertion is a round trip
  # through Shellwords rather than a hand-written escape sequence.
  it "quotes so that shell metacharacters in a value cannot escape the literal" do
    body = { "note" => "it's $(whoami) `id` \"quoted\" \\ end" }
    command = described_class.render(observation(http_method: "POST", body_representation: :json,
                                                 body_params: body))

    words = Shellwords.split(command)

    expect(words.first(4)).to eq(["curl", "-X", "POST", "http://localhost:3000/api/v1/inspections"])
    expect(JSON.parse(words.last)).to eq(body)
  end

  it "accepts the caller's own base URL and never invents a host of its own" do
    command = described_class.render(observation, base_url: "http://127.0.0.1:4000/")

    expect(command).to eq("curl 'http://127.0.0.1:4000/api/v1/inspections'")
  end

  it "keeps a redacted path segment redacted in the generated URL" do
    command = described_class.render(observation(url_path: "/reset/<TOKEN>"))

    expect(command).to include("/reset/<TOKEN>")
  end
end
# rubocop:enable Metrics/BlockLength
