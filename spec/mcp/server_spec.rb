# frozen_string_literal: true

require "spec_helper"
require "karst/mcp/server"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Mcp::Server do
  describe ".build" do
    it "exposes exactly one tool: verify_access" do
      server = described_class.build

      expect(server.tools.keys).to eq(["verify_access"])
    end

    it "exposes no prompts or resources" do
      server = described_class.build

      expect(server.prompts).to be_empty
      expect(server.resources).to be_empty
    end

    it "advertises verify_access over the real tools/list protocol handler" do
      server = described_class.build

      response = server.handle(jsonrpc: "2.0", id: 1, method: "tools/list")

      expect(response.dig(:result, :tools).map { |tool| tool[:name] }).to eq(["verify_access"])
    end

    it "exposes no browser identity or Test As capability" do
      server = described_class.build

      names = server.tools.keys + server.instance_variable_get(:@handlers).keys
      expect(names.grep(/browser|test_as|identity/i)).to be_empty
    end

    it "exposes no arbitrary principal selection input on its one tool" do
      server = described_class.build

      properties = server.tools.fetch("verify_access").input_schema.to_h[:properties].keys
      expect(properties).not_to include(:principal, :principal_id, :user, :user_id, :population)
    end

    it "reports a stable exception to stderr rather than letting exceptions reach stdout directly" do
      server = described_class.build

      expect { server.configuration.exception_reporter.call(RuntimeError.new("boom"), nil) }
        .to output(/karst-mcp: RuntimeError: boom/).to_stderr
    end
  end
end
# rubocop:enable Metrics/BlockLength
