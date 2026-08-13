# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require_relative "../support/test_application"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Rails integration harness" do
  before { Karst.config.enabled = true }

  it "applies application initializer configuration during boot on the intended Rails series" do
    expect(defined?(Karst)).to eq("constant")
    expect(KarstTestApplication.initializer_ran).to be(true)
    expect(Rails.application.initialized?).to be(true)
    expect(Rails.gem_version.segments.first(2).join(".")).to eq(ENV.fetch("EXPECTED_RAILS_VERSION"))
    expect(Karst).to be_enabled
  end

  it "survives a reload cycle without accumulating state" do
    previous_count = KarstTestApplication.prepare_count
    listeners = KarstTestApplication.sql_listener_count

    KarstTestApplication.run_prepare_cycle

    expect(KarstTestApplication.prepare_count).to be > previous_count
    expect(KarstTestApplication.sql_listener_count).to eq(listeners)
  end

  it "loads the host application's Rails tasks without a dangling Karst task reference" do
    expect { Rails.application.load_tasks }.not_to raise_error
  end

  # Karst captured every sql.active_record notification process-wide in an
  # earlier product direction. Nothing reports that evidence now, so a full
  # Rails boot must not reintroduce that subscription lifecycle. The exact
  # "requiring Karst adds no sql.active_record listener" check runs in a
  # clean process in spec/karst_spec.rb, where Rails' own Active Record log
  # subscriber is not there to be confused for Karst's.
  it "exposes no runtime SQL capture surface after a full Rails boot" do
    %i[buffer window subscribe! unsubscribe! subscribed?].each do |method|
      expect(Karst).not_to respond_to(method)
    end
    expect(defined?(Karst::Sql)).to be_nil
  end

  it "boots cleanly, and stays off, when application initializer configuration disables Karst" do
    harness = File.expand_path("../support/test_application", __dir__)
    script = <<~RUBY
      require #{harness.inspect}
      abort "configuration initializer did not run" unless KarstTestApplication.initializer_ran
      abort "Karst is enabled" if Karst.enabled?
      Rails.application.reloader.prepare!
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
