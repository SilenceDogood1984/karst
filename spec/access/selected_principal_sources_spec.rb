# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rails"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's fixtures can never collide with
# any other spec file's global AR::Base connection state.
class SelectedSourcesFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class SelectedSourcesUser < SelectedSourcesFixtureRecord; end
class SelectedSourcesAdmin < SelectedSourcesFixtureRecord; end

# Devise itself is not a dependency of this suite -- a struct with
# Devise::Mapping's real public shape (#to, #name) is enough, exactly as in
# spec/identity/devise_support_spec.rb.
SelectedSourcesFakeMapping = Struct.new(:to, :name)

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::SelectedPrincipalSources do
  around do |example|
    Dir.mktmpdir("karst-selected-sources") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(Karst::Access::PrincipalSourceSelection).to receive(:path)
      .and_return(File.join(@root, "tmp/karst/principal_source_selection.json"))
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    stub_const("Devise", Module.new)
    allow(Devise).to receive(:mappings).and_return(
      user: SelectedSourcesFakeMapping.new(SelectedSourcesUser, :user),
      admin: SelectedSourcesFakeMapping.new(SelectedSourcesAdmin, :admin)
    )
  end

  def select(*model_names)
    Karst::Access::PrincipalSourceSelection.replace(model_names)
  end

  describe ".mappings" do
    it "is empty before anything has been selected" do
      expect(described_class.mappings).to eq([])
    end

    it "reflects a single selected model" do
      select("SelectedSourcesUser")

      expect(described_class.mappings).to contain_exactly(
        have_attributes(model: SelectedSourcesUser, scope: :user)
      )
    end

    it "reflects both selected models, each with its own Devise scope" do
      select("SelectedSourcesUser", "SelectedSourcesAdmin")

      expect(described_class.mappings).to contain_exactly(
        have_attributes(model: SelectedSourcesUser, scope: :user),
        have_attributes(model: SelectedSourcesAdmin, scope: :admin)
      )
    end

    it "drops a selected model Devise no longer maps, never constantizing it" do
      select("SelectedSourcesUser", "SelectedSourcesAdmin")
      allow(Devise).to receive(:mappings).and_return(
        user: SelectedSourcesFakeMapping.new(SelectedSourcesUser, :user)
      )

      expect(described_class.mappings).to contain_exactly(have_attributes(model: SelectedSourcesUser))
    end

    it "is empty once every selected mapping has gone stale -- Karst asks again rather than guessing" do
      select("SelectedSourcesAdmin")
      allow(Devise).to receive(:mappings).and_return(
        user: SelectedSourcesFakeMapping.new(SelectedSourcesUser, :user)
      )

      expect(described_class.mappings).to be_empty
    end

    it "never trusts a hand-written entry naming a class Devise never mapped" do
      Karst::Access::PrincipalSourceSelection.replace([]) # baseline: writer validates against Devise already
      path = Karst::Access::PrincipalSourceSelection.path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '{"version":1,"selected":["Kernel"]}')

      expect(described_class.mappings).to be_empty
    end

    it "is empty outside development/test, without reading the file at all" do
      select("SelectedSourcesUser")
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(Karst::Access::PrincipalSourceSelection).to receive(:load).and_call_original

      expect(described_class.mappings).to eq([])
      expect(Karst::Access::PrincipalSourceSelection).not_to have_received(:load)
    end

    it "degrades to an empty selection rather than raising if resolution itself fails" do
      select("SelectedSourcesUser")
      allow(Karst::Identity::DeviseSupport).to receive(:mappings).and_raise("boom")

      expect(described_class.mappings).to eq([])
    end
  end

  describe ".sources" do
    it "is nil when nothing is selected" do
      expect(described_class.sources).to be_nil
    end

    it "builds one independently queryable PrincipalSource per selected model, keyed by its own Devise scope" do
      select("SelectedSourcesUser", "SelectedSourcesAdmin")

      sources = described_class.sources

      expect(sources.keys).to contain_exactly(:user, :admin)
      expect(sources[:user].record_klass).to eq(SelectedSourcesUser)
      expect(sources[:admin].record_klass).to eq(SelectedSourcesAdmin)
    end

    it "never collapses two selected models into one combined source" do
      select("SelectedSourcesUser", "SelectedSourcesAdmin")

      sources = described_class.sources

      expect(sources.size).to eq(2)
      expect(sources[:user].evaluate).to be_a(ActiveRecord::Relation)
      expect(sources[:user].evaluate.klass).to eq(SelectedSourcesUser)
    end

    it "is nil once every selected mapping has gone stale" do
      select("SelectedSourcesAdmin")
      allow(Devise).to receive(:mappings).and_return(
        user: SelectedSourcesFakeMapping.new(SelectedSourcesUser, :user)
      )

      expect(described_class.sources).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
