# frozen_string_literal: true

require "cgi"
require "rack/utils"

begin
  require_relative "../spec/catalog"
rescue LoadError
  # Degrades to a countless badge rather than preventing the host response
  # from being served, mirroring Panel's own posture toward a missing Catalog.
end

module Karst
  module Web
    # Rewrites an eligible host HTML response to add a small, page-local link
    # into Karst's route-scoped scenario catalog. Every check here exists to
    # make injection safe to skip: Badge never guesses, never raises into the
    # host application, and never touches a response it cannot confidently
    # rewrite -- an untouched response is always the safe fallback.
    #
    # Route identity (controller/action/http_method) comes from
    # Middleware, itself derived from a real process_action.action_controller
    # notification; Badge never infers it from a path. `context.path` is
    # carried along purely as display context for the panel (see
    # Karst::Web::Panel), never as part of route identity.
    module Badge
      Context = Struct.new(:controller, :action, :http_method, :path, keyword_init: true)

      # A generous ceiling, not a tuning knob: real pages are a few hundred KB
      # at most, and this exists only to decline joining a body large enough
      # that string-splicing it would be wasteful, not to police page weight.
      MAX_INJECTABLE_BYTES = 5 * 1024 * 1024
      private_constant :MAX_INJECTABLE_BYTES

      BODY_CLOSE_TAG = %r{</body>}i
      private_constant :BODY_CLOSE_TAG

      # `all:initial` strips whatever the host page's own CSS would otherwise
      # inherit onto the badge (fonts, colors, positioning contexts); every
      # property Karst actually wants is re-declared afterward in the same
      # attribute, so the cascade only ever sees Karst's own values.
      BADGE_STYLE =
        "all:initial;position:fixed;bottom:12px;right:12px;z-index:2147483647;" \
        "display:inline-block;padding:.35rem .65rem;border-radius:999px;" \
        "background:#202124;color:#fff;font:600 12px/1.4 -apple-system,system-ui,sans-serif;" \
        "text-decoration:none;box-shadow:0 1px 4px rgba(0,0,0,.35)"
      private_constant :BADGE_STYLE

      class << self
        # Returns a replacement [status, headers, body] triple, or nil when
        # the response should be returned to the host application unchanged
        # -- including when anything above raises, so a bug here can never
        # turn into a broken host page.
        def apply(status:, headers:, body:, context:)
          return nil unless context
          return nil unless html_response?(status: status, headers: headers)
          # `to_ary` is Rack's own signal that a body is already fully
          # buffered rather than genuinely streaming (Rack::ETag relies on
          # exactly this same check for exactly this same reason). Rails
          # delegates it down to the response's real stream object, so a
          # Live-streaming response correctly reports false and is left
          # alone. Under Rack 2 (Rails 7.0), ActionDispatch's older
          # RackBody wrapper never exposes to_ary at all -- every response
          # reports false there, so Badge never injects on that Rails
          # series. That is a missing feature, not a bug: guessing
          # bufferability by any other means risks blocking forever on a
          # real streaming body, which this module will not do.
          return nil unless body.respond_to?(:to_ary)

          parts = body.to_ary
          return nil unless bufferable?(parts)

          rewrite(status: status, headers: headers, parts: parts, body: body, context: context)
        rescue StandardError
          nil
        end

        private

        def html_response?(status:, headers:)
          return false unless status.is_a?(Integer) && status >= 200 && status < 300
          return false if header(headers, "content-disposition")
          return false if content_encoded?(headers)

          header(headers, "content-type").to_s.downcase.start_with?("text/html")
        end

        def content_encoded?(headers)
          encoding = header(headers, "content-encoding").to_s.strip
          !encoding.empty? && !encoding.casecmp?("identity")
        end

        def bufferable?(parts)
          parts.is_a?(Array) && parts.all?(String) && parts.sum(&:bytesize) <= MAX_INJECTABLE_BYTES
        end

        def rewrite(status:, headers:, parts:, body:, context:)
          original = parts.join
          index = original.rindex(BODY_CLOSE_TAG)
          return nil unless index

          html = "#{original[0...index]}#{markup(headers: headers, context: context)}#{original[index..]}"
          new_headers = headers.dup
          set_content_length!(new_headers, html.bytesize)
          strip_validators!(new_headers)
          body.close if body.respond_to?(:close)
          [status, new_headers, [html]]
        end

        def markup(headers:, context:)
          href = escape("/karst?#{query_for(context)}")
          label = escape(label_for(context))
          style = inline_style_allowed?(headers) ? " style=\"#{BADGE_STYLE}\"" : ""
          "<a href=\"#{href}\"#{style}>#{label}</a>"
        end

        def query_for(context)
          Rack::Utils.build_query(
            "controller" => context.controller, "action" => context.action,
            "method" => context.http_method, "path" => context.path
          )
        end

        def label_for(context)
          catalog = load_catalog
          return "Karst" unless catalog && catalog.status == :ready

          count = catalog.scenarios_for(
            controller: context.controller, action: context.action, http_method: context.http_method
          ).size
          "Karst · #{count}"
        end

        def load_catalog
          return nil unless defined?(Karst::Spec::Catalog)

          Karst::Spec::Catalog.load
        rescue StandardError
          nil
        end

        # A CSP the host response itself declares is the only signal Badge
        # trusts: Karst never rewrites that header, only reads it, and falls
        # back to an unstyled link rather than risk a silently-dropped style
        # under a policy with no 'unsafe-inline'.
        def inline_style_allowed?(headers)
          csp = header(headers, "content-security-policy").to_s.strip
          return true if csp.empty?

          directives = csp.split(";").map(&:strip)
          directive = directives.find { |item| item.start_with?("style-src") } ||
                      directives.find { |item| item.start_with?("default-src") }
          directive.nil? || directive.include?("'unsafe-inline'")
        end

        def header(headers, name)
          key = headers.keys.find { |candidate| candidate.to_s.casecmp?(name) }
          key && headers[key]
        end

        def set_content_length!(headers, bytesize)
          key = headers.keys.find { |candidate| candidate.to_s.casecmp?("content-length") }
          headers[key || "content-length"] = bytesize.to_s
        end

        # ETag/Last-Modified validate a specific byte sequence; once Karst
        # appends the badge, any validator computed on the host's original
        # body no longer describes what is actually being served. Dropping
        # them is safer than emitting a validator Karst never recomputed.
        def strip_validators!(headers)
          %w[etag last-modified].each do |name|
            key = headers.keys.find { |candidate| candidate.to_s.casecmp?(name) }
            headers.delete(key) if key
          end
        end

        def escape(value)
          CGI.escapeHTML(value.to_s)
        end
      end
    end
  end
end
