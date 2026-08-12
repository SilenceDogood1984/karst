# frozen_string_literal: true

require "spec_helper"
require "logger"
require "tmpdir"
require "rails"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's fixtures can never collide with
# any other spec file's global AR::Base connection state. No table is needed:
# nothing here ever executes an approved scope.
class ApprovedPopFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

# rubocop:disable Style/ClassVars
class ApprovedPopUser < ApprovedPopFixtureRecord
  @@executed = []

  def self.executed
    @@executed
  end

  scope :system_admins, -> { @@executed << :system_admins and all }
  scope :auditors, -> { all }
  scope :for_role, ->(role) { where(role: role) }

  # Deliberately not a `scope` declaration: an approval naming it must never
  # be confirmed, however it was written into the file.
  def self.destroy_everything
    @@executed << :destroy_everything
    all
  end
end
# rubocop:enable Style/ClassVars

class ApprovedPopAdmin < ApprovedPopFixtureRecord
  scope :active, -> { all }
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::ApprovedPopulations do
  around do |example|
    Dir.mktmpdir("karst-approved") do |dir|
      @root = dir
      example.run
    end
  end

  before do
    allow(Karst::Access::PopulationApprovals).to receive(:path)
      .and_return(File.join(@root, "tmp/karst/approved_populations.json"))
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    ApprovedPopUser.executed.clear
    Karst.config.principals = -> { ApprovedPopUser.all }
  end

  after do
    Karst.config.principals = nil
    Karst.config.principal_populations = nil
  end

  def approve(*pairs)
    entries = pairs.map do |model_name, method_name|
      Karst::Access::PopulationApprovals::Entry.new(model_name: model_name, method_name: method_name)
    end
    Karst::Access::PopulationApprovals.replace(entries)
  end

  def approve_raw(json)
    path = Karst::Access::PopulationApprovals.path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, json)
  end

  def populations(source_name = :default)
    Karst.config.principal_sources.fetch(source_name).populations
  end

  describe "an approved candidate becomes an ordinary configured population" do
    it "adds exactly the approved scope to the matching source" do
      approve(%w[ApprovedPopUser auditors])

      expect(populations.keys).to eq([:auditors])
    end

    it "builds a callable that resolves to that model's own relation, with no eval and no stored Ruby" do
      approve(%w[ApprovedPopUser auditors])

      relation = populations.fetch(:auditors).call

      expect(relation).to be_a(ActiveRecord::Relation)
      expect(relation.klass).to eq(ApprovedPopUser)
      expect(relation.to_sql).to eq(ApprovedPopUser.auditors.to_sql)
    end

    it "never executes an approved scope while resolving configuration" do
      approve(%w[ApprovedPopUser system_admins])
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Karst.config.principal_sources }

      expect(ApprovedPopUser.executed).to be_empty
      expect(queries).to be_empty
    end

    it "survives the fresh configuration object a process reload produces" do
      approve(%w[ApprovedPopUser auditors])

      reloaded = Karst.const_get(:Configuration, false).new
      reloaded.principals = -> { ApprovedPopUser.all }

      expect(reloaded.principal_sources.fetch(:default).populations.keys).to eq([:auditors])
    end

    it "degrades to explicitly configured populations if approval resolution itself fails" do
      Karst.config.principal_populations = { explicit: -> { ApprovedPopUser.all } }
      approve(%w[ApprovedPopUser auditors])
      allow(Karst::Access::PopulationDiscovery).to receive(:new).and_raise("discovery exploded")

      expect(populations.keys).to eq([:explicit])
    end

    it "reflects an approval revoked since the last analysis, without a restart" do
      approve(%w[ApprovedPopUser auditors])
      expect(populations.keys).to eq([:auditors])

      approve

      expect(populations).to be_empty
    end
  end

  describe "only approved, currently discovered scopes are ever executable" do
    it "ignores a discovered scope that was never approved" do
      expect(populations).to be_empty
    end

    it "ignores an approval for a scope current discovery no longer confirms" do
      approve(%w[ApprovedPopUser vanished_scope])

      expect(populations).to be_empty
    end

    it "ignores a hand-written approval naming an ordinary class method" do
      approve_raw('{"version":1,"approved":[{"model":"ApprovedPopUser","scope":"destroy_everything"}]}')

      expect(populations).to be_empty
      expect(ApprovedPopUser.executed).to be_empty
    end

    it "ignores an approval for a scope that takes arguments" do
      approve(%w[ApprovedPopUser for_role])

      expect(populations).to be_empty
    end

    it "ignores an approval for a model that is not a configured user source" do
      approve(%w[ApprovedPopAdmin active])

      expect(populations).to be_empty
    end

    it "approves nothing at all when the stored document is malformed" do
      approve_raw("{ not json")

      expect(populations).to be_empty
    end
  end

  describe "explicit configuration precedence" do
    it "keeps an explicitly configured callable of the same name, and executes it only once" do
      explicit = -> { ApprovedPopUser.where(role: "explicit") }
      Karst.config.principal_populations = { auditors: explicit }
      approve(%w[ApprovedPopUser auditors])

      expect(populations.keys).to eq([:auditors])
      expect(populations.fetch(:auditors)).to be(explicit)
    end

    it "keeps explicitly configured populations ahead of approved ones, deterministically" do
      Karst.config.principal_populations = { explicit_first: -> { ApprovedPopUser.all } }
      approve(%w[ApprovedPopUser system_admins], %w[ApprovedPopUser auditors])

      expect(populations.keys).to eq(%i[explicit_first auditors system_admins])
    end

    it "leaves an explicitly configured source untouched when nothing is approved" do
      explicit = -> { ApprovedPopUser.where(role: "explicit") }
      Karst.config.principal_populations = { admins: explicit }

      expect(populations).to eq(admins: explicit)
    end
  end

  describe "multiple principal models" do
    before do
      Karst.config.principals = nil
      Karst.config.principal_sources = { members: -> { ApprovedPopUser.all }, staff: -> { ApprovedPopAdmin.all } }
    end

    after { Karst.config.principal_sources = nil }

    it "routes each approval to the source whose model it names, and to no other" do
      approve(%w[ApprovedPopUser auditors], %w[ApprovedPopAdmin active])

      expect(populations(:members).keys).to eq([:auditors])
      expect(populations(:staff).keys).to eq([:active])
    end

    it "never lets one model's approval widen another model's source" do
      approve(%w[ApprovedPopAdmin active])

      expect(populations(:members)).to be_empty
      expect(populations(:staff).keys).to eq([:active])
    end
  end

  describe "environment" do
    it "ignores the local approval file entirely in production" do
      approve(%w[ApprovedPopUser auditors])
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect(populations).to be_empty
      expect(described_class).not_to be_local_environment
    end

    it "never reads the approval file at all in production" do
      approve(%w[ApprovedPopUser auditors])
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(Karst::Access::PopulationApprovals).to receive(:load).and_call_original

      Karst.config.principal_sources

      expect(Karst::Access::PopulationApprovals).not_to have_received(:load)
    end

    it "applies in development and test, the environments the workflow exists for" do
      approve(%w[ApprovedPopUser auditors])

      %w[development test].each do |environment|
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(environment))
        expect(populations.keys).to eq([:auditors])
      end
    end
  end

  describe ".stale" do
    it "reports an approval whose scope is no longer discovered" do
      approve(%w[ApprovedPopUser vanished_scope])

      stale = described_class.stale(Karst.config.principal_sources)

      expect(stale.map { |entry, reason| [entry.display_label, reason] })
        .to eq([["ApprovedPopUser.vanished_scope", :not_discovered]])
    end

    it "reports an approval for a model no configured source exposes" do
      approve(%w[ApprovedPopAdmin active])

      stale = described_class.stale(Karst.config.principal_sources)

      expect(stale.map { |entry, reason| [entry.display_label, reason] })
        .to eq([["ApprovedPopAdmin.active", :no_principal_source]])
    end

    it "reports nothing for an approval that is actually in use" do
      approve(%w[ApprovedPopUser auditors])

      expect(described_class.stale(Karst.config.principal_sources)).to be_empty
    end
  end
end
# rubocop:enable Metrics/BlockLength
