# frozen_string_literal: true

require "spec_helper"
require_relative "../support/test_application"

RSpec.describe "Rails integration harness" do
  it "loads Karst and initializes the test application on the intended Rails series" do
    expect(defined?(Karst)).to eq("constant")
    expect(KarstTestApplication.initializer_ran).to be(true)
    expect(Rails.application.initialized?).to be(true)
    expect(Rails.gem_version.segments.first(2).join(".")).to eq(ENV.fetch("EXPECTED_RAILS_VERSION"))
  end

  it "supports reloader preparation cycles" do
    previous_count = KarstTestApplication.prepare_count

    KarstTestApplication.run_prepare_cycle

    expect(KarstTestApplication.prepare_count).to be > previous_count
  end

  it "can instrument a synthetic Active Record SQL notification" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      events << event
    end

    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT 1",
      name: "Karst integration probe"
    )

    expect(events.one? { |event| event.payload[:sql] == "SELECT 1" }).to be(true)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
