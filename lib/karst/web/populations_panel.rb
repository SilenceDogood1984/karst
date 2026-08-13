# frozen_string_literal: true

require "cgi"

module Karst
  module Web
    # Advanced, local-only management for approvals already granted from the
    # contextual /karst workflow. New approvals deliberately cannot be made
    # here: this surface exists only so persistent state can be inspected and
    # safely revoked, including after its model or scope becomes stale.
    module PopulationsPanel
      STALE_REASONS = {
        not_discovered: "no longer a discovered scope on this model — not used",
        no_principal_source: "not part of a configured user source — not used"
      }.freeze
      private_constant :STALE_REASONS

      STYLE = <<~CSS
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;max-width:42rem;margin:2rem auto;padding:0 1.25rem;color:#1a1a1a;background:#fff}
        h1{font-size:1.4rem;margin:0 0 1rem} h2{font-size:1.1rem;margin:1.5rem 0 .5rem}
        a{color:#2563eb} .lead,small{color:#666} ul{list-style:none;padding:0}
        li{display:flex;justify-content:space-between;align-items:center;gap:1rem;border-top:1px solid #ddd;padding:.75rem 0}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
        .stale{color:#8a5b00;font-size:.85rem;display:block}
        .warning{color:#8a5b00;font-size:.85rem;border:1px solid #eacb6b;background:#fff7e0;border-radius:.4rem;padding:.6rem .8rem}
        .saved{color:#0f5132;font-size:.9rem;border:1px solid #a6d9bb;background:#e6f4ea;border-radius:.4rem;padding:.6rem .8rem}
        button{font:inherit;padding:.35rem .65rem;border:1px solid #b3261e;border-radius:.35rem;background:transparent;color:#b3261e;cursor:pointer}
        button:focus-visible,a:focus-visible{outline:2px solid #2563eb;outline-offset:2px}
        @media (prefers-color-scheme:dark){body{background:#16171a;color:#e4e4e6}.lead,small{color:#a7a7ad}li{border-color:#33343a}.stale,.warning{color:#d8a63d}.warning{background:#3a2f0d;border-color:#6b5423}.saved{background:#123822;border-color:#1f5c37;color:#7fd8a4}button{color:#ff817a;border-color:#ff817a}}
      CSS
      private_constant :STYLE

      class << self
        def render(approved: [], stale: [], storage_path: nil, storage_error: nil, revoked: false)
          [200, headers, [document(approved, stale, storage_path, storage_error, revoked)]]
        end

        private

        def headers
          {
            "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
            "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY",
            "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
          }
        end

        def document(approved, stale, storage_path, storage_error, revoked)
          <<~HTML
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Karst — Manage approvals</title>
            <style>#{STYLE}</style></head><body><h1>Karst</h1>
            <p><a href="/karst">&larr; Back to route evidence</a></p>
            <h2>Manage population approvals</h2>
            <p class="lead">Advanced local-state management. Approve new candidate populations only when a failed route analysis offers them on <code>/karst</code>.</p>
            #{notice(revoked)}#{storage_error_message(storage_error)}#{approval_list(approved, stale)}
            #{storage_note(storage_path)}</body></html>
          HTML
        end

        def approval_list(approved, stale)
          return "<p>No population approvals are stored.</p>" if approved.empty?

          items = approved.map { |entry| approval_item(entry, stale) }.join
          "<ul>#{items}</ul>"
        end

        def approval_item(entry, stale)
          match = stale.find { |item, _reason| item.matches?(entry.model_name, entry.method_name) }
          note = match ? "<span class=\"stale\">#{escape(STALE_REASONS.fetch(match.last, 'not used'))}</span>" : ""
          <<~HTML
            <li><span><code>#{escape(entry.display_label)}</code>#{note}</span>
            <form method="post" action="/karst/populations"><input type="hidden" name="operation" value="revoke_population">
            <input type="hidden" name="population" value="#{escape(entry.model_name)}::#{escape(entry.method_name)}">
            <button type="submit">Revoke</button></form></li>
          HTML
        end

        def notice(revoked)
          revoked ? '<p class="saved" role="status">Approval revoked.</p>' : ""
        end

        def storage_error_message(error)
          error ? "<p class=\"warning\" role=\"alert\">#{escape(error)}</p>" : ""
        end

        def storage_note(path)
          return "" unless path

          "<p><small>Approvals are stored locally in <code>#{escape(path)}</code> " \
            "as model and scope names only.</small></p>"
        end

        def escape(value)
          CGI.escapeHTML(value.to_s)
        end
      end
    end
  end
end
