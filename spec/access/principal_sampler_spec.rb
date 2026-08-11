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

# A fixture dedicated to configured Karst::Access::PrincipalDimension
# coverage: `role` is a plain scalar column (an attribute dimension),
# `premium` is a real boolean column reachable either directly or through
# Rails' auto-generated `premium?` predicate (a queryable dimension either
# way), and `system_admin?` is a computed predicate with no backing column
# at all (so it can only be evaluated over the bounded candidate pool, never
# translated to SQL).
class DimensionPrincipal < PrincipalSamplerFixtureRecord
  def system_admin?
    role == "system_admin"
  end
end

# A wide table where the column that matters (is_admin) sits well past
# MAX_DIMENSIONS -- schema-heuristic dimension discovery structurally cannot
# reach it, regardless of query budget, so any coverage of it can only come
# from an explicitly configured candidate population. Uses a real Rails
# named scope only because it is a convenient, realistic query builder --
# PrincipalSampler never requires or verifies that the configured callable
# came from the `scope` macro specifically.
class WideScopedPrincipal < PrincipalSamplerFixtureRecord
  scope :system_admins, -> { where(is_admin: true) }
end

# Application-authored vocabulary for meaningful, non-dimension-shaped
# subsets, mirroring the task's own motivating example. `flagged` is a
# second, independent axis so a single row can belong to more than one
# configured population at once (e.g. both system_admins and auditors).
class ScopedSamplerPrincipal < PrincipalSamplerFixtureRecord
  scope :system_admins, -> { where(role: "system_admin") }
  scope :auditors, -> { where(flagged: true) }
  scope :responders, -> { where(role: "responder") }
end

# A second, independent principal source with a scope of the *same name* as
# ScopedSamplerPrincipal's, to prove a configured population's callable
# stays bound to the model it actually queries and never leaks across
# sources.
class OtherScopedPrincipal < PrincipalSamplerFixtureRecord
  scope :system_admins, -> { where(role: "owner") }
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

  before(:all) do
    PrincipalSamplerFixtureRecord.connection.create_table :dimension_principals, force: true do |t|
      t.string :role, null: false, default: "responder"
      t.boolean :premium, null: false, default: false
      t.string :plan
    end
  end

  before(:all) do
    PrincipalSamplerFixtureRecord.connection.create_table :wide_scoped_principals, force: true do |t|
      8.times { |i| t.boolean "filler_#{i}", null: false, default: false }
      t.boolean :is_admin, null: false, default: false
    end
    PrincipalSamplerFixtureRecord.connection.create_table :scoped_sampler_principals, force: true do |t|
      t.string :role, null: false
      t.boolean :flagged, null: false, default: false
    end
    PrincipalSamplerFixtureRecord.connection.create_table :other_scoped_principals, force: true do |t|
      t.string :role, null: false
    end
  end

  after(:all) do
    PrincipalSamplerFixtureRecord.connection.drop_table :sampler_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :budget_stress_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :dimension_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :wide_scoped_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :scoped_sampler_principals, if_exists: true
    PrincipalSamplerFixtureRecord.connection.drop_table :other_scoped_principals, if_exists: true
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

  describe "the bounded candidate pool: 500k-dogfood-scale hardening" do
    def candidate_reasons(result, id)
      result.candidates.find { |candidate| candidate.principal.id == id }.reasons
    end

    it "derives the pool with exactly one query, then fixes it as a literal id list every later query is " \
       "scoped to -- never a live subquery re-evaluated (and re-scanning the full table) on every query" do
      120.times { |i| SamplerPrincipal.create!(premium: false, status: :active, tenant_id: i, created_at: Time.now) }

      queries = sql_queries { described_class.new(source: SamplerPrincipal.all, limit: 5, pool_size: 30).call }
      selects = queries.grep(/\ASELECT/i)
      pool_derivation, rest = selects.partition { |sql| sql.match?(/ORDER BY .*LIMIT \?\z/i) && !sql.include?("IN (") }

      expect(pool_derivation.size).to eq(1)
      expect(rest).not_to be_empty
      expect(rest).to all(match(/\bid IN \(\d/))
    end

    it "orders the pool by created_at desc when the column exists, otherwise by primary key desc" do
      old = SamplerPrincipal.create!(premium: false, status: :active, tenant_id: 1, created_at: 2.days.ago)
      recent = SamplerPrincipal.create!(premium: false, status: :active, tenant_id: 2, created_at: Time.now)

      result = described_class.new(source: SamplerPrincipal.all, limit: 5, pool_size: 1).call

      expect(result.principals.map(&:id)).to eq([recent.id])
      expect(result.principals.map(&:id)).not_to include(old.id)
    end

    it "never selects, or even discovers dimensions from, a row outside the bounded pool" do
      total = 3_000
      pool_size = 200
      now = Time.now
      rows = Array.new(total) do |i|
        { premium: false, status: 0, tenant_id: i, created_at: now - (total - i).minutes }
      end
      SamplerPrincipal.insert_all(rows)
      # A minority state seeded only among the most-recent (in-pool) rows...
      in_pool_minority = SamplerPrincipal.create!(premium: true, status: :active, tenant_id: 90_001,
                                                  created_at: now + 1.minute)
      # ...and an identical minority state seeded only among old (out-of-pool) rows, which must never surface.
      out_of_pool_minority = SamplerPrincipal.create!(premium: false, status: :canceled, tenant_id: 90_002,
                                                      created_at: now - (total + 1_000).minutes)

      expected_pool_ids = SamplerPrincipal.order(created_at: :desc).limit(pool_size).pluck(:id)
      expect(expected_pool_ids).to include(in_pool_minority.id)
      expect(expected_pool_ids).not_to include(out_of_pool_minority.id)

      result = described_class.new(source: SamplerPrincipal.all, limit: 25, pool_size: pool_size).call

      expect(result.principals.map(&:id) - expected_pool_ids).to be_empty
      expect(result.principals.map(&:id)).to include(in_pool_minority.id)
      expect(result.principals.map(&:id)).not_to include(out_of_pool_minority.id)
      expect(candidate_reasons(result, in_pool_minority.id)).to include("premium=true")
    end

    it "falls back to primary-key ordering for the pool when the table has no created_at column" do
      BudgetStressPrincipal.delete_all
      40.times do |_i|
        BudgetStressPrincipal.create!(flag_a: false, flag_b: false, flag_c: false, flag_d: false, category: :category0)
      end
      newest = BudgetStressPrincipal.create!(flag_a: true, flag_b: false, flag_c: false, flag_d: false,
                                             category: :category0)

      result = described_class.new(source: BudgetStressPrincipal.all, limit: 5, pool_size: 5).call

      expect(result.principals.map(&:id)).to include(newest.id)
    end

    it "keeps query volume flat even when the pool itself is scanned repeatedly across a much larger table" do
      SamplerPrincipal.delete_all
      (0...8_000).each_slice(1_000) do |slice|
        rows = slice.map { |i| { premium: i.even?, status: i % 3, tenant_id: i, created_at: Time.now - i.seconds } }
        SamplerPrincipal.insert_all(rows)
      end

      queries = sql_queries { described_class.new(source: SamplerPrincipal.all, limit: 25, pool_size: 500).call }

      expect(queries.size).to be <= described_class.query_budget(25)
    end

    it "still finds minority states within the pool, matching un-pooled representative discovery" do
      299.times { |i| SamplerPrincipal.create!(premium: false, status: :active, tenant_id: i, created_at: Time.now) }
      minority = SamplerPrincipal.create!(premium: true, status: :active, tenant_id: 999, created_at: Time.now)

      result = described_class.new(source: SamplerPrincipal.all, limit: 25, pool_size: 1_000).call

      expect(result.principals.map(&:id)).to include(minority.id)
    end

    it "returns fewer principals than the limit, never an error, once the pool itself is smaller than the limit" do
      10.times { |i| SamplerPrincipal.create!(premium: false, status: :active, tenant_id: i, created_at: Time.now) }

      result = described_class.new(source: SamplerPrincipal.all, limit: 25, pool_size: 5).call

      expect(result.principals.size).to be <= 5
    end

    it "reports the configured pool size on a representative result and nil on the Enumerable fallback" do
      SamplerPrincipal.create!(premium: false, status: :active, tenant_id: 1, created_at: Time.now)

      representative = described_class.new(source: SamplerPrincipal.all, limit: 5, pool_size: 40).call
      fallback = described_class.new(source: [Struct.new(:id).new(1)], limit: 5, pool_size: 40).call

      expect(representative.candidate_pool_size).to eq(40)
      expect(fallback.candidate_pool_size).to be_nil
    end

    it "defaults the pool size from Karst.config.principal_candidate_pool_size" do
      Karst.config.principal_candidate_pool_size = 17
      SamplerPrincipal.create!(premium: false, status: :active, tenant_id: 1, created_at: Time.now)

      result = described_class.new(source: SamplerPrincipal.all, limit: 5).call

      expect(result.candidate_pool_size).to eq(17)
    ensure
      Karst.config.principal_candidate_pool_size = 1_000
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

  describe "configured dimensions" do
    def dimensions(hash)
      Karst::Access::PrincipalDimension.normalize(hash)
    end

    def reasons_for(result, id)
      result.candidates.find { |candidate| candidate.principal.id == id }.reasons
    end

    before do
      DimensionPrincipal.delete_all
    end

    it "deliberately represents at least one record for each configured attribute-dimension value within " \
       "the limit, ahead of simply filling with the majority value" do
      900.times { DimensionPrincipal.create!(role: "responder") }
      6.times { DimensionPrincipal.create!(role: "local_admin") }
      3.times { DimensionPrincipal.create!(role: "group_admin") }
      2.times { DimensionPrincipal.create!(role: "reseller") }
      DimensionPrincipal.create!(role: "system_admin")

      result = described_class.new(source: DimensionPrincipal.all, limit: 10,
                                   dimensions: dimensions(role: :role)).call

      selected_roles = result.principals.map(&:role).uniq
      expect(selected_roles).to include("local_admin", "group_admin", "reseller", "system_admin")
      local_admin_candidate = result.candidates.find { |candidate| candidate.principal.role == "local_admin" }
      expect(local_admin_candidate.reasons).to include("role=local_admin")
    end

    it "represents a configured boolean predicate (`premium?`) exactly like the real boolean column, without " \
       "a duplicate reason from generic schema discovery" do
      47.times { DimensionPrincipal.create!(premium: false) }
      premium = DimensionPrincipal.create!(premium: true)

      result = described_class.new(source: DimensionPrincipal.all, limit: 10,
                                   dimensions: dimensions(premium: :premium?)).call

      expect(result.principals.map(&:id)).to include(premium.id)
      reasons = reasons_for(result, premium.id)
      expect(reasons.count("premium=true")).to eq(1)
    end

    it "represents a configured callable dimension, bounded to the already-fetched candidate pool" do
      47.times { DimensionPrincipal.create!(plan: "standard") }
      reseller = DimensionPrincipal.create!(plan: "reseller")
      dimension = dimensions(reseller: ->(record) { record.plan == "reseller" })

      result = described_class.new(source: DimensionPrincipal.all, limit: 10, dimensions: dimension).call

      expect(result.principals.map(&:id)).to include(reseller.id)
      expect(reasons_for(result, reseller.id)).to include("reseller=true")
    end

    it "represents a computed predicate with no backing column, evaluated in Ruby over the bounded pool" do
      47.times { DimensionPrincipal.create!(role: "responder") }
      admin = DimensionPrincipal.create!(role: "system_admin")

      result = described_class.new(source: DimensionPrincipal.all, limit: 10,
                                   dimensions: dimensions(admin: :system_admin?)).call

      expect(result.principals.map(&:id)).to include(admin.id)
      expect(reasons_for(result, admin.id)).to include("admin=true")
    end

    it "prioritizes configured dimensions over generic schema heuristics when both could otherwise apply" do
      47.times { DimensionPrincipal.create!(role: "responder", premium: false) }
      minority = DimensionPrincipal.create!(role: "responder", premium: true)

      # Only 3 slots: without configured-dimension priority, generic
      # discovery over two low-cardinality columns (role, premium) would
      # already exhaust the limit before the configured dimension's own
      # target-lookup queries ever ran.
      result = described_class.new(source: DimensionPrincipal.all, limit: 3,
                                   dimensions: dimensions(premium: :premium)).call

      expect(result.principals.map(&:id)).to include(minority.id)
    end

    it "still runs generic schema discovery for columns no configured dimension names, once room remains" do
      47.times { DimensionPrincipal.create!(role: "responder", premium: false) }
      premium_minority = DimensionPrincipal.create!(role: "responder", premium: true)

      result = described_class.new(source: DimensionPrincipal.all, limit: 10,
                                   dimensions: dimensions(role: :role)).call

      expect(result.principals.map(&:id)).to include(premium_minority.id)
    end

    it "behaves exactly as before when no dimensions are configured" do
      47.times { DimensionPrincipal.create!(role: "responder") }

      result = described_class.new(source: DimensionPrincipal.all, limit: 5).call

      expect(result.strategy).to eq(:representative)
      expect(result.principals.size).to eq(5)
    end

    it "never issues more queries than the declared budget once configured dimensions are added" do
      60.times { |i| DimensionPrincipal.create!(role: %w[responder local_admin group_admin][i % 3], plan: "p#{i}") }
      dimension = dimensions(role: :role, admin: :system_admin?, reseller: ->(record) { record.plan == "p0" })

      queries = sql_queries do
        described_class.new(source: DimensionPrincipal.all, limit: 10, dimensions: dimension).call
      end

      expect(queries.size).to be <= described_class.query_budget(10)
    end
  end

  describe "configured candidate populations" do
    def candidate_reasons(result, id)
      result.candidates.find { |candidate| candidate.principal.id == id }.reasons
    end

    def scoped_sampler_populations
      {
        system_admins: -> { ScopedSamplerPrincipal.system_admins },
        auditors: -> { ScopedSamplerPrincipal.auditors },
        responders: -> { ScopedSamplerPrincipal.responders }
      }
    end

    it "finds a configured population's principal even when it falls outside the recent-N candidate pool" do
      ScopedSamplerPrincipal.delete_all
      old_admin = ScopedSamplerPrincipal.create!(role: "system_admin")
      50.times { ScopedSamplerPrincipal.create!(role: "responder") }

      populations = { system_admins: -> { ScopedSamplerPrincipal.system_admins } }
      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 10, pool_size: 10,
                                   populations: populations).call

      # old_admin has the lowest id, created before all 50 responders --
      # well outside the 10-row recent-N pool the responders alone occupy.
      expect(result.principals.map(&:id)).to include(old_admin.id)
      expect(candidate_reasons(result, old_admin.id)).to include("population=system_admins")
    end

    it "surfaces a principal a wide table's own dimension discovery structurally cannot reach" do
      WideScopedPrincipal.delete_all
      # Created first (lowest id): with seed/fill now biased toward the most
      # recently created rows, these must stay old/excluded from a plain
      # sweep so the admin's absence below is actually due to MAX_DIMENSIONS
      # capping column discovery, not merely due to recency.
      admin = WideScopedPrincipal.create!(is_admin: true)
      filler_hit = WideScopedPrincipal.create!(filler_0: true) # rubocop:disable Naming/VariableNumber
      300.times { WideScopedPrincipal.create! }

      without_populations = described_class.new(source: WideScopedPrincipal.all, limit: 25).call
      expect(without_populations.principals.map(&:id)).not_to include(admin.id)

      populations = { system_admins: -> { WideScopedPrincipal.system_admins } }
      with_populations = described_class.new(source: WideScopedPrincipal.all, limit: 25, populations: populations).call
      expect(with_populations.principals.map(&:id)).to include(admin.id, filler_hit.id)
      expect(candidate_reasons(with_populations, admin.id)).to include("population=system_admins")
    end

    it "gives every configured population a fair chance to contribute, even when one dominates" do
      ScopedSamplerPrincipal.delete_all
      300.times { ScopedSamplerPrincipal.create!(role: "responder") }
      8.times { ScopedSamplerPrincipal.create!(role: "system_admin") }
      3.times { ScopedSamplerPrincipal.create!(role: "auditor", flagged: true) }

      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 12,
                                   populations: scoped_sampler_populations).call

      roles = result.principals.map(&:role)
      expect(roles).to include("system_admin", "auditor", "responder")
      expect(result.principals.size).to eq(12)
      expect(result.populations.map(&:name)).to eq(%i[system_admins auditors responders])
    end

    it "retains a generic or dimension candidate within the global limit" do
      ScopedSamplerPrincipal.delete_all
      20.times { ScopedSamplerPrincipal.create!(role: "responder") }
      ScopedSamplerPrincipal.create!(role: "outside_populations")

      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5,
                                   populations: scoped_sampler_populations).call

      expect(result.principals.size).to eq(5)
      expect(result.candidates).to include(satisfy do |candidate|
        candidate.reasons.none? { |reason| reason.start_with?("population=") }
      end)
    end

    it "includes every configured population in the declared query budget" do
      ScopedSamplerPrincipal.delete_all
      50.times { ScopedSamplerPrincipal.create!(role: "responder") }
      populations = 10.times.to_h do |index|
        [:"population_#{index}", -> { ScopedSamplerPrincipal.where(role: "responder") }]
      end

      queries = sql_queries do
        @result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 25,
                                      populations: populations).call
      end

      expect(@result.principals.size).to be <= 25
      expect(queries.size).to be <= described_class.query_budget(25, 10)
    end

    it "probes a principal belonging to two populations once, preserving both populations' provenance" do
      ScopedSamplerPrincipal.delete_all
      dual = ScopedSamplerPrincipal.create!(role: "system_admin", flagged: true)
      10.times { ScopedSamplerPrincipal.create!(role: "responder") }

      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5,
                                   populations: scoped_sampler_populations).call

      expect(result.principals.map(&:id).tally[dual.id]).to eq(1)
      expect(candidate_reasons(result, dual.id)).to include("population=system_admins", "population=auditors")
    end

    it "skips a population whose callable raises, without raising, still sampling the valid ones" do
      ScopedSamplerPrincipal.delete_all
      admin = ScopedSamplerPrincipal.create!(role: "system_admin")

      populations = { system_admins: -> { ScopedSamplerPrincipal.system_admins }, broken: -> { raise "boom" } }
      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5, populations: populations).call

      expect(result.principals.map(&:id)).to include(admin.id)
      expect(result.populations.map(&:name)).to eq([:system_admins])
    end

    it "skips a population whose callable returns another model's relation, without raising" do
      ScopedSamplerPrincipal.delete_all
      OtherScopedPrincipal.delete_all
      admin = ScopedSamplerPrincipal.create!(role: "system_admin")

      populations = { system_admins: -> { ScopedSamplerPrincipal.system_admins },
                      cross_model: -> { OtherScopedPrincipal.all } }
      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5, populations: populations).call

      expect(result.principals.map(&:id)).to include(admin.id)
      expect(result.populations.map(&:name)).to eq([:system_admins])
    end

    it "contributes nothing, without raising, for a population with no currently matching rows" do
      ScopedSamplerPrincipal.delete_all
      ScopedSamplerPrincipal.create!(role: "responder")

      populations = { system_admins: -> { ScopedSamplerPrincipal.system_admins } }
      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5, populations: populations).call

      expect(result.populations.first).to have_attributes(name: :system_admins, records: [])
    end

    it "leaves explicit schema-heuristic dimension sampling working exactly as before" do
      SamplerPrincipal.delete_all
      295.times { |i| SamplerPrincipal.create!(premium: false, status: :active, tenant_id: i) }
      premium = SamplerPrincipal.create!(premium: true, status: :active, tenant_id: 900)

      result = described_class.new(source: SamplerPrincipal.all, limit: 25, populations: {}).call

      expect(result.principals.map(&:id)).to include(premium.id)
    end

    it "ignores configured populations entirely for a generic Enumerable source" do
      principals = (1..10).map { |id| Struct::SamplerFallbackPrincipal.new(id) }
      populations = { system_admins: -> { ScopedSamplerPrincipal.system_admins } }

      result = described_class.new(source: principals, limit: 5, populations: populations).call

      expect(result.strategy).to eq(:first_n)
      expect(result.populations).to eq([])
    end

    it "keeps a dominant population's query volume flat and never exceeds the configured limit" do
      ScopedSamplerPrincipal.delete_all
      1200.times { ScopedSamplerPrincipal.create!(role: "responder") }
      2.times { ScopedSamplerPrincipal.create!(role: "system_admin") }

      queries = sql_queries do
        @result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 10,
                                      populations: scoped_sampler_populations).call
      end
      selects = queries.grep(/\A\s*SELECT/i)

      expect(@result.principals.size).to eq(10)
      expect(selects).not_to be_empty
      expect(selects.grep(/COUNT/i)).to be_empty
      expect(selects).to all(match(/LIMIT/i))
    end

    it "keeps a configured population bound to the exact source its callable queries, across two sources" do
      ScopedSamplerPrincipal.delete_all
      OtherScopedPrincipal.delete_all
      admin = ScopedSamplerPrincipal.create!(role: "system_admin")
      owner = OtherScopedPrincipal.create!(role: "owner")
      10.times { ScopedSamplerPrincipal.create!(role: "responder") }

      first = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5,
                                  populations: { system_admins: -> { ScopedSamplerPrincipal.system_admins } }).call
      second = described_class.new(source: OtherScopedPrincipal.all, limit: 5,
                                   populations: { system_admins: -> { OtherScopedPrincipal.system_admins } }).call

      expect(first.principals.map(&:id)).to include(admin.id)
      expect(first.principals).to all(be_a(ScopedSamplerPrincipal))
      expect(second.principals.map(&:id)).to include(owner.id)
      expect(second.principals).to all(be_a(OtherScopedPrincipal))
    end

    it "never considers a candidate population unless one is explicitly configured" do
      ScopedSamplerPrincipal.delete_all
      ScopedSamplerPrincipal.create!(role: "system_admin")

      result = described_class.new(source: ScopedSamplerPrincipal.all, limit: 5).call

      expect(result.populations).to eq([])
    end
  end
end
# rubocop:enable Metrics/BlockLength
