# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/command"
require "rails/commands/karst/verify/verify_command"

RSpec.describe Rails::Command::Karst::VerifyCommand do
  def command(*arguments)
    described_class.new([], arguments)
  end

  it "registers as karst:verify" do
    expect(described_class.printing_commands).to eq(["karst:verify"])
  end

  it "reads METHOD PATH, defaulting to GET when only a path is given" do
    expect(command.send(:parse, %w[POST /admin/imports/123])).to eq(%w[POST /admin/imports/123])
    expect(command.send(:parse, ["/admin/imports/123"])).to eq(["GET", "/admin/imports/123"])
  end

  it "refuses an empty or over-long invocation rather than guessing a target" do
    expect { command.send(:parse, []) }.to raise_error(ArgumentError, /local application path is required/)
    expect { command.send(:parse, %w[GET /a /b]) }.to raise_error(ArgumentError, /expected METHOD PATH/)
  end

  it "leaves --as unset by default" do
    expect(command("/admin/imports/123").options[:as]).to be_nil
  end

  it "reads a --as MODEL:ID reference from the command line" do
    expect(command("/admin/imports/123", "--as", "User:72").options[:as]).to eq("User:72")
  end

  it "reads --anonymous as a boolean, defaulting to false" do
    expect(command("/admin/imports/123").options[:anonymous]).to be(false)
    expect(command("/admin/imports/123", "--anonymous").options[:anonymous]).to be(true)
  end
end
