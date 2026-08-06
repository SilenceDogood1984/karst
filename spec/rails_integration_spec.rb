# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

require "open3"
require "rbconfig"

RSpec.describe "Rails integration" do
  def run_application(initializer_value)
    script = <<~RUBY
      require "rails"
      require "karst"
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

  it "applies initializer configuration before subscribing once, including across preparation" do
    output, status = run_application(true)

    expect(status).to be_success, output
  end

  it "remains unsubscribed when an initializer disables Karst" do
    output, status = run_application(false)

    expect(status).to be_success, output
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
