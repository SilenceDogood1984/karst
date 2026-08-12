# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "json"
require "karst"

# Runs the real `bin/rails karst:mcp` boot path (via Karst::Mcp::Server.run!
# directly, to avoid depending on a full generated Rails app on disk) in its
# own OS process, talking to it only over stdin/stdout exactly as a real MCP
# client would -- the one way to prove the protocol stream itself, not just
# Karst's in-process return values, stays uncorrupted by Rails boot noise or
# stderr logging. See spec/integration/mcp_server_spec.rb for the in-process
# functional coverage this file deliberately doesn't repeat.
# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst MCP server over real stdio" do
  # rubocop:disable Metrics/MethodLength
  def fixture_script
    harness = File.expand_path("../support/test_application", __dir__)
    <<~RUBY
      require #{harness.inspect}
      require "karst/mcp/server"

      ActiveRecord::Migration.verbose = false
      ActiveRecord::Schema.define do
        create_table :karst_mcp_stdio_users, force: true do |t|
          t.boolean :admin, default: false
        end
      end

      class KarstMcpStdioUser < ActiveRecord::Base; end
      KarstMcpStdioUser.create!(admin: false)
      KarstMcpStdioUser.create!(admin: true)

      class KarstMcpStdioController < ActionController::Base
        before_action :require_admin, only: :secret

        def login
          session[:user_id] = params[:id]
          head :no_content
        end

        def logout
          session.delete(:user_id)
          head :no_content
        end

        def secret
          render plain: "ok"
        end

        private

        def require_admin
          user = KarstMcpStdioUser.find_by(id: session[:user_id])
          head :forbidden unless user&.admin?
        end
      end

      KarstTestApplication.routes.draw do
        post "/karst_mcp_stdio/login", to: "karst_mcp_stdio#login"
        delete "/karst_mcp_stdio/logout", to: "karst_mcp_stdio#logout"
        get "/karst_mcp_stdio/secret", to: "karst_mcp_stdio#secret"
      end

      Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }

      Karst.configure do |config|
        config.principals = -> { KarstMcpStdioUser.order(:id) }
        config.assume_identity = lambda do |session, principal|
          session.post "/karst_mcp_stdio/login", params: { id: principal.id }
        end
        config.clear_identity = ->(session) { session.delete "/karst_mcp_stdio/logout" }
        config.assume_browser_identity = ->(request, principal) { request.session[:user_id] = principal.id }
        config.clear_browser_identity = ->(request) { request.session.delete(:user_id) }
      end

      warn("karst-mcp-fixture: deliberate stderr line, must never reach stdout")

      Karst::Mcp::Server.run!
    RUBY
  end
  # rubocop:enable Metrics/MethodLength

  def run_requests(*requests)
    stdin_data = requests.map { |request| JSON.generate(request) }.join("\n") << "\n"

    Open3.capture3(
      { "RAILS_ENV" => "test" },
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", fixture_script,
      stdin_data: stdin_data
    )
  end

  def initialize_request(id: 1)
    { jsonrpc: "2.0", id: id, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "0" } } }
  end

  def tool_call_request(id:, arguments:)
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: "verify_access", arguments: arguments } }
  end

  it "emits only valid JSON-RPC frames on stdout, one response per request, in order" do
    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_mcp_stdio/secret" }),
      tool_call_request(id: 3, arguments: { path: "http://evil.example.com" })
    )

    expect(status).to be_success
    lines = stdout.each_line.map(&:strip).reject(&:empty?)
    parsed = lines.map { |line| JSON.parse(line) }

    expect(parsed.map { |frame| frame["id"] }).to eq([1, 2, 3])
    expect(parsed).to all(include("jsonrpc" => "2.0"))
  end

  it "returns real bounded evidence for a verified user over the wire, matching the CLI schema" do
    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_mcp_stdio/secret" })
    )
    call_response = stdout.each_line.map { |line| JSON.parse(line) }.find { |frame| frame["id"] == 2 }
    document = JSON.parse(call_response.dig("result", "content", 0, "text"))

    expect(status).to be_success
    expect(document).to include("schema_version" => 1, "verified_usable" => true)
    expect(document.dig("verified_outcome", "status")).to eq(200)
  end

  it "keeps stderr logging separate from the stdout protocol stream" do
    stdout, stderr, status = run_requests(initialize_request(id: 1))

    expect(status).to be_success
    expect(stderr).to include("karst-mcp-fixture: deliberate stderr line")
    lines = stdout.each_line.map(&:strip).reject(&:empty?)
    expect(lines).to all(satisfy { |line| JSON.parse(line).key?("jsonrpc") })
    expect(stdout).not_to include("karst-mcp-fixture")
  end

  it "serves multiple sequential tool calls in one process without leaking identity between them" do
    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_mcp_stdio/secret" }),
      tool_call_request(id: 3, arguments: { path: "/karst_mcp_stdio/secret" })
    )

    expect(status).to be_success
    frames = stdout.each_line.map { |line| JSON.parse(line) }
    [2, 3].each do |id|
      document = JSON.parse(frames.find { |frame| frame["id"] == id }.dig("result", "content", 0, "text"))
      expect(document["verified_usable"]).to be(true)
      expect(document.dig("sample", "users_tested")).to eq(2)
    end
  end
end
# rubocop:enable Metrics/BlockLength
