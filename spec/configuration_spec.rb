# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst::Configuration#principal_populations" do
  describe "default usable access outcome" do
    subject(:usable) { Karst.config.usable_access_outcome }

    def outcome(status:, exception_class: nil, halted_callback: nil)
      Struct.new(:status, :exception_class, :halted_callback)
            .new(status, exception_class, halted_callback)
    end

    it "requires exactly 200 without an exception or halted callback" do
      expect(usable.call(outcome(status: 200))).to be(true)
      expect(usable.call(outcome(status: 204))).to be(false)
      expect(usable.call(outcome(status: 200, halted_callback: :authorize_admin))).to be(false)
      expect(usable.call(outcome(status: 204, halted_callback: :redirect_if_suspended))).to be(false)
      expect(usable.call(outcome(status: 302))).to be(false)
      expect(usable.call(outcome(status: 200, exception_class: "RuntimeError"))).to be(false)
    end

    it "remains replaceable with an application-specific policy" do
      Karst.config.usable_access_outcome = ->(observed) { observed.status == 204 }

      expect(Karst.config.usable_access_outcome.call(outcome(status: 204))).to be(true)
    end
  end

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
