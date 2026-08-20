# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/command"
require "rails/commands/karst/reproduce/reproduce_command"

# rubocop:disable Metrics/BlockLength
RSpec.describe Rails::Command::Karst::ReproduceCommand do
  def command(*arguments)
    described_class.new([], arguments)
  end

  it "registers as karst:reproduce" do
    expect(described_class.printing_commands).to eq(["karst:reproduce"])
  end

  it "reads METHOD PATH, defaulting to GET when only a path is given" do
    expect(command.send(:parse, %w[POST /api/v1/inspections])).to eq(%w[POST /api/v1/inspections])
    expect(command.send(:parse, ["/api/v1/inspections"])).to eq(["GET", "/api/v1/inspections"])
  end

  it "refuses an empty or over-long invocation rather than guessing a target" do
    expect { command.send(:parse, []) }.to raise_error(ArgumentError, /local application path is required/)
    expect { command.send(:parse, %w[POST /a /b]) }.to raise_error(ArgumentError, /expected METHOD PATH/)
  end

  it "parses repeatable --header options into name/value pairs" do
    parsed = command("--header", "X-Api-Key: abc", "Authorization: Bearer z").send(:headers)

    expect(parsed).to eq("X-Api-Key" => "abc", "Authorization" => "Bearer z")
  end

  it "keeps a colon inside a header value" do
    expect(command("--header", "X-Trace: a:b:c").send(:headers)).to eq("X-Trace" => "a:b:c")
  end

  # A header quietly dropped would make every observation below it wrong --
  # the request Karst reports on would not be the request the developer asked
  # for.
  it "refuses an unreadable --header rather than dropping it" do
    expect { command("--header", "oops").send(:headers) }.to raise_error(ArgumentError, /Name: value/)
  end

  it "sends no headers when none are given" do
    expect(command.send(:headers)).to eq({})
  end
end
# rubocop:enable Metrics/BlockLength
