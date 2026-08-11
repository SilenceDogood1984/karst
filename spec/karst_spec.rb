# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "open3"
require "rbconfig"
require "karst"

RSpec.describe Karst do
  configuration_class = Karst.const_get(:Configuration, false)
  buffer_class = Karst.const_get(:Buffer, false)
  subscription_class = Karst.const_get(:Subscription, false)

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
      configuration = configuration_class.new

      expect(configuration.buffer_size).to eq(2_000)
      configuration.buffer_size = 12
      expect(configuration.buffer_size).to eq(12)
      [0, -1, 1.5, "12"].each do |value|
        expect { configuration.buffer_size = value }.to raise_error(ArgumentError)
      end
    end

    it "defaults access sweeps to 25 and enforces the conservative hard ceiling" do
      configuration = configuration_class.new

      expect(configuration.access_sweep_limit).to eq(25)
      configuration.access_sweep_limit = 100
      expect(configuration.access_sweep_limit).to eq(100)
      [0, 101, 1.5, "25"].each do |value|
        expect { configuration.access_sweep_limit = value }.to raise_error(ArgumentError)
      end
    end

    it "defaults the principal candidate pool to 1,000 and enforces the conservative hard ceiling" do
      configuration = configuration_class.new

      expect(configuration.principal_candidate_pool_size).to eq(1_000)
      configuration.principal_candidate_pool_size = 5_000
      expect(configuration.principal_candidate_pool_size).to eq(5_000)
      configuration.principal_candidate_pool_size = 500
      expect(configuration.principal_candidate_pool_size).to eq(500)
      [0, -1, 10_001, 1.5, "500"].each do |value|
        expect { configuration.principal_candidate_pool_size = value }.to raise_error(ArgumentError)
      end
    end

    it "treats only observed 2xx statuses as usable by default and accepts a custom policy" do
      configuration = configuration_class.new
      outcome = Struct.new(:status)

      expect([200, 204, 299].map { |status| configuration.usable_access_outcome.call(outcome.new(status)) })
        .to all(be_truthy)
      expect([nil, 302, 401, 403].map { |status| configuration.usable_access_outcome.call(outcome.new(status)) })
        .to all(be_falsey)

      configuration.usable_access_outcome = ->(observed) { observed.status == 302 }
      expect(configuration.usable_access_outcome.call(outcome.new(302))).to be(true)
      expect { configuration.usable_access_outcome = :two_xx }.to raise_error(ArgumentError, /callable/)
    end

    describe "principal_dimensions" do
      it "defaults to empty and normalizes a configured Hash into PrincipalDimension instances" do
        configuration = configuration_class.new

        expect(configuration.principal_dimensions).to eq({})
        configuration.principal_dimensions = { role: :role, system_admin: :system_admin? }
        expect(configuration.principal_dimensions.keys).to eq(%i[role system_admin])
        expect(configuration.principal_dimensions.values).to all(be_a(Karst::Access::PrincipalDimension))
      end

      it "rejects a sensitive dimension name or accessor at assignment time" do
        configuration = configuration_class.new

        expect { configuration.principal_dimensions = { email: :status } }.to raise_error(ArgumentError)
        expect { configuration.principal_dimensions = { contact: :email } }.to raise_error(ArgumentError)
      end
    end

    describe "principal_sources" do
      it "is nil when neither config.principals nor config.principal_sources is configured" do
        configuration = configuration_class.new
        expect(configuration.principal_sources).to be_nil
      end

      it "wraps a bare config.principals as one implicit :default source, carrying principal_dimensions" do
        configuration = configuration_class.new
        configuration.principals = -> { [] }
        configuration.principal_dimensions = { role: :role }

        sources = configuration.principal_sources

        expect(sources.keys).to eq([:default])
        expect(sources[:default].records).to equal(configuration.principals)
        expect(sources[:default].dimensions).to have_key(:role)
      end

      it "prefers an explicit config.principal_sources over a bare config.principals" do
        configuration = configuration_class.new
        configuration.principals = -> { [] }
        configuration.principal_sources = { authors: -> { [] }, readers: -> { [] } }

        expect(configuration.principal_sources.keys).to eq(%i[authors readers])
      end

      it "normalizes an explicit Hash into PrincipalSource instances, accepting per-source dimensions" do
        configuration = configuration_class.new
        configuration.principal_sources = {
          authors: { records: -> { [] }, dimensions: { premium: :premium? } },
          readers: -> { [] }
        }

        expect(configuration.principal_sources[:authors].dimensions).to have_key(:premium)
        expect(configuration.principal_sources[:readers].dimensions).to eq({})
      end

      it "raises for an invalid principal_sources shape rather than failing later, obscurely" do
        configuration = configuration_class.new
        expect { configuration.principal_sources = [:authors] }.to raise_error(ArgumentError, /must be a Hash/)
        expect { configuration.principal_sources = { authors: 42 } }
          .to raise_error(ArgumentError, /must be callable or a Hash/)
      end
    end

    describe "artifact scenarios" do
      it "registers explicit bounded sources and scenarios" do
        configuration = configuration_class.new
        configuration.artifact_source(:imports, limit: 20) { [] }
        configured = configuration.access_scenario(:missing_import, artifact: :imports,
                                                                    path: ->(item) { "/imports/#{item.id}" },
                                                                    expect: { status: 404, body_includes: "Not found" },
                                                                    combination_limit: 10)

        expect(configuration.artifact_sources[:imports]).to have_attributes(limit: 20)
        expect(configured).to have_attributes(name: :missing_import, combination_limit: 10, stop_on_match: true)
      end

      it "requires explicit safe bounds and rejects unknown predicates and sources" do
        configuration = configuration_class.new
        expect { configuration.artifact_source(:imports, limit: 1_001) { [] } }.to raise_error(ArgumentError)
        expect do
          configuration.access_scenario(:missing, artifact: :unknown, path: ->(_item) { "/" },
                                                  expect: { status: 404 })
        end.to raise_error(ArgumentError, /unknown artifact source/)
        configuration.artifact_source(:imports, limit: 1) { [] }
        expect do
          configuration.access_scenario(:missing, artifact: :imports, path: ->(_item) { "/" },
                                                  expect: { semantic_access: true })
        end.to raise_error(ArgumentError, /unsupported expectation/)
      end
    end
  end

  describe "process-level buffer" do
    def reset_runtime!
      described_class.unsubscribe!
      configuration = described_class.const_get(:Configuration, false).new
      described_class.instance_variable_set(:@config, configuration)
      %i[@buffer @subscription].each do |variable|
        described_class.remove_instance_variable(variable) if described_class.instance_variable_defined?(variable)
      end
    end

    before do
      reset_runtime!
      described_class.config.enabled = true
    end

    after { reset_runtime! }

    it "is one instance whose capacity is fixed from configuration at first use" do
      described_class.config.buffer_size = 2
      original = described_class.buffer
      described_class.config.buffer_size = 5

      expect(described_class.buffer).to equal(original)
      3.times { |event| original.send(:call, event) }
      expect(original.to_a).to eq([1, 2])
    end

    it "does not expose evidence ingestion through the public buffer" do
      event = Karst::Sql::Event.new(
        name: nil, sql: "SELECT 1", cached: false, duration_ms: 1.0, monotonic_started_at: 1.0
      )

      expect(described_class.buffer).not_to respond_to(:call)
      expect { described_class.buffer.call(event) }.to raise_error(NoMethodError, /private method [`']call/)
      expect(described_class.buffer.size).to eq(0)
    end

    it "constructs one buffer when first accessed concurrently" do
      allow(buffer_class).to receive(:new).and_wrap_original do |constructor, **arguments|
        sleep(0.01)
        constructor.call(**arguments)
      end

      buffers = 10.times.map { Thread.new { described_class.buffer } }.map(&:value)

      expect(buffer_class).to have_received(:new).once
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

  describe "window" do
    def event(sql, started_at:)
      Karst::Sql::Event.new(name: nil, sql: sql, cached: false, duration_ms: 1.0, monotonic_started_at: started_at)
    end

    before do
      described_class.unsubscribe!
      described_class.instance_variable_set(:@config, configuration_class.new)
      described_class.remove_instance_variable(:@buffer) if described_class.instance_variable_defined?(:@buffer)
      described_class.config.buffer_size = 10
    end

    it "exists as the public entry point for a Karst::Sql::Window snapshot" do
      expect(described_class.window).to be_a(Karst::Sql::Window)
    end

    it "reads the live buffer exactly once per call" do
      buffer = described_class.buffer
      expect(buffer).to receive(:to_a).once.and_call_original

      described_class.window
    end

    it "does not construct a Window from a stale buffer reference across separate calls" do
      described_class.buffer.send(:call, event("SELECT 1", started_at: 1.0))
      first_window = described_class.window

      described_class.buffer.send(:call, event("SELECT 2", started_at: 2.0))
      second_window = described_class.window

      expect(first_window.event_count).to eq(1)
      expect(second_window.event_count).to eq(2)
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

  describe subscription_class do
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
      expect(described_class.superclass).to eq(Struct)
      expect(Karst.const_defined?(:Event, false)).to be(false)
    end
  end

  describe "public constant visibility" do
    it "keeps supported constants public" do
      expect(Karst::Sql::Event).to be_a(Class)
      expect(Karst::Sql::Shape).to be_a(Class)
      expect(Karst::Sql::Window).to be_a(Class)
      expect(Karst::VERSION).to be_a(String)
    end

    it "prevents external lookup of implementation constants" do
      expect { Karst::Configuration }.to raise_error(NameError, /private constant/)
      expect { Karst::Buffer }.to raise_error(NameError, /private constant/)
      expect { Karst::Subscription }.to raise_error(NameError, /private constant/)
      expect { Karst::Sql::Canonicalizer }.to raise_error(NameError, /private constant/)
    end
  end

  it "can be required without Rails and defaults to disabled" do
    script = <<~RUBY
      require "karst"

      abort "Karst should be disabled outside Rails" if Karst.enabled?
      abort "Karst should not load Rails" if defined?(Rails)
      abort "Karst should not load ActiveRecord" if defined?(ActiveRecord)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

    expect(status).to be_success, output
  end

  it "uses the same version as the gemspec" do
    gemspec = Gem::Specification.load(File.expand_path("../karst.gemspec", __dir__))

    expect(described_class::VERSION).to eq(gemspec.version.to_s)
  end
end
# rubocop:enable Metrics/BlockLength
