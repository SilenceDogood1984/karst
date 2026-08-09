# frozen_string_literal: true

require "cgi"

begin
  require_relative "../spec/catalog"
rescue LoadError
  # The panel reports an unavailable catalog rather than preventing /karst
  # from loading. This keeps the development evidence surface degradable.
end

module Karst
  module Web
    # Read-only HTML presentation of route-specific spec evidence. All artifact
    # and query-string values cross #escape before entering the document.
    # rubocop:disable Metrics/ModuleLength
    module Panel
      CONTENT_SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
      private_constant :CONTENT_SECURITY_POLICY

      HEADERS = {
        "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
        "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY",
        "content-security-policy" => CONTENT_SECURITY_POLICY
      }.freeze
      private_constant :HEADERS

      # rubocop:disable Metrics/ClassLength
      class << self
        def render(params: {})
          [200, HEADERS.dup, [document(params)]]
        end

        private

        # rubocop:disable Metrics/MethodLength
        def document(params)
          controller = string_param(params, "controller")
          action = string_param(params, "action")
          http_method = string_param(params, "method")
          path = string_param(params, "path")
          catalog = load_catalog
          <<~HTML
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8"><title>Karst scenarios</title>
            <style>body{font:16px system-ui,sans-serif;max-width:58rem;margin:2rem auto;padding:0 1rem;color:#202124}form,.scenario,.runtime{border:1px solid #ddd;border-radius:.4rem;padding:1rem;margin:1rem 0}.scenario h4{margin:.1rem 0}.evidence{display:flex;gap:1rem;flex-wrap:wrap}.label{font-size:.78rem;font-weight:700;text-transform:uppercase}.failed,.pending{border-left:5px solid #777}code{background:#f4f4f4;padding:.12rem .3rem}small{color:#555}.page-context{color:#555;margin-bottom:0}</style>
            </head><body><h1>Karst</h1>
            #{route_form(controller, action)}
            #{catalog_section(catalog, controller, action, http_method, path)}
            #{runtime_section}
            </body></html>
          HTML
        end
        # rubocop:enable Metrics/MethodLength

        def string_param(params, key)
          value = params[key]
          value.is_a?(String) ? value.strip : ""
        end

        def load_catalog
          return nil unless defined?(Karst::Spec::Catalog)

          Karst::Spec::Catalog.load
        rescue StandardError
          nil
        end

        def route_form(controller, action)
          <<~HTML
            <section><h2>Current route</h2>
            <form action="/karst" method="get">
            <label>Controller <input name="controller" value="#{escape(controller)}" placeholder="Author::ProjectsController"></label>
            <label>Action <input name="action" value="#{escape(action)}" placeholder="index"></label>
            <button type="submit">Show observed scenarios</button>
            </form></section>
          HTML
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
        def catalog_section(catalog, controller, action, http_method, path)
          identity = page_identity(controller, action, http_method, path)
          return "#{identity}#{catalog_unreadable}" unless catalog
          return "#{identity}#{missing_catalog}" if catalog.status == :missing
          return "#{identity}#{catalog_unreadable}" if catalog.status == :invalid
          return "#{identity}#{select_route}" if controller.empty? || action.empty?

          scenarios = catalog.scenarios_for(
            controller: controller, action: action, http_method: http_method.empty? ? nil : http_method
          )
          heading = "#{identity}<h2>Tested scenarios</h2>"
          return "#{heading}<p>No observed specs currently cover this route.</p>" if scenarios.empty?

          "#{heading}#{scenario_groups(scenarios)}"
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

        # The controller/action pairing is always the identity line; the
        # method/path line above it is contextual evidence of the actual host
        # request that linked here (see Karst::Web::Badge), shown only when
        # present, never used to select scenarios.
        def page_identity(controller, action, http_method, path)
          return "" if controller.empty? || action.empty?

          route_line = path.empty? ? "" : "<p class=\"page-context\">#{method_prefix(http_method)}#{escape(path)}</p>"
          "#{route_line}<p><strong>#{escape(controller)}##{escape(action)}</strong></p>"
        end

        def method_prefix(http_method)
          http_method.empty? ? "" : "#{escape(http_method)} "
        end

        def missing_catalog
          <<~HTML
            <h2>Tested scenarios</h2><p>No Karst scenario catalog has been generated yet.</p>
            <p>Run <code>bundle exec rspec</code> with Karst's spec observer configured to generate it.</p>
          HTML
        end

        def catalog_unreadable
          "<h2>Tested scenarios</h2><p>Karst could not read the scenario catalog.</p>"
        end

        def select_route
          "<h2>Tested scenarios</h2><p>Enter a controller and action to view route-specific observed spec evidence.</p>"
        end

        def scenario_groups(scenarios)
          explicit, discovered = scenarios.partition(&:explicit?)
          [["Explicit QA scenarios", explicit], ["Discovered scenarios", discovered]].filter_map do |title, group|
            next if group.empty?

            "<section><h3>#{title}</h3>#{group.map { |scenario| scenario_card(scenario) }.join}</section>"
          end.join
        end

        def scenario_card(scenario)
          <<~HTML
            <article class="scenario #{escape(scenario.example_outcome)}">
            <div class="label">#{escape(outcome_label(scenario.example_outcome))}</div>
            <h4>#{escape(scenario.name)}</h4>
            <div class="evidence"><span>Observed status: <strong>#{escape(scenario.observed_status || 'Unavailable')}</strong></span>#{redirect(scenario)}<span>Principal: #{escape(principal_label(scenario))}</span></div>
            <p><small>Observed by spec: <code>#{escape(scenario.file_path)}:#{escape(scenario.line_number)}</code></small></p>
            </article>
          HTML
        end

        def outcome_label(outcome)
          labels = { passed: "Passed spec", failed: "Failed spec — observed behavior is not trusted QA evidence",
                     pending: "Pending spec — observed behavior is not trusted QA evidence" }
          labels.fetch(outcome, "Unknown spec outcome")
        end

        def redirect(scenario)
          return "" if scenario.observed_redirect.nil? || scenario.observed_redirect.to_s.empty?

          "<span>Observed redirect: <strong>#{escape(scenario.observed_redirect)}</strong></span>"
        end

        def principal_label(scenario)
          before = scenario.principal_before&.type || "Anonymous"
          after = scenario.principal_after&.type || "Anonymous"
          scenario.principal_changed ? "#{before} → #{after}" : before
        end

        def runtime_section
          window = Karst.window
          <<~HTML
            <section class="runtime"><h2>Runtime SQL evidence</h2>
            <p>#{escape(window.event_count)} observations · #{escape(window.shapes.size)} shapes · #{escape(window.declined.size)} declined</p>
            <p>Capture: #{escape(Karst.enabled? ? 'enabled' : 'disabled')} · Subscription: #{escape(Karst.subscribed? ? 'active' : 'inactive')}</p>
            <small>Process-local, bounded, recently retained.</small></section>
          HTML
        end

        def escape(value)
          CGI.escapeHTML(value.to_s)
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
