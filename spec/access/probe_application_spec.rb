# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "karst"

RSpec.describe Karst::Access::ProbeApplication do
  it "reports invalid host session middleware without exposing its exception message" do
    session_store = Class.new do
      def initialize(*)
        raise "database password was invalid"
      end
    end
    config = Struct.new(:session_store, :session_options, :hosts).new(session_store, {}, [])
    routes = Struct.new(:default_url_options).new({})
    application = Struct.new(:routes, :config, :env_config).new(routes, config, {})

    expect { described_class.for(application) }.to raise_error(
      described_class::ConstructionError,
      "Karst could not build the Rails probe endpoint; check the application's session store configuration"
    ) do |error|
      expect(error.message).not_to include("password")
      expect(error.cause.message).to include("password")
    end
  end
end
