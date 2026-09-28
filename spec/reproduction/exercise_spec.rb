# frozen_string_literal: true

require "spec_helper"
require "rails"
require "active_record"
require "karst"

# Input and safety boundaries only. What Karst actually observes when it
# issues a request is exercised against a real booted Rails application in
# spec/integration/request_reproduction_spec.rb -- a stubbed session could
# only prove Karst's own assumptions back to itself.
# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Reproduction::Exercise do
  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
  end

  def build(**overrides)
    described_class.new(path: "/api/v1/inspections", application: Object.new, **overrides)
  end

  describe "target safety" do
    it "refuses an absolute URL, so reproduction can never leave the application" do
      expect { build(path: "https://evil.example/steal") }
        .to raise_error(Karst::Access::UnsafeTarget, /local application path/)
    end

    it "refuses a protocol-relative target" do
      expect { build(path: "//evil.example/steal") }.to raise_error(Karst::Access::UnsafeTarget)
    end

    it "refuses a target that is not a path at all" do
      expect { build(path: "api/v1/inspections") }.to raise_error(Karst::Access::UnsafeTarget)
    end

    it "accepts a local path with a query string" do
      expect { build(path: "/api/v1/inspections?status=passed") }.not_to raise_error
    end
  end

  describe "method safety" do
    it "accepts the ordinary HTTP methods a Rails application routes" do
      described_class::METHODS.each do |method|
        expect { build(http_method: method) }.not_to raise_error
      end
    end

    it "refuses anything else rather than passing it through to the application" do
      ["TRACE", "CONNECT", "OPTIONS", "GET /x", ""].each do |method|
        expect { build(http_method: method) }.to raise_error(Karst::Access::UnsupportedMethod)
      end
    end
  end

  describe "body input" do
    it "refuses a body with no content type rather than guessing one" do
      expect { build(http_method: "POST", body: '{"a":1}') }
        .to raise_error(ArgumentError, /content type is required/)
    end

    it "accepts a body with an explicit content type" do
      expect { build(http_method: "POST", body: '{"a":1}', content_type: "application/json") }.not_to raise_error
    end

    it "treats an empty body as no body, so a bare GET needs no content type" do
      expect { build(body: "") }.not_to raise_error
    end
  end

  # Anything outside ActionDispatch::Http::Headers' own header-name shape is
  # written straight into the Rack env rather than prefixed with HTTP_, and a
  # CGI variable is mapped onto the request itself. Either would let a caller
  # change the request Karst issues without changing the request Karst
  # reports -- a recipe describing a request nobody made.
  describe "header input" do
    it "accepts ordinary request headers" do
      expect { build(headers: { "Authorization" => "Bearer x", "X-Api-Key" => "k", "Accept" => "*/*" }) }
        .not_to raise_error
    end

    it "refuses a name that would be written straight into the Rack environment" do
      ["rack.session", "action_dispatch.request.parameters", "rack.input", "HTTP_X_FORGED: x"].each do |name|
        expect { build(headers: { name => "x" }) }
          .to raise_error(ArgumentError, /is not a request header name/)
      end
    end

    it "refuses a CGI variable that would change the request itself" do
      %w[REQUEST_METHOD PATH_INFO QUERY_STRING REMOTE_ADDR Content-Length].each do |name|
        expect { build(headers: { name => "x" }) }
          .to raise_error(ArgumentError, /is not a request header name/)
      end
    end

    it "still allows Content-Type, which is a real header Karst sets itself" do
      expect { build(headers: { "Content-Type" => "application/json" }) }.not_to raise_error
    end

    # A header-shaped name Karst has never heard of is not reserved and is
    # not env-shaped, so ActionDispatch prefixes it with HTTP_ like any
    # other header. Refusing it would be Karst deciding which headers an
    # application is allowed to read.
    it "allows an unfamiliar but header-shaped name" do
      expect { build(headers: { "warden" => "x", "X-Vendor-Trace" => "y" }) }.not_to raise_error
    end

    it "ignores an empty header name rather than refusing the whole request" do
      expect { build(headers: { "" => "x", "  " => "y" }) }.not_to raise_error
    end
  end

  # Unit-level rather than through a real request: the whole point is that
  # this method must never make a real request-dispatch decision (it does
  # not touch Rack, routing, or any Rails engine internals), so the safest
  # way to prove it never reaches for the global Rails.application is to
  # call it directly rather than issuing a request and hoping nothing else
  # in a real Rails boot happens to read that global too (it does, on some
  # Rails series -- see the history of this describe block).
  describe "#filter_parameters" do
    def build_with_config(filter_parameters: nil, raises: nil)
      config = double("config")
      if raises
        allow(config).to receive(:filter_parameters).and_raise(raises)
      else
        allow(config).to receive(:filter_parameters).and_return(filter_parameters)
      end
      build(application: double("application", config: config))
    end

    it "returns the reproduced application's own filters as an Array" do
      exercise = build_with_config(filter_parameters: [:passcode])

      expect(exercise.send(:filter_parameters)).to eq([:passcode])
    end

    it "returns an empty Array, never nil, when the application declares none" do
      exercise = build_with_config(filter_parameters: nil)

      expect(exercise.send(:filter_parameters)).to eq([])
    end

    # Sanitizer.rails_filter treats a nil `filters` argument as "none given,
    # read the global Rails.application" -- the one fallback Exercise must
    # never trigger, because @application is a specific, deliberately chosen
    # application (never necessarily Rails.application, as in this very
    # spec file's own `application: Object.new`). Returning [] here rather
    # than nil is what keeps that fallback from ever firing.
    it "returns an empty Array, never nil, when the application's own filter_parameters raises" do
      exercise = build_with_config(raises: RuntimeError.new("boom"))

      expect(exercise.send(:filter_parameters)).to eq([])
    end

    it "never reaches for the global Rails.application, whether its own config succeeds or raises" do
      allow(Rails).to receive(:application).and_raise("Exercise must never read the global Rails.application")

      expect(build_with_config(filter_parameters: [:passcode]).send(:filter_parameters)).to eq([:passcode])
      expect(build_with_config(raises: RuntimeError.new("boom")).send(:filter_parameters)).to eq([])
    end
  end

  describe "environment gates" do
    it "refuses to run outside development" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { build.call }.to raise_error(Karst::Access::Unavailable, /development-only/)
    end

    it "refuses to run when Karst is disabled" do
      Karst.config.enabled = false

      expect { build.call }.to raise_error(Karst::Access::Unavailable, /disabled/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
