# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order.
class PrincipalSelectionFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class SelectionAuthor < PrincipalSelectionFixtureRecord; end
class SelectionReader < PrincipalSelectionFixtureRecord; end

def selection_source(name, klass, dimensions: {})
  Karst::Access::PrincipalSource.new(name: name, records: -> { klass.all }, dimensions: dimensions)
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PrincipalSelection do
  before(:all) do
    PrincipalSelectionFixtureRecord.connection.create_table :selection_authors, force: true do |t|
      t.boolean :premium, null: false, default: false
    end
    PrincipalSelectionFixtureRecord.connection.create_table :selection_readers, force: true do |t|
      t.string :role, null: false, default: "responder"
    end
  end

  after(:all) do
    PrincipalSelectionFixtureRecord.connection.drop_table :selection_authors, if_exists: true
    PrincipalSelectionFixtureRecord.connection.drop_table :selection_readers, if_exists: true
  end

  before do
    SelectionAuthor.delete_all
    SelectionReader.delete_all
  end

  describe "no sources configured" do
    it "returns an empty result for nil" do
      result = described_class.new(sources: nil, limit: 10).call

      expect(result.principals).to eq([])
      expect(result.candidates).to eq([])
      expect(result.candidate_pool_size).to be_nil
    end

    it "returns an empty result for an empty Hash" do
      result = described_class.new(sources: {}, limit: 10).call
      expect(result.principals).to eq([])
    end
  end

  describe "a single source" do
    it "behaves exactly like calling PrincipalSampler directly, with no source tag" do
      12.times { SelectionAuthor.create!(premium: false) }
      minority = SelectionAuthor.create!(premium: true)
      sources = { authors: selection_source(:authors, SelectionAuthor) }

      direct = Karst::Access::PrincipalSampler.new(source: SelectionAuthor.all, limit: 5).call
      selected = described_class.new(sources: sources, limit: 5).call

      expect(selected.principals.map(&:id)).to eq(direct.principals.map(&:id))
      expect(selected.candidates.flat_map(&:reasons).grep(/\Asource=/)).to be_empty
      expect(selected.principals.map(&:id)).to include(minority.id)
      expect(selected.candidate_pool_size).to eq(direct.candidate_pool_size)
    end
  end

  describe "multiple sources" do
    it "represents both sources within the overall limit and never merges their records together" do
      6.times { SelectionAuthor.create!(premium: false) }
      6.times { SelectionReader.create!(role: "responder") }
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 6).call

      by_class = result.principals.group_by(&:class)
      expect(by_class.keys).to contain_exactly(SelectionAuthor, SelectionReader)
      expect(result.principals.size).to eq(6)
    end

    it "distinguishes overlapping primary keys across sources by class identity" do
      author = SelectionAuthor.create!(id: 999, premium: false)
      reader = SelectionReader.create!(id: 999, role: "responder")
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 5).call

      expect(result.principals).to contain_exactly(author, reader)
    end

    it "guarantees at least one candidate per non-empty source before filling further" do
      20.times { SelectionAuthor.create!(premium: false) }
      SelectionReader.create!(role: "responder")
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 3).call

      expect(result.principals.map(&:class)).to include(SelectionReader)
    end

    it "never lets an empty source starve a non-empty one" do
      5.times { SelectionAuthor.create!(premium: false) }
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 5).call

      expect(result.principals.size).to eq(5)
      expect(result.principals).to all(be_a(SelectionAuthor))
    end

    it "respects the overall limit rather than taking `limit` from every source" do
      20.times { SelectionAuthor.create!(premium: false) }
      20.times { SelectionReader.create!(role: "responder") }
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 7).call

      expect(result.principals.size).to eq(7)
    end

    it "tags each candidate's reasons with its source name only once more than one source is configured" do
      SelectionAuthor.create!(premium: false)
      SelectionReader.create!(role: "responder")
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 5).call

      expect(result.candidates.flat_map(&:reasons)).to include("source=authors", "source=readers")
    end

    it "sums candidate_pool_size across sources that reported one" do
      3.times { SelectionAuthor.create!(premium: false) }
      3.times { SelectionReader.create!(role: "responder") }
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 5, pool_size: 100).call

      expect(result.candidate_pool_size).to eq(200)
    end

    it "sums queries across every sampled source" do
      3.times { SelectionAuthor.create!(premium: false) }
      3.times { SelectionReader.create!(role: "responder") }
      sources = { authors: selection_source(:authors, SelectionAuthor),
                  readers: selection_source(:readers, SelectionReader) }

      result = described_class.new(sources: sources, limit: 5).call

      expect(result.queries).to be > 0
    end

    it "carries each source's configured dimensions through independently" do
      47.times { SelectionAuthor.create!(premium: false) }
      premium_author = SelectionAuthor.create!(premium: true)
      47.times { SelectionReader.create!(role: "responder") }
      admin_reader = SelectionReader.create!(role: "system_admin")
      sources = {
        authors: selection_source(:authors, SelectionAuthor, dimensions: { premium: :premium }),
        readers: selection_source(:readers, SelectionReader, dimensions: { role: :role })
      }

      result = described_class.new(sources: sources, limit: 10).call

      expect(result.principals.map(&:id)).to include(premium_author.id, admin_reader.id)
    end
  end

  describe "a generic Enumerable source alongside an Active Record source" do
    it "keeps each source independently sampled -- bounded-first for the Enumerable, representative for the AR one" do
      SelectionFallbackPrincipal = Struct.new(:id) unless defined?(SelectionFallbackPrincipal)
      enumerable_principals = (1..5).map { |id| SelectionFallbackPrincipal.new(id) }
      5.times { SelectionAuthor.create!(premium: false) }
      sources = {
        legacy: Karst::Access::PrincipalSource.new(name: :legacy, records: -> { enumerable_principals }),
        authors: selection_source(:authors, SelectionAuthor)
      }

      result = described_class.new(sources: sources, limit: 6).call

      expect(result.principals.map(&:class).uniq).to contain_exactly(SelectionFallbackPrincipal, SelectionAuthor)
    end
  end
end
# rubocop:enable Metrics/BlockLength
