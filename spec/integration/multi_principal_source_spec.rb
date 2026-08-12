# frozen_string_literal: true

require "spec_helper"
require "rails"
require "action_controller/railtie"
require "action_dispatch/testing/integration"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order.
class MultiSourceFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class MultiSourceAuthor < MultiSourceFixtureRecord; end
class MultiSourceReader < MultiSourceFixtureRecord; end

# Exercises Karst::Access::PrincipalSelection end to end against real
# Active Record sources and a real Karst::Access::Sweep, the same way
# spec/access/sweep_spec.rb exercises Sweep alone: a stubbed
# ActionDispatch::Integration::Session stands in for a real Rails
# application, since this file is proving multi-source *sampling and
# resolution* semantics, not Rails routing/session-middleware behavior --
# spec/integration/access_sweep_spec.rb already covers that separately
# against a real Rails::Application.
# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe "multiple configured principal sources" do
  class MultiSourceResponse
    attr_accessor :status, :location
  end

  class MultiSourceSession
    attr_reader :response

    def initialize(_application)
      @response = MultiSourceResponse.new
    end

    attr_writer :identity

    def get(_path)
      @response.status = @identity.behavior == "forbidden" ? 403 : 200
    end
  end

  before(:all) do
    MultiSourceFixtureRecord.connection.create_table :multi_source_authors, force: true do |t|
      t.string :behavior, null: false, default: "ok"
      t.boolean :premium, null: false, default: false
    end
    MultiSourceFixtureRecord.connection.create_table :multi_source_readers, force: true do |t|
      t.string :behavior, null: false, default: "ok"
      t.string :role, null: false, default: "responder"
    end
  end

  after(:all) do
    MultiSourceFixtureRecord.connection.drop_table :multi_source_authors, if_exists: true
    MultiSourceFixtureRecord.connection.drop_table :multi_source_readers, if_exists: true
  end

  before do
    MultiSourceAuthor.delete_all
    MultiSourceReader.delete_all
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(ActiveRecord::Base).to receive(:transaction) do |requires_new:, &block|
      expect(requires_new).to be(true)
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    stub_const("ActionDispatch::Integration::Session", MultiSourceSession)
    Karst.config.assume_identity = ->(session, principal) { session.identity = principal }
    Karst.config.clear_identity = ->(session) { session.identity = nil }
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
    Karst.config.principal_sources = nil
    Karst.config.access_sweep_limit = 25
    Karst.config.principal_candidate_pool_size = 1_000
  end

  def sql_queries(&block)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  it "analyzes candidates from both sources without materializing them together, honoring the overall " \
     "sweep limit and preserving each principal's own model identity" do
    12.times { MultiSourceAuthor.create!(behavior: "ok") }
    12.times { MultiSourceReader.create!(behavior: "ok") }
    Karst.config.principal_sources = {
      authors: -> { MultiSourceAuthor.all }, readers: -> { MultiSourceReader.all }
    }
    Karst.config.access_sweep_limit = 6

    sampled = Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 6).call
    result = Karst::Access::Sweep.new(
      path: "/documents", principals: sampled.principals, application: Object.new
    ).call

    expect(result.outcomes.size).to eq(6)
    classes = result.outcomes.map { |outcome| outcome.principal.model_name }.uniq
    expect(classes).to contain_exactly("MultiSourceAuthor", "MultiSourceReader")
  end

  it "distinguishes an Author and a Reader that share the same numeric id" do
    author = MultiSourceAuthor.create!(id: 500, behavior: "ok")
    reader = MultiSourceReader.create!(id: 500, behavior: "forbidden")
    Karst.config.principal_sources = {
      authors: -> { MultiSourceAuthor.all }, readers: -> { MultiSourceReader.all }
    }

    sampled = Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 2).call
    result = Karst::Access::Sweep.new(
      path: "/documents", principals: sampled.principals, application: Object.new
    ).call

    expect(result.outcomes.map(&:principal).map(&:model_name)).to contain_exactly("MultiSourceAuthor",
                                                                                  "MultiSourceReader")
    expect(result.outcomes.find { |o| o.principal.model_name == "MultiSourceAuthor" }.status).to eq(200)
    expect(result.outcomes.find { |o| o.principal.model_name == "MultiSourceReader" }.status).to eq(403)

    expect(Karst::Identity.resolve(model_name: "MultiSourceAuthor", id: 500)).to eq(author)
    expect(Karst::Identity.resolve(model_name: "MultiSourceReader", id: 500)).to eq(reader)
  end

  it "threads PrincipalSampler's schema-derived evidence through Sweep's outcomes, tagged by source" do
    47.times { MultiSourceAuthor.create!(behavior: "ok", premium: false) }
    premium_author = MultiSourceAuthor.create!(behavior: "ok", premium: true)
    47.times { MultiSourceReader.create!(behavior: "ok", role: "responder") }
    admin_reader = MultiSourceReader.create!(behavior: "ok", role: "system_admin")
    Karst.config.principal_sources = {
      authors: { records: -> { MultiSourceAuthor.all } },
      readers: { records: -> { MultiSourceReader.all } }
    }
    Karst.config.access_sweep_limit = 10

    sampled = Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 10).call
    reasons = sampled.candidates.to_h { |c| [c.principal, c.reasons] }
    result = Karst::Access::Sweep.new(
      path: "/documents", principals: sampled.principals, sampling_reasons: reasons, application: Object.new
    ).call

    premium_outcome = result.outcomes.find do |o|
      o.principal.id == premium_author.id && o.principal.model_name == "MultiSourceAuthor"
    end
    admin_outcome = result.outcomes.find do |o|
      o.principal.id == admin_reader.id && o.principal.model_name == "MultiSourceReader"
    end
    expect(premium_outcome.sampling_reasons).to include("premium=true", "source=authors")
    expect(admin_outcome.sampling_reasons).to include("role=system_admin", "source=readers")
  end

  it "keeps query volume flat per source as each underlying table grows, without loading either whole table" do
    Karst.config.principal_sources = {
      authors: -> { MultiSourceAuthor.all }, readers: -> { MultiSourceReader.all }
    }

    populate = lambda do |count|
      MultiSourceAuthor.insert_all(Array.new(count) { |i| { behavior: "ok", premium: i.even? } })
      MultiSourceReader.insert_all(Array.new(count) { |i| { behavior: "ok", role: i.even? ? "a" : "b" } })
    end

    populate.call(150)
    small_queries = sql_queries do
      Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 10).call
    end.size

    MultiSourceAuthor.delete_all
    MultiSourceReader.delete_all
    populate.call(4_000)
    large_queries = sql_queries do
      Karst::Access::PrincipalSelection.new(sources: Karst::Identity.principal_sources, limit: 10).call
    end.size

    expect(large_queries).to eq(small_queries)
  end

  it "bounds each source's own candidate pool independently -- a small pool_size on one source does not " \
     "starve the other" do
    600.times { |i| MultiSourceAuthor.create!(behavior: "ok", premium: i.even?) }
    5.times { MultiSourceReader.create!(behavior: "ok") }
    Karst.config.principal_sources = {
      authors: -> { MultiSourceAuthor.all }, readers: -> { MultiSourceReader.all }
    }

    sampled = Karst::Access::PrincipalSelection.new(
      sources: Karst::Identity.principal_sources, limit: 10, pool_size: 30
    ).call

    expect(sampled.candidate_pool_size).to eq(60)
    expect(sampled.principals.map(&:class)).to include(MultiSourceReader)
  end

  it "resolves an Identity.resolve request only within the matching source, never touching a later one " \
     "once an earlier source already resolved it" do
    later_source_evaluated = false
    MultiSourceAuthor.create!(id: 1, behavior: "ok")
    Karst.config.principal_sources = {
      authors: -> { MultiSourceAuthor.all },
      readers: lambda {
        later_source_evaluated = true
        MultiSourceReader.all
      }
    }

    resolved = Karst::Identity.resolve(model_name: "MultiSourceAuthor", id: 1)

    expect(resolved).to eq(MultiSourceAuthor.find(1))
    expect(later_source_evaluated).to be(false)
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
