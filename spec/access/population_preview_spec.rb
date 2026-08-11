# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- mirrors candidate_population_spec.rb and
# principal_sampler_spec.rb so this file's schema/fixtures can never collide
# with any other spec file's global AR::Base connection state.
class PopulationPreviewFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class PreviewUser < PopulationPreviewFixtureRecord
  class << self
    attr_accessor :unauthorized_calls
  end
  self.unauthorized_calls = 0

  def self.admins
    where(role: "admin")
  end

  def self.not_a_relation
    "nope"
  end

  def self.recalculate_totals
    update_all(role: "recalculated")
    all
  end

  def self.broken
    raise "boom"
  end

  def self.writing_then_broken
    update_all(role: "temporarily changed")
    raise "boom after write"
  end

  # Deliberately not passed to PopulationPreview's discovery_result in any
  # spec below -- exists to prove an un-discovered method is never invoked.
  def self.unauthorized_method
    self.unauthorized_calls += 1
    all
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationPreview do
  before(:all) do
    PopulationPreviewFixtureRecord.connection.create_table :preview_users, force: true do |t|
      t.string :role, null: false
    end
  end

  after(:all) do
    PopulationPreviewFixtureRecord.connection.drop_table :preview_users, if_exists: true
  end

  before { PreviewUser.delete_all }

  def discovery_result(candidate_names)
    group = Karst::Access::PopulationDiscovery::ModelGroup.new(
      model_name: "PreviewUser", candidate_names: candidate_names, principal_source: nil
    )
    Karst::Access::PopulationDiscovery::Result.new(model_groups: [group], load_warning: nil)
  end

  def sql_queries(&block)
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  def call(method_name:, candidates:, model_name: "PreviewUser")
    described_class.call(model_name: model_name, method_name: method_name,
                         discovery_result: discovery_result(candidates))
  end

  describe ".call" do
    it "resolves a known candidate to a bounded preview" do
      admin = PreviewUser.create!(role: "admin")

      result = call(method_name: "admins", candidates: [:admins])

      expect(result.resolved).to be(true)
      expect(result.records).to eq([admin])
      expect(result.error).to be_nil
    end

    it "bounds the preview to exactly one LIMIT-ed query, never a COUNT" do
      30.times { |i| PreviewUser.create!(role: i.even? ? "admin" : "member") }

      queries = sql_queries { @result = call(method_name: "admins", candidates: [:admins]) }
      selects = queries.grep(/\A\s*SELECT/i)

      expect(@result.records.size).to eq(described_class::PREVIEW_LIMIT)
      expect(selects.size).to eq(1)
      expect(selects.first).to match(/LIMIT/i)
      expect(selects.grep(/COUNT/i)).to be_empty
    end

    it "reports an unresolved result, without raising, for a candidate that is not a Relation" do
      result = call(method_name: "not_a_relation", candidates: [:not_a_relation])

      expect(result.resolved).to be(false)
      expect(result.records).to eq([])
      expect(result.error).to be_a(String)
    end

    it "rolls back and rejects a candidate class method that writes before returning a Relation" do
      user = PreviewUser.create!(role: "admin")

      result = call(method_name: "recalculate_totals", candidates: [:recalculate_totals])

      expect(result.resolved).to be(false)
      expect(user.reload.role).to eq("admin")
    end

    it "reports an unresolved result, without raising, when the candidate raises" do
      result = call(method_name: "broken", candidates: [:broken])

      expect(result.resolved).to be(false)
      expect(result.records).to eq([])
    end

    it "rolls back a candidate write even when the candidate subsequently raises" do
      user = PreviewUser.create!(role: "admin")

      result = call(method_name: "writing_then_broken", candidates: [:writing_then_broken])

      expect(result.resolved).to be(false)
      expect(user.reload.role).to eq("admin")
    end

    it "never calls a method discovery did not list as a candidate for this model" do
      PreviewUser.unauthorized_calls = 0

      result = call(method_name: "unauthorized_method", candidates: [:admins])

      expect(result.resolved).to be(false)
      expect(PreviewUser.unauthorized_calls).to eq(0)
    end

    it "reports when a discovered scope no longer exists" do
      result = call(method_name: "removed_scope", candidates: [:removed_scope])

      expect(result.resolved).to be(false)
      expect(result.error).to include("no longer exists")
    end

    it "rejects an unknown model name without raising" do
      result = described_class.call(model_name: "NoSuchModel", method_name: "admins",
                                    discovery_result: discovery_result([:admins]))

      expect(result.resolved).to be(false)
    end

    it "reports an empty-but-resolved preview for a currently-empty relation" do
      result = call(method_name: "admins", candidates: [:admins])

      expect(result.resolved).to be(true)
      expect(result.records).to eq([])
    end
  end
end
# rubocop:enable Metrics/BlockLength
