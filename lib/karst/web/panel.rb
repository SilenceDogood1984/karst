# frozen_string_literal: true

require "cgi"

module Karst
  module Web
    # Renders Karst's minimal development evidence page with no templating
    # dependency. Karst currently holds only process-level Window evidence, so
    # this page must never claim more than that: it reports capture state and
    # Window counts, and says nothing about any request, controller, action,
    # route, or user.
    #
    # Future raw SQL rendered here may contain arbitrary application data, so
    # every runtime-derived value is escaped through #escape rather than
    # trusted, even though today's values are plain counts and booleans.
    module Panel
      CONTENT_SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
      private_constant :CONTENT_SECURITY_POLICY

      HEADERS = {
        "content-type" => "text/html; charset=utf-8",
        "cache-control" => "no-store",
        "x-robots-tag" => "noindex, nofollow",
        "x-frame-options" => "DENY",
        "content-security-policy" => CONTENT_SECURITY_POLICY
      }.freeze
      private_constant :HEADERS

      class << self
        def render
          [200, HEADERS.dup, [document]]
        end

        private

        def document
          <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <title>Karst</title>
            </head>
            <body>
            <h1>Karst</h1>
            <p>Runtime evidence</p>
            #{capture_section}
            #{evidence_section}
            </body>
            </html>
          HTML
        end

        def capture_section
          <<~HTML
            <h2>Capture</h2>
            <p>Capture: #{escape(Karst.enabled? ? 'enabled' : 'disabled')}</p>
            <p>Subscription: #{escape(Karst.subscribed? ? 'active' : 'inactive')}</p>
          HTML
        end

        def evidence_section
          window = Karst.window

          <<~HTML
            <h2>Retained evidence</h2>
            <p>Process-local, bounded, recently retained. Not request-scoped.</p>
            <p>Retained observations: #{escape(window.event_count)} / #{escape(window.capacity)}</p>
            <p>Query shapes: #{escape(window.shapes.size)}</p>
            <p>Declined: #{escape(window.declined.size)}</p>
            <p>Detailed evidence view coming from the existing Window model.</p>
          HTML
        end

        def escape(value)
          CGI.escapeHTML(value.to_s)
        end
      end
    end
  end
end
