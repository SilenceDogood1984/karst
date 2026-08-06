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

    it "receives five monotonic notification values once and stops after unsubscribe" do
      calls = []
      subscription = described_class.new(callback: proc { |*arguments| calls << arguments })
      subscription.subscribe!
      subscription.subscribe!

      ActiveSupport::Notifications.instrument("sql.active_record", arbitrary: Object.new)
      expect(calls.length).to eq(1)
      name, started, finished, transaction_id, payload = calls.first
      expect(name).to eq("sql.active_record")
      expect(started).to be_a(Numeric)
      expect(finished).to be >= started
      expect(transaction_id).to be_a(String)
      expect(payload).to include(:arbitrary)

      subscription.unsubscribe!
      ActiveSupport::Notifications.instrument("sql.active_record", arbitrary: Object.new)
      expect(calls.length).to eq(1)
    ensure
      subscription&.unsubscribe!
    end

    it "contains errors raised by Karst-owned callback work" do
      subscription = described_class.new(callback: proc { raise "Karst callback failure" })
      subscription.subscribe!

      expect { ActiveSupport::Notifications.instrument("sql.active_record") }.not_to raise_error
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

  it "can be required outside an application without loading Active Record" do
    script = 'require "karst"; abort if defined?(ActiveRecord)'
    _output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

    expect(status).to be_success
  end

  it "uses the same version as the gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../karst.gemspec", __dir__))

    expect(described_class::VERSION).to eq(gemspec.version.to_s)
  end
end
# rubocop:enable Metrics/BlockLength
