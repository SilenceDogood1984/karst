# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/badge"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::Badge do
  def context(controller: "PagesController", action: "index", http_method: "GET", path: "/pages")
    described_class::Context.new(controller: controller, action: action, http_method: http_method, path: path)
  end

  def html_body(inner: "<h1>Hi</h1>")
    ["<!DOCTYPE html><html><head></head><body>#{inner}</body></html>"]
  end

  def headers(overrides = {})
    { "content-type" => "text/html; charset=utf-8" }.merge(overrides)
  end

  describe "ineligible responses are returned untouched" do
    it "returns nil with no context" do
      expect(described_class.apply(status: 200, headers: headers, body: html_body, context: nil)).to be_nil
    end

    it "returns nil for a redirect status" do
      result = described_class.apply(status: 302, headers: headers, body: html_body, context: context)
      expect(result).to be_nil
    end

    it "returns nil for a non-html content type" do
      result = described_class.apply(
        status: 200, headers: headers("content-type" => "application/json; charset=utf-8"),
        body: ['{"a":1}'], context: context
      )
      expect(result).to be_nil
    end

    it "returns nil for a Turbo Stream content type" do
      result = described_class.apply(
        status: 200, headers: headers("content-type" => "text/vnd.turbo-stream.html; charset=utf-8"),
        body: ["<turbo-stream></turbo-stream>"], context: context
      )
      expect(result).to be_nil
    end

    it "returns nil when a content-disposition header marks a download" do
      result = described_class.apply(
        status: 200, headers: headers("content-disposition" => "attachment; filename=\"export.html\""),
        body: html_body, context: context
      )
      expect(result).to be_nil
    end

    it "returns nil when the response is content-encoded" do
      result = described_class.apply(
        status: 200, headers: headers("content-encoding" => "gzip"), body: html_body, context: context
      )
      expect(result).to be_nil
    end

    it "returns nil for a non-bufferable (streaming) body" do
      streaming = Enumerator.new { |yielder| yielder << "<html><body></body></html>" }
      result = described_class.apply(status: 200, headers: headers, body: streaming, context: context)
      expect(result).to be_nil
    end

    it "returns nil when a bufferable body contains a non-String part" do
      body = Struct.new(:parts) { def to_ary = parts }.new([1, 2])
      result = described_class.apply(status: 200, headers: headers, body: body, context: context)
      expect(result).to be_nil
    end

    it "returns nil when the buffered body exceeds the injectable size ceiling" do
      huge = Struct.new(:parts) { def to_ary = parts }.new(["a" * (6 * 1024 * 1024)])
      result = described_class.apply(status: 200, headers: headers, body: huge, context: context)
      expect(result).to be_nil
    end

    it "returns nil when the body has no closing body tag" do
      body = ["<turbo-frame id=\"x\">fragment</turbo-frame>"]
      result = described_class.apply(status: 200, headers: headers, body: body, context: context)
      expect(result).to be_nil
    end

    it "never raises even when the response cannot be safely inspected" do
      hostile_headers = Class.new { def keys = raise("boom") }.new
      expect do
        described_class.apply(status: 200, headers: hostile_headers, body: html_body, context: context)
      end.not_to raise_error
    end
  end

  describe "successful injection" do
    it "splices a link before the closing body tag and preserves surrounding markup" do
      body = html_body(inner: "<h1>Hi</h1>")
      status, _headers, new_body = described_class.apply(status: 200, headers: headers, body: body, context: context)

      html = new_body.join
      expect(status).to eq(200)
      expect(html).to start_with("<!DOCTYPE html><html><head></head><body><h1>Hi</h1><a href=")
      expect(html).to end_with("</a></body></html>")
    end

    it "updates Content-Length to the new byte size, preserving the header's original casing" do
      original = headers("Content-Length" => html_body.first.bytesize.to_s)
      _status, new_headers, new_body = described_class.apply(
        status: 200, headers: original, body: html_body, context: context
      )

      expect(new_headers).to have_key("Content-Length")
      expect(new_headers).not_to have_key("content-length")
      expect(new_headers["Content-Length"]).to eq(new_body.join.bytesize.to_s)
    end

    it "adds a lowercase Content-Length when none was present" do
      _status, new_headers, new_body = described_class.apply(
        status: 200, headers: headers, body: html_body, context: context
      )

      expect(new_headers["content-length"]).to eq(new_body.join.bytesize.to_s)
    end

    it "preserves unrelated headers untouched" do
      original = headers("x-request-id" => "abc123")
      _status, new_headers, = described_class.apply(status: 200, headers: original, body: html_body, context: context)

      expect(new_headers["x-request-id"]).to eq("abc123")
    end

    it "does not mutate the original headers hash" do
      original = headers
      described_class.apply(status: 200, headers: original, body: html_body, context: context)

      expect(original).not_to have_key("content-length")
    end

    it "drops ETag and Last-Modified, since they validate a body Karst just changed" do
      original = headers("ETag" => 'W/"stale"', "Last-Modified" => "Mon, 01 Jan 2024 00:00:00 GMT")
      _status, new_headers, = described_class.apply(status: 200, headers: original, body: html_body, context: context)

      expect(new_headers).not_to have_key("ETag")
      expect(new_headers).not_to have_key("Last-Modified")
    end

    it "closes the original body when it responds to close, and replaces it with a single string" do
      body = html_body
      def body.close = (@closed = true)
      def body.closed? = @closed

      _status, _headers, new_body = described_class.apply(status: 200, headers: headers, body: body, context: context)

      expect(body).to be_closed
      expect(new_body).to be_an(Array)
      expect(new_body.size).to eq(1)
    end

    it "does not close the original body when injection is skipped" do
      body = ["no body tag here"]
      def body.close = (@closed = true)
      def body.closed? = @closed

      described_class.apply(status: 200, headers: headers, body: body, context: context)

      expect(body.closed?).to be_falsy
    end
  end

  describe "escaping" do
    it "percent-encodes hostile controller/action values within the href, never emitting them raw" do
      hostile = "<script>alert(1)</script>"
      result = described_class.apply(
        status: 200, headers: headers, body: html_body,
        context: context(controller: hostile, action: hostile)
      )
      html = result.last.join

      expect(html).not_to include(hostile)
      expect(html).to include(Rack::Utils.escape(hostile))
    end

    it "HTML-escapes the '&' query separators within the href attribute" do
      result = described_class.apply(status: 200, headers: headers, body: html_body, context: context)

      href = result.last.join[/href="([^"]*)"/, 1]
      expect(href).to include("&amp;")
      expect(href).not_to match(/&(?!amp;)/)
    end
  end

  describe "CSP-aware styling" do
    it "includes an inline style when no CSP header is present" do
      html = described_class.apply(status: 200, headers: headers, body: html_body, context: context).last.join

      expect(html).to include(" style=\"")
    end

    it "includes an inline style when the host CSP allows unsafe-inline styles" do
      csp_headers = headers("content-security-policy" => "default-src 'self'; style-src 'unsafe-inline'")
      html = described_class.apply(status: 200, headers: csp_headers, body: html_body, context: context).last.join

      expect(html).to include(" style=\"")
    end

    it "omits the inline style when the host style-src forbids unsafe-inline" do
      csp_headers = headers("content-security-policy" => "default-src 'self'; style-src 'self'")
      html = described_class.apply(status: 200, headers: csp_headers, body: html_body, context: context).last.join

      expect(html).not_to include(" style=\"")
      expect(html).to include("<a href=")
    end

    it "falls back to default-src when style-src is absent" do
      csp_headers = headers("content-security-policy" => "default-src 'none'")
      html = described_class.apply(status: 200, headers: csp_headers, body: html_body, context: context).last.join

      expect(html).not_to include(" style=\"")
    end

    it "never rewrites the host's Content-Security-Policy header" do
      csp = "default-src 'self'; style-src 'self'"
      csp_headers = headers("content-security-policy" => csp)
      _status, new_headers, = described_class.apply(
        status: 200, headers: csp_headers, body: html_body, context: context
      )

      expect(new_headers["content-security-policy"]).to eq(csp)
    end
  end

  describe "href shape" do
    it "encodes controller, action, method, and path as query parameters, never the host query string" do
      html = described_class.apply(
        status: 200, headers: headers, body: html_body,
        context: context(controller: "Author::ProjectsController", action: "index", http_method: "GET",
                         path: "/author/projects")
      ).last.join

      expected = "/karst?controller=Author%3A%3AProjectsController&action=index&method=GET&path=%2Fauthor%2Fprojects"
      expect(html).to include(CGI.escapeHTML(expected))
    end
  end
end
# rubocop:enable Metrics/BlockLength
