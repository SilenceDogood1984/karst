# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "json"

# The multi-Devise counterpart to spec/integration/mcp_stdio_spec.rb: proves
# `bin/rails karst:mcp` (via Karst::Mcp::Server.run!, see that file for why)
# against the same real, two-mapping Devise/Warden host used by
# spec/integration/multi_devise_golden_path_integration_spec.rb, talking to it
# only over real stdio JSON-RPC. Every example here launches its own fresh OS
# process, so -- unlike two real-Devise Rails::Application boots sharing one
# rspec process -- there is no risk of Devise::Engine state colliding with
# any other spec file.
# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst MCP server over real stdio, real multi-Devise host" do
  # rubocop:disable Metrics/MethodLength
  def fixture_script(selected:, setup: "")
    support = File.expand_path("../support/multi_devise_application", __dir__)
    <<~RUBY
      require #{support.inspect}
      require "karst/mcp/server"

      # spec/support/multi_devise_application.rb flips Rails.env to
      # "development" only for its own initialize! call, then restores it
      # (see that file) -- exactly right for booting alongside other
      # "test"-env fixtures in one rspec process, but this process serves
      # requests afterward, and Access::Sweep itself refuses to run outside
      # a real development boot. A one-shot MCP subprocess has no other
      # fixture to share Rails.env with, so it is flipped for good here,
      # matching spec/integration/mcp_stdio_spec.rb's own fixture.
      Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("development") }

      selection_dir = Dir.mktmpdir("karst-mcp-multi-devise-selection")
      Karst::Access::PrincipalSourceSelection.define_singleton_method(:path) do
        File.join(selection_dir, "selection.json")
      end
      approvals_dir = Dir.mktmpdir("karst-mcp-multi-devise-approvals")
      Karst::Access::PopulationApprovals.define_singleton_method(:path) do
        File.join(approvals_dir, "approvals.json")
      end

      Karst::Access::PrincipalSourceSelection.replace(#{selected.inspect})

      #{setup}

      Karst::Mcp::Server.run!
    RUBY
  end
  # rubocop:enable Metrics/MethodLength

  def run_requests(*requests, selected:, setup: "")
    stdin_data = requests.map { |request| JSON.generate(request) }.join("\n") << "\n"

    Open3.capture3(
      { "RAILS_ENV" => "test" },
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e",
      fixture_script(selected: selected, setup: setup), stdin_data: stdin_data
    )
  end

  def initialize_request(id: 1)
    { jsonrpc: "2.0", id: id, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "0" } } }
  end

  def tool_call_request(id:, arguments:)
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: "verify_access", arguments: arguments } }
  end

  it "honors a saved User-only selection, verifying only against the :karst_multi_user Warden scope" do
    setup = <<~RUBY
      KarstMultiUser.create!(email: "mcp-user@example.com", password: "password123!")
    RUBY

    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_multi_secrets/1" }),
      selected: ["KarstMultiUser"], setup: setup
    )

    expect(status).to be_success
    frame = stdout.each_line.map { |line| JSON.parse(line) }.find { |item| item["id"] == 2 }
    document = JSON.parse(frame.dig("result", "content", 0, "text"))

    expect(document["verified_usable"]).to be(true)
    expect(document.dig("verified_principal", "model")).to eq("KarstMultiUser")
  end

  it "honors an approved candidate population for the selected Admin model" do
    setup = <<~RUBY
      rare_admin = KarstMultiAdmin.create!(email: "rare-admin@example.com", password: "password123!")
      KarstMultiSuperGrant.create!(karst_multi_admin: rare_admin)
      27.times { |i| KarstMultiAdmin.create!(email: "admin\#{i}@example.com", password: "password123!") }
      Karst::Access::PopulationApprovals.replace(
        [Karst::Access::PopulationApprovals::Entry.new(model_name: "KarstMultiAdmin", method_name: "super_admins")]
      )
      Karst.config.access_sweep_limit = 3
      Object.const_set(:KARST_MCP_RARE_ADMIN_ID, rare_admin.id)
    RUBY

    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_multi_super_secrets/1" }),
      selected: ["KarstMultiAdmin"], setup: setup
    )

    expect(status).to be_success
    frame = stdout.each_line.map { |line| JSON.parse(line) }.find { |item| item["id"] == 2 }
    document = JSON.parse(frame.dig("result", "content", 0, "text"))

    expect(document["verified_usable"]).to be(true)
    expect(document.dig("source", "type")).to eq("population")
    expect(document.dig("source", "name")).to eq("super_admins")
    expect(document.dig("verified_principal", "model")).to eq("KarstMultiAdmin")
  end

  it "keeps both selected sources independently queryable and leaks no Warden identity between " \
     "sequential calls against a User route and an Admin route" do
    setup = <<~RUBY
      KarstMultiUser.create!(email: "mcp-multi-user@example.com", password: "password123!")
      KarstMultiAdmin.create!(email: "mcp-multi-admin@example.com", password: "password123!")
    RUBY

    stdout, _stderr, status = run_requests(
      initialize_request(id: 1),
      { jsonrpc: "2.0", method: "notifications/initialized" },
      tool_call_request(id: 2, arguments: { path: "/karst_multi_secrets/1" }),
      tool_call_request(id: 3, arguments: { path: "/karst_multi_admin_secrets/1" }),
      selected: %w[KarstMultiUser KarstMultiAdmin], setup: setup
    )

    expect(status).to be_success
    frames = stdout.each_line.map { |line| JSON.parse(line) }
    user_document = JSON.parse(frames.find { |f| f["id"] == 2 }.dig("result", "content", 0, "text"))
    admin_document = JSON.parse(frames.find { |f| f["id"] == 3 }.dig("result", "content", 0, "text"))

    expect(user_document["verified_usable"]).to be(true)
    expect(user_document.dig("verified_principal", "model")).to eq("KarstMultiUser")
    expect(admin_document["verified_usable"]).to be(true)
    expect(admin_document.dig("verified_principal", "model")).to eq("KarstMultiAdmin")
  end
end
# rubocop:enable Metrics/BlockLength
