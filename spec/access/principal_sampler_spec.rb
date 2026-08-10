# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order.
class PrincipalSamplerFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class SamplerPrincipal < PrincipalSamplerFixtureRecord
  # Rails 7 introduced the positional `enum :name, {...}` form and Rails 8
  # removed the old `enum name: {...}` keyword form entirely; this fixture
  # spans Karst's whole supported floor (Rails 6.1-8), so it picks whichever
  # form the loaded Active Record actually accepts.
  if ActiveRecord::VERSION::MAJOR >= 7
    enum :status, { active: 0, trial: 1, canceled: 2 }
  else
    enum status: { active: 0, trial: 1, canceled: 2 }
  end
end

# A deliberately adversarial fixture for the hard query-budget regression:
# many boolean/enum dimension targets that no row in the (small, homogeneous)
# table ever satisfies, so every one of those lookups is a wasted query. If
# the budget were an estimate rather than an enforced invariant, this table
# would drive #call well past PrincipalSampler.query_budget(limit).
class BudgetStressPrincipal < PrincipalSamplerFixtureRecord
  CATEGORY_KEYS = (0..29).to_h { |i| ["category#{i}", i] }.freeze

  if ActiveRecord::VERSION::MAJOR >= 7
    enum :category, CATEGORY_KEYS
  else
    enum category: CATEGORY_KEYS
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PrincipalSampler do
  before(:all) do
    PrincipalSamplerFixtureRecord.connection.create_table :sampler_principals, force: true do |t|
      t.boolean :premium, null: false, default: false
      t.integer :status, null: false, default: 0
      t.integer :author_id
      t.integer :tenant_id, null: false
      t.integer :account_id
      t.string :external_ref
      t.string :email
      t.datetime :created_at
    end
  end

  before(:all) do
    PrincipalSamplerFixtureRecord.connection.create_table :budget_stress_principals, force: true do |t|
      t.boolean :flag_a, null: false, default: false
      t.boolean :flag_b, null: false, default: false
      t.boolean :flag_c, null: false, default: false
      t.boolean :flag_d, null: false, default: false
      t.integer :category, null: false, default: 0
    end
  end

  after(:all) do
    PrincipalSamplerFixtureRecord.connection.drop_table :sampler_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :budget_stress_principals, if_exists: true
  end

  before do
    SamplerPrincipal.delete_all
  end

  def sql_queries(&block)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  describe "the dogfood regression: homogeneous first-N rows hide minority states" do
    it "selects minority boolean/enum/nullable-FK states first-N sampling would miss entirely" do
      295.times do |i|
        SamplerPrincipal.create!(premium: false, status: :active, tenant_id: i, external_ref: "ref-#{i}",
                                 email: "user#{i}@example.com")
      end
      premium = SamplerPrincipal.create!(premium: true, status: :active, tenant_id: 900, external_ref: "ref-900",
                                         email: "premium@example.com")
      canceled = SamplerPrincipal.create!(premium: false, status: :canceled, tenant_id: 901, external_ref: "ref-901",
                                          email: "canceled@example.com")
      authored = SamplerPrincipal.create!(premium: false, status: :active, author_id: 42, tenant_id: 902,
                                          external_ref: "ref-902", email: "authored@example.com")

      first_25_ids = SamplerPrincipal.order(:id).limit(25).pluck(:id)
      expect(first_25_ids).not_to include(premium.id, canceled.id, authored.id)

      result = described_class.new(source: SamplerPrincipal.all, limit: 25).call

      expect(result.strategy).to eq(:representative)
      selected_ids = result.principals.map(&:id)
      expect(selected_ids.size).to eq(25)
      expect(selected_ids).to include(premium.id, canceled.id, authored.id)

      expect(candidate_reasons(result, premium.id)).to include("premium=true")
      expect(candidate_reasons(result, canceled.id)).to include("status=canceled")
      expect(candidate_reasons(result, authored.id)).to include("author_id present")
    end

    def candidate_reasons(result, id)
      result.candidates.find { |candidate| candidate.principal.id == id }.reasons
    end
  end

  describe "dimension safety" do
    before do
      50.times do |i|
        SamplerPrincipal.create!(premium: i.even?, status: SamplerPrincipal.statuses.keys[i % 3], tenant_id: i,
                                 external_ref: "ref-#{i}", email: "user#{i}@example.com")
      end
    end

    it "never stratifies on a high-cardinality string column" do
      result = described_class.new(source: SamplerPrincipal.all, limit: 10).call
      expect(reasons_starting_with(result, "external_ref=")).to be_empty
    end

    it "never stratifies on a high-cardinality tenant foreign key" do
      result = described_class.new(source: SamplerPrincipal.all, limit: 10).call
      expect(reasons_starting_with(result, "tenant_id=")).to be_empty
    end

    it "never inspects a sensitive column name even when its observed cardinality is low" do
      SamplerPrincipal.update_all(email: "shared@example.com")

      result = described_class.new(source: SamplerPrincipal.all, limit: 10).call
      expect(result.candidates.flat_map(&:reasons).grep(/email/)).to be_empty
    end

    it "respects an already tenant-scoped relation and never returns principals outside it" do
      scoped = SamplerPrincipal.where(tenant_id: 7)
      result = described_class.new(source: scoped, limit: 10).call

      expect(result.principals).not_to be_empty
      expect(result.principals.map(&:tenant_id).uniq).to eq([7])
      expect(reasons_starting_with(result, "tenant_id=")).to be_empty
    end

    it "never treats a nullable tenant-style foreign key as a presence/absence dimension" do
      SamplerPrincipal.find_each.with_index { |row, i| row.update!(account_id: i) }

      result = described_class.new(source: SamplerPrincipal.all, limit: 10).call
      expect(reasons_starting_with(result, "account_id")).to be_empty
    end

    def reasons_starting_with(result, prefix)
      result.candidates.flat_map(&:reasons).select { |reason| reason.start_with?(prefix) }
    end
  end

  describe "generic Enumerable fallback" do
    Struct.new("SamplerFallbackPrincipal", :id)

    it "falls back to bounded first-N in original order without issuing any query" do
      principals = (1..40).map { |id| Struct::SamplerFallbackPrincipal.new(id) }

      result = described_class.new(source: principals, limit: 5).call

      expect(result.strategy).to eq(:first_n)
      expect(result.principals.map(&:id)).to eq([1, 2, 3, 4, 5])
      expect(result.candidates.map(&:reasons)).to all(eq([]))
      expect(result.queries).to eq(0)
    end

    it "consumes a lazily infinite Enumerable only up to the bound" do
      infinite = (1..Float::INFINITY).lazy.map { |id| Struct::SamplerFallbackPrincipal.new(id) }

      result = described_class.new(source: infinite, limit: 3).call

      expect(result.principals.map(&:id)).to eq([1, 2, 3])
    end
  end

  describe "determinism and the hard limit" do
    before do
      60.times do |i|
        SamplerPrincipal.create!(premium: i.even?, status: SamplerPrincipal.statuses.keys[i % 3], tenant_id: i,
                                 author_id: i.zero? ? nil : i, external_ref: "ref-#{i}", email: "u#{i}@example.com")
      end
    end

    it "returns the same principals across repeated calls over the same scope" do
      first = described_class.new(source: SamplerPrincipal.all, limit: 15).call
      second = described_class.new(source: SamplerPrincipal.all, limit: 15).call

      expect(first.principals.map(&:id)).to eq(second.principals.map(&:id))
    end

    it "never returns more principals than the configured limit" do
      result = described_class.new(source: SamplerPrincipal.all, limit: 5).call
      expect(result.principals.size).to eq(5)
    end

    it "accepts a bare Active Record class exactly like Access::Sweep does" do
      result = described_class.new(source: SamplerPrincipal, limit: 5).call
      expect(result.strategy).to eq(:representative)
      expect(result.principals.size).to eq(5)
    end
  end

  describe "query budget" do
    it "never issues an un-bounded SELECT while sampling" do
      120.times do |i|
        SamplerPrincipal.create!(premium: i.even?, status: SamplerPrincipal.statuses.keys[i % 3], tenant_id: i,
                                 external_ref: "ref-#{i}", email: "u#{i}@example.com")
      end

      queries = sql_queries { described_class.new(source: SamplerPrincipal.all, limit: 25).call }
      selects = queries.grep(/\A\s*SELECT/i)

      expect(selects).not_to be_empty
      expect(selects).to all(match(/LIMIT/i))
    end

    # Simulates a 100k+ row table without materializing it: query volume for
    # representative sampling is driven by dimension/target/limit counts, not
    # row count, so it must stay flat between a small and a much larger table
    # built from the identical schema and value distribution.
    it "keeps query volume flat as the underlying table grows, without loading it" do
      populate = lambda do |count|
        rows = Array.new(count) do |i|
          { premium: i.even?, status: i % 3, tenant_id: i, external_ref: "ref-#{i}", email: "u#{i}@example.com" }
        end
        SamplerPrincipal.insert_all(rows)
      end

      SamplerPrincipal.delete_all
      populate.call(300)
      small_queries = sql_queries { described_class.new(source: SamplerPrincipal.all, limit: 25).call }.size

      SamplerPrincipal.delete_all
      populate.call(8_000)
      large_queries = sql_queries { described_class.new(source: SamplerPrincipal.all, limit: 25).call }.size

      expect(large_queries).to eq(small_queries)
      expect(large_queries).to be < 50
    end

    it "never issues more queries than the declared budget, even under an adversarial fixture" do
      BudgetStressPrincipal.delete_all
      create_homogeneous_stress_principals(5)

      [1, 2, 3, 5, 25].each do |limit|
        budget = described_class.query_budget(limit)
        queries = sql_queries { described_class.new(source: BudgetStressPrincipal.all, limit: limit).call }

        expect(queries.size).to be <= budget
      end
    end

    it "returns at most, and may return fewer than, `limit` principals once the budget is exhausted" do
      BudgetStressPrincipal.delete_all
      create_homogeneous_stress_principals(5)

      result = described_class.new(source: BudgetStressPrincipal.all, limit: 3).call

      expect(result.principals.size).to be <= 3
      expect(result.queries).to be <= described_class.query_budget(3)
    end

    def create_homogeneous_stress_principals(count)
      count.times do
        BudgetStressPrincipal.create!(flag_a: false, flag_b: false, flag_c: false, flag_d: false,
                                      category: :category0)
      end
    end
  end

  describe "primary key safety" do
    before do
      SamplerPrincipal.create!(premium: false, status: :active, tenant_id: 1)
    end

    it "raises a Karst-specific actionable error for a composite primary key rather than crashing obscurely" do
      allow(SamplerPrincipal).to receive(:primary_key).and_return(%w[tenant_id id])

      expect { described_class.new(source: SamplerPrincipal.all, limit: 5).call }
        .to raise_error(Karst::Access::PrincipalSampler::UnsupportedPrimaryKey, /single-column primary key/)
    end

    it "raises the same actionable error when the model has no primary key at all" do
      allow(SamplerPrincipal).to receive(:primary_key).and_return(nil)

      expect { described_class.new(source: SamplerPrincipal.all, limit: 5).call }
        .to raise_error(Karst::Access::PrincipalSampler::UnsupportedPrimaryKey, /single-column primary key/)
    end

    it "is a Karst::Access::Error, so the existing middleware/panel error surface catches it unchanged" do
      expect(Karst::Access::PrincipalSampler::UnsupportedPrimaryKey.ancestors).to include(Karst::Access::Error)
    end
  end
end
# rubocop:enable Metrics/BlockLength
