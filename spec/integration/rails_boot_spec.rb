# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "open3"
require "rbconfig"
require_relative "../support/test_application"

RSpec.describe "Rails integration harness" do
  before do
    Karst.config.enabled = true
    Karst.subscribe!
  end

  it "applies configuration before one stable automatic subscription on the intended Rails series" do
    expect(defined?(Karst)).to eq("constant")
    expect(KarstTestApplication.initializer_ran).to be(true)
    expect(KarstTestApplication.subscribed_during_initializer).to be(false)
    expect(Rails.application.initialized?).to be(true)
    expect(Rails.gem_version.segments.first(2).join(".")).to eq(ENV.fetch("EXPECTED_RAILS_VERSION"))
    expect(Karst).to be_enabled
    expect(Karst).to be_subscribed
    expect(KarstTestApplication.subscription_handle_after_initialization).not_to be_nil
    expect(KarstTestApplication.listener_count_after_initialization).to eq(1)
    expect(KarstTestApplication.owned_listener_count).to eq(1)

    previous_count = KarstTestApplication.prepare_count
    subscription_handle = KarstTestApplication.owned_subscription_handle

    KarstTestApplication.run_prepare_cycle

    expect(KarstTestApplication.prepare_count).to be > previous_count
    expect(KarstTestApplication.owned_subscription_handle).to equal(subscription_handle)
    expect(KarstTestApplication.owned_listener_count).to eq(1)
  end

  it "converts a synthetic SQL notification to the minimal immutable event shape" do
    events = []
    Karst.unsubscribe!
    subscription = Karst::Subscription.new(receiver: events.method(:<<))
    subscription.subscribe!

    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT 1",
      name: "Karst integration probe"
    )

    expect(events).to contain_exactly(
      an_instance_of(Karst::Sql::Event).and(
        have_attributes(
          name: "Karst integration probe",
          sql: "SELECT 1",
          cached: false,
          duration_ms: be_a(Float),
          started_at: be_a(Float)
        )
      )
    )
    expect(events.first.members).to eq(%i[name sql cached duration_ms started_at])
    expect(events.first).to be_frozen
    expect(events.first.name).to be_frozen
    expect(events.first.sql).to be_frozen
  ensure
    subscription&.unsubscribe!
  end

  it "remains unsubscribed when application initializer configuration disables Karst" do
    harness = File.expand_path("../support/test_application", __dir__)
    script = <<~RUBY
      require #{harness.inspect}
      abort "configuration initializer did not run before subscription" unless KarstTestApplication.subscribed_during_initializer == false
      abort "Karst is enabled" if Karst.enabled?
      abort "Karst subscribed" if Karst.subscribed?
      Rails.application.reloader.prepare!
      abort "prepare cycle subscribed Karst" if Karst.subscribed?
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1")
    RUBY

    output, status = Open3.capture2e(
      { "KARST_ENABLED" => "false", "EXPECTED_RAILS_VERSION" => ENV.fetch("EXPECTED_RAILS_VERSION") },
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      script
    )

    expect(status).to be_success, output
  end
end

# rubocop:enable Metrics/BlockLength
