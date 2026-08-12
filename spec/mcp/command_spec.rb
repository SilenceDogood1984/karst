# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rails/commands/karst/mcp/mcp_command"

RSpec.describe Rails::Command::Karst::McpCommand do
  subject(:command) { described_class.new }

  describe "optional dependency loading" do
    it "does not load MCP merely by loading the command" do
      script = <<~RUBY
        require "rails/commands/karst/mcp/mcp_command"
        abort "MCP was loaded" if defined?(MCP)
      RUBY

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

      expect(status).to be_success, stderr
    end

    it "fails with an actionable message when the supported MCP dependency is unavailable" do
      allow(command).to receive(:gem).with("mcp", "~> 0.9.0").and_raise(Gem::LoadError)

      expect { command.perform }
        .to raise_error(SystemExit)
        .and output(/Add gem "mcp", "~> 0\.9\.0" to your Gemfile and run bundle install/).to_stderr
    end
  end
end
