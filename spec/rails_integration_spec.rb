# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

require "open3"
require "rbconfig"

RSpec.describe "Rails integration" do
  def run_application(initializer_value)
    script = <<~RUBY
      require "karst"
      abort unless Karst.const_defined?(:Railtie, false)
      require "rails"
      class TestApplication < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(File::NULL)
        initializer "test.configure_karst" do
          Karst.configure { |config| config.enabled = #{initializer_value} }
        end
      end
      TestApplication.initialize!
      handle = Karst.send(:subscription).instance_variable_get(:@handle)
      Rails.application.reloader.prepare!
      abort unless Karst.subscribed? == #{initializer_value}
      abort unless Karst.send(:subscription).instance_variable_get(:@handle).equal?(handle)
    RUBY

    Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)
  end

  it "loads Karst before application boot and subscribes once after initializer configuration" do
    output, status = run_application(true)

    expect(status).to be_success, output
  end

  it "remains unsubscribed when an initializer disables Karst" do
    output, status = run_application(false)

    expect(status).to be_success, output
  end

  it "constructs the minimal SQL event shape under the installed Rails version" do
    script = <<~RUBY
      require "karst"
      require "active_support"
      require "active_support/notifications"
      events = []
      subscription = Karst::Subscription.new(receiver: events.method(:<<))
      subscription.subscribe!
      ActiveSupport::Notifications.instrument(
        "sql.active_record", name: "Synthetic Load", sql: "SELECT 1", cached: false
      )
      subscription.unsubscribe!
      event = events.fetch(0)
      abort unless events.one?
      abort unless event.instance_of?(Karst::Sql::Event)
      abort unless event.members == %i[name sql cached duration_ms started_at]
      abort unless event.name == "Synthetic Load" && event.sql == "SELECT 1"
      abort unless event.frozen? && event.name.frozen? && event.sql.frozen?
      abort unless event.cached == false
      abort unless event.duration_ms.is_a?(Float) && event.duration_ms >= 0.0
      abort unless event.started_at.is_a?(Float)
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script)

    expect(status).to be_success, output
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
