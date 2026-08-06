# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "open3"
require "rbconfig"
require "karst"

RSpec.describe Karst do
  describe "configuration" do
    it "is disabled by default outside Rails" do
      expect(described_class.enabled?).to be(false)
    end

    it "yields its single process-level configuration and reflects changes" do
      original = described_class.config

      described_class.configure { |configuration| configuration.enabled = true }

      expect(described_class.config).to equal(original)
      expect(described_class.enabled?).to be(true)
    end
  end

  describe "subscription lifecycle" do
    before do
      described_class.unsubscribe!
      described_class.config.enabled = true
    end

    it "installs one subscription and reports its state" do
      described_class.subscribe!
      owned_subscription = described_class.send(:subscription)

      expect(described_class).to be_subscribed
      expect { described_class.subscribe! }.not_to(change { owned_subscription.instance_variable_get(:@handle) })
    end

    it "unsubscribes idempotently and can subscribe again" do
      expect { described_class.unsubscribe! }.not_to raise_error
      described_class.subscribe!
      described_class.unsubscribe!

      expect(described_class).not_to be_subscribed
      expect { described_class.unsubscribe! }.not_to raise_error

      described_class.subscribe!
      expect(described_class).to be_subscribed
    end

    it "does not subscribe while disabled" do
      described_class.config.enabled = false

      described_class.subscribe!

      expect(described_class).not_to be_subscribed
    end
  end

  describe Karst::Subscription do
    require "active_support"
    require "active_support/notifications"

    it "receives notifications once and stops receiving them after unsubscribe" do
      calls = 0
      subscription = described_class.new(callback: proc { calls += 1 })
      subscription.subscribe!
      subscription.subscribe!

      ActiveSupport::Notifications.instrument("sql.active_record", arbitrary: Object.new)
      expect(calls).to eq(1)

      subscription.unsubscribe!
      ActiveSupport::Notifications.instrument("sql.active_record", arbitrary: Object.new)
      expect(calls).to eq(1)
    ensure
      subscription&.unsubscribe!
    end

    it "does not retain arbitrary payload objects" do
      subscription = described_class.new
      payload_object = Object.new
      subscription.subscribe!

      ActiveSupport::Notifications.instrument("sql.active_record", arbitrary: payload_object)

      expect(subscription.instance_variables.map { |name| subscription.instance_variable_get(name) })
        .not_to include(payload_object)
    ensure
      subscription&.unsubscribe!
    end
  end

  it "can be required without Rails being loaded" do
    script = 'require "karst"; abort if defined?(Rails)'
    _output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

    expect(status).to be_success
  end

  it "uses the same version as the gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../karst.gemspec", __dir__))

    expect(described_class::VERSION).to eq(gemspec.version.to_s)
  end
end
# rubocop:enable Metrics/BlockLength
