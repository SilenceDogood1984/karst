# frozen_string_literal: true

require "cgi"
require "rack/utils"
require "active_support/number_helper"

begin
  require_relative "../spec/catalog"
rescue LoadError
  # The panel reports an unavailable catalog rather than preventing /karst
  # from loading. This keeps the development evidence surface degradable.
end

module Karst
  module Web
    # Read-only HTML presentation of Karst's evidence for the current route.
    # Information architecture: "which existing principal can I use to test
    # what I'm looking at" is the primary workflow -- spec evidence and raw
    # SQL evidence are supporting diagnostics, collapsed by default. All
    # artifact and query-string values cross #escape before entering the
    # document.
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

      STYLE = <<~CSS
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1.25rem;color:#1a1a1a;background:#fff}
        h1{font-size:1.4rem;margin:0 0 1rem}
        h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.05em;color:#555;margin:1.75rem 0 .6rem;border-bottom:1px solid #e2e2e2;padding-bottom:.35rem}
        h3{font-size:1rem;margin:0}
        h4{margin:0}
        .route-path{margin:0;color:#555;font-size:.95rem;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
        .route-controller{margin:.15rem 0 0;font-size:1.2rem;font-weight:600}
        .route-lookup{margin-top:.6rem;border:0;padding:0}
        .route-lookup summary{cursor:pointer;color:#555;font-size:.85rem;font-weight:400}
        .route-lookup form{margin-top:.6rem;display:flex;gap:.75rem;flex-wrap:wrap;align-items:flex-end}
        label{display:flex;flex-direction:column;font-size:.78rem;font-weight:600;gap:.25rem;color:#444}
        input{font:inherit;padding:.4rem .5rem;border:1px solid #ccc;border-radius:.3rem}
        button{font:inherit;padding:.45rem .8rem;border:1px solid #ccc;border-radius:.35rem;background:#f4f4f4;cursor:pointer}
        button:hover{background:#eaeaea}
        button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid #2563eb;outline-offset:2px}
        button.primary{background:#202124;border-color:#202124;color:#fff;font-weight:600;padding:.65rem 1.15rem;font-size:.95rem}
        button.primary:hover{background:#3a3b3e}
        .hint{color:#8a5b00;font-size:.85rem;margin:.4rem 0}
        .testing-banner{background:#fff7e0;border:1px solid #eacb6b;border-radius:.4rem;padding:.75rem 1rem;margin-bottom:1.25rem}
        .testing-banner form{margin-top:.5rem}
        .testing-banner p{margin:0}
        .testing-banner p+p{margin-top:.35rem}
        section.access{margin-bottom:1rem}
        .meta{color:#555;font-size:.88rem}
        section.usable{margin:1rem 0}
        .usable-principal{border:1px solid #ddd;border-radius:.5rem;padding:.9rem 1rem;margin:.75rem 0}
        .usable-principal h4{display:flex;justify-content:space-between;align-items:center;gap:.75rem;margin:0;flex-wrap:wrap}
        .test-as{border:0;padding:0;margin:0;display:inline}
        .usable-principal button[type=submit]{background:#0f5132;border-color:#0f5132;color:#fff;font-weight:600}
        .usable-principal button[type=submit]:hover{background:#0a3d25}
        .usable-principal p{margin:.5rem 0 0;color:#444;font-size:.92rem}
        .related-state{margin:.75rem 0 0;padding:.6rem .75rem;border-left:3px solid #ccc;background:#fafafa;font-size:.9rem}
        .related-state ul{margin:.25rem 0 0;padding-left:1.1rem}
        details{border:1px solid #e2e2e2;border-radius:.4rem;padding:.6rem .8rem;margin:.75rem 0}
        details summary{cursor:pointer;font-weight:600}
        details[open]>summary{margin-bottom:.5rem}
        .scenario{border:1px solid #ddd;border-radius:.4rem;padding:.75rem;margin:.6rem 0}
        .scenario h4{margin:.1rem 0}
        .evidence{display:flex;gap:1rem;flex-wrap:wrap;font-size:.9rem}
        .label{font-size:.72rem;font-weight:700;text-transform:uppercase;color:#666}
        .failed,.pending{border-left:4px solid #b3261e}
        small{color:#666}
        .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
        @media (max-width:480px){
          body{margin:1rem auto;padding:0 .85rem}
          .usable-principal h4{flex-direction:column;align-items:flex-start}
          .route-lookup form{flex-direction:column;align-items:stretch}
        }
        @media (prefers-color-scheme:dark){
          body{background:#16171a;color:#e4e4e6}
          h2{color:#a7a7ad;border-color:#2c2d31}
          .route-path{color:#a7a7ad}
          .meta,small{color:#9a9aa0}
          input{background:#1f2023;border-color:#3a3b3e;color:#e4e4e6}
          button{background:#26272b;border-color:#3a3b3e;color:#e4e4e6}
          button:hover{background:#303136}
          button.primary{background:#e4e4e6;border-color:#e4e4e6;color:#16171a}
          button.primary:hover{background:#c9c9cc}
          .usable-principal{border-color:#33343a}
          .usable-principal button[type=submit]{background:#2e7d52;border-color:#2e7d52;color:#0b1a12}
          .related-state{background:#1c1d20;border-color:#3a3b3e}
          details{border-color:#2c2d31}
          .scenario{border-color:#33343a}
          .testing-banner{background:#3a2f0d;border-color:#6b5423;color:#f0e4c0}
          .hint{color:#d8a63d}
          .failed,.pending{border-left-color:#e5534b}
        }
      CSS
      private_constant :STYLE

      # rubocop:disable Metrics/ClassLength
      class << self
        def render(params: {}, access_result: nil, csrf_token: nil, browser_identity_active: false)
          [200, HEADERS.dup, [document(params, access_result, csrf_token, browser_identity_active)]]
        end

        private

        def document(params, access_result, csrf_token, browser_identity_active)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8"><title>Karst</title>
            <style>#{STYLE}</style>
            </head><body>
            <h1>Karst</h1>
            #{page_body(params, access_result, csrf_token, browser_identity_active)}
            </body></html>
          HTML
        end

        def page_body(params, access_result, csrf_token, browser_identity_active)
          controller = string_param(params, "controller")
          action = string_param(params, "action")
          http_method = string_param(params, "method")
          path = string_param(params, "path")
          "#{testing_banner(path, csrf_token, browser_identity_active)}" \
            "#{route_header(controller, action, http_method, path)}" \
            "#{access_section(http_method, path, controller, action, access_result, csrf_token)}" \
            "#{diagnostics_section(load_catalog, controller, action, http_method)}"
        end

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

        # -- Testing-as banner ------------------------------------------------

        def testing_banner(path, csrf_token, active)
          return "" unless active && Identity.browser_supported? && csrf_token

          fields = hidden("operation", "stop_test_as") + hidden("csrf_token", csrf_token) + hidden("path", path)
          <<~HTML
            <div class="testing-banner" role="status">
            <p><strong>Currently testing as an assumed browser identity.</strong></p>
            <p><small>Stopping clears to whatever identity your configured clear_browser_identity hook defines
            (commonly signed out) -- Karst does not restore a previous session.</small></p>
            <form action="/karst" method="post">#{fields}<button type="submit">Stop testing as</button></form>
            </div>
          HTML
        end

        # -- Compact route header ----------------------------------------------

        def route_header(controller, action, http_method, path)
          has_route = !(controller.empty? && action.empty?)
          identity = has_route ? route_identity(controller, action, http_method, path) : "<p>No route selected yet.</p>"
          "<header class=\"route\">#{identity}#{route_lookup(controller, action, open: !has_route)}</header>"
        end

        def route_identity(controller, action, http_method, path)
          path_line = path.empty? ? "" : "<p class=\"route-path\">#{method_prefix(http_method)}#{escape(path)}</p>"
          controller_line = controller.empty? || action.empty? ? "" : route_controller_line(controller, action)
          "#{path_line}#{controller_line}"
        end

        def route_controller_line(controller, action)
          "<p class=\"route-controller\">#{escape(controller)}##{escape(action)}</p>"
        end

        def method_prefix(http_method)
          http_method.empty? ? "" : "#{escape(http_method)} "
        end

        def route_lookup(controller, action, open:)
          summary = open ? "Look up a route" : "Look up a different route"
          attr = open ? " open" : ""
          <<~HTML
            <details class="route-lookup"#{attr}><summary>#{summary}</summary>
            <form action="/karst" method="get">
            <label>Controller <input name="controller" value="#{escape(controller)}" placeholder="Author::ProjectsController"></label>
            <label>Action <input name="action" value="#{escape(action)}" placeholder="index"></label>
            <button type="submit">View route evidence</button>
            </form></details>
          HTML
        end

        # -- Primary action: access analysis ------------------------------------

        # rubocop:disable Metrics/ParameterLists
        def access_section(http_method, path, controller, action, result, csrf_token)
          return "" if path.empty?

          context = hidden("controller", controller) + hidden("action", action) +
                    hidden("method", http_method) + hidden("path", path)
          body = if http_method == "GET"
                   analyze_form(context)
                 else
                   "<p>Access analysis is available for GET routes only.</p>"
                 end
          heading = "<h2 class=\"sr-only\">Access analysis</h2>"
          "<section class=\"access\">#{heading}#{body}#{access_result(result, csrf_token)}</section>"
        end
        # rubocop:enable Metrics/ParameterLists

        def analyze_form(context)
          source = principal_source
          kind = source && Access::PrincipalSampler.representative_capable?(source) ? "representative " : ""
          label = "Analyze #{Karst.config.access_sweep_limit} #{kind}principals"
          operation = "<input type=\"hidden\" name=\"operation\" value=\"access_sweep\">"
          button = "<button class=\"primary\" type=\"submit\">#{escape(label)}</button>"
          form = "<form action=\"/karst\" method=\"post\">#{context}#{operation}#{button}</form>"
          "#{form}#{principal_source_hint(source)}"
        end

        # Only ever type-checks the configured source (see
        # Access::PrincipalSampler.representative_capable?); it never queries
        # or enumerates it, so this is safe to compute on every panel render.
        def principal_source
          Identity.principals
        rescue Identity::Error
          nil
        end

        def principal_source_hint(source)
          return "" if source

          "<p class=\"hint\">No principal source is configured (config.principals). " \
            "Analyzing will report why nothing could be sampled.</p>"
        end

        def hidden(name, value)
          "<input type=\"hidden\" name=\"#{name}\" value=\"#{escape(value)}\">"
        end

        def access_result(result, csrf_token)
          return "" unless result
          return "<p>Analysis unavailable: #{escape(result.message)}</p>" if result.is_a?(StandardError)

          write_count = result.outcomes.count(&:writes_observed)
          warning = write_count.positive? ? write_warning(write_count) : ""
          usable, other = result.outcomes.partition { |outcome| usable_outcome?(outcome) }
          usable_section = usable_outcomes(usable, result, csrf_token)
          other_section = other_outcomes(other, result.path)
          "#{access_meta(result)}#{warning}#{usable_section}#{other_section}"
        end

        def access_meta(result)
          seconds = escape(result.elapsed_ms / 1000.0)
          "<p class=\"meta\">#{result.outcomes.size} principals tested#{candidate_pool_note(result)} · " \
            "#{seconds}s · database rollback was attempted; other connections and non-database effects are not " \
            "isolated.</p>"
        end

        # A bounded candidate pool is reported explicitly rather than left
        # implicit, so this never reads as "the entire principal universe was
        # searched."
        def candidate_pool_note(result)
          size = result.candidate_pool_size
          return "" unless size

          delimited = ActiveSupport::NumberHelper.number_to_delimited(size)
          " · candidate pool: up to #{escape(delimited)} most recent principals"
        end

        def write_warning(count)
          "<p><strong>⚠ Database writes were observed during #{count} probes.</strong></p>"
        end

        def usable_outcome?(outcome)
          Karst.config.usable_access_outcome.call(outcome)
        end

        # -- Usable principals ---------------------------------------------------

        def usable_outcomes(outcomes, result, csrf_token)
          body = if outcomes.empty?
                   "<p>No sampled principal produced a usable outcome.</p>"
                 else
                   usable_cards(outcomes,
                                result, csrf_token)
                 end
          "<section class=\"usable\"><h2>Usable principals — #{outcomes.size}</h2>" \
            "#{test_as_hint(outcomes, csrf_token)}#{body}</section>"
        end

        def usable_cards(outcomes, result, csrf_token)
          outcomes.map { |outcome| usable_principal(outcome, result, csrf_token) }.join
        end

        def test_as_hint(outcomes, csrf_token)
          return "" if outcomes.empty? || (Identity.browser_supported? && csrf_token)

          "<p class=\"hint\">Browser Test as is not configured (config.assume_browser_identity / " \
            "config.clear_browser_identity).</p>"
        end

        def usable_principal(outcome, result, csrf_token)
          writes = outcome.writes_observed ? " — ⚠ #{escape(outcome.write_count)} database writes observed" : ""
          action = test_as_form(outcome.principal, result.path, csrf_token)
          evidence = resource_evidence(outcome, result)
          "<article class=\"usable-principal\"><h4><span>#{escape(outcome.principal.display_label)}#{writes}</span>" \
            "#{action}</h4><p>#{outcome_title(outcome, prefix: 'Observed ')} · " \
            "#{escape(outcome.elapsed_ms)}ms</p>#{evidence}</article>"
        end

        def resource_evidence(outcome, result)
          evidence = Access::ResourceEvidence.for_outcome(outcome: outcome, path: result.path,
                                                          http_method: result.http_method)
          return "" if evidence.limitation || evidence.relationships.empty?

          "<div class=\"related-state\"><strong>Related state</strong>" \
            "#{relationship_groups(evidence.relationships)}</div>"
        rescue StandardError
          ""
        end

        def relationship_groups(relationships)
          relationships.group_by { |item| [item.from_model, item.from_id] }.map do |key, items|
            model, id = key
            "<p><strong>#{escape(model)} ##{escape(id)}</strong></p><ul>#{relationship_rows(items)}</ul>"
          end.join
        end

        def relationship_rows(relationships)
          relationships.map do |item|
            "<li>#{escape(item.column)} → #{escape(item.to_model)} ##{escape(item.to_id)}</li>"
          end.join
        end

        # -- Other observed outcomes (collapsed) ---------------------------------

        def other_outcomes(outcomes, path)
          groups = outcomes.group_by { |item| [item.status, item.redirect, item.exception_class] }
                           .map { |_key, grouped| outcome_group(grouped, path, nil) }.join
          "<details><summary>Other observed outcomes — #{outcomes.size}</summary>#{groups}</details>"
        end

        def outcome_group(outcomes, path, csrf_token)
          first = outcomes.first
          title = outcome_title(first)
          labels = outcomes.map { |item| outcome_principal(item, path, csrf_token) }.join
          "<article class=\"scenario\"><h3>#{title} — #{outcomes.size}</h3><ul>#{labels}</ul></article>"
        end

        def outcome_title(outcome, prefix: "")
          title = if outcome.exception_class
                    "Exception: #{escape(outcome.exception_class)}"
                  elsif outcome.redirect
                    "#{escape(outcome.status)} → #{escape(outcome.redirect)}"
                  else
                    status_title(outcome.status)
                  end
          "#{prefix}#{title}"
        end

        def outcome_principal(item, path, csrf_token)
          writes = item.writes_observed ? " — ⚠ #{escape(item.write_count)} database writes observed" : ""
          action = test_as_form(item.principal, path, csrf_token)
          "<li>#{escape(item.principal.display_label)} — #{escape(item.elapsed_ms)}ms#{writes}#{action}</li>"
        end

        def test_as_form(principal, path, csrf_token)
          return "" unless Identity.browser_supported? && csrf_token

          fields = hidden("operation", "test_as") + hidden("csrf_token", csrf_token) + hidden("path", path) +
                   hidden("principal_type", principal.model_name) + hidden("principal_id", principal.id)
          button = "<button type=\"submit\">Test as</button>"
          " <form class=\"test-as\" action=\"/karst\" method=\"post\">#{fields}#{button}</form>"
        end

        def status_title(status)
          phrase = Rack::Utils::HTTP_STATUS_CODES[status]
          phrase ? "#{escape(status)} #{escape(phrase)}" : escape(status)
        end

        # -- Diagnostics: spec evidence + runtime SQL (collapsed) ----------------

        def diagnostics_section(catalog, controller, action, http_method)
          "<section class=\"diagnostics\"><h2>Diagnostics</h2>" \
            "#{spec_evidence_details(catalog, controller, action, http_method)}#{runtime_sql_details}</section>"
        end

        def spec_evidence_details(catalog, controller, action, http_method)
          return "" if controller.empty? || action.empty?

          state = catalog_state(catalog)
          return spec_evidence_state(*state) if state

          scenarios = catalog.scenarios_for(
            controller: controller, action: action, http_method: http_method.empty? ? nil : http_method
          )
          spec_evidence_state(spec_evidence_summary(scenarios.size), spec_evidence_body(scenarios))
        end

        def catalog_state(catalog)
          return ["Spec evidence — unavailable", catalog_unreadable_body] unless catalog
          return ["Spec evidence — not yet generated", missing_catalog_body] if catalog.status == :missing
          return ["Spec evidence — unavailable", catalog_unreadable_body] if catalog.status == :invalid

          nil
        end

        def spec_evidence_state(summary, body)
          "<details class=\"diagnostic\"><summary>#{summary}</summary>#{body}</details>"
        end

        def spec_evidence_summary(count)
          noun = count == 1 ? "scenario" : "scenarios"
          "Spec evidence — #{count} matching #{noun}"
        end

        def spec_evidence_body(scenarios)
          return "<p>No observed specs currently cover this route.</p>" if scenarios.empty?

          "#{spec_evidence_caveat}#{scenario_groups(scenarios)}"
        end

        def spec_evidence_caveat
          "<p><small>Spec evidence reflects test-time behavior. It does not prove current runtime " \
            "authorization.</small></p>"
        end

        def missing_catalog_body
          <<~HTML
            <p>No Karst scenario catalog has been generated yet.</p>
            <p>Run <code>bundle exec rspec</code> with Karst's spec observer configured to generate it.</p>
          HTML
        end

        def catalog_unreadable_body
          "<p>Karst could not read the scenario catalog.</p>"
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

        def runtime_sql_details
          window = Karst.window
          enabled = Karst.enabled?
          summary = runtime_sql_summary(window, enabled)
          attr = enabled ? "" : " open"
          <<~HTML
            <details class="diagnostic"#{attr}><summary>#{summary}</summary>
            <p>#{escape(window.declined.size)} declined · Capture: #{escape(enabled ? 'enabled' : 'disabled')} · Subscription: #{escape(Karst.subscribed? ? 'active' : 'inactive')}</p>
            <p><small>Process-local, bounded, recently retained.</small></p>
            </details>
          HTML
        end

        def runtime_sql_summary(window, enabled)
          summary = "Runtime SQL — #{escape(window.event_count)} observations · #{escape(window.shapes.size)} shapes"
          enabled ? summary : "#{summary} — capture disabled"
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
