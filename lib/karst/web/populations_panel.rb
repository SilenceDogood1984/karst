# frozen_string_literal: true

require "cgi"
require "securerandom"
module Karst
  module Web
    # The local approval surface for Karst::Access::PopulationDiscovery:
    # browse the application-defined groups Karst found, approve the ones
    # Karst may try, and see which approvals are no longer doing anything.
    #
    # Kept as a pure renderer, exactly like Karst::Web::Panel: every value
    # this module needs (the discovery result, the approved entries, stale
    # approvals and an optional storage error) is computed by
    # Karst::Web::Middleware and
    # passed in, so this file never touches Active Record, the filesystem, or
    # Karst.config directly.
    # rubocop:disable Metrics/ModuleLength
    module PopulationsPanel
      CANDIDATE_SEPARATOR = "::"

      # Why an approved entry currently does nothing (see
      # Karst::Access::ApprovedPopulations.stale). Reported rather than
      # silently ignored -- and never repaired automatically, since the fix
      # is always a decision about the application, not about Karst.
      STALE_REASONS = {
        not_discovered: "no longer a discovered scope on this model — not used",
        no_principal_source: "not part of a configured user source — not used"
      }.freeze
      private_constant :STALE_REASONS

      STYLE = <<~CSS
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1.25rem;color:#1a1a1a;background:#fff}
        h1{font-size:1.4rem;margin:0 0 1rem}
        h2{font-size:1.1rem;margin:1.5rem 0 .5rem}
        h3{font-size:.85rem;text-transform:uppercase;letter-spacing:.05em;color:#555;margin:1.5rem 0 .6rem;border-bottom:1px solid #e2e2e2;padding-bottom:.35rem}
        a{color:#2563eb}
        .lead{margin:.4rem 0 1rem}
        .hint{color:#8a5b00;font-size:.85rem;margin:.4rem 0}
        .warning{color:#8a5b00;font-size:.85rem;margin:.4rem 0;border:1px solid #eacb6b;background:#fff7e0;border-radius:.4rem;padding:.6rem .8rem}
        .saved{color:#0f5132;font-size:.9rem;margin:.4rem 0;border:1px solid #a6d9bb;background:#e6f4ea;border-radius:.4rem;padding:.6rem .8rem}
        .search-box{margin:1rem 0}
        .search-box label{display:flex;flex-direction:column;font-size:.78rem;font-weight:600;gap:.25rem;color:#444}
        .search-box input{font:inherit;padding:.5rem .6rem;border:1px solid #ccc;border-radius:.3rem;max-width:24rem}
        button{font:inherit;padding:.35rem .65rem;border:1px solid #ccc;border-radius:.35rem;background:#f4f4f4;cursor:pointer}
        button:hover{background:#eaeaea}
        button:focus-visible,input:focus-visible,summary:focus-visible,a:focus-visible{outline:2px solid #2563eb;outline-offset:2px}
        button.primary{background:#202124;border-color:#202124;color:#fff;font-weight:600;padding:.65rem 1.15rem;font-size:.95rem;margin-top:1rem}
        button.primary:hover{background:#3a3b3e}
        .approved-summary{border:1px solid #ddd;border-radius:.5rem;padding:.75rem 1rem}
        .approved-model{margin:.4rem 0}
        .approved-model strong{display:block}
        .approved-model ul{margin:.2rem 0 0;padding-left:1.2rem}
        .approved-model .stale{color:#8a5b00;font-size:.85rem}
        details.model-group{border:1px solid #e2e2e2;border-radius:.4rem;padding:.5rem .8rem;margin:.5rem 0}
        details.model-group summary{cursor:pointer;font-weight:600;display:flex;gap:.6rem;align-items:baseline;flex-wrap:wrap}
        details.model-group summary .count{font-weight:400;color:#666;font-size:.85rem}
        details.model-group summary .badge{font-weight:400;font-size:.72rem;color:#0f5132;background:#e6f4ea;border-radius:.6rem;padding:.05rem .5rem}
        .candidate-list{list-style:none;margin:.6rem 0 0;padding:0}
        .candidate-row{display:flex;align-items:center;gap:.6rem;padding:.3rem 0;flex-wrap:wrap}
        .candidate-row label{display:flex;align-items:center;gap:.4rem;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92rem}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em}
        small{color:#666}
        @media (prefers-color-scheme:dark){
          body{background:#16171a;color:#e4e4e6}
          a{color:#7aa2f7}
          h3{color:#a7a7ad;border-color:#2c2d31}
          .search-box input{background:#1f2023;border-color:#3a3b3e;color:#e4e4e6}
          button{background:#26272b;border-color:#3a3b3e;color:#e4e4e6}
          button:hover{background:#303136}
          button.primary{background:#e4e4e6;border-color:#e4e4e6;color:#16171a}
          button.primary:hover{background:#c9c9cc}
          .approved-summary,details.model-group{border-color:#33343a}
          .hint,.warning,.approved-model .stale{color:#d8a63d}
          .warning{background:#3a2f0d;border-color:#6b5423}
          .saved{background:#123822;border-color:#1f5c37;color:#7fd8a4}
          details.model-group summary .badge{background:#123822;color:#7fd8a4}
        }
      CSS
      private_constant :STYLE

      SEARCH_SCRIPT = <<~JS
        (function () {
          var input = document.getElementById("karst-population-search");
          if (!input) return;
          var groups = document.querySelectorAll(".model-group");
          input.addEventListener("input", function () {
            var query = input.value.trim().toLowerCase();
            groups.forEach(function (details) {
              var model = (details.getAttribute("data-model") || "").toLowerCase();
              var modelMatches = query === "" || model.indexOf(query) !== -1;
              var rows = details.querySelectorAll(".candidate-row");
              var anyRowMatches = false;
              rows.forEach(function (row) {
                var name = (row.getAttribute("data-name") || "").toLowerCase();
                var rowMatches = query === "" || modelMatches || name.indexOf(query) !== -1;
                row.style.display = rowMatches ? "" : "none";
                if (rowMatches) anyRowMatches = true;
              });
              var show = query === "" || modelMatches || anyRowMatches;
              details.style.display = show ? "" : "none";
              if (query !== "" && show) details.open = true;
            });
          });
        })();
      JS
      private_constant :SEARCH_SCRIPT

      # rubocop:disable Metrics/ClassLength
      class << self
        # `approved` and each entry of `stale` are anything exposing
        # #model_name/#method_name -- in practice
        # Karst::Access::PopulationApprovals::Entry.
        # rubocop:disable Metrics/ParameterLists
        def render(discovery:, approved: [], stale: [], storage_path: nil, storage_error: nil, saved: false)
          nonce = SecureRandom.hex(16)
          state = { approved: approved, stale: stale, storage_path: storage_path,
                    storage_error: storage_error, saved: saved }
          [200, headers(nonce), [document(discovery, state, nonce)]]
        end
        # rubocop:enable Metrics/ParameterLists

        private

        def headers(nonce)
          csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-#{nonce}'; frame-ancestors 'none'"
          {
            "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
            "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY", "content-security-policy" => csp
          }
        end

        def document(discovery, state, nonce)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8"><title>Karst — Candidate groups</title>
            <style>#{STYLE}</style>
            </head><body>
            <h1>Karst</h1>
            <p><a href="/karst">&larr; Back to route evidence</a></p>
            <h2>Candidate groups</h2>
            <p class="lead">Approving a group lets Karst try a few existing users from it when the ordinary sample
            fails. Approving is not a claim that the group grants access — only running an analysis against a route
            shows what actually happens.</p>
            #{saved_notice(state[:saved])}
            #{storage_error(state[:storage_error])}
            #{load_warning(discovery)}
            <form method="post" action="/karst/populations">
            #{search_box}
            #{approved_section(state[:approved], state[:stale])}
            #{model_groups_section(discovery, state[:approved])}
            <button type="submit" name="save_approvals" value="1" class="primary">Approve selected groups</button>
            </form>
            #{storage_note(state[:storage_path])}
            <script nonce="#{nonce}">#{SEARCH_SCRIPT}</script>
            </body></html>
          HTML
        end

        def saved_notice(saved)
          return "" unless saved

          "<p class=\"saved\" role=\"status\">Approvals saved.</p>"
        end

        def storage_error(error)
          return "" unless error

          "<p class=\"warning\" role=\"alert\">#{escape(error)}</p>"
        end

        def storage_note(path)
          return "" unless path

          "<p><small>Approvals are stored locally in <code>#{escape(path)}</code> as plain model and " \
            "scope names — no user data, no Ruby. Delete that file to reset every approval.</small></p>"
        end

        def load_warning(discovery)
          return "" unless discovery.load_warning

          "<p class=\"warning\" role=\"alert\">#{escape(discovery.load_warning)}</p>"
        end

        def search_box
          <<~HTML
            <div class="search-box">
            <label>Search groups or models
            <input type="search" id="karst-population-search" placeholder="e.g. admin, User, subscription">
            </label>
            </div>
          HTML
        end

        # -- Approved summary --------------------------------------------------

        def approved_section(approved, stale)
          body = if approved.empty?
                   "<p>No groups approved yet.</p>"
                 else
                   approved.group_by(&:model_name).sort.map do |model_name, group|
                     approved_model(model_name, group, stale)
                   end.join
                 end
          "<section class=\"approved-summary\"><h3>Approved (#{approved.size})</h3>#{body}</section>"
        end

        def approved_model(model_name, entries, stale)
          items = entries.sort_by { |entry| entry.method_name.to_s }.map do |entry|
            "<li>#{escape(entry.method_name)}#{stale_note(entry, stale)}</li>"
          end.join
          "<div class=\"approved-model\"><strong>#{escape(model_name)}</strong><ul>#{items}</ul></div>"
        end

        def stale_note(entry, stale)
          match = stale.find { |item, _reason| same_candidate?(item, entry) }
          return "" unless match

          " <span class=\"stale\">— #{escape(STALE_REASONS.fetch(match.last, 'not used'))}</span>"
        end

        def same_candidate?(left, right)
          left.model_name.to_s == right.model_name.to_s && left.method_name.to_s == right.method_name.to_s
        end

        # -- Model groups ------------------------------------------------------

        def model_groups_section(discovery, approved)
          groups = discovery.model_groups.reject { |group| group.candidate_names.empty? }
          body = if groups.empty?
                   "<p>No candidate groups were discovered.</p>"
                 else
                   groups.map { |group| model_group(group, approved) }.join
                 end
          "<section class=\"model-groups\"><h3>Available models</h3>#{body}</section>"
        end

        def model_group(group, approved)
          approved_names = approved.select { |entry| entry.model_name == group.model_name }
                                   .map { |entry| entry.method_name.to_s }
          open = approved_names.any? ? " open" : ""
          rows = group.candidate_names.map { |name| candidate_row(group, name, approved_names) }.join
          <<~HTML
            <details class="model-group" data-model="#{escape(group.model_name)}"#{open}>
            <summary>#{model_summary(group)}</summary>
            <ul class="candidate-list">#{rows}</ul>
            </details>
          HTML
        end

        def model_summary(group)
          count = group.candidate_names.size
          "#{escape(group.model_name)} <span class=\"count\">#{count} group#{'s' unless count == 1}</span>" \
            "#{principal_badge(group)}"
        end

        def principal_badge(group)
          return "" unless group.principal_source

          "<span class=\"badge\">user source: #{escape(group.principal_source)}</span>"
        end

        def candidate_row(group, method_name, approved_names)
          key = candidate_key(group.model_name, method_name)
          checked = approved_names.include?(method_name.to_s)
          box = "<input type=\"checkbox\" name=\"population[]\" value=\"#{escape(key)}\"#{' checked' if checked}>"
          label = "<label>#{box} #{escape(method_name)}</label>"
          "<li class=\"candidate-row\" data-name=\"#{escape(method_name)}\">#{label}</li>"
        end

        def candidate_key(model_name, method_name)
          "#{model_name}#{CANDIDATE_SEPARATOR}#{method_name}"
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
