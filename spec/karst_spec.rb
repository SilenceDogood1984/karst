# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "open3"
require "rbconfig"
require "karst"

RSpec.describe Karst do
  configuration_class = Karst.const_get(:Configuration, false)

  it "loads the core without loading the optional MCP dependency" do
    script = 'require "karst"; abort "MCP was loaded" if defined?(MCP)'
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status).to be_success, stderr
  end

  describe "configuration" do
    it "yields its single process-level configuration and reflects changes" do
      original = described_class.config

      described_class.configure { |configuration| configuration.enabled = false }

      expect(described_class.config).to equal(original)
      expect(described_class.enabled?).to be(false)

      described_class.configure { |configuration| configuration.enabled = true }
      expect(described_class.enabled?).to be(true)
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

    it "defaults the population retry limit to 3 and enforces its hard ceiling" do
      configuration = configuration_class.new

      expect(configuration.population_retry_limit).to eq(3)
      configuration.population_retry_limit = 10
      expect(configuration.population_retry_limit).to eq(10)
      [0, -1, 11, 1.5, "3"].each do |value|
        expect { configuration.population_retry_limit = value }.to raise_error(ArgumentError)
      end
    end

    it "treats only an observed 200 without contrary evidence as usable and accepts a custom policy" do
      configuration = configuration_class.new
      outcome = Struct.new(:status)

      expect(configuration.usable_access_outcome.call(outcome.new(200))).to be(true)
      expect([nil, 204, 299, 302, 401, 403].map do |status|
        configuration.usable_access_outcome.call(outcome.new(status))
      end)
        .to all(be_falsey)

      configuration.usable_access_outcome = ->(observed) { observed.status == 302 }
      expect(configuration.usable_access_outcome.call(outcome.new(302))).to be(true)
      expect { configuration.usable_access_outcome = :two_xx }.to raise_error(ArgumentError, /callable/)
    end

    describe "principal_sources" do
      it "is nil when neither config.principals nor config.principal_sources is configured" do
        configuration = configuration_class.new
        expect(configuration.principal_sources).to be_nil
      end

      it "wraps a bare config.principals as one implicit :default source" do
        configuration = configuration_class.new
        configuration.principals = -> { [] }

        sources = configuration.principal_sources

        expect(sources.keys).to eq([:default])
        expect(sources[:default].records).to equal(configuration.principals)
      end

      it "carries configured principal_populations onto the implicit :default source" do
        configuration = configuration_class.new
        configuration.principals = -> { [] }
        configuration.principal_populations = { system_admins: -> { [] } }

        expect(configuration.principal_sources[:default].populations).to have_key(:system_admins)
      end

      it "prefers an explicit config.principal_sources over a bare config.principals" do
        configuration = configuration_class.new
        configuration.principals = -> { [] }
        configuration.principal_sources = { authors: -> { [] }, readers: -> { [] } }

        expect(configuration.principal_sources.keys).to eq(%i[authors readers])
      end

      it "normalizes an explicit Hash into PrincipalSource instances, accepting per-source populations" do
        configuration = configuration_class.new
        configuration.principal_sources = {
          authors: { records: -> { [] }, populations: { admins: -> { [] } } },
          readers: -> { [] }
        }

        expect(configuration.principal_sources[:authors].populations).to have_key(:admins)
        expect(configuration.principal_sources[:readers].populations).to eq({})
      end

      it "raises for an invalid principal_sources shape rather than failing later, obscurely" do
        configuration = configuration_class.new
        expect { configuration.principal_sources = [:authors] }.to raise_error(ArgumentError, /must be a Hash/)
        expect { configuration.principal_sources = { authors: 42 } }
          .to raise_error(ArgumentError, /must be callable or a Hash/)
      end
    end

    # Karst is pre-1.0 and removes configuration rather than carrying it
    # forever, but a removed option must never be silently ignored or
    # quietly reinterpreted as something else.
    describe "removed options" do
      it "names the removal and what replaced it, rather than failing generically" do
        configuration = configuration_class.new

        expect { configuration.principal_dimensions = { role: :role } }
          .to raise_error(Karst::RemovedConfiguration, /principal_dimensions was removed.*schema/m)
        expect { configuration.buffer_size = 10 }
          .to raise_error(Karst::RemovedConfiguration, /buffer_size was removed.*runtime SQL capture/m)
        expect { configuration.artifact_source(:imports, limit: 20) { [] } }
          .to raise_error(Karst::RemovedConfiguration, /artifact_source was removed/)
        expect { configuration.access_scenario(:missing, artifact: :imports, path: nil, expect: {}) }
          .to raise_error(Karst::RemovedConfiguration, /access_scenario was removed/)
      end

      it "reports a removed option as an ordinary missing method for reflection" do
        expect(configuration_class.public_instance_methods(false)).not_to include(:buffer_size)
        expect(Karst::RemovedConfiguration.superclass).to eq(NoMethodError)
      end

      it "still fails generically for an option Karst never had" do
        configuration = configuration_class.new

        expect { configuration.wharrgarbl = 1 }
          .to raise_error(an_instance_of(NoMethodError).and(satisfy { |e| !e.is_a?(Karst::RemovedConfiguration) }))
      end
    end
  end

  describe "public constant visibility" do
    it "keeps supported constants public" do
      expect(Karst::VERSION).to be_a(String)
      expect(Karst::RemovedConfiguration).to be_a(Class)
    end

    it "prevents external lookup of implementation constants" do
      expect { Karst::Configuration }.to raise_error(NameError, /private constant/)
    end
  end

  # Karst captured a process-wide sql.active_record window in an earlier
  # product direction. Nothing in Karst reads one now, so nothing installs
  # one either: a host application must not pay a per-query notification
  # callback for evidence no surface reports.
  describe "runtime SQL capture" do
    it "exposes no buffer, window, or subscription lifecycle" do
      %i[buffer window subscribe! unsubscribe! subscribed?].each do |method|
        expect(described_class).not_to respond_to(method)
      end
      expect(defined?(Karst::Sql)).to be_nil
    end

    it "installs no sql.active_record subscriber merely by being required" do
      script = <<~RUBY
        require "active_support/notifications"
        require "karst"

        listeners = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record")
        abort "Karst subscribed to sql.active_record: \#{listeners.inspect}" unless listeners.empty?
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

      expect(status).to be_success, output
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
