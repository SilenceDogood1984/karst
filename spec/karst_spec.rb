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

    it "defaults buffer size to 2,000 and validates configured values" do
      configuration = Karst::Configuration.new

      expect(configuration.buffer_size).to eq(2_000)
      configuration.buffer_size = 12
      expect(configuration.buffer_size).to eq(12)
      [0, -1, 1.5, "12"].each do |value|
        expect { configuration.buffer_size = value }.to raise_error(ArgumentError)
      end
    end
  end

  describe "process-level buffer" do
    before do
      described_class.unsubscribe!
      described_class.instance_variable_set(:@config, Karst::Configuration.new)
      described_class.remove_instance_variable(:@buffer) if described_class.instance_variable_defined?(:@buffer)
      if described_class.instance_variable_defined?(:@subscription)
        described_class.remove_instance_variable(:@subscription)
      end
      described_class.config.enabled = true
    end

    after { described_class.unsubscribe! }

    it "is one instance whose capacity is fixed from configuration at first use" do
      described_class.config.buffer_size = 2
      original = described_class.buffer
      described_class.config.buffer_size = 5

      expect(described_class.buffer).to equal(original)
      3.times { |event| original.call(event) }
      expect(original.to_a).to eq([1, 2])
    end

    it "constructs one buffer when first accessed concurrently" do
      allow(Karst::Buffer).to receive(:new).and_wrap_original do |constructor, **arguments|
        sleep(0.01)
        constructor.call(**arguments)
      end

      buffers = 10.times.map { Thread.new { described_class.buffer } }.map(&:value)

      expect(Karst::Buffer).to have_received(:new).once
      expect(buffers.map(&:object_id).uniq.size).to eq(1)
    end

    it "is the default subscription receiver and observes each notification once" do
      expect(described_class.send(:subscription).instance_variable_get(:@receiver)).to equal(described_class.buffer)
      described_class.subscribe!
      described_class.subscribe!

      ActiveSupport::Notifications.instrument("sql.active_record", name: "Probe", sql: "SELECT 1")

      expect(described_class.buffer.size).to eq(1)
      expect(described_class.buffer.to_a.last).to be_a(Karst::Sql::Event)
      described_class.unsubscribe!
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 2")
      expect(described_class.buffer.size).to eq(1)
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

    it "installs one subscription when called concurrently" do
      subscription = described_class.send(:subscription)
      allow(ActiveSupport::Notifications)
        .to receive(:monotonic_subscribe)
        .and_wrap_original do |subscribe, *arguments, &callback|
          sleep(0.01)
          subscribe.call(*arguments, &callback)
        end

      10.times.map { Thread.new { subscription.subscribe! } }.each(&:value)

      expect(ActiveSupport::Notifications).to have_received(:monotonic_subscribe).once
    ensure
      subscription&.unsubscribe!
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

    context "before runtime state has been constructed" do
      before do
        described_class.unsubscribe!
        if described_class.instance_variable_defined?(:@subscription)
          described_class.remove_instance_variable(:@subscription)
        end
        described_class.remove_instance_variable(:@buffer) if described_class.instance_variable_defined?(:@buffer)
      end

      it "reports that it is unsubscribed without constructing runtime state" do
        expect(described_class.subscribed?).to be(false)
        expect(described_class.instance_variable_defined?(:@subscription)).to be(false)
        expect(described_class.instance_variable_defined?(:@buffer)).to be(false)
      end

      it "unsubscribes without constructing runtime state" do
        expect(described_class.unsubscribe!).to be_nil
        expect(described_class.instance_variable_defined?(:@subscription)).to be(false)
        expect(described_class.instance_variable_defined?(:@buffer)).to be(false)
        expect(described_class.subscribed?).to be(false)
      end

      it "handles concurrent observations and unsubscriptions without constructing runtime state" do
        threads = 10.times.map do |index|
          Thread.new { index.even? ? described_class.subscribed? : described_class.unsubscribe! }
        end

        expect { threads.each(&:value) }.not_to raise_error
        expect(described_class.instance_variable_defined?(:@subscription)).to be(false)
        expect(described_class.instance_variable_defined?(:@buffer)).to be(false)
        expect(described_class.subscribed?).to be(false)
      end
    end
  end

  describe Karst::Subscription do
    require "active_support"
    require "active_support/notifications"

    it "requires a receiver" do
      expect { described_class.new }.to raise_error(ArgumentError, /receiver/)
    end

    it "converts a notification once and stops after unsubscribe" do
      events = []
      subscription = described_class.new(receiver: events.method(:<<))
      subscription.subscribe!
      subscription.subscribe!

      ActiveSupport::Notifications.instrument("sql.active_record", name: "Widget Load", sql: "SELECT 1", cached: 1)
      expect(events.length).to eq(1)
      expect(events.first).to have_attributes(
        name: "Widget Load",
        sql: "SELECT 1",
        cached: true,
        duration_ms: be_a(Float),
        monotonic_started_at: be_a(Float)
      )
      expect(events.first.duration_ms).to be >= 0.0

      subscription.unsubscribe!
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 2")
      expect(events.length).to eq(1)
    ensure
      subscription&.unsubscribe!
    end

    it "calculates controlled monotonic timing and coerces cached to Boolean" do
      events = []
      subscription = described_class.new(receiver: events.method(:<<))

      subscription.send(:receive, "sql.active_record", 12.25, 12.375, "id", { sql: "SELECT 1", cached: nil })

      expect(events.first).to have_attributes(duration_ms: 125.0, monotonic_started_at: 12.25, cached: false)
    end

    it "reports and contains errors raised by the receiver" do
      reporter = instance_double(ActiveSupport::ErrorReporter)
      allow(ActiveSupport).to receive(:error_reporter).and_return(reporter)
      expect(reporter).to receive(:report).with(instance_of(RuntimeError), handled: true, context: { source: "karst" })
      subscription = described_class.new(receiver: proc { raise "Karst receiver failure" })
      subscription.subscribe!

      expect { ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") }.not_to raise_error
    ensure
      subscription&.unsubscribe!
    end

    it "owns its strings and does not retain arbitrary payload objects" do
      events = []
      subscription = described_class.new(receiver: events.method(:<<))
      name = +"Widget Load"
      sql = +"SELECT * FROM widgets"
      payload_object = Object.new
      connection = Object.new
      subscription.subscribe!

      payload = { name: name, sql: sql, arbitrary: payload_object, connection: connection }
      ActiveSupport::Notifications.instrument("sql.active_record", payload)
      name.replace("changed")
      sql.replace("changed")

      expect(events.first).to have_attributes(name: "Widget Load", sql: "SELECT * FROM widgets")
      expect(events.first.name).to be_frozen
      expect(events.first.sql).to be_frozen
      retained_values = events.first.members.map { |member| events.first.public_send(member) }
      expect(retained_values).not_to include(payload, payload_object, connection)
    ensure
      subscription&.unsubscribe!
    end

    it "silently drops missing, nil, and non-string SQL" do
      events = []
      subscription = described_class.new(receiver: events.method(:<<))

      expect do
        subscription.send(:receive, "sql.active_record", 1.0, 2.0, "id", {})
        subscription.send(:receive, "sql.active_record", 1.0, 2.0, "id", { sql: nil })
        subscription.send(:receive, "sql.active_record", 1.0, 2.0, "id", { sql: Object.new })
      end.not_to raise_error
      expect(events).to be_empty
    end

    it "contains malformed optional values and timing" do
      events = []
      subscription = described_class.new(receiver: events.method(:<<))
      allow(ActiveSupport).to receive(:error_reporter).and_return(nil)

      expect do
        subscription.send(:receive, "sql.active_record", Object.new, 2.0, "id", { sql: "SELECT 1" })
        subscription.send(:receive, "sql.active_record", 1.0, 2.0, "id", { sql: "SELECT 1", name: Object.new })
      end.not_to output.to_stderr
      expect(events.length).to eq(1)
      expect(events.first.name).to be_nil
    end
  end

  describe Karst::Sql::Event do
    it "has only the documented immutable, value-based shape" do
      attributes = { name: "Load", sql: "SELECT 1", cached: false, duration_ms: 1.0, monotonic_started_at: 2.0 }
      event = described_class.new(**attributes)

      expect(event.members).to eq(%i[name sql cached duration_ms monotonic_started_at])
      expect(event).to eq(described_class.new(**attributes))
      expect(event).to be_frozen
      expect(event).not_to respond_to(:payload)
      expect(described_class.superclass).to eq(Data)
      expect(Karst.const_defined?(:Event, false)).to be(false)
    end
  end

  it "can be required without Rails and defaults to disabled" do
    script = <<~'RUBY'
      require "karst"
      puts "enabled=#{Karst.enabled?.inspect}"
      puts "rails=#{defined?(Rails).inspect}"
      puts "active_record=#{defined?(ActiveRecord).inspect}"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

    expect(status).to be_success
    expect(output).to eq("enabled=false\nrails=nil\nactive_record=nil\n")
  end

  it "uses the same version as the gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../karst.gemspec", __dir__))

    expect(described_class::VERSION).to eq(gemspec.version.to_s)
  end
end
# rubocop:enable Metrics/BlockLength
