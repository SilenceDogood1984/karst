# frozen_string_literal: true

require "spec_helper"
require "karst/mcp/verify_access_tool"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Mcp::VerifyAccessTool do
  def stub_evidence(document)
    verification = instance_double(Karst::CLI::Verification, evidence: document)
    allow(Karst::CLI::Verification).to receive(:new).and_return(verification)
    verification
  end

  it "is named verify_access" do
    expect(described_class.name_value).to eq("verify_access")
  end

  it "requires only path, with no default, and offers method with a GET default" do
    schema = described_class.input_schema.to_h

    expect(schema[:required]).to eq(["path"])
    expect(schema[:properties].keys).to contain_exactly(:path, :method, :identity)
    expect(schema[:properties][:method][:default]).to eq("GET")
  end

  it "exposes no argument beyond path/method/identity -- no principal, population, or limit override" do
    expect(described_class.input_schema.to_h[:properties].keys).to eq(%i[path method identity])
    expect(described_class.input_schema.to_h[:properties][:identity][:enum])
      .to eq(%w[application_identities anonymous])
  end

  # The CLI's --as (see Karst::CLI::Verification/PrincipalReference) is
  # deliberately human-only: an agent can pick a path, but never a
  # principal. This tool's #call signature is the actual enforcement --
  # the input schema above only documents it -- so this pins both.
  it "never gains a human-only principal selector such as --as" do
    expect(described_class.input_schema.to_h[:properties].keys).not_to include(:as, :principal, :principal_id)
    expect(described_class.method(:call).parameters.map(&:last)).not_to include(:as, :principal, :principal_id)
  end

  it "delegates to Karst::CLI::Verification with the given path and method" do
    stub_evidence({ schema_version: 1, verified_usable: true })

    described_class.call(path: "/admin/imports/123", method: "GET")

    expect(Karst::CLI::Verification).to have_received(:new).with(path: "/admin/imports/123", http_method: "GET",
                                                                 identity: nil)
  end

  it "requests a genuinely anonymous probe when the caller asks for one" do
    stub_evidence({ schema_version: 2, verified_usable: false })

    described_class.call(path: "/users", identity: "anonymous")

    expect(Karst::CLI::Verification).to have_received(:new).with(path: "/users", http_method: "GET",
                                                                 identity: "anonymous")
  end

  it "treats the documented application_identities default as the ordinary search, not an error" do
    stub_evidence({ schema_version: 2, verified_usable: false })

    described_class.call(path: "/users", identity: "application_identities")

    expect(Karst::CLI::Verification).to have_received(:new).with(path: "/users", http_method: "GET",
                                                                 identity: nil)
  end

  it "defaults method to GET when the caller omits it" do
    stub_evidence({ schema_version: 1, verified_usable: false })

    described_class.call(path: "/admin/imports/123")

    expect(Karst::CLI::Verification).to have_received(:new).with(path: "/admin/imports/123", http_method: "GET",
                                                                 identity: nil)
  end

  it "returns the evidence document unchanged as JSON text content, not a separate result model" do
    document = { schema_version: 1, verified_usable: true, verified_principal: { model: "User", id: 27 } }
    stub_evidence(document)

    response = described_class.call(path: "/admin/imports/123")

    expect(response).to be_a(MCP::Tool::Response)
    expect(response.error?).to be(false)
    expect(response.content).to eq([{ type: "text", text: JSON.generate(document) }])
  end

  it "cannot add a browser-only authentication identifier to privacy-bounded evidence" do
    document = { schema_version: 1,
                 verified_principal: { model: "User", id: 27, label: "User #27" } }
    stub_evidence(document)

    text = described_class.call(path: "/admin/imports/123").content.first[:text]

    expect(text).to eq(JSON.generate(document))
    expect(text).not_to include("user@example.com")
  end

  it "marks the tool response as an MCP error when the evidence document is an error document" do
    document = { schema_version: 1,
                 error: { type: "input_error", message: "target must be a local application path" } }
    stub_evidence(document)

    response = described_class.call(path: "http://evil.example.com")

    expect(response.error?).to be(true)
    expect(JSON.parse(response.content.first[:text])).to eq(
      "schema_version" => 1,
      "error" => { "type" => "input_error", "message" => "target must be a local application path" }
    )
  end
end
# rubocop:enable Metrics/BlockLength
