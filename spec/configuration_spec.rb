# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst::Configuration#principal_populations" do
  it "defaults to an empty Hash, considering no candidate populations at all" do
    expect(Karst.config.principal_populations).to eq({})
  end

  it "accepts a Hash of Symbol => callable" do
    populations = { system_admins: -> { User.system_admins }, auditors: -> { User.auditors } }
    Karst.configure { |config| config.principal_populations = populations }

    expect(Karst.config.principal_populations).to eq(populations)
  end

  it "accepts nil, resetting to no populations" do
    Karst.configure { |config| config.principal_populations = nil }

    expect(Karst.config.principal_populations).to eq({})
  end

  it "rejects a non-Symbol key" do
    expect { Karst.configure { |config| config.principal_populations = { "system_admins" => -> { User.all } } } }
      .to raise_error(ArgumentError, /populations must be a Hash of Symbol => callable/)
  end

  it "rejects a non-callable value" do
    expect { Karst.configure { |config| config.principal_populations = { system_admins: :not_callable } } }
      .to raise_error(ArgumentError, /populations must be a Hash of Symbol => callable/)
  end

  it "rejects a bare Array" do
    expect { Karst.configure { |config| config.principal_populations = %i[system_admins] } }
      .to raise_error(ArgumentError, /populations must be a Hash of Symbol => callable/)
  end

  it "wraps into the implicit :default principal source alongside config.principals" do
    admins = -> { [] }
    Karst.configure do |config|
      config.principals = -> { [] }
      config.principal_populations = { admins: admins }
    end

    expect(Karst.config.principal_sources[:default].populations).to eq(admins: admins)
  ensure
    Karst.config.principals = nil
  end
end
# rubocop:enable Metrics/BlockLength
