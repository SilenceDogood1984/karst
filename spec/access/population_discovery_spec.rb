# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

module PopDisco
  # Some deliberately unusual method names below prove class-method naming
  # heuristics no longer participate in discovery.
  # rubocop:disable Naming/PredicateMethod, Style/Lambda
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class User < Record
    DYNAMIC_SCOPE_NAME = :dynamic_admins

    class << self
      attr_accessor :scope_body_calls
    end
    self.scope_body_calls = 0

    scope :admins, -> { where(is_admin: true) }
    scope :active, -> {
      where(active: true)
    }
    scope(
      :auditors,
      -> { where(role: "auditor") }
    )
    scope :renewable, lambda {
      where(status: "active")
    }
    scope :tracked, -> {
      self.scope_body_calls += 1
      all
    }
    scope :for_org, ->(org) { where(organization: org) }
    scope :between, ->(from, to) { where(created_at: from..to) }
    scope :optional, ->(value = nil) { where(value: value) }
    scope :splatted, ->(*values) { where(value: values) }
    scope :keyword, ->(role:) { where(role: role) }
    scope DYNAMIC_SCOPE_NAME, -> { all }

    def self.some_report
      where(active: true)
    end

    def self.zero_argument_method
      []
    end

    def self.irrelevant?
      true
    end

    def self.irrelevant!
      true
    end

    def self.irrelevant=(value)
      value
    end
  end

  class Subscription < Record
    scope :cancelled, -> { where(status: "cancelled") }
  end
  # rubocop:enable Naming/PredicateMethod, Style/Lambda
end

module ActiveStorage
  class PopDiscoBlob < ActiveRecord::Base
    scope :recent, -> { all }
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PopulationDiscovery do
  def fixture_groups(result)
    result.model_groups.select { |group| group.model_name.start_with?("PopDisco::") }
  end

  def fixture_group(result, name)
    fixture_groups(result).find { |group| group.model_name == "PopDisco::#{name}" }
  end

  describe "#call" do
    it "discovers one-line, multiline, parenthesized, arrow, and lambda scopes" do
      names = fixture_group(described_class.new.call, "User").candidate_names

      expect(names).to include(:admins, :active, :auditors, :renewable)
    end

    it "discovers multiple scopes across multiple models" do
      result = described_class.new.call

      expect(fixture_group(result, "User").candidate_names).to include(:admins, :auditors)
      expect(fixture_group(result, "Subscription").candidate_names).to eq([:cancelled])
    end

    it "excludes required, optional, splat, and keyword parameters conservatively" do
      names = fixture_group(described_class.new.call, "User").candidate_names

      expect(names).not_to include(:for_org, :between, :optional, :splatted, :keyword)
    end

    it "excludes dynamically named scopes" do
      expect(fixture_group(described_class.new.call, "User").candidate_names).not_to include(:dynamic_admins)
    end

    it "never considers ordinary class methods, regardless of return or name shape" do
      names = fixture_group(described_class.new.call, "User").candidate_names

      expect(names).not_to include(:some_report, :zero_argument_method, :irrelevant?, :irrelevant!, :irrelevant=)
    end

    it "excludes abstract, anonymous, and framework models" do
      Class.new(PopDisco::Record)
      result = described_class.new.call

      expect(fixture_groups(result).map(&:model_name)).not_to include("PopDisco::Record", nil)
      expect(result.model_groups.map(&:model_name)).not_to include("ActiveStorage::PopDiscoBlob")
    end

    it "does not invoke a discovered scope body" do
      PopDisco::User.scope_body_calls = 0

      expect(fixture_group(described_class.new.call, "User").candidate_names).to include(:tracked)
      expect(PopDisco::User.scope_body_calls).to eq(0)
    end

    it "issues no SQL queries" do
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.new.call }

      expect(queries).to be_empty
    end

    it "associates matching configured principal-source metadata" do
      Karst.config.principal_sources = { members: -> { PopDisco::User } }

      expect(fixture_group(described_class.new.call, "User").principal_source).to eq(:members)
    end
  end

  describe "PopulationDiscovery::Result#candidates" do
    it "flattens model groups into scope candidates" do
      candidates = described_class.new.call.candidates.select { |candidate| candidate.model_name == "PopDisco::User" }

      expect(candidates.map(&:method_name)).to include(:admins)
      expect(candidates.first).to be_a(described_class::Candidate)
    end
  end
end
# rubocop:enable Metrics/BlockLength
