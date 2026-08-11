# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A unique prefix (PopDisco::) so assertions can filter
# ActiveRecord::Base.descendants down to exactly the fixtures this file
# defines, regardless of what other spec files' own fixture models happen to
# already be loaded in this process (spec order is randomized, and Ruby
# classes never unload). No connection is established -- discovery never
# queries a row, only introspects already-loaded class/method metadata.
module PopDisco
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class User < Record
    class << self
      attr_accessor :tracked_scope_calls
    end
    self.tracked_scope_calls = 0

    def self.system_admins
      []
    end

    def self.tracked_scope
      self.tracked_scope_calls += 1
      []
    end

    def self.by_role(role)
      [role]
    end

    def self.destroy_everything!
      []
    end

    def self.admin?
      false
    end

    def self.role=(value)
      value
    end

    class << self
      private

      def hidden_scope
        []
      end
    end
  end

  class Subscription < Record
    def self.renewable
      []
    end
  end
end

module ActiveStorage
  class PopDiscoBlob < ActiveRecord::Base
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
    it "discovers application models grouped with their candidate method names" do
      result = described_class.new.call

      expect(fixture_group(result, "User").candidate_names).to include(:system_admins, :tracked_scope)
      expect(fixture_group(result, "Subscription").candidate_names).to include(:renewable)
    end

    it "excludes the abstract base class" do
      result = described_class.new.call

      expect(fixture_groups(result).map(&:model_name)).not_to include("PopDisco::Record")
    end

    it "excludes methods that require an argument" do
      result = described_class.new.call

      expect(fixture_group(result, "User").candidate_names).not_to include(:by_role)
    end

    it "excludes bang, predicate, and writer-shaped method names" do
      result = described_class.new.call

      names = fixture_group(result, "User").candidate_names
      expect(names).not_to include(:destroy_everything!, :admin?, :role=)
    end

    it "excludes private class methods" do
      result = described_class.new.call

      expect(fixture_group(result, "User").candidate_names).not_to include(:hidden_scope)
    end

    it "excludes framework-namespaced models" do
      result = described_class.new.call

      expect(result.model_groups.map(&:model_name)).not_to include("ActiveStorage::PopDiscoBlob")
    end

    it "excludes an anonymous class without raising" do
      Class.new(PopDisco::Record) # never assigned to a constant -- klass.name is nil

      result = nil
      expect { result = described_class.new.call }.not_to raise_error
      expect(result.model_groups.map(&:model_name)).not_to include(nil)
    end

    it "never executes a discovered candidate method" do
      PopDisco::User.tracked_scope_calls = 0

      result = described_class.new.call

      expect(fixture_group(result, "User").candidate_names).to include(:tracked_scope)
      expect(PopDisco::User.tracked_scope_calls).to eq(0)
    end

    it "issues no SQL queries" do
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.new.call }

      expect(queries).to be_empty
    end

    it "reports no principal_source when no principal source is configured" do
      Karst.config.principals = nil
      Karst.config.principal_sources = nil

      result = described_class.new.call

      expect(fixture_group(result, "User").principal_source).to be_nil
    end

    it "matches a model against config.principals wrapped as the implicit :default source" do
      Karst.config.principals = -> { PopDisco::User }

      result = described_class.new.call

      expect(fixture_group(result, "User").principal_source).to eq(:default)
      expect(fixture_group(result, "Subscription").principal_source).to be_nil
    end

    it "matches a model against an explicitly named config.principal_sources entry" do
      Karst.config.principal_sources = { members: -> { PopDisco::User } }

      result = described_class.new.call

      expect(fixture_group(result, "User").principal_source).to eq(:members)
    end
  end

  describe "PopulationDiscovery::Result#candidates" do
    it "flattens every model group into individual Candidate entries" do
      result = described_class.new.call

      user_candidates = result.candidates.select { |c| c.model_name == "PopDisco::User" }
      expect(user_candidates.map(&:method_name)).to include(:system_admins)
      expect(user_candidates.first).to be_a(described_class::Candidate)
    end
  end
end
# rubocop:enable Metrics/BlockLength
