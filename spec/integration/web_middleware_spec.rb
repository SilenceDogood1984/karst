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

  def sweep_spy
    <<~RUBY
      Karst.config.principals = -> { [] }
      $karst_sweep_calls = 0
      Karst::Access::Sweep.define_singleton_method(:new) do |**_arguments|
        $karst_sweep_calls += 1
        result = Karst::Access::Result.new(
          path: "/documents", http_method: "GET", outcomes: [].freeze, elapsed_ms: 0.0,
          aborted_reason: nil, database_isolation: :same_connection_rollback_attempted
        )
        Struct.new(:result) { def call; result; end }.new(result)
      end
    RUBY
  end

  def analyze_request
    <<~RUBY
      MOCK.post(
        "/karst", "REMOTE_ADDR" => remote_address,
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        input: "operation=access_sweep&method=GET&path=%2Fdocuments"
      )
    RUBY
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

  describe "route context" do
    it "recognizes a manual GET path and renders access analysis" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        class OrganizationsController < ActionController::Base; end
        Rails.application.routes.draw { get "/organizations", to: "organizations#index" }
        response = MOCK.get(
          "/karst?operation=route_lookup&method=GET&path=%2Forganizations", "REMOTE_ADDR" => "127.0.0.1"
        )
        abort "controller/action was not derived" unless response.body.include?("OrganizationsController#index")
        abort "route context was not retained" unless response.body.include?("GET /organizations")
        abort "access analysis was not offered" unless response.body.include?("Analyze 25 principals")
      RUBY

      expect(status).to be_success, output
    end

    it "retains an exact resource path when recognizing a manual GET route" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        class OrganizationsController < ActionController::Base; end
        Rails.application.routes.draw { get "/organizations/:id", to: "organizations#show" }
        response = MOCK.get(
          "/karst?operation=route_lookup&method=GET&path=%2Forganizations%2F22", "REMOTE_ADDR" => "127.0.0.1"
        )
        abort "controller/action was not derived" unless response.body.include?("OrganizationsController#show")
        abort "exact resource path was lost" unless response.body.include?("GET /organizations/22")
        abort "access analysis was not offered" unless response.body.include?("Analyze 25 principals")
        abort "wrong sweep path" unless response.body.include?('name="path" value="/organizations/22"')
      RUBY

      expect(status).to be_success, output
    end

    it "rejects unsafe paths and clearly reports unrecognized routes" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        ["https%3A%2F%2Fexample.com%2Forganizations", "%2F%2Fexample.com%2Forganizations",
         "%2Forganizations%2F%5B", "%2Fmissing"].each do |path|
          response = MOCK.get(
            "/karst?operation=route_lookup&method=GET&path=\#{path}", "REMOTE_ADDR" => "127.0.0.1"
          )
          abort "unsafe or unknown route produced analysis" if response.body.include?("Analyze 25 principals")
          abort "missing route limitation" unless response.body.include?("Karst will not guess the route") ||
                                                  response.body.include?("valid local application path")
        end
      RUBY

      expect(status).to be_success, output
    end

    it "uses explicit query parameters and never attributes /karst to a host controller" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        response = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "falsely attributed panel route" if response.body.include?("Karst::Web::Panel#index")
        abort "expected route selector" unless response.body.include?('name="controller"')

        selected = MOCK.get("/karst?controller=PostsController&amp;action=index", "REMOTE_ADDR" => "127.0.0.1")
        abort "query changed host routing" unless selected.status == 200
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "security" do
    it "assumes and clears a scoped principal in the real browser session" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        require "rack/mock"
        require "rack/session/cookie"
        principal = Struct.new(:id).new(27)
        Karst.config.principals = -> { [principal] }
        Karst.config.assume_browser_identity = ->(request, selected) { request.session["user_id"] = selected.id }
        Karst.config.clear_browser_identity = ->(request) { request.session.delete("user_id") }
        descriptor = Karst::Identity.describe(principal)
        outcome = Karst::Access::Outcome.new(
          principal: descriptor, status: 200, redirect: nil, exception_class: nil,
          writes_observed: false, write_count: 0, elapsed_ms: 0.0, database_rollback_attempted: true
        )
        result = Karst::Access::Result.new(
          path: "/documents/22/reader", http_method: "GET", outcomes: [outcome], elapsed_ms: 0.0,
          aborted_reason: nil, database_isolation: :same_connection_rollback_attempted
        )
        Karst::Access::Sweep.define_singleton_method(:new) { |**| Struct.new(:value) { def call; value; end }.new(result) }
        host = ->(env) { [200, { "Content-Type" => "text/plain" }, ["user=\#{env['rack.session']['user_id'] || 'anonymous'}"]] }
        stack = Rack::Builder.new do
          use Rack::Session::Cookie, secret: "s" * 64
          use Karst::Web::Middleware
          run host
        end.to_app
        browser = Rack::Test::Session.new(Rack::MockSession.new(stack))
        browser.header("REMOTE_ADDR", "127.0.0.1")
        browser.post("/karst", operation: "access_sweep", method: "GET", path: "/documents/22/reader")
        token = browser.last_response.body[/name="csrf_token" value="([^"]+)"/, 1]
        abort "missing test-as token" unless token
        browser.post("/karst", operation: "test_as", csrf_token: token, principal_type: descriptor.model_name,
                     principal_id: descriptor.id, path: "/documents/22/reader?secret=discarded")
        abort "wrong return path" unless browser.last_response.status == 303 &&
                                         browser.last_response["Location"] == "/documents/22/reader"
        browser.get("/documents/22/reader")
        abort "browser identity was not retained" unless browser.last_response.body == "user=27"
        browser.post("/karst", operation: "stop_test_as", csrf_token: token, path: "/documents/22/reader")
        browser.get("/documents/22/reader")
        abort "browser identity was not cleared" unless browser.last_response.body == "user=anonymous"
      RUBY

      expect(status).to be_success, output
    end

    it "only lets a local development POST trigger an access sweep" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        #{sweep_spy}
        remote_address = "127.0.0.1"
        response = #{analyze_request}
        abort "expected panel response" unless response.body.include?("0 principals tested")
        abort "expected exactly one sweep" unless $karst_sweep_calls == 1
      RUBY

      expect(status).to be_success, output
    end

    it "falls through without triggering a sweep for a nonlocal POST" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        #{sweep_spy}
        remote_address = "192.168.1.10"
        response = #{analyze_request}
        abort "expected host fallthrough" unless response.body.start_with?(SENTINEL_BODY)
        abort "nonlocal POST triggered a sweep" unless $karst_sweep_calls.zero?
      RUBY

      expect(status).to be_success, output
    end

    it "falls through without triggering a sweep for a production POST" do
      output, status = run_script(rails_env: "production", script: <<~RUBY)
        require "karst/web/middleware"
        #{request_harness}
        #{sweep_spy}
        remote_address = "127.0.0.1"
        response = #{analyze_request}
        abort "expected host fallthrough" unless response.body.start_with?(SENTINEL_BODY)
        abort "production POST triggered a sweep" unless $karst_sweep_calls.zero?
      RUBY

      expect(status).to be_success, output
    end

    it "never lets a GET request trigger a sweep" do
      output, status = run_script(rails_env: "development", script: <<~RUBY)
        #{request_harness}
        #{sweep_spy}
        response = MOCK.get(
          "/karst?operation=access_sweep&method=GET&path=%2Fdocuments", "REMOTE_ADDR" => "127.0.0.1"
        )
        abort "expected panel response" unless response.body.include?("Karst")
        abort "GET triggered a sweep" unless $karst_sweep_calls.zero?
      RUBY

      expect(status).to be_success, output
    end

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
          Karst::Sql::Window.new(shapes: [], declined: [], event_count: hostile, capacity: 2_000, saturated: false)
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
