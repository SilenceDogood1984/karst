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

  def access_outcome(id:, status:, redirect: nil, exception_class: nil)
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: id, display_label: "User ##{id}")
    Karst::Access::Outcome.new(principal: descriptor, status: status, redirect: redirect,
                               exception_class: exception_class, writes_observed: false, write_count: 0,
                               elapsed_ms: 1.0, database_rollback_attempted: true)
  end

  def access_result(outcomes)
    Karst::Access::Result.new(path: "/documents/22/reader", http_method: "GET", outcomes: outcomes,
                              elapsed_ms: outcomes.size.to_f, aborted_reason: nil,
                              database_isolation: :same_connection_rollback_attempted)
  end

  it "distinguishes missing and invalid catalogs" do
    expect(render(catalog(:missing))).to include(
      "No Karst scenario catalog has been generated yet.", "bundle exec rspec"
    )
    expect(render(catalog(:invalid))).to include(
      "Karst could not read the scenario catalog."
    )
  end

  it "distinguishes a ready catalog with no route coverage" do
    body = render(catalog(:ready), route)

    expect(body).to include("PagesController#index", "No observed specs currently cover this route.")
  end

  it "renders passed anonymous evidence with provenance" do
    observed = scenario(name: "Signed out")
    body = render(catalog(:ready, { %w[PagesController index] => [observed] }), route)

    expect(body).to include("Signed out", "Observed status: <strong>200</strong>", "Principal: Anonymous",
                            "Observed by spec: <code>spec/requests/page_spec.rb:42</code>", "Passed spec")
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

  it "labels rollback as attempted and keeps write evidence inside a response cohort" do
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 1, display_label: "User #1")
    common = { principal: descriptor, status: 200, redirect: nil, exception_class: nil,
               elapsed_ms: 1.0, database_rollback_attempted: true }
    outcomes = [Karst::Access::Outcome.new(**common, writes_observed: false, write_count: 0),
                Karst::Access::Outcome.new(**common, writes_observed: true, write_count: 2)]
    result = Karst::Access::Result.new(path: "/pages", http_method: "GET", outcomes: outcomes,
                                       elapsed_ms: 2.0, aborted_reason: nil,
                                       database_isolation: :same_connection_rollback_attempted)
    body = described_class.render(params: route.merge("method" => "GET", "path" => "/pages"),
                                  access_result: result).last.join

    expect(body).to include("Usable principals — 2")
    expect(body).to include("rollback was attempted", "other connections and non-database effects are not isolated",
                            "2 database writes observed")
  end

  it "promotes all usable principals and collapses other raw outcomes without Test as actions" do
    outcomes = [access_outcome(id: 27, status: 200), access_outcome(id: 28, status: 204),
                access_outcome(id: 1, status: 302, redirect: "/login"),
                access_outcome(id: 2, status: 403), access_outcome(id: 3, status: nil, exception_class: "RuntimeError")]
    Karst.config.assume_browser_identity = ->(*) {}
    Karst.config.clear_browser_identity = ->(*) {}

    body = described_class.render(params: route.merge("method" => "GET", "path" => "/documents/22/reader"),
                                  access_result: access_result(outcomes), csrf_token: "nonce").last.join

    expect(body).to include("Usable principals — 2", "User #27", "Observed 200 OK", "User #28",
                            "Observed 204 No Content", "Other observed outcomes — 3", "302 → /login — 1",
                            "Exception: RuntimeError — 1")
    expect(body.scan("Test as").size).to eq(2)
    expect(body.index("User #27")).to be < body.index("<details>")
  end

  it "describes zero usable sampled principals without overclaiming" do
    body = described_class.render(params: route.merge("method" => "GET", "path" => "/documents/22/reader"),
                                  access_result: access_result([access_outcome(id: 1, status: 401)])).last.join

    expect(body).to include("Usable principals — 0", "No sampled principal produced a usable outcome.",
                            "Other observed outcomes — 1")
    expect(body).not_to include("No user can access this page")
  end

  it "uses the configured usable-outcome presentation policy" do
    Karst.config.usable_access_outcome = ->(outcome) { outcome.status == 302 }
    body = described_class.render(params: route.merge("method" => "GET", "path" => "/documents/22/reader"),
                                  access_result: access_result([access_outcome(id: 1, status: 302)])).last.join

    expect(body).to include("Usable principals — 1", "Observed 302 Found", "Other observed outcomes — 0")
  end

  it "shows exact-resource relationships for usable principals when available" do
    relationship = Karst::Access::ResourceEvidence::Relationship.new(
      column: "user_id", from_model: "Document", from_id: 22, to_model: "User", to_id: 27
    )
    evidence = Karst::Access::ResourceEvidence::Result.new(
      principal: access_outcome(id: 27, status: 200).principal,
      resource: Karst::Access::ResourceEvidence::ResourceDescriptor.new(model_name: "Document", id: 22),
      relationships: [relationship], observed_status: 200, observed_redirect: nil, limitation: nil
    )
    allow(Karst::Access::ResourceEvidence).to receive(:for_outcome).and_return(evidence)

    body = described_class.render(params: route.merge("method" => "GET", "path" => "/documents/22/reader"),
                                  access_result: access_result([access_outcome(id: 27, status: 200)])).last.join

    expect(body).to include("Related state", "Document #22", "user_id → User #27")
  end

  it "keeps usable principals visible when resource evidence is limited" do
    allow(Karst::Access::ResourceEvidence).to receive(:for_outcome).and_raise(StandardError, "unavailable")

    body = described_class.render(params: route.merge("method" => "GET", "path" => "/documents/22/reader"),
                                  access_result: access_result([access_outcome(id: 27, status: 200)])).last.join

    expect(body).to include("Usable principals — 1", "User #27", "Observed 200 OK")
    expect(body).not_to include("Related state")
  end

  it "only renders Test as when browser identity is configured" do
    descriptor = Karst::Identity::PrincipalDescriptor.new(model_name: "User", id: 27, display_label: "User #27")
    outcome = Karst::Access::Outcome.new(principal: descriptor, status: 200, redirect: nil,
                                         exception_class: nil, writes_observed: false, write_count: 0,
                                         elapsed_ms: 1.0, database_rollback_attempted: true)
    result = Karst::Access::Result.new(path: "/documents/22/reader", http_method: "GET", outcomes: [outcome],
                                       elapsed_ms: 1.0, aborted_reason: nil,
                                       database_isolation: :same_connection_rollback_attempted)
    arguments = { params: route.merge("method" => "GET", "path" => result.path),
                  access_result: result, csrf_token: "nonce" }

    expect(described_class.render(**arguments).last.join).not_to include("Test as")
    Karst.config.assume_browser_identity = ->(*) {}
    Karst.config.clear_browser_identity = ->(*) {}
    body = described_class.render(**arguments).last.join
    expect(body).to include("User #27", "Test as", 'value="/documents/22/reader"')
  ensure
    Karst.config.assume_browser_identity = nil
    Karst.config.clear_browser_identity = nil
  end
end
# rubocop:enable Metrics/BlockLength
