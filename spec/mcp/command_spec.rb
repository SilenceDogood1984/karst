# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rails/commands/karst/mcp/mcp_command"

# rubocop:disable Metrics/BlockLength
RSpec.describe Rails::Command::Karst::McpCommand do
  RSpec::Matchers.define_negated_matcher :not_output, :output

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

    context "when the supported MCP dependency cannot be activated" do
      before do
        allow(command).to receive(:gem).with("mcp", ">= 1.5.0", "< 1.7").and_raise(Gem::LoadError)
      end

      it "tells an application without mcp to add it" do
        allow(Gem).to receive(:loaded_specs).and_return({})
        allow(Gem::Specification).to receive(:find_all_by_name).with("mcp").and_return([])

        expect { command.perform }
          .to raise_error(SystemExit)
          .and output(
            /optional dependency\. Add gem "mcp", ">= 1\.5\.0", "< 1\.7" to your Gemfile and run bundle install/
          ).to_stderr
      end

      it "names the installed version and the required range instead of asking for an install" do
        unsupported = Gem::Specification.new do |spec|
          spec.name = "mcp"
          spec.version = "1.7.0"
        end
        allow(Gem).to receive(:loaded_specs).and_return("mcp" => unsupported)

        expect { command.perform }
          .to raise_error(SystemExit)
          .and output(
            /found mcp 1\.7\.0, but Karst #{Regexp.escape(Karst::VERSION)} requires mcp ">= 1\.5\.0", "< 1\.7"/
          ).to_stderr
      end

      it "does not claim the dependency is missing when an unsupported version is installed" do
        unsupported = Gem::Specification.new do |spec|
          spec.name = "mcp"
          spec.version = "1.4.0"
        end
        allow(Gem).to receive(:loaded_specs).and_return("mcp" => unsupported)

        expect { command.perform }
          .to raise_error(SystemExit)
          .and output(/found mcp 1\.4\.0/).to_stderr
          .and(not_output(/optional dependency|Add gem/).to_stderr)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
