# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Karst page-local badge" do
  # Every example boots a real Rails::Application (spec/support/badge_application.rb)
  # in its own subprocess and drives it through Rack::MockRequest, so what is
  # asserted here came from genuine ActionController dispatch and a genuine
  # process_action.action_controller notification -- never a hand-built
  # controller/action pair.
  def run_script(script:, rails_env: "development", extra_env: {})
    harness = File.expand_path("../support/badge_application", __dir__)
    full_script = "require #{harness.inspect}\n#{script}"

    Open3.capture2e(
      { "RAILS_ENV" => rails_env }.merge(extra_env),
      RbConfig.ruby,
      "-I#{File.expand_path('../../lib', __dir__)}",
      "-e",
      full_script
    )
  end

  def mock_setup
    <<~RUBY
      require "rack/mock"
      MOCK = Rack::MockRequest.new(BadgeApplication)
      # Badge only ever rewrites a body that reports itself bufferable via
      # Rack's own to_ary idiom (see Karst::Web::Badge). Under Rack 2 (only
      # the rails_7_0 compatibility target), ActionDispatch's older RackBody
      # wrapper never exposes to_ary, so Badge intentionally never injects
      # there -- a documented, safe no-op, not a bug this suite should hide.
      BUFFERABLE = Rack.release.split(".").first.to_i >= 3
    RUBY
  end

  describe "html injection" do
    it "injects a badge linking to the exact controller/action/method, and fixes up Content-Length" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        response = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200, got \#{response.status}" unless response.status == 200

        if BUFFERABLE
          href = "controller=BadgePagesController&amp;action=show&amp;method=GET&amp;path=%2Fbadge_pages%2F1"
          abort "expected badge href, got:\\n\#{response.body}" unless response.body.include?(href)
          abort "expected the badge before </body>" unless response.body.end_with?("</a></body></html>")
          unless response.headers["content-length"].to_i == response.body.bytesize
            abort "Content-Length \#{response.headers['content-length']} != actual \#{response.body.bytesize}"
          end
        else
          abort "expected the host page unmodified" unless response.body.include?("<h1>Page 1</h1>")
        end
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "dynamic route identity" do
    it "shares one catalog identity across different dynamic ids on the same route" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        one = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
        other = MOCK.get("/badge_pages/999", "REMOTE_ADDR" => "127.0.0.1")

        if BUFFERABLE
          identity = "controller=BadgePagesController&amp;action=show&amp;method=GET"
          abort "expected shared identity on id 1" unless one.body.include?(identity)
          abort "expected shared identity on id 999" unless other.body.include?(identity)
          abort "expected id 1's own observed path" unless one.body.include?("path=%2Fbadge_pages%2F1\\"")
          abort "expected id 999's own observed path" unless other.body.include?("path=%2Fbadge_pages%2F999")
        end
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "ineligible responses are left untouched" do
    it "does not inject into JSON, redirect, Turbo Stream, downloads, or body-tag-less fragments" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}

        json = MOCK.get("/badge_pages/1/data", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected untouched JSON body" if json.body.include?("/karst?controller=")
        abort "expected json content-type" unless json.headers["content-type"].to_s.include?("application/json")

        redirected = MOCK.get("/badge_pages/1/redirect", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected a redirect status" unless redirected.status == 302
        abort "expected no badge in a redirect" if redirected.body.include?("/karst?controller=")

        stream = MOCK.get("/badge_pages/1/stream", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected no badge in a Turbo Stream response" if stream.body.include?("/karst?controller=")

        download = MOCK.get("/badge_pages/1/download", "REMOTE_ADDR" => "127.0.0.1")
        disposition = download.headers["content-disposition"].to_s
        abort "expected attachment disposition" unless disposition.include?("attachment")
        abort "expected no badge in a file download" if download.body.include?("/karst?controller=")

        fragment = MOCK.get("/badge_pages/1/fragment", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected no badge in a body-tag-less fragment" if fragment.body.include?("/karst?controller=")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "/karst itself" do
    it "is never recursively badged, and shows only URL identity when reached via a badge-shaped link" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        panel = MOCK.get("/karst", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected no recursive badge on /karst" if panel.body.include?('href="/karst?controller=')

        linked = MOCK.get(
          "/karst?controller=BadgePagesController&action=show&method=GET&path=%2Fbadge_pages%2F1",
          "REMOTE_ADDR" => "127.0.0.1"
        )
        abort "expected method+path context" unless linked.body.include?("GET /badge_pages/1")
        abort "controller/action identity leaked into the panel" if linked.body.include?("BadgePagesController#show")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "locality and environment" do
    it "does not inject a badge for a nonlocal request" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        response = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "203.0.113.5")
        abort "expected no badge for a nonlocal request" if response.body.include?("/karst?controller=")
        abort "expected the host body otherwise unchanged" unless response.body.include?("<h1>Page 1</h1>")
      RUBY

      expect(status).to be_success, output
    end

    it "never loads Karst::Web::Middleware, and injects nothing, in production" do
      output, status = run_script(rails_env: "production", script: <<~RUBY)
        abort "Karst::Web::Middleware should not load in production" if Object.const_defined?("Karst::Web::Middleware")
        #{mock_setup}
        response = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200, got \#{response.status}" unless response.status == 200
        abort "expected no badge in production" if response.body.include?("/karst?controller=")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "CSP-aware styling" do
    it "omits the inline style only when the host response's own CSP forbids unsafe-inline styles" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        csp = MOCK.get("/badge_pages/1/csp", "REMOTE_ADDR" => "127.0.0.1")
        expected_csp = "default-src 'self'; style-src 'self'"
        abort "Karst must never rewrite the host CSP header" unless csp.headers["Content-Security-Policy"] == expected_csp

        if BUFFERABLE
          plain = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
          abort "expected an inline style with no host CSP present" unless plain.body.include?(' style="')
          abort "expected no inline style under a strict host CSP" if csp.body.include?(' style="')
          unless csp.body.include?("/karst?controller=BadgePagesController")
            abort "expected a badge link even without styling"
          end
        end
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "catalog integration" do
    it "shows a quiet label for missing/invalid catalogs and an unrelated route, without breaking the host page" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}

        missing = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200 with no catalog artifact yet" unless missing.status == 200
        abort "expected a quiet label for a missing catalog" if BUFFERABLE && !missing.body.include?(">Karst<")

        scenarios_path = Rails.root.join("tmp", "karst", "scenarios.json")
        FileUtils.mkdir_p(File.dirname(scenarios_path))
        File.write(scenarios_path, "not valid json")

        invalid = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
        abort "expected 200 with a malformed catalog artifact" unless invalid.status == 200
        abort "expected a quiet label for an invalid catalog" if BUFFERABLE && !invalid.body.include?(">Karst<")
      RUBY

      expect(status).to be_success, output
    end

    it "derives the badge count from a real Catalog artifact without exposing it in the panel" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}
        require "karst/spec/reporter"
        require "karst/spec/request_observation"
        require "karst/spec/example_observation"

        request = Karst::Spec::RequestObservation.new(
          sequence: 0, http_method: "GET", path: "/badge_pages/1", route_pattern: "/badge_pages/:id(.:format)",
          controller: "BadgePagesController", action: "show", format: "html", status: 200, redirect_location: nil,
          principal_before: nil, principal_after: nil, principal_changed: false
        )
        example = Karst::Spec::ExampleObservation.new(
          example_id: "./spec/badge_fixture_spec.rb[1:1]", file_path: "spec/badge_fixture_spec.rb", line_number: 5,
          spec_type: :request, description_parts: ["shows the badge fixture route"],
          full_description: "shows the badge fixture route", karst_explicit: false, karst_name: nil,
          outcome: :passed, requests: [request]
        )
        reporter = Karst::Spec::Reporter.new
        reporter.record(example)
        reporter.write(Rails.root.join("tmp", "karst", "scenarios.json").to_s)

        if BUFFERABLE
          ready = MOCK.get("/badge_pages/1", "REMOTE_ADDR" => "127.0.0.1")
          abort "expected a count of 1, got:\\n\#{ready.body}" unless ready.body.include?(">Karst · 1<")

          unrelated = MOCK.get("/others/1", "REMOTE_ADDR" => "127.0.0.1")
          abort "expected a zero count for an unrelated route" unless unrelated.body.include?(">Karst · 0<")
        end

        panel = MOCK.get(
          "/karst?controller=BadgePagesController&action=show&method=GET&path=%2Fbadge_pages%2F1",
          "REMOTE_ADDR" => "127.0.0.1"
        )
        abort "expected method+path context" unless panel.body.include?("GET /badge_pages/1")
        abort "catalog evidence leaked into the panel" if panel.body.include?("shows the badge fixture route")
        abort "spec evidence leaked into the panel" if panel.body.include?("Spec evidence")
      RUBY

      expect(status).to be_success, output
    end
  end

  describe "concurrency" do
    it "keeps concurrent requests' controller/action context isolated across threads" do
      output, status = run_script(script: <<~RUBY)
        #{mock_setup}

        threads = 24.times.map do |i|
          Thread.new do
            if i.even?
              response = MOCK.get("/badge_pages/\#{i}", "REMOTE_ADDR" => "127.0.0.1")
              [:pages, i, response.body]
            else
              response = MOCK.get("/others/\#{i}", "REMOTE_ADDR" => "127.0.0.1")
              [:other, i, response.body]
            end
          end
        end

        if BUFFERABLE
          threads.map(&:value).each do |kind, i, body|
            if kind == :pages
              abort "request \#{i}: expected BadgePagesController identity" unless body.include?("controller=BadgePagesController&amp;action=show")
              abort "request \#{i}: cross-talk from BadgeOtherController" if body.include?("BadgeOtherController")
            else
              abort "request \#{i}: expected BadgeOtherController identity" unless body.include?("controller=BadgeOtherController&amp;action=show")
              abort "request \#{i}: cross-talk from BadgePagesController" if body.include?("controller=BadgePagesController")
            end
          end
        else
          threads.each(&:value)
        end
      RUBY

      expect(status).to be_success, output
    end
  end
end

# rubocop:enable Metrics/BlockLength
