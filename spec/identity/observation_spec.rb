# frozen_string_literal: true

require "spec_helper"
require "karst"

# A stand-in for whatever the application resolved: the observer only ever
# needs a class name and an id, and must never reach for anything else.
KarstObservedRecord = Struct.new(:id) do
  def self.name
    "User"
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity::Observer do
  let(:controller) { double("controller") }
  let(:env) { { "action_controller.instance" => controller } }

  after { Karst.config.observe_identity = nil }

  it "observes what the configured seam reports the application resolved" do
    Karst.config.observe_identity = ->(context) { context.controller.current_user }
    allow(controller).to receive(:current_user).and_return(KarstObservedRecord.new(27))

    observation = described_class.observe(env)

    expect(observation).to be_observable
    expect(observation.source).to eq(:configured)
    expect(observation.principal).to eq(Karst::Identity::ObservedPrincipal.new(model_name: "User", id: 27))
  end

  it "passes the controller that actually processed the request, plus its request and env" do
    seen = nil
    Karst.config.observe_identity = lambda do |context|
      seen = context
      nil
    end

    described_class.observe(env)

    expect(seen.controller).to be(controller)
    expect(seen.env).to be(env)
  end

  it "treats nil and false as the application having resolved no principal" do
    [nil, false].each do |value|
      Karst.config.observe_identity = ->(_context) { value }
      observation = described_class.observe(env)

      expect(observation).to be_observable
      expect(observation.principal).to be_nil
    end
  end

  it "fails closed when the configured seam raises" do
    Karst.config.observe_identity = ->(_context) { raise ArgumentError, "boom" }

    observation = described_class.observe(env)

    expect(observation).not_to be_observable
    expect(observation.error).to include("ArgumentError", "boom")
  end

  it "fails closed when the observed object cannot state a stable identity" do
    Karst.config.observe_identity = ->(_context) { Object.new }

    observation = described_class.observe(env)

    expect(observation).not_to be_observable
    expect(observation.error).to include("no usable id")
  end

  it "reports a decorator or proxy as the class it actually is, never as the model it wraps" do
    decorator = Class.new(Struct.new(:id)) do
      def self.name
        "UserDecorator"
      end
    end
    Karst.config.observe_identity = ->(_context) { decorator.new(27) }

    expect(described_class.observe(env).principal.model_name).to eq("UserDecorator")
  end

  it "raises for a non-callable configuration rather than silently observing nothing" do
    Karst.config.observe_identity = "current_user"

    expect { described_class.observe(env) }.to raise_error(Karst::Identity::ConfigurationError, /callable/)
  end

  it "reads the application's own Warden proxy when no seam is configured" do
    proxy = double("warden")
    allow(proxy).to receive(:user).and_return(KarstObservedRecord.new(9))

    observation = described_class.observe(env.merge("warden" => proxy))

    expect(observation.source).to eq(:warden)
    expect(observation.principal.id).to eq(9)
  end

  it "reports no principal, not an unobservable one, when Warden has nobody" do
    proxy = double("warden")
    allow(proxy).to receive(:user).and_return(nil)

    observation = described_class.observe(env.merge("warden" => proxy))

    expect(observation).to be_observable
    expect(observation.principal).to be_nil
  end

  it "fails closed when reading the Warden proxy raises" do
    proxy = double("warden")
    allow(proxy).to receive(:user).and_raise(RuntimeError, "serializer exploded")

    expect(described_class.observe(env.merge("warden" => proxy))).not_to be_observable
  end

  it "refuses to conclude anything with no observation seam at all" do
    observation = described_class.observe(env)

    expect(observation).not_to be_observable
    expect(observation.error).to include("observe_identity")
  end

  it "refuses to conclude anything when the request environment was never captured" do
    expect(described_class.observe(nil)).not_to be_observable
  end
end
# rubocop:enable Metrics/BlockLength
