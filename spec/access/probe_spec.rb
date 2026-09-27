# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "action_dispatch/testing/integration"
require "active_record"
require "karst"

# The target-window mechanics of Karst::Access::Probe against a scripted
# session. What a real Rails application produces through the same call is
# exercised in spec/integration/execution_parity_spec.rb.
# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe Karst::Access::Probe do
  class ProbeSpecResponse
    attr_accessor :status, :location, :content_type
  end

  # Issues each request through the endpoint Karst hands it, as
  # ActionDispatch::Integration::Session does, then runs whatever the example
  # scripted for "the application" -- SQL, a halt, a raise.
  class ProbeSpecSession
    class << self
      attr_accessor :script
    end

    attr_reader :response

    def initialize(application)
      @application = application
      @response = ProbeSpecResponse.new
    end

    def request
      nil
    end

    def process(_method, path, **)
      env = { "PATH_INFO" => path }
      @application.call(env)
      self.class.script&.call(env)
      @response.status = 200
    end
  end

  def sql(statement)
    ActiveSupport::Notifications.instrument("sql.active_record", sql: statement)
  end

  let(:application) { ->(_env) { [200, {}, []] } }
  let(:principal) { Struct.new(:id).new(7) }

  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(ActiveRecord::Base).to receive(:transaction) do |requires_new:, &block|
      expect(requires_new).to be(true)
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    stub_const("ActionDispatch::Integration::Session", ProbeSpecSession)
    ProbeSpecSession.script = nil
    # Identity setup and teardown each run SQL of their own -- like a sign-in
    # that inserts a session row and a sign-out that deletes it.
    Karst.config.assume_identity = ->(_session, _principal) { sql("INSERT INTO sessions VALUES (1)") }
    Karst.config.clear_identity = ->(_session) { sql("DELETE FROM sessions WHERE id = 1") }
  end

  after do
    %i[assume_identity clear_identity observe_identity].each { |hook| Karst.config.public_send("#{hook}=", nil) }
  end

  def probe(script = nil)
    ProbeSpecSession.script = script
    described_class.new(application).call(principal: principal, target: "/reports/1")
  end

  describe "the target observation window" do
    it "counts the target's own writes, never identity setup's or teardown's" do
      observation = probe(->(_env) { sql("UPDATE reports SET views = views + 1") })

      expect(observation.write_count).to eq(1)
      expect(observation.identity.establishment).to eq(:established)
    end

    it "does not count Karst's own identity work applied inside the target request" do
      observation = probe(lambda do |_env|
        Karst::Identity.establishing { sql("UPDATE users SET sign_in_count = 1") }
        sql("SELECT 1")
      end)

      expect(observation.write_count).to eq(0)
    end

    it "ignores SQL another thread runs while the target is in flight" do
      observation = probe(->(_env) { Thread.new { sql("UPDATE unrelated SET x = 1") }.join })

      expect(observation.write_count).to eq(0)
    end

    it "keeps the halted callback, and nothing from before or after the target" do
      Karst.config.assume_identity = lambda do |_session, _principal|
        ActiveSupport::Notifications.instrument("halted_callback.action_controller", filter: :sign_in_gate)
      end

      observation = probe(lambda do |_env|
        ActiveSupport::Notifications.instrument("halted_callback.action_controller", filter: :authorize_admin)
      end)

      expect(observation.halted_callback).to eq(:authorize_admin)
    end
  end

  describe "failures that are not the application's" do
    it "fails loudly, without raising into the application, when its own write observer breaks" do
      allow(Karst::Access::DatabaseIsolation).to receive(:mutation?).and_raise(NoMethodError, "observer bug")
      application_saw = nil

      expect do
        probe(lambda do |_env|
          sql("UPDATE reports SET views = 1")
        rescue StandardError => e
          application_saw = e
        end)
      end.to raise_error(Karst::Access::ObservationError, /NoMethodError: observer bug/)
      expect(application_saw).to be_nil
    end

    it "reports a misconfigured observe_identity as the configuration error it is, never as the route raising" do
      Karst.config.observe_identity = "not callable"

      expect { probe }.to raise_error(Karst::Identity::ConfigurationError, /observe_identity must be callable/)
    end

    it "never reports a request that did not reach the application as the route raising" do
      allow_any_instance_of(ProbeSpecSession).to receive(:process).and_raise(URI::InvalidURIError, "bad target")

      expect { probe }.to raise_error(Karst::Access::ObservationError, /bad target/)
    end

    it "reports Karst's own sign-in failing inside the request as failed identity setup, not a route exception" do
      observation = probe(->(_env) { raise Karst::Identity::EstablishmentError, "RuntimeError: set_user broke" })

      expect(observation.exception_class).to be_nil
      expect(observation.status).to be_nil
      expect(observation.controller).to be_nil
      expect(observation.identity.establishment).to eq(:failed)
      expect(observation.identity.establishment_error).to include("set_user broke")
      expect(observation.identity.confirmation).to eq(:unobservable)
    end

    it "keeps an exception the application raised as the target's own evidence" do
      observation = probe(->(_env) { raise ArgumentError, "application bug" })

      expect(observation.exception_class).to eq("ArgumentError")
      expect(observation.status).to be_nil
    end
  end

  # Invariants 1-3: exactly one implementation executes and observes a
  # target request, and neither workflow carries a request engine of its
  # own. Checked against the source, so a second engine cannot quietly
  # reappear alongside this one.
  describe "the single execution primitive" do
    let(:lib) { File.expand_path("../../lib", __dir__) }

    def files_mentioning(pattern)
      Dir[File.join(lib, "**/*.rb")].select { |file| File.read(file).match?(pattern) }
                                     .map { |file| file.delete_prefix("#{lib}/") }
    end

    it "is the only code that opens an integration session to issue a request" do
      expect(files_mentioning(/Integration::Session\.new/)).to eq(["karst/access/probe.rb"])
    end

    it "is the only code that observes request-level instrumentation" do
      pattern = /halted_callback\.action_controller|process_action\.action_controller|render_template\.action_view/

      expect(files_mentioning(pattern)).to eq(["karst/access/probe.rb"])
    end
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
