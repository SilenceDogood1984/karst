# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::IdentityProbe do
  let(:principal) { double("principal", id: 27, class: fake_model) }
  let(:fake_model) do
    Class.new do
      def self.name
        "User"
      end
    end
  end
  let(:session) { double("session") }

  before do
    Karst.config.assume_identity = ->(_session, _principal) {}
    Karst.config.clear_identity = ->(_session) {}
    Karst.config.observe_identity = ->(_context) {}
  end

  after do
    %i[assume_identity clear_identity observe_identity].each { |hook| Karst.config.public_send("#{hook}=", nil) }
  end

  def probe_for(subject)
    described_class.new(subject)
  end

  it "describes the requested identity for a named probe, and none for an anonymous one" do
    expect(probe_for(principal).requested.id).to eq(27)
    expect(probe_for(Karst::Identity::ANONYMOUS).requested).to be_nil
    expect(probe_for(Karst::Identity::ANONYMOUS)).to be_anonymous
  end

  it "records a failed establishment instead of raising, so the request still runs and is still observed" do
    Karst.config.assume_identity = ->(_session, _principal) { raise Karst::Identity::Unavailable, "no proxy" }
    probe = probe_for(principal)

    expect { probe.establish(session) }.not_to raise_error
    expect(probe.evidence.establishment).to eq(:failed)
    expect(probe.evidence.establishment_error).to include("no proxy")
  end

  it "runs the application's own clear seam for an anonymous probe" do
    cleared = 0
    Karst.config.clear_identity = ->(_session) { cleared += 1 }
    probe = probe_for(Karst::Identity::ANONYMOUS)

    probe.establish(session)

    expect(cleared).to eq(1)
    expect(probe.evidence.establishment).to eq(:cleared)
  end

  it "records a failed anonymous clear rather than silently claiming the probe was anonymous" do
    Karst.config.clear_identity = ->(_session) { raise "logout endpoint exploded" }
    probe = probe_for(Karst::Identity::ANONYMOUS)

    probe.establish(session)

    expect(probe.evidence.establishment).to eq(:clear_failed)
    expect(probe.evidence.establishment_error).to include("logout endpoint exploded")
  end

  it "records a cleanup failure without raising out of the caller's ensure" do
    Karst.config.clear_identity = ->(_session) { raise "teardown exploded" }
    probe = probe_for(principal)
    probe.establish(session)

    expect { probe.release(session) }.not_to raise_error
    expect(probe.evidence.cleanup_error).to include("teardown exploded")
  end

  it "drops a queued Warden principal on release so it cannot leak into the next probe" do
    allow(Karst::Identity::WardenAdapter).to receive(:discard_pending!)
    probe = probe_for(principal)

    probe.release(session)

    expect(Karst::Identity::WardenAdapter).to have_received(:discard_pending!)
  end

  it "drops a queued Warden principal before an anonymous probe runs" do
    allow(Karst::Identity::WardenAdapter).to receive(:discard_pending!)

    probe_for(Karst::Identity::ANONYMOUS).establish(session)

    expect(Karst::Identity::WardenAdapter).to have_received(:discard_pending!)
  end

  it "forgets any env identity setup left behind once the target request starts" do
    Karst.config.observe_identity = ->(context) { context.env["setup.principal"] }
    probe = probe_for(principal)
    probe.capture_env({ "setup.principal" => principal }) # e.g. a sign-in request's env

    probe.begin_target
    probe.observe(:request_completion)

    expect(probe.request_env).to be_nil
    expect(probe.evidence.confirmation).to eq(:unobservable)
  end

  it "records Karst's own in-request sign-in failing as failed setup, observing nothing from that request" do
    Karst.config.observe_identity = ->(_context) { principal }
    probe = probe_for(principal)
    probe.establish(session)
    probe.capture_env({ "action_controller.instance" => nil })

    probe.establishment_failed("Karst::Identity::EstablishmentError: serializer exploded")
    probe.observe(:request_completion)
    evidence = probe.evidence

    expect(probe.request_env).to be_nil
    expect(evidence.establishment).to eq(:failed)
    expect(evidence.establishment_error).to include("serializer exploded")
    expect(evidence.confirmation).to eq(:unobservable)
    expect(evidence.observation_error).to include("before the application ran")
  end

  it "ignores observations raised on another thread" do
    probe = probe_for(principal)
    probe.capture_env({})

    Thread.new { probe.observe(:halted_callback) }.join

    expect(probe.observed_this_probe?(:halted_callback)).to be(false)
  end

  it "observes each phase exactly once, keeping the first answer for that phase" do
    observed = 0
    Karst.config.observe_identity = lambda do |_context|
      observed += 1
      nil
    end
    probe = probe_for(principal)
    probe.capture_env({})

    2.times { probe.observe(:halted_callback) }

    expect(observed).to eq(1)
  end
end
# rubocop:enable Metrics/BlockLength
