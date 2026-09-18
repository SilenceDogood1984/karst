# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/reproduction/sanitizer"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Reproduction::Sanitizer do
  # Karst::Reproduction::Sanitizer reads exactly one thing off Rails --
  # the host application's own config.filter_parameters -- so a full Rails
  # boot would only obscure what this class actually depends on.
  def with_filter_parameters(filters)
    config = double("config", filter_parameters: filters)
    application = double("application", config: config)
    stub_const("Rails", double("Rails", application: application))
  end

  describe ".parameters" do
    it "defers to the host application's own config.filter_parameters" do
      with_filter_parameters([:passcode, /vault/])

      result = described_class.parameters({ "passcode" => "hunter2", "vault_id" => "v1", "serial" => "ABC123" })

      expect(result).to eq("passcode" => "<FILTERED>", "vault_id" => "<FILTERED>", "serial" => "ABC123")
    end

    it "applies Rails' filtering through nested hashes and arrays, not just the top level" do
      with_filter_parameters([:passcode])

      result = described_class.parameters({
                                            "inspection" => { "passcode" => "hunter2",
                                                              "readings" => [{ "passcode" => "hunter2",
                                                                               "value" => 3 }] }
                                          })

      expect(result).to eq("inspection" => { "passcode" => "<FILTERED>",
                                             "readings" => [{ "passcode" => "<FILTERED>", "value" => 3 }] })
    end

    it "masks credentials the application's own filters miss" do
      with_filter_parameters([])

      credentials = { "api_key" => "sk-live", "access_token" => "t", "client_secret" => "s",
                      "password" => "p", "csrf_token" => "c", "signature" => "sig",
                      "authenticity_token" => "a", "session_id" => "s" }

      result = described_class.parameters(credentials)

      expect(result.values).to all(eq("<FILTERED>"))
    end

    it "leaves ordinary business fields alone, so a recipe stays usable" do
      with_filter_parameters([])

      result = described_class.parameters({ "serial_number" => "ABC123", "status" => "passed",
                                            "inspected_at" => "2026-08-20T14:30:00Z", "monkey" => "yes" })

      expect(result).to eq("serial_number" => "ABC123", "status" => "passed",
                           "inspected_at" => "2026-08-20T14:30:00Z", "monkey" => "yes")
    end

    it "rewrites Rails' own mask to Karst's placeholder convention" do
      with_filter_parameters([:passcode])

      expect(described_class.parameters({ "passcode" => "x" })["passcode"]).to eq("<FILTERED>")
    end

    it "stringifies symbol keys so a recipe has one key convention" do
      with_filter_parameters([])

      expect(described_class.parameters({ serial: "ABC123" })).to eq("serial" => "ABC123")
    end

    it "returns an empty hash for nil rather than raising" do
      with_filter_parameters([])

      expect(described_class.parameters(nil)).to eq({})
    end

    it "falls back to its own net when the application's filter_parameters is unreadable" do
      unreadable = double("Rails")
      allow(unreadable).to receive(:application).and_raise(RuntimeError)
      stub_const("Rails", unreadable)

      expect(described_class.parameters({ "api_key" => "sk-live" })).to eq("api_key" => "<FILTERED>")
    end

    it "re-reads filter_parameters per call rather than memoizing a stale filter" do
      with_filter_parameters([])
      expect(described_class.parameters({ "nickname" => "ace" })).to eq("nickname" => "ace")

      with_filter_parameters([:nickname])
      expect(described_class.parameters({ "nickname" => "ace" })).to eq("nickname" => "<FILTERED>")
    end
  end

  describe ".headers" do
    it "replaces credential-bearing headers with named placeholders" do
      result = described_class.headers(
        "Authorization" => "Bearer real-key", "Cookie" => "_session=abcd",
        "X-Api-Key" => "sk-live-123", "X-CSRF-Token" => "tok"
      )

      expect(result).to eq("Authorization" => "<AUTH_TOKEN>", "Cookie" => "<SESSION_COOKIE>",
                           "X-Api-Key" => "<API_KEY>", "X-Csrf-Token" => "<CSRF_TOKEN>")
    end

    it "echoes headers that describe the request rather than authorize it" do
      result = described_class.headers("Content-Type" => "application/json", "Accept" => "application/json")

      expect(result).to eq("Content-Type" => "application/json", "Accept" => "application/json")
    end

    it "masks an unrecognized header whose name looks like a credential" do
      result = described_class.headers("X-Vendor-Signature" => "abc", "X-Tenant-Id" => "42")

      expect(result).to eq("X-Vendor-Signature" => "<FILTERED>", "X-Tenant-Id" => "42")
    end

    it "normalizes header casing and underscores to one canonical form" do
      expect(described_class.headers("content_type" => "text/plain")).to eq("Content-Type" => "text/plain")
    end

    it "never returns a credential value, whatever the header's casing" do
      %w[authorization AUTHORIZATION Authorization cookie COOKIE].each do |name|
        expect(described_class.headers(name => "secret-value").values).not_to include("secret-value")
      end
    end
  end

  describe ".masked?" do
    it "distinguishes a placeholder from an observed value" do
      expect(described_class.masked?("<FILTERED>")).to be(true)
      expect(described_class.masked?("<API_KEY>")).to be(true)
      expect(described_class.masked?("ABC123")).to be(false)
      expect(described_class.masked?(42)).to be(false)
    end
  end
end
# rubocop:enable Metrics/BlockLength
