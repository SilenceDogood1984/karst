# frozen_string_literal: true

require "spec_helper"
require "karst"

WardenConcurrencySpecPrincipal = Struct.new(:id)

# A minimal stand-in for Warden::Manager's own class-level on_request hook
# registry and per-request dispatch -- real enough to prove the queue/
# consume contract Karst::Identity::WardenAdapter.install_hook! relies on,
# without a full Warden::Manager Rack cycle (see
# spec/integration/devise_golden_path_integration_spec.rb for that hook
# installed by the real gem, end to end, on a single thread).
class WardenConcurrencySpecManager
  class << self
    def hooks
      @hooks ||= []
    end

    def on_request(&block)
      hooks << block
    end
  end
end

# Responds like the pre-dispatch integration session
# Karst::Identity::WardenAdapter#deferrable? requires: not a Hash, and
# responds to #request (env not yet populated, so #assume finds no existing
# proxy and queues instead of raising).
WardenConcurrencySpecSession = Struct.new(:request)

# PR #59 introduced one process-global Warden::Manager.on_request hook,
# shared by every concurrent thread of a real development server, backed
# only by Karst::ExecutionContext's own thread-local storage to keep
# concurrent threads from observing each other's queued identity. This file
# proves that contract directly, rather than only indirectly through a
# single-threaded real Rack request.
# rubocop:disable Metrics/BlockLength
RSpec.describe "Karst::Identity::WardenAdapter concurrency" do
  let(:proxy) { instance_double("Warden proxy", set_user: nil, logout: nil) }

  before do
    stub_const("Warden::Manager", WardenConcurrencySpecManager)
    WardenConcurrencySpecManager.hooks.clear
    # .install_hook! guards itself with a class-level @installed flag so it
    # only ever registers once per real process -- reset here so each
    # example sees it as fresh as an actual new process would.
    Karst::Identity::WardenAdapter.instance_variable_set(:@installed, false)
  end

  def dispatch(proxy_double)
    WardenConcurrencySpecManager.hooks.each { |hook| hook.call(proxy_double) }
  end

  it "consumes a queued principal only on the thread that queued it, applying it to that thread's own " \
     "dispatched proxy" do
    principal = WardenConcurrencySpecPrincipal.new(1)
    adapter = Karst::Identity::WardenAdapter.new(scope: :user)

    adapter.assume(WardenConcurrencySpecSession.new, principal)
    dispatch(proxy)

    expect(proxy).to have_received(:set_user).with(principal, scope: :user)
  end

  it "does not let a concurrent thread's own Warden request inherit another thread's queued principal" do
    principal = WardenConcurrencySpecPrincipal.new(1)
    adapter = Karst::Identity::WardenAdapter.new(scope: :user)
    other_thread_proxy = instance_double("Warden proxy", set_user: nil, logout: nil)

    adapter.assume(WardenConcurrencySpecSession.new, principal)

    Thread.new { dispatch(other_thread_proxy) }.join

    expect(other_thread_proxy).not_to have_received(:set_user)

    # The principal is still queued for the thread that actually queued it
    # -- a concurrent thread merely observing the same process-global hook
    # must not have consumed it on the queuing thread's behalf.
    dispatch(proxy)
    expect(proxy).to have_received(:set_user).with(principal, scope: :user)
  end

  it "deletes the pending identity once consumed, never applying it again to a later dispatch on the " \
     "same thread" do
    principal = WardenConcurrencySpecPrincipal.new(1)
    adapter = Karst::Identity::WardenAdapter.new(scope: :user)
    later_proxy = instance_double("Warden proxy", set_user: nil, logout: nil)

    adapter.assume(WardenConcurrencySpecSession.new, principal)
    dispatch(proxy)
    dispatch(later_proxy)

    expect(later_proxy).not_to have_received(:set_user)
  end

  it "leaves no pending identity behind when the caller's own block raises before Warden ever dispatches " \
     "the queued request" do
    principal = WardenConcurrencySpecPrincipal.new(1)
    session = WardenConcurrencySpecSession.new

    expect do
      Karst::Identity.with(session, principal) { raise "boom" }
    end.to raise_error(Karst::Identity::Unavailable, /no initialized Warden proxy/)

    # Nothing was left queued for a later, unrelated request on this same
    # thread to accidentally pick up.
    dispatch(proxy)
    expect(proxy).not_to have_received(:set_user)
  end
end
# rubocop:enable Metrics/BlockLength
