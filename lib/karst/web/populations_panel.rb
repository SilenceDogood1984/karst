# frozen_string_literal: true

require "cgi"
require "securerandom"
require_relative "../access/population_preview"

module Karst
  module Web
    # Read-only-except-for-selection HTML presentation of
    # Karst::Access::PopulationDiscovery: browse application models and
    # their discovered candidate populations without being buried by
    # hundreds of them, curate a selection, preview one bounded candidate at
    # a time, and copy a generated config snippet. Never mutates the host
    # application's files -- see Karst::Access::PopulationConfigSnippet.
    #
    # Kept as a pure renderer, exactly like Karst::Web::Panel: every value
    # this module needs (the discovery result, the current selection, an
    # optional generated snippet, an optional single preview) is computed
    # by Karst::Web::Middleware and passed in, so this file never touches
    # Active Record, the filesystem, or Karst.config directly.
    # rubocop:disable Metrics/ModuleLength
    module PopulationsPanel
      CANDIDATE_SEPARATOR = "::"

      STYLE = <<~CSS
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1.25rem;color:#1a1a1a;background:#fff}
        h1{font-size:1.4rem;margin:0 0 1rem}
        h2{font-size:1.1rem;margin:1.5rem 0 .5rem}
        h3{font-size:.85rem;text-transform:uppercase;letter-spacing:.05em;color:#555;margin:1.5rem 0 .6rem;border-bottom:1px solid #e2e2e2;padding-bottom:.35rem}
        a{color:#2563eb}
        .hint{color:#8a5b00;font-size:.85rem;margin:.4rem 0}
        .warning{color:#8a5b00;font-size:.85rem;margin:.4rem 0;border:1px solid #eacb6b;background:#fff7e0;border-radius:.4rem;padding:.6rem .8rem}
        .search-box{margin:1rem 0}
        .search-box label{display:flex;flex-direction:column;font-size:.78rem;font-weight:600;gap:.25rem;color:#444}
        .search-box input{font:inherit;padding:.5rem .6rem;border:1px solid #ccc;border-radius:.3rem;max-width:24rem}
        button{font:inherit;padding:.35rem .65rem;border:1px solid #ccc;border-radius:.35rem;background:#f4f4f4;cursor:pointer}
        button:hover{background:#eaeaea}
        button:focus-visible,input:focus-visible,summary:focus-visible,a:focus-visible{outline:2px solid #2563eb;outline-offset:2px}
        button.primary{background:#202124;border-color:#202124;color:#fff;font-weight:600;padding:.65rem 1.15rem;font-size:.95rem;margin-top:1rem}
        button.primary:hover{background:#3a3b3e}
        .selected-summary{border:1px solid #ddd;border-radius:.5rem;padding:.75rem 1rem}
        .selected-model{margin:.4rem 0}
        .selected-model strong{display:block}
        .selected-model ul{margin:.2rem 0 0;padding-left:1.2rem}
        details.model-group{border:1px solid #e2e2e2;border-radius:.4rem;padding:.5rem .8rem;margin:.5rem 0}
        details.model-group summary{cursor:pointer;font-weight:600;display:flex;gap:.6rem;align-items:baseline;flex-wrap:wrap}
        details.model-group summary .count{font-weight:400;color:#666;font-size:.85rem}
        details.model-group summary .badge{font-weight:400;font-size:.72rem;color:#0f5132;background:#e6f4ea;border-radius:.6rem;padding:.05rem .5rem}
        .candidate-list{list-style:none;margin:.6rem 0 0;padding:0}
        .candidate-row{display:flex;align-items:center;gap:.6rem;padding:.3rem 0;flex-wrap:wrap}
        .candidate-row label{display:flex;align-items:center;gap:.4rem;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92rem}
        .preview{flex-basis:100%;margin:.2rem 0 .3rem 1.6rem;font-size:.85rem;color:#444}
        .preview.error{color:#8a5b00}
        .snippet{border:1px solid #ddd;border-radius:.5rem;padding:.9rem 1rem;margin:1rem 0}
        .snippet textarea{width:100%;min-height:6rem;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.85rem;padding:.5rem;border:1px solid #ccc;border-radius:.3rem}
        small{color:#666}
        @media (prefers-color-scheme:dark){
          body{background:#16171a;color:#e4e4e6}
          a{color:#7aa2f7}
          h3{color:#a7a7ad;border-color:#2c2d31}
          .search-box input,.snippet textarea{background:#1f2023;border-color:#3a3b3e;color:#e4e4e6}
          button{background:#26272b;border-color:#3a3b3e;color:#e4e4e6}
          button:hover{background:#303136}
          button.primary{background:#e4e4e6;border-color:#e4e4e6;color:#16171a}
          button.primary:hover{background:#c9c9cc}
          .selected-summary,details.model-group,.snippet{border-color:#33343a}
          .hint,.warning{color:#d8a63d}
          .warning{background:#3a2f0d;border-color:#6b5423}
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

      COPY_SCRIPT = <<~JS
        (function () {
          var button = document.getElementById("karst-copy-snippet");
          var field = document.getElementById("karst-snippet-code");
          if (!button || !field || !navigator.clipboard) return;
          button.addEventListener("click", function () {
            navigator.clipboard.writeText(field.value).then(function () {
              button.textContent = "Copied";
              setTimeout(function () { button.textContent = "Copy"; }, 1500);
            }, function () {});
          });
        })();
      JS
      private_constant :COPY_SCRIPT

      # rubocop:disable Metrics/ClassLength
      class << self
        def render(discovery:, selected: [], snippet: nil, preview: nil)
          nonce = SecureRandom.hex(16)
          [200, headers(nonce), [document(discovery, selected, snippet, preview, nonce)]]
        end

        private

        def headers(nonce)
          csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-#{nonce}'; frame-ancestors 'none'"
          {
            "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
            "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY", "content-security-policy" => csp
          }
        end

        def document(discovery, selected, snippet, preview, nonce)
          <<~HTML
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8"><title>Karst — Candidate populations</title>
            <style>#{STYLE}</style>
            </head><body>
            <h1>Karst</h1>
            <p><a href="/karst">&larr; Back to route evidence</a></p>
            <h2>Candidate populations</h2>
            <p class="hint">Discovered candidates are a hint about where a useful principal or artifact subset
            might live -- never a claim that a name is a real scope, that it returns anything, or that it
            grants access. Only running an actual sweep against a route proves behavior.</p>
            #{load_warning(discovery)}
            <form method="post" action="/karst/populations">
            #{search_box}
            #{snippet_section(snippet)}
            #{selected_section(selected)}
            #{model_groups_section(discovery, selected, preview)}
            <button type="submit" name="generate_snippet" value="1" class="primary">Generate configuration snippet</button>
            </form>
            <script nonce="#{nonce}">#{SEARCH_SCRIPT}#{COPY_SCRIPT}</script>
            </body></html>
          HTML
        end

        def load_warning(discovery)
          return "" unless discovery.load_warning

          "<p class=\"warning\" role=\"alert\">#{escape(discovery.load_warning)}</p>"
        end

        def search_box
          <<~HTML
            <div class="search-box">
            <label>Search models or populations
            <input type="search" id="karst-population-search" placeholder="e.g. admin, User, subscription">
            </label>
            </div>
          HTML
        end

        # -- Selected summary -----------------------------------------------

        def selected_section(selected)
          body = if selected.empty?
                   "<p>No populations selected yet.</p>"
                 else
                   selected.group_by(&:model_name).sort.map do |model_name, group|
                     selected_model(model_name, group)
                   end.join
                 end
          "<section class=\"selected-summary\"><h3>Selected (#{selected.size})</h3>#{body}</section>"
        end

        def selected_model(model_name, candidates)
          items = candidates.sort_by { |c| c.method_name.to_s }.map { |c| "<li>#{escape(c.method_name)}</li>" }.join
          "<div class=\"selected-model\"><strong>#{escape(model_name)}</strong><ul>#{items}</ul></div>"
        end

        # -- Model groups ------------------------------------------------------

        def model_groups_section(discovery, selected, preview)
          groups = discovery.model_groups.reject { |group| group.candidate_names.empty? }
          body = if groups.empty?
                   "<p>No candidate populations were discovered.</p>"
                 else
                   groups.map { |group| model_group(group, selected, preview) }.join
                 end
          "<section class=\"model-groups\"><h3>Available models</h3>#{body}</section>"
        end

        def model_group(group, selected, preview)
          selected_names = selected.select { |c| c.model_name == group.model_name }.map(&:method_name)
          open = selected_names.any? ? " open" : ""
          rows = group.candidate_names.map { |name| candidate_row(group, name, selected_names, preview) }.join
          <<~HTML
            <details class="model-group" data-model="#{escape(group.model_name)}"#{open}>
            <summary>#{model_summary(group)}</summary>
            <ul class="candidate-list">#{rows}</ul>
            </details>
          HTML
        end

        def model_summary(group)
          count = group.candidate_names.size
          "#{escape(group.model_name)} <span class=\"count\">#{count} candidate#{'s' unless count == 1}</span>" \
            "#{principal_badge(group)}"
        end

        def principal_badge(group)
          return "" unless group.principal_source

          "<span class=\"badge\">principal source: #{escape(group.principal_source)}</span>"
        end

        def candidate_row(group, method_name, selected_names, preview)
          key = candidate_key(group.model_name, method_name)
          checked = selected_names.include?(method_name)
          box = "<input type=\"checkbox\" name=\"population[]\" value=\"#{escape(key)}\"#{' checked' if checked}>"
          preview_button = "<button type=\"submit\" name=\"preview\" value=\"#{escape(key)}\">Preview</button>"
          label = "<label>#{box} #{escape(method_name)}</label>"
          "<li class=\"candidate-row\" data-name=\"#{escape(method_name)}\">#{label}" \
            "#{preview_button}#{preview_result(group, method_name, preview)}</li>"
        end

        def preview_result(group, method_name, preview)
          unless preview && preview.model_name == group.model_name && preview.method_name.to_s == method_name.to_s
            return ""
          end

          preview.resolved ? preview_success(preview) : preview_failure(preview)
        end

        def preview_success(preview)
          return "<p class=\"preview\">Preview: no matching records currently.</p>" if preview.records.empty?

          labels = preview.records.map { |record| record_label(record) }.join(", ")
          "<p class=\"preview\">Preview (up to #{Access::PopulationPreview::PREVIEW_LIMIT}): #{escape(labels)}</p>"
        end

        def preview_failure(preview)
          "<p class=\"preview error\">Preview: #{escape(preview.error)}.</p>"
        end

        # Deliberately generic -- "ModelName #id" only, never an arbitrary
        # attribute dump, regardless of whether the previewed model happens
        # to be a configured principal source. A discovered candidate may
        # belong to any application model, not only ones a developer has
        # already reviewed for what is safe to display.
        def record_label(record)
          primary_key = record.class.respond_to?(:primary_key) ? record.class.primary_key : "id"
          "#{record.class.name} ##{record.public_send(primary_key)}"
        end

        # -- Snippet -------------------------------------------------------

        def snippet_section(snippet)
          return "" unless snippet

          <<~HTML
            <div class="snippet">
            <h3>Configuration snippet</h3>
            <p><small>Copy this into your own Karst.configure block. Karst does not write to your application's
            files automatically.</small></p>
            <textarea id="karst-snippet-code" readonly>#{escape(snippet.code)}</textarea>
            <p><button type="button" id="karst-copy-snippet">Copy</button></p>
            #{unwired_note(snippet)}
            </div>
          HTML
        end

        def unwired_note(snippet)
          return "" if snippet.unwired.empty?

          names = snippet.unwired.map { |c| "#{c.model_name}.#{c.method_name}" }.join(", ")
          "<p class=\"hint\">#{snippet.unwired.size} selected population(s) are not part of a configured " \
            "principal source yet and were left out of the snippet above: #{escape(names)}.</p>"
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
