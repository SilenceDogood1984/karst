# frozen_string_literal: true

require "spec_helper"
require_relative "../support/test_application"
require "karst/mcp/server"

ActiveRecord::Schema.define do
  create_table :karst_mcp_principals, force: true do |table|
    table.string :behavior, null: false, default: "ok"
    table.integer :visits, null: false, default: 0
  end
end

class KarstMcpPrincipal < ActiveRecord::Base
  scope :workers, -> { where(behavior: "ok") }
end

class KarstMcpFixtureController < ActionController::Base
  before_action :gate, only: :document

  def login
    session[:karst_mcp_principal_id] = params[:id]
    head :no_content
  end

  def logout
    session.delete(:karst_mcp_principal_id)
    head :no_content
  end

  def document
    principal = KarstMcpPrincipal.find_by(id: session[:karst_mcp_principal_id])
    principal&.update!(visits: principal.visits + 1) if params[:id] == "write"
    render plain: "document #{params[:id]}"
  end

  private

  def gate
    principal = KarstMcpPrincipal.find_by(id: session[:karst_mcp_principal_id])
    return head(:forbidden) if principal.nil? || principal.behavior == "forbidden"
    return head(:no_content) if principal.behavior == "denied"
    raise "fixture detail must not escape" if principal.behavior == "raise"
  end
end

# Added directly through the mapper (not .draw, which clears and redraws
# the whole route set, and not .append, which only queues the block for the
# next .draw/finalize! that may never come once the set is already
# finalized) so this file's routes coexist safely with every other spec
# file's own routes on the one shared KarstTestApplication -- see
# access_sweep_spec.rb, the only other file that draws routes on it.
KarstTestApplication.routes.send(:eval_block, proc {
  post "/karst_mcp/login", to: "karst_mcp_fixture#login"
  delete "/karst_mcp/logout", to: "karst_mcp_fixture#logout"
  get "/mcp_documents/:id", to: "karst_mcp_fixture#document"
})

# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst MCP server, end to end against a real Rails application" do
  let(:server) { Karst::Mcp::Server.build }

  def call_tool(arguments)
    response = server.handle(jsonrpc: "2.0", id: 1, method: "tools/call",
                             params: { name: "verify_access", arguments: arguments })
    result = response.fetch(:result)
    [JSON.parse(result.fetch(:content).first.fetch(:text)), result.fetch(:isError)]
  end

  before do
    # Access::Sweep refuses to run outside development -- mirrors
    # access_sweep_spec.rb's own stub for the same reason.
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    KarstMcpPrincipal.delete_all
    Karst.config.assume_identity = lambda do |session, principal|
      session.post "/karst_mcp/login", params: { id: principal.id }
    end
    Karst.config.clear_identity = ->(session) { session.delete "/karst_mcp/logout" }
    Karst.config.assume_browser_identity = lambda { |request, principal|
      request.session[:karst_mcp_principal_id] = principal.id
    }
    Karst.config.clear_browser_identity = ->(request) { request.session.delete(:karst_mcp_principal_id) }
  end

  after do
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
    Karst.config.access_sweep_limit = 25
  end

  it "verifies a usable ordinary sample outcome and reports the winning source" do
    ok = KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, error = call_tool(path: "/mcp_documents/1")

    expect(error).to be(false)
    expect(document).to include("verified_usable" => true, "schema_version" => 1)
    expect(document.dig("verified_outcome", "status")).to eq(200)
    expect(document.dig("verified_principal", "id")).to eq(ok.id)
    expect(document["source"]).to eq("type" => "sample", "name" => nil)
  end

  it "defaults to GET when method is omitted" do
    KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, = call_tool(path: "/mcp_documents/1")

    expect(document.dig("request", "method")).to eq("GET")
  end

  it "falls back to a configured population once the ordinary sample finds nothing usable" do
    3.times { KarstMcpPrincipal.create!(behavior: "forbidden") }
    working = KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.access_sweep_limit = 3
    Karst.config.principals = -> { KarstMcpPrincipal.where(behavior: "forbidden") }
    Karst.config.principal_populations = { workers: -> { KarstMcpPrincipal.workers } }

    document, = call_tool(path: "/mcp_documents/1")

    expect(document["verified_usable"]).to be(true)
    expect(document.dig("verified_principal", "id")).to eq(working.id)
    expect(document["source"]).to eq("type" => "population", "name" => "workers")
    expect(document["populations"]).to contain_exactly(include("name" => "workers", "state" => "usable"))
  end

  it "reports no verified usable user when nothing, including no population, is usable" do
    3.times { KarstMcpPrincipal.create!(behavior: "forbidden") }
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, error = call_tool(path: "/mcp_documents/1")

    expect(error).to be(false)
    expect(document["verified_usable"]).to be(false)
    expect(document["verified_outcome"]).to be_nil
    expect(document["verified_principal"]).to be_nil
  end

  it "keeps a 204 status with a halted callback non-usable, matching the configured usable policy" do
    KarstMcpPrincipal.create!(behavior: "denied")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, = call_tool(path: "/mcp_documents/1")

    outcome = document.dig("sample", "outcomes").first
    expect(outcome).to include("status" => 204, "halted_callback" => "gate")
    expect(document["verified_usable"]).to be(false)
  end

  it "rejects a nonlocal target the same way Access::Sweep does, as a structured error" do
    KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, error = call_tool(path: "http://evil.example.com/x")

    expect(error).to be(true)
    expect(document).to eq(
      "schema_version" => 1,
      "error" => { "type" => "input_error", "message" => "target must be a local application path" }
    )
  end

  it "surfaces an ambiguous Devise setup as a structured configuration_error, never a crash" do
    stub_const("Devise", Module.new)
    mapping = Struct.new(:to, :name)
    allow(Devise).to receive(:mappings).and_return(
      user: mapping.new(KarstMcpPrincipal, :user), admin: mapping.new(KarstMcpPrincipal, :admin)
    )
    stub_const("Warden::Manager", Class.new)

    document, error = call_tool(path: "/mcp_documents/1")

    expect(error).to be(true)
    expect(document.dig("error", "type")).to eq("configuration_error")
    expect(document.dig("error", "message")).to include("multiple Devise models")
  end

  it "still bounds sampling to the configured access_sweep_limit" do
    6.times { KarstMcpPrincipal.create!(behavior: "forbidden") }
    Karst.config.access_sweep_limit = 4
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, = call_tool(path: "/mcp_documents/1")

    expect(document.dig("sample", "users_tested")).to eq(4)
  end

  it "matches Karst::CLI::Verification's --json evidence for the identical scenario" do
    KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, = call_tool(path: "/mcp_documents/1")
    cli_document = JSON.parse(JSON.generate(Karst::CLI::Verification.new(path: "/mcp_documents/1").evidence))

    expect(strip_elapsed(document)).to eq(strip_elapsed(cli_document))
  end

  it "performs multiple sequential tool calls without leaking a prior call's identity or DB state" do
    denied_only = KarstMcpPrincipal.create!(behavior: "forbidden")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    first_document, = call_tool(path: "/mcp_documents/1")
    expect(first_document["verified_usable"]).to be(false)

    KarstMcpPrincipal.create!(behavior: "ok")
    second_document, = call_tool(path: "/mcp_documents/1")
    expect(second_document["verified_usable"]).to be(true)

    third_document, = call_tool(path: "/mcp_documents/1")
    tested_ids = third_document.dig("sample", "outcomes").flat_map { |o| o["principals"] }.map { |p| p["id"] }
    expect(tested_ids).to include(denied_only.id)
  end

  it "preserves write and rollback-isolation evidence for a mutating request" do
    writer = KarstMcpPrincipal.create!(behavior: "ok")
    Karst.config.principals = -> { KarstMcpPrincipal.all }

    document, = call_tool(path: "/mcp_documents/write")

    outcome = document["verified_outcome"]
    expect(outcome).to include("writes_observed" => true, "write_count" => 1, "database_rollback_attempted" => true)
    expect(document.dig("sample", "database_isolation")).to eq("same_connection_rollback_attempted")
    expect(writer.reload.visits).to eq(0)
  end

  def strip_elapsed(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), memo| memo[k] = strip_elapsed(v) unless k == "elapsed_ms" }
    when Array
      value.map { |item| strip_elapsed(item) }
    else
      value
    end
  end
end
# rubocop:enable Metrics/BlockLength
