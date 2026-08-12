# frozen_string_literal: true

require "spec_helper"
require "karst"
require "karst/web/populations_panel"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Web::PopulationsPanel do
  def group(model_name, candidate_names, principal_source: nil)
    Karst::Access::PopulationDiscovery::ModelGroup.new(
      model_name: model_name, candidate_names: candidate_names, principal_source: principal_source
    )
  end

  def discovery(groups, load_warning: nil)
    Karst::Access::PopulationDiscovery::Result.new(model_groups: groups, load_warning: load_warning)
  end

  def candidate(model_name, method_name, principal_source: nil)
    Karst::Access::PopulationDiscovery::Candidate.new(
      model_name: model_name, method_name: method_name, principal_source: principal_source
    )
  end

  def entry(model_name, method_name)
    Karst::Access::PopulationApprovals::Entry.new(model_name: model_name, method_name: method_name)
  end

  def render(**kwargs)
    described_class.render(**kwargs).last.join
  end

  describe "headers" do
    it "keeps the development-only evidence surface headers, with a nonce-scoped script CSP" do
      status, headers, = described_class.render(discovery: discovery([]))

      expect(status).to eq(200)
      expect(headers).to include("cache-control" => "no-store", "x-robots-tag" => "noindex, nofollow",
                                 "x-frame-options" => "DENY")
      expect(headers["content-security-policy"]).to match(/script-src 'nonce-[0-9a-f]+'/)
      expect(headers["content-security-policy"]).not_to include("script-src 'unsafe-inline'")
    end
  end

  describe "scale: many models" do
    it "renders every model collapsed by default, never as a flat unbounded checkbox dump" do
      groups = Array.new(150) { |i| group("Model#{i}", [:"scope_#{i}_a", :"scope_#{i}_b", :"scope_#{i}_c"]) }

      body = render(discovery: discovery(groups))

      expect(body.scan('<details class="model-group"').size).to eq(150)
      expect(body.scan('<details class="model-group" data-model="Model0" open').size).to eq(0)
      expect(body.scan("3 groups").size).to eq(150)
      expect(body).to include("Model0", "Model149")
    end

    it "opens only the model group(s) that currently have an approved candidate" do
      groups = [group("User", %i[system_admins auditors]), group("Subscription", [:renewable])]

      body = render(discovery: discovery(groups), approved: [entry("User", "system_admins")])

      expect(body).to match(/<details class="model-group" data-model="User" open>/)
      expect(body).not_to match(/<details class="model-group" data-model="Subscription" open>/)
    end

    it "excludes a model with no discovered candidates from the browsable list" do
      groups = [group("Empty", []), group("User", [:system_admins])]

      body = render(discovery: discovery(groups))

      expect(body).not_to include(">Empty<")
    end
  end

  describe "search" do
    it "renders a client-side search input and its filtering script" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include('<input type="search" id="karst-population-search"')
      expect(body).to match(/<script nonce="[0-9a-f]+">/)
      expect(body).to include("Search groups or models")
    end
  end

  describe "approval as the primary workflow" do
    it "explains what approving does without claiming a group grants access" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include("Approving a group lets Karst try a few existing users from it")
      expect(body).to match(/when the ordinary sample\s+fails/)
      expect(body).to include("only running an analysis against a route")
      expect(body).not_to include("authorization", "permission", "admin role")
    end

    it "offers one explicit approve action carrying the checkbox state" do
      body = render(discovery: discovery([group("User", %i[system_admins auditors])]))

      expect(body).to include('<button type="submit" name="save_approvals" value="1" class="primary">' \
                              "Approve selected groups</button>")
      expect(body).to include('<input type="checkbox" name="population[]" value="User::system_admins">')
    end

    it "checks exactly the approved candidates and lists them above the browsable list" do
      groups = [group("User", %i[system_admins auditors])]

      body = render(discovery: discovery(groups), approved: [entry("User", "system_admins")])

      expect(body).to include("Approved (1)")
      expect(body.index("Approved (1)")).to be < body.index("Available models")
      expect(body).to include('<input type="checkbox" name="population[]" value="User::system_admins" checked>')
      expect(body).to include('<input type="checkbox" name="population[]" value="User::auditors">')
    end

    it "reports zero approvals without claiming a group is unusable" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include("Approved (0)", "No groups approved yet.")
    end

    it "confirms a save so approving is visibly durable, and never claims one that did not happen" do
      groups = [group("User", [:system_admins])]

      expect(render(discovery: discovery(groups), saved: true)).to include("Approvals saved.")
      expect(render(discovery: discovery(groups))).not_to include("Approvals saved.")
    end

    it "keeps Preview and the Ruby export on a separate form, so neither can save an approval" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include('<form id="karst-secondary" method="post" action="/karst/populations"></form>')
      expect(body).to include('<button type="submit" form="karst-secondary" name="preview" ' \
                              'value="User::system_admins">Preview</button>')
      expect(body).to include('form="karst-secondary" name="generate_snippet"')
    end

    it "shows a user-source badge only for a model matching a configured source" do
      groups = [group("User", [:system_admins], principal_source: :default), group("Subscription", [:renewable])]

      body = render(discovery: discovery(groups))

      expect(body).to include("user source: default")
      expect(body.scan('class="badge"').size).to eq(1)
    end
  end

  describe "approval storage" do
    it "says where approvals live and how to reset them" do
      body = render(discovery: discovery([]), storage_path: "tmp/karst/approved_populations.json")

      expect(body).to include("tmp/karst/approved_populations.json", "Delete that file to reset every approval",
                              "no user data, no Ruby")
    end

    it "surfaces a rejected approval file instead of silently approving nothing" do
      body = render(discovery: discovery([]), storage_error: "tmp/karst/approved_populations.json is not JSON")

      expect(body).to include('role="alert"', "tmp/karst/approved_populations.json is not JSON")
    end
  end

  describe "stale approvals" do
    it "marks an approval whose scope is no longer discovered as unused, rather than hiding it" do
      stale = [[entry("User", "system_admins"), :not_discovered]]

      body = render(discovery: discovery([group("User", [:auditors])]), approved: [entry("User", "system_admins")],
                    stale: stale)

      expect(body).to include("no longer a discovered scope on this model — not used")
    end

    it "marks an approval on a model that is not a configured user source as unused" do
      stale = [[entry("Subscription", "renewable"), :no_principal_source]]

      body = render(discovery: discovery([group("Subscription", [:renewable])]),
                    approved: [entry("Subscription", "renewable")], stale: stale)

      expect(body).to include("not part of a configured user source — not used")
    end

    it "leaves a live approval unmarked" do
      body = render(discovery: discovery([group("User", [:system_admins])]),
                    approved: [entry("User", "system_admins")], stale: [])

      expect(body).not_to include("not used")
    end
  end

  describe "advanced Ruby export" do
    it "keeps snippet generation available but out of the primary flow" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include("Advanced: export approvals as Ruby")
      expect(body.index("Approve selected groups")).to be < body.index("Advanced: export approvals as Ruby")
      expect(body).not_to include("<textarea")
    end

    it "renders a generated snippet in a readonly textarea with a copy control" do
      snippet = Karst::Access::PopulationConfigSnippet.generate(
        [candidate("User", :system_admins, principal_source: :default)]
      )

      body = render(discovery: discovery([group("User", [:system_admins], principal_source: :default)]),
                    snippet: snippet)

      expect(body).to include("config.principal_populations", 'id="karst-copy-snippet"')
      expect(body).to include('<textarea id="karst-snippet-code" readonly>')
    end

    it "discloses, rather than silently drops, an approval with no matching user source" do
      snippet = Karst::Access::PopulationConfigSnippet.generate([candidate("Subscription", :renewable)])

      body = render(discovery: discovery([group("Subscription", [:renewable])]), snippet: snippet)

      expect(body).to include("not part of a configured user source", "Subscription.renewable")
    end
  end

  describe "discovery limitations" do
    it "discloses the concern limitation and an honest load warning" do
      body = render(discovery: discovery([], load_warning: "The application could not be fully loaded"))

      expect(body).to include("Candidate groups", "The application could not be fully loaded")
    end

    it "escapes hostile model, scope, and warning text instead of rendering it as markup" do
      hostile_scope = :"</label><script>alert(1)</script>"
      hostile_model = "User<script>alert(2)</script>"

      body = render(discovery: discovery([group(hostile_model, [hostile_scope])],
                                         load_warning: "<script>alert(3)</script>"),
                    approved: [entry(hostile_model, hostile_scope.to_s)])

      expect(body).not_to include("<script>alert(1)</script>", "<script>alert(2)</script>",
                                  "<script>alert(3)</script>")
      expect(body).to include(CGI.escapeHTML(hostile_scope.to_s), CGI.escapeHTML(hostile_model))
    end
  end
end
# rubocop:enable Metrics/BlockLength
