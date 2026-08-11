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
      expect(body.scan("3 candidates").size).to eq(150)
      expect(body).to include("Model0", "Model149")
    end

    it "opens only the model group(s) that currently have a selected candidate" do
      groups = [group("User", %i[system_admins auditors]), group("Subscription", [:renewable])]
      selected = [candidate("User", :system_admins)]

      body = render(discovery: discovery(groups), selected: selected)

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
      expect(body).to include("karst-population-search")
      expect(body).to match(/<script nonce="[0-9a-f]+">/)
    end
  end

  describe "selection surfaced first" do
    it "lists the current selection, grouped by model, above the full browsable list" do
      groups = [group("User", %i[system_admins auditors])]
      selected = [candidate("User", :system_admins), candidate("User", :auditors)]

      body = render(discovery: discovery(groups), selected: selected)

      expect(body).to include("Selected (2)")
      expect(body.index("Selected (2)")).to be < body.index("Available models")
      expect(body).to include('<input type="checkbox" name="population[]" value="User::system_admins" checked>')
    end

    it "reports zero selected without claiming a population is unusable" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).to include("Selected (0)", "No populations selected yet.")
    end

    it "shows a principal-source badge only for a model matching a configured source" do
      groups = [group("User", [:system_admins], principal_source: :default), group("Subscription", [:renewable])]

      body = render(discovery: discovery(groups))

      expect(body).to include("principal source: default")
      expect(body.scan('class="badge"').size).to eq(1)
    end
  end

  describe "configuration snippet" do
    it "renders the generated snippet in a readonly textarea with a copy control" do
      snippet = Karst::Access::PopulationConfigSnippet.generate(
        [candidate("User", :system_admins, principal_source: :default)]
      )

      body = render(discovery: discovery([group("User", [:system_admins], principal_source: :default)]),
                    snippet: snippet)

      expect(body).to include("Configuration snippet", "config.principal_populations", "id=\"karst-copy-snippet\"")
      expect(body).to include("<textarea id=\"karst-snippet-code\" readonly>")
    end

    it "discloses, rather than silently drops, a selected population with no matching principal source" do
      snippet = Karst::Access::PopulationConfigSnippet.generate([candidate("Subscription", :renewable)])

      body = render(discovery: discovery([group("Subscription", [:renewable])]), snippet: snippet)

      expect(body).to include("not part of a configured principal source", "Subscription.renewable")
    end

    it "omits the snippet section entirely when nothing has been generated yet" do
      body = render(discovery: discovery([group("User", [:system_admins])]))

      expect(body).not_to include("Configuration snippet")
    end
  end

  describe "bounded preview" do
    let(:preview_record_class) do
      Class.new do
        def self.name
          "User"
        end

        def self.primary_key
          "id"
        end

        attr_reader :id

        def initialize(id)
          @id = id
        end
      end
    end

    it "shows only the bounded preview records for the exact candidate previewed" do
      preview = Karst::Access::PopulationPreview::Result.new(
        model_name: "User", method_name: "system_admins", resolved: true,
        records: [preview_record_class.new(1)], error: nil
      )

      body = render(discovery: discovery([group("User", %i[system_admins auditors])]), preview: preview)

      expect(body).to include("Preview (up to 3): User #1")
    end

    it "reports a failed preview honestly instead of pretending success" do
      preview = Karst::Access::PopulationPreview::Result.new(
        model_name: "User", method_name: "system_admins", resolved: false, records: [],
        error: "did not resolve to a usable ActiveRecord::Relation for User"
      )

      body = render(discovery: discovery([group("User", [:system_admins])]), preview: preview)

      expect(body).to include("Preview: did not resolve to a usable ActiveRecord::Relation for User.")
    end

    it "reports an empty result honestly rather than as a failure" do
      preview = Karst::Access::PopulationPreview::Result.new(
        model_name: "User", method_name: "system_admins", resolved: true, records: [], error: nil
      )

      body = render(discovery: discovery([group("User", [:system_admins])]), preview: preview)

      expect(body).to include("Preview: no matching records currently.")
    end
  end

  describe "discovery limitations" do
    it "surfaces an honest load warning instead of silently under-reporting models" do
      body = render(discovery: discovery([], load_warning: "The application could not be fully loaded"))

      expect(body).to include("The application could not be fully loaded")
    end

    it "escapes a hostile load warning instead of rendering it as markup" do
      hostile = "<script>alert(1)</script>"

      body = render(discovery: discovery([], load_warning: hostile))

      expect(body).not_to include(hostile)
      expect(body).to include(CGI.escapeHTML(hostile))
    end
  end
end
# rubocop:enable Metrics/BlockLength
