# frozen_string_literal: true

require "spec_helper"
require "karst/mcp/reproduce_request_tool"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Mcp::ReproduceRequestTool do
  def stub_evidence(document)
    reproduction = instance_double(Karst::CLI::Reproduction, evidence: document)
    allow(Karst::CLI::Reproduction).to receive(:new).and_return(reproduction)
    reproduction
  end

  let(:document) do
    { schema_version: 1, request: { method: "POST", path: "/api/v1/inspections" },
      reproduce: { curl: "curl -X POST 'http://localhost:3000/api/v1/inspections'" } }
  end

  it "is named reproduce_request" do
    expect(described_class.name_value).to eq("reproduce_request")
  end

  it "requires only path and constrains method to the ordinary HTTP verbs" do
    schema = described_class.input_schema.to_h

    expect(schema[:required]).to eq(["path"])
    expect(schema[:properties][:method][:enum]).to eq(%w[GET HEAD POST PUT PATCH DELETE])
    expect(schema[:properties][:method][:default]).to eq("GET")
  end

  it "exposes no way for an agent to pick a principal, a population, or a request budget" do
    expect(described_class.input_schema.to_h[:properties].keys)
      .to contain_exactly(:path, :method, :body, :content_type, :headers, :anonymous, :base_url)
  end

  it "tells an agent that this issues one real request whose non-database effects are not isolated" do
    expect(described_class.description).to include("exactly one request", "not isolated")
  end

  it "tells an agent that placeholders in the result are intentional, not a failure" do
    expect(described_class.description).to include("<API_KEY>", "working as intended")
  end

  it "delegates to the one shared adapter rather than re-running an Exercise of its own" do
    stub_evidence(document)

    described_class.call(path: "/api/v1/inspections", method: "POST", body: '{"a":1}',
                         content_type: "application/json", headers: { "X-Api-Key" => "k" })

    expect(Karst::CLI::Reproduction).to have_received(:new).with(
      path: "/api/v1/inspections", http_method: "POST", body: '{"a":1}',
      content_type: "application/json", headers: { "X-Api-Key" => "k" },
      anonymous: false, base_url: nil
    )
  end

  it "defaults method to GET and headers to none when the caller omits them" do
    stub_evidence(document)

    described_class.call(path: "/api/v1/inspections")

    expect(Karst::CLI::Reproduction).to have_received(:new)
      .with(hash_including(http_method: "GET", headers: {}, anonymous: false))
  end

  it "returns the evidence document unchanged as JSON text content" do
    stub_evidence(document)

    response = described_class.call(path: "/api/v1/inspections")

    expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to eq(document)
    expect(response.error?).to be(false)
  end

  it "marks a Karst error document as an MCP error rather than a successful recipe" do
    stub_evidence({ schema_version: 1, error: { type: "input_error", message: "nope" } })

    expect(described_class.call(path: "https://evil.example").error?).to be(true)
  end
end
# rubocop:enable Metrics/BlockLength
