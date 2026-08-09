# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# The inline program intentionally keeps the Rails fixture in a fresh process,
# isolated from the separate integration fixture that loads Active Record.
# rubocop:disable Metrics/BlockLength
RSpec.describe "custom session identity" do
  it "boots without Active Record and isolates identities in an integration session" do
    fixture = File.expand_path("../support/identity_application", __dir__)
    script = <<~RUBY
      require #{fixture.inspect}

      abort "Active Record was loaded by the identity fixture" if defined?(ActiveRecord)

      user_class = Struct.new(:id)
      session = ActionDispatch::Integration::Session.new(KarstIdentityApplication)
      Karst.configure do |config|
        config.assume_identity = lambda do |target, principal|
          target.post("/karst_test_login", params: { user_id: principal.id })
        end
        config.clear_identity = ->(target) { target.delete("/karst_test_logout") }
      end

      session.get("/protected")
      abort "anonymous request was not denied: \#{session.response.status}" unless session.response.status == 401

      [user_class.new(1), user_class.new(2)].each do |user|
        Karst::Identity.with(session, user) do
          session.get("/protected")
          abort "user \#{user.id} was not allowed: \#{session.response.status}" unless session.response.status == 200
        end
        session.get("/protected")
        abort "user \#{user.id} leaked after clear: \#{session.response.status}" unless session.response.status == 401
      end

      begin
        Karst::Identity.with(session, user_class.new(3)) { raise "probe failed" }
      rescue RuntimeError => error
        raise unless error.message == "probe failed"
      end
      session.get("/protected")
      abort "identity leaked after exception: \#{session.response.status}" unless session.response.status == 401
    RUBY

    output, status = Open3.capture2e(
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      script
    )

    expect(status).to be_success, output
  end
end
# rubocop:enable Metrics/BlockLength
