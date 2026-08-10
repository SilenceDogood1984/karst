# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/panel"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::Panel do
  let(:catalog_state_class) do
    Data.define(:status, :matches) do
      def scenarios_for(controller:, action:, http_method: nil)
        matches.fetch([controller, action], []).select do |scenario|
          http_method.nil? || scenario.http_method == http_method
        end
      end
    end
  end

  # rubocop:disable Metrics/ParameterLists
  def scenario(name:, outcome: :passed, explicit: false, principal: nil, redirect: nil, status: 200,
               file_path: "spec/requests/page_spec.rb")
    Karst::Spec::Scenario.new(
      example_id: "example", file_path: file_path, line_number: 42, description_parts: [name],
      full_description: name, karst_explicit: explicit, karst_name: explicit ? name : nil,
      example_outcome: outcome, controller: "PagesController", action: "index", http_method: "GET",
      route_pattern: "/pages", observed_path: "/pages", observed_status: status,
      observed_redirect: redirect, principal_before: principal, principal_after: principal,
      principal_changed: false, sequence: 0
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def catalog(status, matches = {})
    catalog_state_class.new(status: status, matches: matches)
  end

  def render(catalog, params = {})
    allow(Karst::Spec::Catalog).to receive(:load).and_return(catalog)
    described_class.render(params: params).last.join
  end

  let(:route) { { "controller" => "PagesController", "action" => "index" } }
  let(:analyzed_route) { route.merge("method" => "GET", "path" => "/documents/22/reader") }

  def access_outcome(id:, status:, redirect: nil, exception_class: nil)
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: "User ##{id}")
    Karst::Access::Outcome.new(principal: descriptor, status: status, redirect: redirect,
                               exception_class: exception_class, writes_observed: false, write_count: 0,
                               elapsed_ms: 1.0, database_rollback_attempted: true)
  end

  def access_result(outcomes, candidate_pool_size: nil)
    Karst::Access::Result.new(path: "/documents/22/reader", http_method: "GET", outcomes: outcomes,
                              elapsed_ms: outcomes.size.to_f, aborted_reason: nil,
                              database_isolation: :same_connection_rollback_attempted,
                              candidate_pool_size: candidate_pool_size)
  end

  def enable_browser_identity!
    Karst.config.assume_browser_identity = ->(*) {}
    Karst.config.clear_browser_identity = ->(*) {}
  end

  after do
    Karst.config.assume_browser_identity = nil
    Karst.config.clear_browser_identity = nil
  end

  describe "security headers" do
    it "keeps the existing development-only evidence surface headers" do
      status, headers, = described_class.render

      expect(status).to eq(200)
      expect(headers).to include(
        "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
        "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY",
        "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
      )
    end
  end

  describe "route header" do
    it "shows a compact route identity with method, path, controller, and action" do
      body = render(catalog(:ready), route.merge("method" => "GET", "path" => "/documents/22/reader"))

      expect(body).to include(
        "<p class=\"route-path\">GET /documents/22/reader</p>",
        "<p class=\"route-controller\">PagesController#index</p>"
      )
    end

    it "omits the path line when no host request path is known" do
      body = render(catalog(:ready), route)

      expect(body).to include("PagesController#index")
      expect(body).not_to include('<p class="route-path">')
    end

    it "shows a coherent empty state and an open route lookup when nothing is selected" do
      body = render(catalog(:ready))

      expect(body).to include("No route selected yet.", "Look up a route", '<details class="route-lookup" open>',
                              'name="path"', 'name="method"', 'value="GET"',
                              'name="controller"', 'name="action"')
    end

    it "collapses the route lookup once a route is already known" do
      body = render(catalog(:ready), route)

      expect(body).to include("Look up a different route")
      expect(body).not_to include('<details class="route-lookup" open>')
    end
  end

  describe "primary analyze action" do
    it "renders Analyze as the obvious primary action with the sample count visible" do
      Karst.config.principals = -> { [] }
      body = render(catalog(:ready), analyzed_route)

      expect(body).to include('<button class="primary" type="submit">Analyze 25 principals</button>')
    ensure
      Karst.config.principals = nil
    end

    it "notes when no principal source is configured, without dominating the page" do
      body = render(catalog(:ready), analyzed_route)

      expect(body).to include("No principal source is configured")
    end

    it "does not offer access analysis for non-GET routes" do
      body = render(catalog(:ready), route.merge("method" => "POST", "path" => "/documents/22"))

      expect(body).to include("Access analysis is available for GET routes only.")
      expect(body).not_to include("Analyze 25")
    end

    it "omits the access section entirely when no host path is known" do
      body = render(catalog(:ready), route)

      expect(body).not_to include("Analyze 25", "Access analysis is available for GET routes only.")
    end
  end

  describe "usable result hierarchy" do
    it "promotes usable principals above collapsed other outcomes" do
      outcomes = [access_outcome(id: 27, status: 200), access_outcome(id: 28, status: 204),
                  access_outcome(id: 1, status: 302, redirect: "/login"), access_outcome(id: 2, status: 403),
                  access_outcome(id: 3, status: nil, exception_class: "RuntimeError")]
      enable_browser_identity!

      body = described_class.render(params: analyzed_route, access_result: access_result(outcomes),
                                    csrf_token: "nonce").last.join

      expect(body).to include("<h2>Usable principals — 2</h2>", "User #27", "Observed 200 OK", "User #28",
                              "Observed 204 No Content", "Other observed outcomes — 3", "302 → /login — 1",
                              "Exception: RuntimeError — 1")
      expect(body.scan('<button type="submit">Test as</button>').size).to eq(2)
      expect(body.index("User #27")).to be < body.index("<details>")
    end

    it "describes zero usable sampled principals without overclaiming" do
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 401)])).last.join

      expect(body).to include("<h2>Usable principals — 0</h2>", "No sampled principal produced a usable outcome.",
                              "Other observed outcomes — 1")
      expect(body).not_to include("No user can access this page")
    end

    it "uses the configured usable-outcome presentation policy rather than reinventing it" do
      Karst.config.usable_access_outcome = ->(outcome) { outcome.status == 302 }
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 302)])).last.join

      expect(body).to include("<h2>Usable principals — 1</h2>", "Observed 302 Found", "Other observed outcomes — 0")
    ensure
      Karst.config.usable_access_outcome = ->(outcome) { outcome.status && (200..299).cover?(outcome.status) }
    end

    it "reports a sweep exception without overclaiming" do
      error = Karst::Access::Unavailable.new("probe endpoint unavailable")
      body = described_class.render(params: analyzed_route, access_result: error).last.join

      expect(body).to include("Analysis unavailable: probe endpoint unavailable")
      expect(body).not_to include("Usable principals")
    end

    it "shows exact-resource relationships for usable principals compactly, in non-causal language" do
      relationship = Karst::Access::ResourceEvidence::Relationship.new(
        column: "user_id", from_model: "Document", from_id: 22, to_model: "User", to_id: 27
      )
      evidence = Karst::Access::ResourceEvidence::Result.new(
        principal: access_outcome(id: 27, status: 200).principal,
        resource: Karst::Access::ResourceEvidence::ResourceDescriptor.new(model_name: "Document", id: 22),
        relationships: [relationship], observed_status: 200, observed_redirect: nil, limitation: nil
      )
      allow(Karst::Access::ResourceEvidence).to receive(:for_outcome).and_return(evidence)

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)])).last.join

      expect(body).to include("Related state", "Document #22", "user_id → User #27")
      expect(body).not_to include("owns", "authorized", "grants", "permitted because", "access rule")
    end

    it "keeps usable principals visible when resource evidence is limited, without a Related state block" do
      allow(Karst::Access::ResourceEvidence).to receive(:for_outcome).and_raise(StandardError, "unavailable")

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)])).last.join

      expect(body).to include("<h2>Usable principals — 1</h2>", "User #27", "Observed 200 OK")
      expect(body).not_to include("Related state")
    end
  end

  describe "candidate pool disclosure" do
    it "truthfully reports a bounded candidate pool without implying the full universe was searched" do
      body = described_class.render(
        params: analyzed_route,
        access_result: access_result([access_outcome(id: 27, status: 200)], candidate_pool_size: 1_000)
      ).last.join

      expect(body).to include("1 principals tested", "candidate pool: up to 1,000 most recent principals")
    end

    it "omits the candidate pool line when the result carries no pool (e.g. an Enumerable source)" do
      body = described_class.render(
        params: analyzed_route, access_result: access_result([access_outcome(id: 27, status: 200)])
      ).last.join

      expect(body).to include("1 principals tested")
      expect(body).not_to include("candidate pool")
    end
  end

  describe "Test as / Stop testing as" do
    it "only renders Test as when browser identity hooks are configured" do
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)]),
                                    csrf_token: "nonce").last.join

      expect(body).not_to include("<button type=\"submit\">Test as</button>")
      expect(body).to include("Browser Test as is not configured")
    end

    it "renders Test as for a usable principal once configured" do
      enable_browser_identity!
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)]),
                                    csrf_token: "nonce").last.join

      expect(body).to include("User #27", '<button type="submit">Test as</button>', 'value="/documents/22/reader"')
      expect(body).not_to include("Browser Test as is not configured")
    end

    it "requires a csrf token before rendering Test as" do
      enable_browser_identity!
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)])).last.join

      expect(body).not_to include("<button type=\"submit\">Test as</button>")
    end

    it "shows a clear banner and Stop testing as while a browser identity is assumed" do
      enable_browser_identity!
      body = described_class.render(params: { "path" => "/documents/22/reader" }, csrf_token: "nonce",
                                    browser_identity_active: true).last.join

      expect(body).to include("Currently testing as an assumed browser identity.",
                              '<button type="submit">Stop testing as</button>',
                              "Karst does not restore a previous session.")
      expect(body).not_to include("restores your previous session", "restore your previous user")
    end

    it "does not render the banner when no browser identity is active" do
      enable_browser_identity!
      body = described_class.render(params: { "path" => "/documents/22/reader" }, csrf_token: "nonce",
                                    browser_identity_active: false).last.join

      expect(body).not_to include("Stop testing as")
    end
  end

  describe "diagnostics: spec evidence (collapsed)" do
    it "distinguishes missing and invalid catalogs once a route is selected" do
      expect(render(catalog(:missing), route)).to include(
        "Spec evidence — not yet generated", "No Karst scenario catalog has been generated yet.", "bundle exec rspec"
      )
      expect(render(catalog(:invalid), route)).to include(
        "Spec evidence — unavailable", "Karst could not read the scenario catalog."
      )
    end

    it "omits spec evidence entirely when no route is selected" do
      body = render(catalog(:missing))

      expect(body).not_to include("Spec evidence")
    end

    it "distinguishes a ready catalog with no route coverage" do
      body = render(catalog(:ready), route)

      expect(body).to include("PagesController#index", "Spec evidence — 0 matching scenarios",
                              "No observed specs currently cover this route.")
    end

    it "renders passed anonymous evidence with provenance inside a collapsed details block" do
      observed = scenario(name: "Signed out")
      body = render(catalog(:ready, { %w[PagesController index] => [observed] }), route)

      expect(body).to include("<details class=\"diagnostic\"><summary>Spec evidence — 1 matching scenario</summary>")
      expect(body).to include("Signed out", "Observed status: <strong>200</strong>", "Principal: Anonymous",
                              "Observed by spec: <code>spec/requests/page_spec.rb:42</code>", "Passed spec")
      expect(body).to include("does not prove current runtime authorization")
    end

    it "groups explicit and discovered scenarios in catalog order" do
      principal = Karst::Spec::Principal.new(type: "Author", id: 123, scope: "user")
      explicit = scenario(name: "Author with profile", explicit: true, principal: principal)
      discovered = scenario(name: "redirects a reader", redirect: "/sign-in", status: 302)
      body = render(catalog(:ready, { %w[PagesController index] => [explicit, discovered] }), route)

      expect(body).to include("Explicit QA scenarios", "Discovered scenarios", "Principal: Author",
                              "Observed redirect: <strong>/sign-in</strong>")
      expect(body).not_to include("123")
      expect(body.index("Author with profile")).to be < body.index("redirects a reader")
    end

    it "clearly marks failed and pending observations as untrusted" do
      scenarios = [scenario(name: "broken", outcome: :failed, status: 500),
                   scenario(name: "later", outcome: :pending)]
      body = render(catalog(:ready, { %w[PagesController index] => scenarios }), route)

      expect(body).to include("Failed spec — observed behavior is not trusted QA evidence",
                              "Pending spec — observed behavior is not trusted QA evidence")
    end
  end

  describe "diagnostics: runtime SQL (collapsed)" do
    it "demotes the summary under Diagnostics, collapsed by default when capture is enabled" do
      allow(Karst).to receive_messages(enabled?: true, subscribed?: true)
      body = render(catalog(:ready))

      expect(body).to include("<h2>Diagnostics</h2>")
      expect(body).to match(
        %r{<details class="diagnostic"><summary>Runtime SQL — \d+ observations · \d+ shapes</summary>}
      )
    end

    it "surfaces a disabled capture state instead of a silently collapsed section" do
      allow(Karst).to receive_messages(enabled?: false, subscribed?: false)
      body = render(catalog(:ready))

      expect(body).to include("capture disabled")
      expect(body).to match(/<details class="diagnostic" open><summary>Runtime SQL[^<]*capture disabled/)
    end
  end

  describe "escaping" do
    it "escapes hostile route, scenario, principal, redirect, and provenance strings" do
      hostile = '<script data-x="1">bad</script>'
      principal = Karst::Spec::Principal.new(type: hostile, id: 1, scope: nil)
      observed = scenario(name: hostile, principal: principal, redirect: hostile, file_path: hostile)
      params = { "controller" => hostile, "action" => "index" }
      state = catalog(:ready, { [hostile, "index"] => [observed] })
      body = render(state, params)

      expect(body).not_to include(hostile)
      expect(body.scan(CGI.escapeHTML(hostile)).size).to be >= 5
    end

    it "escapes a hostile display label on a usable principal" do
      hostile = "<script>alert(1)</script>"
      descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 1, display_label: hostile)
      outcome = Karst::Access::Outcome.new(principal: descriptor, status: 200, redirect: nil, exception_class: nil,
                                           writes_observed: false, write_count: 0, elapsed_ms: 1.0,
                                           database_rollback_attempted: true)
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).not_to include(hostile)
      expect(body).to include(CGI.escapeHTML(hostile))
    end
  end
end
# rubocop:enable Metrics/BlockLength
