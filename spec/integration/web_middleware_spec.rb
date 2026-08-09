# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "open3"
require "rbconfig"
require "karst"

RSpec.describe "Karst web middleware" do
  def run_script(rails_env:, script:)
    harness = File.expand_path("../support/test_application", __dir__)
    full_script = "require #{harness.inspect}\n#{script}"

    Open3.capture2e(
      { "RAILS_ENV" => rails_env },
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      full_script
    )
  end

  # Requests are exercised against a Rack stack built directly from the
  # middleware, not through Rails' router, so a pass-through proves the
  # underlying Rack app received the request unchanged rather than Karst
  # having intercepted it.
  def request_harness
    <<~RUBY
      require "rack/mock"

      SENTINEL_BODY = "host application response"
      sentinel = lambda do |env|
        [200, { "Content-Type" => "text/plain", "X-Sentinel" => "1" }, ["\#{SENTINEL_BODY}:\#{env['PATH_INFO']}"]]
      end
      stack = Rack::Builder.new { use Karst::Web::Middleware; run sentinel }.to_app
      MOCK = Rack::MockRequest.new(stack)
    RUBY
  end

  def unsupported_phrases
    [
      "this page", "current request", "controller", "action", "n+1", "slow query",
      "problem", "user can access", "authorized", "this route", "this user"
    ]
  end

  describe "environment insertion" do
    it "is present in development" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        present = Rails.application.middleware.map(&:klass).any? { |klass| klass.name == "Karst::Web::Middleware" }
        abort "expected Karst::Web::Middleware in the development middleware stack" unless present
      RUBY

      expect(status).to be_success, output
    end

    it "is absent in test" do
      output, status = run_script(rails_env: "test", script: <<~RUBY)
        abort "Karst::Web::Middleware should not load in test" if Object.const_defined?("Karst::Web::Middleware")
      RUBY

      expect(status).to be_success, output
    end

    it "is absent in production" do
      output, status = run_script(rails_env: "production", script: <<~RUBY)
        abort "Karst::Web::Middleware should not load in production" if Object.const_defined?("Karst::Web::Middleware")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "locality" do
    it "serves loopback IPv4 requests" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200, got \#{response.status}" unless response.status == 200
        abort "expected the Karst page" unless response.body.include?("Karst")
      RUBY

      expect(status).to be_success, output
    end

    it "serves loopback IPv6 requests" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "::1")
        abort "expected 200, got \#{response.status}" unless response.status == 200
        abort "expected the Karst page" unless response.body.include?("Karst")
      RUBY

      expect(status).to be_success, output
    end

    it "falls through for a non-loopback address instead of serving the page" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "192.168.1.10")
        abort "expected the host application" unless response.body.start_with?(SENTINEL_BODY)
        abort "expected no Karst branding on a non-local fallthrough" if response.body.include?("Karst")
      RUBY

      expect(status).to be_success, output
    end

    it "does not trust X-Forwarded-For or Forwarded to establish locality" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get(
          "/karst",
          "REMOTE_ADDR" => "192.168.1.10",
          "HTTP_X_FORWARDED_FOR" => "127.0.0.1",
          "HTTP_FORWARDED" => "for=127.0.0.1"
        )
        abort "expected fallthrough despite spoofed forwarding headers" unless response.body.start_with?(SENTINEL_BODY)
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "pass-through" do
    it "delivers non-Karst paths to the underlying application unchanged" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/posts", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200, got \#{response.status}" unless response.status == 200
        abort "expected the sentinel body" unless response.body == "\#{SENTINEL_BODY}:/posts"
        abort "expected the sentinel header" unless response.headers["X-Sentinel"] == "1"
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "capture state" do
    it "represents enabled capture with an active subscription" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        Karst.config.enabled = true
        Karst.subscribe!
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected enabled capture wording" unless response.body.include?("Capture: enabled")
        abort "expected active subscription wording" unless response.body.include?("Subscription: active")
      RUBY

      expect(status).to be_success, output
    end

    it "represents disabled capture with no subscription" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        Karst.unsubscribe!
        Karst.config.enabled = false
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected disabled capture wording" unless response.body.include?("Capture: disabled")
        abort "expected inactive subscription wording" unless response.body.include?("Subscription: inactive")
      RUBY

      expect(status).to be_success, output
    end

    it "represents enabled capture that is not yet subscribed, distinct from an empty Window" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        Karst.unsubscribe!
        Karst.config.enabled = true
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected enabled capture wording" unless response.body.include?("Capture: enabled")
        abort "expected inactive subscription wording" unless response.body.include?("Subscription: inactive")
        abort "capture state must not live on Sql::Window" if Karst::Sql::Window.members.include?(:enabled)
        abort "capture state must not live on Sql::Window" if Karst::Sql::Window.members.include?(:subscribed)
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "current evidence wording" do
    it "never claims request, controller, route, or user attribution" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        downcased = response.body.downcase
        #{unsupported_phrases.inspect}.each do |phrase|
          abort "unsupported phrase present: \#{phrase}" if downcased.include?(phrase)
        end
        abort "expected explicit non-request-scoped wording" unless downcased.include?("not request-scoped")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "security" do
    it "returns the required response headers" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "missing Cache-Control" unless response.headers["Cache-Control"] == "no-store"
        abort "missing X-Robots-Tag" unless response.headers["X-Robots-Tag"] == "noindex, nofollow"
        abort "missing X-Frame-Options" unless response.headers["X-Frame-Options"] == "DENY"
        abort "missing Content-Security-Policy" if response.headers["Content-Security-Policy"].to_s.empty?
      RUBY

      expect(status).to be_success, output
    end

    it "emits one canonical lowercase cache policy for the Rack stack" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        status, headers, = Karst::Web::Panel.render
        abort "expected 200, got \#{status}" unless status == 200
        abort "expected one Cache-Control field" unless headers.keys.grep(/cache-control/i) == ["cache-control"]
        abort "expected no-store" unless headers["cache-control"] == "no-store"
      RUBY

      expect(status).to be_success, output
    end

    it "escapes a runtime-derived hostile value instead of rendering it as markup" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        hostile = "<script>alert(1)</script>"
        Karst.define_singleton_method(:window) do
          Karst::Sql::Window.new(shapes: [], declined: [], event_count: 0, capacity: hostile, saturated: false)
        end

        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "hostile value rendered unescaped" if response.body.include?(hostile)
        abort "expected the escaped form" unless response.body.include?(CGI.escapeHTML(hostile))
      RUBY

      expect(status).to be_success, output
    end
  end
end

# rubocop:enable Metrics/BlockLength
