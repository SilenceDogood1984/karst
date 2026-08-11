# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order. Mirrors principal_sampler_spec.rb.
class CandidatePopulationFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class PopulationPrincipal < CandidatePopulationFixtureRecord
end

class OtherPopulationRecord < CandidatePopulationFixtureRecord
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::CandidatePopulation do
  before(:all) do
    CandidatePopulationFixtureRecord.connection.create_table :population_principals, force: true do |t|
      t.string :role, null: false
      t.integer :priority, null: false, default: 0
    end
    CandidatePopulationFixtureRecord.connection.create_table :other_population_records, force: true
  end

  after(:all) do
    CandidatePopulationFixtureRecord.connection.drop_table :population_principals, if_exists: true
    CandidatePopulationFixtureRecord.connection.drop_table :other_population_records, if_exists: true
  end

  before { PopulationPrincipal.delete_all }

  def sql_queries(&block)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  def resolve(name:, callable:, limit: 25, source_klass: PopulationPrincipal)
    described_class.resolve(name: name, callable: callable, source_klass: source_klass, limit: limit)
  end

  describe ".resolve" do
    it "resolves a valid callable into a bounded population with population provenance" do
      admin = PopulationPrincipal.create!(role: "admin")

      population = resolve(name: :admins, callable: -> { PopulationPrincipal.where(role: "admin") })

      expect(population.source).to eq(PopulationPrincipal)
      expect(population.name).to eq(:admins)
      expect(population.records).to eq([admin])
      expect(population.provenance).to eq("population=admins")
    end

    it "returns a population with an empty records array for a currently-empty relation" do
      PopulationPrincipal.create!(role: "admin")

      population = resolve(name: :nobody, callable: -> { PopulationPrincipal.where(role: "ghost") })

      expect(population.records).to eq([])
    end

    it "returns nil, without raising, for a callable that requires an argument" do
      population = resolve(name: :by_role, callable: ->(role) { PopulationPrincipal.where(role: role) })

      expect(population).to be_nil
    end

    it "returns nil, without raising, for a callable that raises" do
      queries = sql_queries { @result = resolve(name: :broken, callable: -> { raise "boom" }) }

      expect(@result).to be_nil
      expect(queries).to be_empty
    end

    it "returns nil for a callable that does not return an ActiveRecord::Relation" do
      population = resolve(name: :count, callable: -> { PopulationPrincipal.where(role: "admin").count })

      expect(population).to be_nil
    end

    it "returns nil for a callable returning another model's relation (same-model requirement)" do
      population = resolve(name: :cross_model, callable: -> { OtherPopulationRecord.all })

      expect(population).to be_nil
    end

    it "never fully materializes a large relation: exactly one bounded, LIMIT-ed query" do
      300.times { |i| PopulationPrincipal.create!(role: i.even? ? "admin" : "member") }

      queries = sql_queries do
        @population = resolve(name: :admins, callable: -> { PopulationPrincipal.where(role: "admin") }, limit: 10)
      end
      selects = queries.grep(/\A\s*SELECT/i)

      expect(@population.records.size).to eq(10)
      expect(selects.size).to eq(1)
      expect(selects.first).to match(/LIMIT/i)
      expect(selects.grep(/COUNT/i)).to be_empty
    end

    it "adds a deterministic primary-key fallback order when the configured relation has none" do
      low = PopulationPrincipal.create!(role: "admin", priority: 5)
      high = PopulationPrincipal.create!(role: "admin", priority: 1)

      population = resolve(name: :admins, callable: -> { PopulationPrincipal.where(role: "admin") })

      expect(population.records.map(&:id)).to eq([low.id, high.id])
    end

    it "preserves the configured relation's own meaningful ordering instead of overriding it" do
      low = PopulationPrincipal.create!(role: "admin", priority: 5)
      high = PopulationPrincipal.create!(role: "admin", priority: 1)

      population = resolve(
        name: :admins, callable: -> { PopulationPrincipal.where(role: "admin").order(priority: :asc) }
      )

      expect(population.records.map(&:id)).to eq([high.id, low.id])
    end
  end
end
# rubocop:enable Metrics/BlockLength
