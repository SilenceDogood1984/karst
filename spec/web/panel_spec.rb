# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/panel"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::Panel do
  def render(params = {})
    described_class.render(params: params).last.join
  end

  let(:route) { { "controller" => "PagesController", "action" => "index" } }
  let(:analyzed_route) { route.merge("method" => "GET", "path" => "/documents/22/reader") }

  # rubocop:disable Metrics/ParameterLists
  def access_outcome(id:, status:, redirect: nil, exception_class: nil, sampling_reasons: nil, halted_callback: nil,
                     writes_observed: false, write_count: 0, label: nil)
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: "User ##{id}")
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: label) if label
    Karst::Access::Outcome.new(principal: descriptor, status: status, redirect: redirect,
                               exception_class: exception_class, writes_observed: writes_observed,
                               write_count: write_count,
                               elapsed_ms: 1.0, database_rollback_attempted: true,
                               sampling_reasons: sampling_reasons, halted_callback: halted_callback)
  end
  # rubocop:enable Metrics/ParameterLists

  def sweep_result(outcomes, candidate_pool_size: nil)
    Karst::Access::Result.new(path: "/documents/22/reader", http_method: "GET", outcomes: outcomes,
                              elapsed_ms: outcomes.size.to_f, aborted_reason: nil,
                              database_isolation: :same_connection_rollback_attempted,
                              candidate_pool_size: candidate_pool_size)
  end

  # The panel renders one access shape: Karst::Access::Search::Result. A
  # plain sweep with no population retries is simply that shape with an
  # empty attempts list.
  def access_result(outcomes, candidate_pool_size: nil, attempts: [])
    Karst::Access::Search::Result.new(initial: sweep_result(outcomes, candidate_pool_size: candidate_pool_size),
                                      attempts: attempts)
  end

  def attempt(name, state, outcomes: nil, error: nil)
    Karst::Access::Search::PopulationAttempt.new(
      name: name, source_name: :default, state: state, error: error,
      result: outcomes && sweep_result(outcomes)
    )
  end

  def enable_browser_identity!
    Karst.config.assume_browser_identity = ->(*) {}
    Karst.config.clear_browser_identity = ->(*) {}
  end

  def discovered_candidate
    Karst::Access::PopulationDiscovery::Candidate.new(model_name: "User", method_name: :system_admins,
                                                      principal_source: :default)
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
        "x-robots-tag" => "noindex, nofollow", "x-frame-options" => "DENY"
      )
      expect(headers["content-security-policy"]).to include("default-src 'none'", "style-src 'unsafe-inline'",
                                                            "script-src 'sha256-", "connect-src 'self'",
                                                            "frame-ancestors 'none'")
    end
  end

  describe "route header" do
    it "shows the HTTP method and URL without controller/action terminology" do
      body = render(route.merge("method" => "GET", "path" => "/documents/22/reader"))

      expect(body).to include("<p class=\"route-path\">GET /documents/22/reader</p>")
      expect(body).not_to include("PagesController#index", "<label>Controller", "<label>Action")
    end

    it "omits the path line when no host request path is known" do
      body = render(route)

      expect(body).to include("No URL selected yet.")
      expect(body).not_to include('<p class="route-path">', "PagesController#index")
    end

    it "shows a coherent empty state and an open route lookup when nothing is selected" do
      body = render

      expect(body).to include("No URL selected yet.", "What URL are you trying to test?",
                              '<details class="route-lookup" open>', 'name="path"', 'name="method"',
                              'value="GET"')
      expect(body).not_to include("Controller", "Action")
    end

    it "collapses the route lookup once a route is already known" do
      body = render(analyzed_route)

      expect(body).to include("Test a different URL")
      expect(body).not_to include('<details class="route-lookup" open>')
    end
  end

  describe "primary analyze action" do
    it "renders Analyze as the obvious primary action with the sample count visible" do
      Karst.config.principals = -> { [] }
      body = render(analyzed_route)

      expect(body).to include('<button class="primary" type="submit">Who can use this? (test 25 users)</button>')
    ensure
      Karst.config.principals = nil
    end

    it "notes when no user source is configured, without dominating the page" do
      body = render(analyzed_route)

      expect(body).to include("Karst couldn't determine how this app authenticates users")
      expect(body).to include("Set up custom authentication")
      expect(body).not_to include("No principal source")
    end

    it "keeps sampler implementation details out of the primary action" do
      Karst.config.principals = -> { [] }

      body = render(analyzed_route)

      expect(body).to include("Who can use this? (test 25 users)")
      expect(body).not_to include("representative users")
    ensure
      Karst.config.principals = nil
    end

    it "does not offer access analysis for non-GET routes" do
      body = render(route.merge("method" => "POST", "path" => "/documents/22"))

      expect(body).to include("Access analysis is available for GET routes only.")
      expect(body).not_to include("Who can use this page?")
    end

    it "omits the access section entirely when no host path is known" do
      body = render(route)

      expect(body).not_to include("Who can use this page?", "Access analysis is available for GET routes only.")
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

      expect(body).to include("<h2>Verified usable user</h2>", "User #27", "Observed 200 OK", "User #28",
                              "204 No Content", "302 → /login — 1",
                              "Exception: RuntimeError — 1")
      expect(body.scan('<button type="submit">Test as</button>').size).to eq(1)
      expect(body.index("User #27")).to be < body.index("<details>")
    end

    it "describes zero usable sampled principals without overclaiming" do
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 401)])).last.join

      expect(body).to include("<h2>No verified usable user found</h2>", "No verified usable user found",
                              "Ordinary sample")
      expect(body).not_to include("No user can access this page")
    end

    it "offers candidate approval inline only when the analysis found nothing usable" do
      body = described_class.render(params: analyzed_route, unapproved_candidates: [discovered_candidate],
                                    csrf_token: "token",
                                    access_result: access_result([access_outcome(id: 1, status: 401)])).last.join

      expect(body).to include("Karst found application-defined user groups in your app",
                              "system_admins", "Approve selected and retry")
      expect(body).not_to include('href="/karst/populations"')
    end

    it "keeps candidate groups out of the page once a usable user was found" do
      body = described_class.render(params: analyzed_route, unapproved_candidates: [discovered_candidate],
                                    csrf_token: "token",
                                    access_result: access_result([access_outcome(id: 1, status: 200)])).last.join

      expect(body).not_to include("/karst/populations", "could be tried")
    end

    it "says nothing about candidate groups when there are none left to approve" do
      body = described_class.render(params: analyzed_route, unapproved_candidates: [], csrf_token: "token",
                                    access_result: access_result([access_outcome(id: 1, status: 401)])).last.join

      expect(body).not_to include("/karst/populations")
    end

    it "renders halted callbacks observationally and keeps otherwise identical groups separate" do
      outcomes = [access_outcome(id: 1, status: 302, redirect: "/login", halted_callback: :require_subscription),
                  access_outcome(id: 2, status: 302, redirect: "/login", halted_callback: :require_admin)]
      body = described_class.render(params: analyzed_route, access_result: access_result(outcomes)).last.join

      expect(body.scan(%r{302 → /login · halted at (?:require_subscription|require_admin) — 1}).size).to eq(2)
      expect(body).to include("Halted callback: require_subscription", "Halted callback: require_admin")
      expect(body).not_to include("Redirected because", "callback failed")
    end

    it "keeps a halted 2xx response as non-usable observed evidence" do
      outcome = access_outcome(id: 123, status: 204, halted_callback: :redirect_if_suspended)
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).to include("No verified usable user found", "204 No Content",
                              "Halted callback: redirect_if_suspended", "Not verified as usable")
      expect(body).not_to include("suspended user", "caused the 404", "204 became 404")
    end

    it "uses the configured usable-outcome presentation policy rather than reinventing it" do
      Karst.config.usable_access_outcome = ->(outcome) { outcome.status == 302 }
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 302)])).last.join

      expect(body).to include("<h2>Verified usable user</h2>", "Observed 302 Found")
    ensure
      Karst.config.usable_access_outcome = lambda do |outcome|
        outcome.status == 200 && outcome.exception_class.nil? && outcome.halted_callback.nil?
      end
    end

    it "reports a sweep exception without overclaiming" do
      error = Karst::Access::Unavailable.new("probe endpoint unavailable")
      body = described_class.render(params: analyzed_route, access_result: error).last.join

      expect(body).to include("Analysis unavailable: probe endpoint unavailable")
      expect(body).not_to include("Users who can use this URL")
    end
  end

  describe "automatic candidate population retries" do
    it "reports the verified user a population produced, alongside what the sample observed" do
      sample = [access_outcome(id: 1, status: 403, halted_callback: :authorize_admin)]
      hit = [access_outcome(id: 27, status: 200, sampling_reasons: ["population=system_admins"])]
      attempts = [attempt(:system_admins, :usable, outcomes: hit), attempt(:auditors, :skipped)]

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result(sample, attempts: attempts)).last.join

      expect(body).to include("Candidate populations", "system_admins", "User #27 → 200 OK ✓",
                              "<h2>Verified usable user</h2>")
      expect(body).to include("Ordinary sample", "No verified usable user", "halted at authorize_admin")
      expect(body).to include("auditors", "not tried — a usable user was already found")
    end

    it "reports every population honestly when none of them produced a usable user" do
      sample = [access_outcome(id: 1, status: 403, halted_callback: :authorize_admin)]
      missed = [access_outcome(id: 5, status: 302, redirect: "/login", halted_callback: :authorize_admin)]
      attempts = [attempt(:system_admins, :no_match, outcomes: missed), attempt(:auditors, :empty),
                  attempt(:responders, :unresolved, error: "did not resolve to a usable relation"),
                  attempt(:legacy, :already_tried), attempt(:late, :budget_exhausted)]

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result(sample, attempts: attempts)).last.join

      expect(body).to include("1 user tested<br>none verified usable", "halted at authorize_admin")
      expect(body).to include("no matching records")
      expect(body).to include("could not be resolved (did not resolve to a usable relation)")
      expect(body).to include("every candidate was already tested above")
      expect(body).to include("not tried — the retry request budget was reached")
      expect(body).to include("<h2>No verified usable user found</h2>")
    end

    it "counts population requests in the analysis meta without implying they were sampled" do
      sample = [access_outcome(id: 1, status: 403)]
      hit = [access_outcome(id: 27, status: 200)]
      attempts = [attempt(:system_admins, :usable, outcomes: hit)]

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result(sample, attempts: attempts)).last.join

      expect(body).to include("1 initial · 1 candidate population · 2 total users/requests")
    end

    it "omits the populations section entirely when none is configured" do
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 403)])).last.join

      expect(body).not_to include("Candidate populations")
    end

    it "never claims a population caused or explains any observed outcome" do
      sample = [access_outcome(id: 1, status: 403, halted_callback: :authorize_admin)]
      hit = [access_outcome(id: 27, status: 200)]
      attempts = [attempt(:system_admins, :usable, outcomes: hit)]

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result(sample, attempts: attempts)).last.join

      expect(body).not_to include("grants access", "will pass", "because", "guaranteed", "is authorized")
    end

    it "escapes hostile population names and errors rather than rendering them as markup" do
      attempts = [attempt(:"<script>x</script>", :unresolved, error: "<img src=x>")]

      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 1, status: 403)],
                                                                 attempts: attempts)).last.join

      expect(body).to include("&lt;script&gt;x&lt;/script&gt;", "&lt;img src=x&gt;")
      expect(body).not_to include("<script>x</script>")
    end
  end

  describe "candidate pool disclosure" do
    it "truthfully reports a bounded candidate pool without implying the full universe was searched" do
      body = described_class.render(
        params: analyzed_route,
        access_result: access_result([access_outcome(id: 27, status: 200)], candidate_pool_size: 1_000)
      ).last.join

      expect(body).to include("1 user tested", "from up to 1,000 recent users")
    end

    it "omits the candidate pool line when the result carries no pool (e.g. an Enumerable source)" do
      body = described_class.render(
        params: analyzed_route, access_result: access_result([access_outcome(id: 27, status: 200)])
      ).last.join

      expect(body).to include("1 user tested")
      expect(body).not_to include("candidate pool")
    end
  end

  describe "one-run evidence" do
    it "groups repeats while preserving exact user identities in expandable details" do
      outcomes = [1, 7, 18].map do |id|
        access_outcome(id: id, status: 302, redirect: "/login", halted_callback: :authenticate_user)
      end

      body = described_class.render(params: analyzed_route, access_result: access_result(outcomes)).last.join

      expect(body).to include("<details><summary>302 → /login · halted at authenticate_user — 3</summary>",
                              "User #1", "User #7", "User #18")
      expect(body.scan("302 → /login").size).to eq(1)
    end

    it "makes writes prominent and states the rollback boundary" do
      outcome = access_outcome(id: 1, status: 403, writes_observed: true, write_count: 2)

      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).to include("write-warning", "⚠ Database writes observed during 1 probe.",
                              "Rollback was attempted on the same Active Record connection.",
                              "Jobs, mail, external HTTP, files, Redis, and other database connections")
      expect(body).not_to include("No side effects occurred")
    end

    it "escapes every observed string in grouped evidence" do
      outcome = access_outcome(id: 1, status: 302, redirect: "<redirect>", halted_callback: "<callback>",
                               label: "<baddies>")

      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).to include("&lt;redirect&gt;", "&lt;callback&gt;", "&lt;baddies&gt;")
      expect(body).not_to include("<redirect>", "<callback>", "<baddies>")
    end
  end

  describe "sampling evidence ('Sampled for')" do
    it "shows a compact line under a usable principal when sampling reasons are available" do
      outcome = access_outcome(id: 27, status: 200, sampling_reasons: ["role=local_admin", "premium=true"])
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).to include("Sampled for: role=local_admin · premium=true")
      expect(body.index("Observed 200 OK")).to be < body.index("Sampled for:")
    end

    it "omits the line entirely when no sampling reasons are available" do
      outcome = access_outcome(id: 27, status: 200, sampling_reasons: [])
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).not_to include("Sampled for:")
    end

    it "omits the line when the outcome carries no sampling_reasons at all (nil)" do
      outcome = access_outcome(id: 27, status: 200, sampling_reasons: nil)
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).not_to include("Sampled for:")
    end

    it "escapes sampling reason text rather than rendering it as markup" do
      hostile = "<script>alert(1)</script>"
      outcome = access_outcome(id: 27, status: 200, sampling_reasons: [hostile])
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).not_to include(hostile)
      expect(body).to include(CGI.escapeHTML(hostile))
    end

    it "does not render sampling evidence for collapsed non-usable outcomes" do
      outcome = access_outcome(id: 27, status: 401, sampling_reasons: ["role=local_admin"])
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).not_to include("Sampled for:")
    end
  end

  describe "Test as / Stop testing as" do
    it "only renders Test as when browser identity hooks are configured" do
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)]),
                                    csrf_token: "nonce").last.join

      expect(body).not_to include("<button type=\"submit\">Test as</button>")
      expect(body).to include("Karst couldn't determine how this app authenticates users")
      expect(body).to include("Set up custom authentication")
    end

    it "renders Test as for a usable principal once configured" do
      enable_browser_identity!
      body = described_class.render(params: analyzed_route,
                                    access_result: access_result([access_outcome(id: 27, status: 200)]),
                                    csrf_token: "nonce").last.join

      expect(body).to include("User #27", '<button type="submit">Test as</button>', 'value="/documents/22/reader"')
      expect(body).to include("fetch(form.action", 'headers: { "Accept": "application/json" }',
                              "window.location.assign(result.location)")
      expect(described_class.render[1]["content-security-policy"]).to include("script-src 'sha256-",
                                                                              "connect-src 'self'")
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

      expect(body).to include("Currently testing as an assumed user.",
                              '<button type="submit">Stop testing as</button>',
                              "Stopping signs this browser out; Karst does not restore your previous session.")
      expect(body).not_to include("restores your previous session", "restore your previous user")
    end

    it "does not render the banner when no browser identity is active" do
      enable_browser_identity!
      body = described_class.render(params: { "path" => "/documents/22/reader" }, csrf_token: "nonce",
                                    browser_identity_active: false).last.join

      expect(body).not_to include("Stop testing as")
    end
  end

  describe "legacy diagnostics" do
    it "does not render diagnostics, runtime SQL, or controller/action controls" do
      body = render(analyzed_route)

      expect(body).not_to include("Diagnostics", "Runtime SQL",
                                  "Controller/action diagnostics", "<label>Controller", "<label>Action")
    end
  end

  describe "escaping" do
    it "escapes a hostile URL" do
      hostile = '/documents/<script data-x="1">bad</script>'
      body = described_class.render(params: { "method" => "GET", "path" => hostile }).last.join

      expect(body).not_to include(hostile)
      expect(body).to include(CGI.escapeHTML(hostile))
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

    it "links a Devise-declared email while escaping its value" do
      email = 'person+\"quoted\"@example.com'
      descriptor = Karst::Identity::PrincipalDescriptor.new(
        model_name: "User", id: 27, display_label: "#{email} · User #27",
        authentication_key: :email, authentication_identifier: email
      )
      outcome = Karst::Access::Outcome.new(principal: descriptor, status: 200, redirect: nil,
                                           exception_class: nil, writes_observed: false, write_count: 0,
                                           elapsed_ms: 1.0, database_rollback_attempted: true)
      body = described_class.render(params: analyzed_route, access_result: access_result([outcome])).last.join

      expect(body).to include("<a href=\"mailto:#{CGI.escapeHTML(email)}\">#{CGI.escapeHTML(email)}</a> · User #27")
      expect(body).not_to include("mailto:#{email}")
    end
  end
end
# rubocop:enable Metrics/BlockLength
