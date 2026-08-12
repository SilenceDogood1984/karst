# frozen_string_literal: true

require "cgi"
require "rack/utils"
require "active_support/number_helper"
require "base64"
require "digest"

module Karst
  module Web
    # Read-only HTML presentation of route access results for existing users.
    # All artifact and query-string values cross #escape before entering the
    # document.
    # rubocop:disable Metrics/ModuleLength
    module Panel
      SCRIPT = <<~JS
        document.addEventListener("submit", function(event) {
          var form = event.target;
          if (!form.matches("form.test-as")) return;
          event.preventDefault();
          fetch(form.action, {
            method: "POST", body: new FormData(form), credentials: "same-origin",
            headers: { "Accept": "application/json" }
          }).then(function(response) {
            if (!response.ok) throw new Error("Test as failed");
            return response.json();
          }).then(function(result) {
            window.location.assign(result.location);
          }).catch(function() {
            window.alert("Karst could not change the browser identity. Reload and try again.");
          });
        });
      JS
      private_constant :SCRIPT

      SCRIPT_HASH = Base64.strict_encode64(Digest::SHA256.digest(SCRIPT))
      private_constant :SCRIPT_HASH

      CONTENT_SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; " \
                                "script-src 'sha256-#{SCRIPT_HASH}'; connect-src 'self'; frame-ancestors 'none'".freeze
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
        section.populations{margin:1rem 0}
        .population-attempt{padding:.35rem 0;font-size:.92rem;border-bottom:1px solid #eee}
        .population-attempt:last-child{border-bottom:0}
        .population-attempt .name{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-weight:600}
        .population-attempt.hit .name{color:#0f5132}
        .population-attempt.untried{color:#777}
        .candidate-review{font-size:.9rem;color:#444;margin:.5rem 0 0}
        .ordinary-sample{border:1px solid #ddd;border-radius:.5rem;padding:.8rem 1rem;margin:1rem 0}
        .ordinary-sample h2{margin:0 0 .45rem}
        .ordinary-sample details{margin:.55rem 0}
        .write-warning{border:2px solid #b3261e;border-radius:.4rem;padding:.7rem .85rem;background:#fff7f6}
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
          .meta,small,.candidate-review{color:#9a9aa0}
          input{background:#1f2023;border-color:#3a3b3e;color:#e4e4e6}
          button{background:#26272b;border-color:#3a3b3e;color:#e4e4e6}
          button:hover{background:#303136}
          button.primary{background:#e4e4e6;border-color:#e4e4e6;color:#16171a}
          button.primary:hover{background:#c9c9cc}
          .usable-principal{border-color:#33343a}
          .population-attempt{border-color:#2c2d31}
          .population-attempt.hit .name{color:#7fd8a4}
          .population-attempt.untried{color:#8a8a90}
          .usable-principal button[type=submit]{background:#2e7d52;border-color:#2e7d52;color:#0b1a12}
          .related-state{background:#1c1d20;border-color:#3a3b3e}
          details{border-color:#2c2d31}
          .scenario{border-color:#33343a}
          .testing-banner{background:#3a2f0d;border-color:#6b5423;color:#f0e4c0}
          .hint{color:#d8a63d}
          .failed,.pending{border-left-color:#e5534b}
          .write-warning{background:#321b1a}
        }
      CSS
      private_constant :STYLE

      # Population-attempt states with no observed result of their own to
      # describe (see Karst::Access::Search). The three that do -- :usable,
      # :no_match, :unresolved -- render from their own evidence instead.
      STATIC_ATTEMPT_STATES = {
        empty: "no matching records",
        already_tried: "every candidate was already tested above",
        skipped: "not tried — a usable user was already found",
        budget_exhausted: "not tried — the retry request budget was reached"
      }.freeze
      private_constant :STATIC_ATTEMPT_STATES

      # rubocop:disable Metrics/ClassLength
      class << self
        # rubocop:disable Metrics/ParameterLists
        def render(params: {}, access_result: nil, csrf_token: nil, browser_identity_active: false,
                   route_lookup_limitation: nil, unapproved_candidate_count: nil,
                   principal_source_selection_saved: false, principal_source_selection_error: nil)
          state = { csrf_token: csrf_token, browser_identity_active: browser_identity_active,
                    route_lookup_limitation: route_lookup_limitation,
                    unapproved_candidate_count: unapproved_candidate_count,
                    principal_source_selection_saved: principal_source_selection_saved,
                    principal_source_selection_error: principal_source_selection_error }
          [200, HEADERS.dup, [document(params, access_result, state)]]
        end
        # rubocop:enable Metrics/ParameterLists

        private

        def document(params, access_result, state)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8"><title>Karst</title>
            <style>#{STYLE}</style>
            <script>#{SCRIPT}</script>
            </head><body>
            <h1>Karst</h1>
            #{page_body(params, access_result, state)}
            </body></html>
          HTML
        end

        def page_body(params, access_result, state)
          controller = string_param(params, "controller")
          action = string_param(params, "action")
          http_method = string_param(params, "method")
          path = string_param(params, "path")
          "#{testing_banner(path, state[:csrf_token], state[:browser_identity_active])}" \
            "#{route_header(http_method, path, state[:route_lookup_limitation])}" \
            "#{access_section(http_method, path, controller, action, access_result, state)}"
        end

        def string_param(params, key)
          value = params[key]
          value.is_a?(String) ? value.strip : ""
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

        def route_header(http_method, path, limitation)
          identity = path.empty? ? "<p>No URL selected yet.</p>" : route_identity(http_method, path)
          lookup = route_lookup(http_method, path, limitation)
          "<header class=\"route\">#{identity}#{lookup}</header>"
        end

        def route_identity(http_method, path)
          "<p class=\"route-path\">#{method_prefix(http_method)}#{escape(path)}</p>"
        end

        def method_prefix(http_method)
          http_method.empty? ? "" : "#{escape(http_method)} "
        end

        # rubocop:disable Metrics/MethodLength
        def route_lookup(http_method, path, limitation)
          open = path.empty?
          summary = open ? "What URL are you trying to test?" : "Test a different URL"
          attr = open ? " open" : ""
          message = limitation ? "<p class=\"hint\" role=\"alert\">#{escape(limitation)}</p>" : ""
          <<~HTML
            <details class="route-lookup"#{attr}><summary>#{summary}</summary>
            #{message}
            <form action="/karst" method="get">
            <input type="hidden" name="operation" value="route_lookup">
            <label>Path <input name="path" value="#{escape(path)}" placeholder="/organizations" required></label>
            <label>Method <input name="method" value="#{escape(http_method.empty? ? 'GET' : http_method)}" placeholder="GET" required></label>
            <button type="submit">Use this URL</button>
            </form></details>
          HTML
        end
        # rubocop:enable Metrics/MethodLength

        # -- Primary action: access analysis ------------------------------------

        # rubocop:disable Metrics/ParameterLists
        def access_section(http_method, path, controller, action, result, state)
          return "" if path.empty? || state[:route_lookup_limitation]

          context = hidden("controller", controller) + hidden("action", action) +
                    hidden("method", http_method) + hidden("path", path)
          body = if http_method == "GET"
                   analyze_form(context, state)
                 else
                   "<p>Access analysis is available for GET routes only.</p>"
                 end
          heading = "<h2 class=\"sr-only\">Access analysis</h2>"
          "<section class=\"access\">#{heading}#{body}#{access_result(result, state)}</section>"
        end
        # rubocop:enable Metrics/ParameterLists

        def analyze_form(context, state)
          sources = principal_sources
          kind = sources && any_representative?(sources) ? "representative " : ""
          label = "Who can use this? (test #{Karst.config.access_sweep_limit} #{kind}users)"
          operation = "<input type=\"hidden\" name=\"operation\" value=\"access_sweep\">"
          button = "<button class=\"primary\" type=\"submit\">#{escape(label)}</button>"
          form = "<form action=\"/karst\" method=\"post\">#{context}#{operation}#{button}</form>"
          # The save notice is independent of whether the save just resolved
          # the ambiguity below: a save that succeeded and immediately made
          # `sources` truthy must still tell the developer it worked, rather
          # than have the confirmation vanish the moment it stops being
          # needed.
          "#{principal_source_selection_notice(state)}#{form}#{scenario_forms}#{principal_source_hint(sources)}"
        end

        def scenario_forms
          Karst.config.access_scenarios.values.map do |scenario|
            fields = hidden("operation", "artifact_sweep") + hidden("scenario", scenario.name)
            label = "Analyze artifact scenario: #{scenario.name}"
            "<form action=\"/karst\" method=\"post\">#{fields}<button type=\"submit\">#{escape(label)}</button></form>"
          end.join
        end

        # Only ever type-checks each configured source's evaluated records
        # (see Access::PrincipalSampler.representative_capable?); it never
        # queries or enumerates any of them, so this is safe to compute on
        # every panel render.
        def principal_sources
          Identity.principal_sources
        rescue Identity::Error
          nil
        end

        def any_representative?(sources)
          sources.values.any? { |source| Access::PrincipalSampler.representative_capable?(source.evaluate) }
        end

        def principal_source_hint(sources)
          return "" if sources

          setup = Identity.setup_state
          return principal_source_selection_form(setup) if setup.status == :ambiguous

          custom_auth_hint
        end

        def custom_auth_hint
          url = "https://github.com/SilenceDogood1984/karst/blob/main/docs/advanced-configuration.md#custom-or-non-devise-authentication"
          "<p class=\"hint\" role=\"alert\">Karst couldn't determine how this app authenticates users. " \
            "<a href=\"#{url}\">Set up custom authentication</a></p>"
        end

        # The one place Karst asks a developer to pick which ambiguous
        # Devise model(s) to test, right where the old "configure
        # config.principals" hint used to sit -- no initializer, no separate
        # page. Only ever offers the models Devise.mappings itself currently
        # reports (see Karst::Identity::DeviseSupport); saving is handled by
        # Karst::Web::Middleware, which only ever persists a submitted name
        # that matches one of those same mappings (see
        # Karst::Access::PrincipalSourceSelection).
        def principal_source_selection_form(setup)
          candidates = Identity::DeviseSupport.mappings.sort_by { |mapping| mapping.model.name }
          return "<p class=\"hint\" role=\"alert\">#{escape(setup.message)}</p>" if candidates.size < 2

          <<~HTML
            <div class="hint" role="alert">
            #{principal_source_selection_intro(candidates)}
            #{principal_source_selection_fields(candidates)}
            </div>
          HTML
        end

        def principal_source_selection_intro(candidates)
          names = candidates.map { |mapping| mapping.model.name }
          "<p>Karst found #{names.size} user types: #{escape(names.join(', '))}.</p>"
        end

        def principal_source_selection_fields(candidates)
          selected = Access::SelectedPrincipalSources.mappings.map { |mapping| mapping.model.name }
          rows = candidates.map { |mapping| principal_source_checkbox(mapping, selected) }.join
          <<~HTML
            <form action="/karst" method="post">
            <input type="hidden" name="operation" value="select_principal_sources">
            <p>Which should Karst test?</p>
            #{rows}
            <button type="submit">Save</button>
            </form>
          HTML
        end

        def principal_source_checkbox(mapping, selected)
          name = mapping.model.name
          box = "<input type=\"checkbox\" name=\"principal[]\" value=\"#{escape(name)}\"" \
                "#{' checked' if selected.include?(name)}>"
          "<label>#{box} #{escape(name)}</label><br>"
        end

        def principal_source_selection_notice(state)
          saved = "<p class=\"hint\" role=\"status\">Selection saved.</p>" if state[:principal_source_selection_saved]
          error = state[:principal_source_selection_error]
          "#{saved}#{"<p class=\"hint\" role=\"alert\">#{escape(error)}</p>" if error}"
        end

        def hidden(name, value)
          "<input type=\"hidden\" name=\"#{name}\" value=\"#{escape(value)}\">"
        end

        def access_result(result, state)
          return "" unless result
          return "<p>Analysis unavailable: #{escape(result.message)}</p>" if result.is_a?(StandardError)

          csrf_token = state[:csrf_token]
          return scenario_result(result, csrf_token) if result.respond_to?(:scenario_name)

          search_result(result, state)
        end

        # Renders one Karst::Access::Search::Result: the ordinary sample and
        # any automatic candidate-population retries as a single answer, so
        # a usable user found through a population reads exactly like one
        # found in the sample -- there is no second workflow to enter.
        def search_result(result, state)
          csrf_token = state[:csrf_token]
          outcomes = result.all_outcomes
          usable = outcomes.select { |outcome| usable_outcome?(outcome) }
          write_count = outcomes.count(&:writes_observed)
          "#{usable_outcomes(usable, result, state)}#{ordinary_sample(result, csrf_token)}" \
            "#{populations_section(result, csrf_token)}#{write_evidence(write_count)}#{search_meta(result)}"
        end

        # -- Automatic candidate-population retries ----------------------------

        # Every approved population appears here, including the ones
        # deliberately not run -- "not tried" is reported honestly rather
        # than left to look like a failure. Only configured populations ever
        # reach this list; a name merely discovered at /karst/populations is
        # never executed automatically.
        def populations_section(result, csrf_token)
          return "" if result.attempts.empty?

          rows = result.attempts.map { |attempt| population_attempt(attempt, result.path, csrf_token) }.join
          "<section class=\"populations\"><h2>Candidate populations</h2>#{rows}</section>"
        end

        def population_attempt(attempt, path, csrf_token)
          details = attempt.result ? observed_groups(attempt.result.outcomes, path, csrf_token) : ""
          "<div class=\"population-attempt #{attempt_class(attempt)}\">" \
            "<span class=\"name\">#{escape(attempt.name)}</span><br>#{attempt_state(attempt)}#{details}</div>"
        end

        def attempt_class(attempt)
          case attempt.state
          when :usable then "hit"
          when :skipped, :budget_exhausted then "untried"
          else ""
          end
        end

        def attempt_state(attempt)
          case attempt.state
          when :usable then population_hit(attempt)
          when :no_match then population_miss(attempt)
          when :unresolved then population_unresolved(attempt)
          else STATIC_ATTEMPT_STATES.fetch(attempt.state, "not tried")
          end
        end

        def population_hit(attempt)
          outcome = attempt.result.outcomes.find { |item| usable_outcome?(item) }
          "#{escape(attempt.result.outcomes.size)} #{users(attempt.result.outcomes.size)} tested<br>" \
            "#{principal_label(outcome.principal)} → #{outcome_title(outcome)} ✓"
        end

        def population_miss(attempt)
          outcomes = attempt.result.outcomes
          "#{escape(outcomes.size)} #{users(outcomes.size)} tested<br>none verified usable"
        end

        def population_unresolved(attempt)
          detail = attempt.error ? " (#{escape(attempt.error)})" : ""
          "could not be resolved#{detail}"
        end

        def dominant_halted_callback(outcomes)
          tally = Hash.new(0)
          outcomes.filter_map(&:halted_callback).each { |callback| tally[callback] += 1 }
          return nil if tally.empty?

          tally.max_by { |_callback, count| count }.first
        end

        def users(count)
          count == 1 ? "user" : "users"
        end

        def scenario_result(result, csrf_token)
          matches, mismatches = result.outcomes.partition(&:match)
          cards = matches.map { |outcome| verified_context(outcome, csrf_token) }.join
          summary = "<details><summary>Failed candidates — #{mismatches.size}</summary></details>"
          meta = "<p class=\"meta\">#{result.outcomes.size} combinations tested (limit #{result.combination_limit}; " \
                 "artifact candidates limited to #{result.artifact_candidate_limit}).</p>"
          "#{meta}<section class=\"usable\"><h2>Verified context — #{matches.size}</h2>#{cards}</section>#{summary}"
        end

        # rubocop:disable Layout/LineLength, Metrics/AbcSize
        def verified_context(outcome, csrf_token)
          marker = if outcome.expected.key?(:body_includes)
                     outcome.body_marker_observed ? " · expected marker observed" : " · expected marker absent"
                   else
                     ""
                   end
          expected = outcome.expected.map { |key, value| "#{key}=#{value}" }.join(", ")
          action = test_as_form(outcome.principal, outcome.path, csrf_token)
          "<article class=\"usable-principal\"><h4><span>#{principal_label(outcome.principal)}</span>#{action}</h4>" \
            "<p><strong>#{escape(outcome.artifact.display_label)}</strong></p><p><code>GET #{escape(outcome.path)}</code></p>" \
            "<p>Expected #{escape(expected)} · Observed #{escape(outcome.status || outcome.exception_class)}#{marker} · Match yes</p></article>"
        end
        # rubocop:enable Layout/LineLength, Metrics/AbcSize

        def search_meta(result)
          initial = result.initial.outcomes.size
          population = result.population_request_count
          total = initial + population
          "<p class=\"meta\"><strong>Request accounting:</strong> #{escape(initial)} initial · " \
            "#{escape(population)} candidate population · #{escape(total)} total " \
            "#{users(total)}/requests · #{escape(total_seconds(result))}s elapsed.</p>"
        end

        def total_seconds(result)
          total = result.initial.elapsed_ms + result.attempted.sum { |attempt| attempt.result.elapsed_ms }
          (total / 1000.0).round(2)
        end

        # The ordinary sample's own result stays visible even when a
        # population later succeeded: "nothing recent worked, and here is
        # what stopped them" is the evidence that explains why a population
        # was tried at all.
        def ordinary_sample(result, _csrf_token)
          outcomes = result.initial.outcomes
          usable = outcomes.count { |outcome| usable_outcome?(outcome) }
          result_text = usable.positive? ? "#{usable} verified usable" : "No verified usable user"
          pool = ordinary_pool(result.initial)
          "<section class=\"ordinary-sample\"><h2>Ordinary sample</h2>" \
            "<p>#{escape(outcomes.size)} #{users(outcomes.size)} tested#{pool}<br>#{result_text}</p>" \
            "<strong>Observed:</strong>#{observed_groups(outcomes, result.path, nil)}</section>"
        end

        def ordinary_pool(initial)
          return "" unless initial.candidate_pool_size

          size = ActiveSupport::NumberHelper.number_to_delimited(initial.candidate_pool_size)
          " from up to #{escape(size)} recent users"
        end

        # A bounded candidate pool is reported explicitly rather than left
        # implicit, so this never reads as "every user was searched."
        def candidate_pool_note(result)
          size = result.candidate_pool_size
          return "" unless size

          delimited = ActiveSupport::NumberHelper.number_to_delimited(size)
          " · candidate pool: up to #{escape(delimited)} most recent users"
        end

        def write_evidence(count)
          return "<p class=\"meta\">Database writes observed: 0</p>" if count.zero?

          "<div class=\"write-warning\" role=\"alert\"><strong>⚠ Database writes observed during " \
            "#{escape(count)} #{count == 1 ? 'probe' : 'probes'}.</strong><br>" \
            "Rollback was attempted on the same Active Record connection." \
            "<br><small>Jobs, mail, external HTTP, files, Redis, and other database connections are not " \
            "isolated by same-connection rollback.</small></div>"
        end

        def usable_outcome?(outcome)
          Karst.config.usable_access_outcome.call(outcome)
        end

        # -- Usable principals ---------------------------------------------------

        def usable_outcomes(outcomes, result, state)
          csrf_token = state[:csrf_token]
          body = if outcomes.empty?
                   candidate_review(state[:unapproved_candidate_count])
                 else
                   usable_cards(outcomes,
                                result, csrf_token)
                 end
          heading = outcomes.empty? ? "No verified usable user found" : "Verified usable user"
          "<section class=\"usable\"><h2>#{heading}</h2>" \
            "#{test_as_hint(outcomes, csrf_token)}#{body}</section>"
        end

        # The one place /karst mentions candidate groups at all: a small
        # contextual action, shown only when the analysis found nothing
        # usable and unapproved application-defined groups actually exist on
        # a configured user source. Deliberately not a configuration
        # workflow -- it says what Karst found and offers to show it, and
        # names nothing it has not been approved to run.
        def candidate_review(count)
          return "" unless count&.positive?

          "<p class=\"candidate-review\">Karst found #{escape(count)} application-defined user " \
            "#{count == 1 ? 'group' : 'groups'} that could be tried. " \
            "<a href=\"/karst/populations\">Review candidate groups</a></p>"
        end

        def usable_cards(outcomes, result, csrf_token)
          outcomes.map { |outcome| usable_principal(outcome, result, csrf_token) }.join
        end

        def test_as_hint(outcomes, csrf_token)
          return "" if outcomes.empty? || (Identity.browser_supported? && csrf_token)

          state = Identity.setup_state
          return "<p class=\"hint\">#{escape(state.message)}</p>" if state.status == :ambiguous

          custom_auth_hint
        end

        def usable_principal(outcome, result, csrf_token)
          writes = outcome.writes_observed ? " — ⚠ #{escape(outcome.write_count)} database writes observed" : ""
          action = test_as_form(outcome.principal, result.path, csrf_token)
          evidence = resource_evidence(outcome, result)
          "<article class=\"usable-principal\"><h4><span>#{principal_label(outcome.principal)}#{writes}</span>" \
            "#{action}</h4><p>#{outcome_title(outcome, prefix: 'Observed ')} · " \
            "#{escape(outcome.elapsed_ms)}ms</p>#{sampled_for(outcome)}#{evidence}</article>"
        end

        # A compact, secondary line -- deliberately below the observed
        # outcome and above any resource evidence, never a card of its own --
        # so it augments a usable principal without competing with Test as,
        # the observed outcome, or resource evidence for attention. Sampling
        # evidence, not an authorization claim: see PrincipalDimension.
        def sampled_for(outcome)
          reasons = outcome.sampling_reasons
          return "" if reasons.nil? || reasons.empty?

          "<p class=\"meta\">Sampled for: #{escape(reasons.join(' · '))}</p>"
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

        def observed_groups(outcomes, path, csrf_token)
          outcomes.group_by { |item| outcome_group_key(item) }
                  .map { |_key, grouped| outcome_group(grouped, path, csrf_token) }.join
        end

        def outcome_group_key(item)
          [item.status, item.redirect, item.exception_class, item.halted_callback,
           item.writes_observed, item.write_count]
        end

        def outcome_group(outcomes, path, csrf_token)
          first = outcomes.first
          title = outcome_title(first)
          labels = outcomes.map { |item| outcome_principal(item, path, csrf_token) }.join
          halt = halted_callback(first)
          usability = usable_outcome?(first) ? "Verified usable" : "Not verified as usable"
          "<details><summary>#{title}#{halt_summary(first)} — #{outcomes.size}</summary>" \
            "#{halt}<p>#{usability}</p><ul>#{labels}</ul></details>"
        end

        def halt_summary(outcome)
          outcome.halted_callback ? " · halted at #{escape(outcome.halted_callback)}" : ""
        end

        def halted_callback(outcome)
          return "" unless outcome.halted_callback

          "<p>Halted callback: #{escape(outcome.halted_callback)}</p>"
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
          "<li>#{principal_label(item.principal)} — #{escape(item.elapsed_ms)}ms#{writes}#{action}</li>"
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

        def principal_label(principal)
          identifier = principal.respond_to?(:authentication_identifier) && principal.authentication_identifier
          key = principal.respond_to?(:authentication_key) && principal.authentication_key
          return escape(principal.display_label) unless identifier

          identity = if key == :email
                       "<a href=\"mailto:#{escape(identifier)}\">#{escape(identifier)}</a>"
                     else
                       escape(identifier)
                     end
          "#{identity} · #{escape(principal.model_name)} ##{escape(principal.id)}"
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
