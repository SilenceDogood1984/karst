# frozen_string_literal: true

require "spec_helper"
require "logger"
require "rails"
require "action_controller/railtie"
require "action_dispatch/testing/integration"
require "active_record"
require "karst"

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order. Mirrors candidate_population_spec.rb.
class SearchFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class SearchUser < SearchFixtureRecord
end

# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe Karst::Access::Search do
  # Records which principal ids each probe actually executed a request for,
  # so "was this population evaluated at all" is asserted against observed
  # requests rather than inferred from the result shape.
  def probed
    PROBED
  end

  PROBED = [] # rubocop:disable Style/MutableConstant

  class SearchResponse
    attr_accessor :status, :location
  end

  class SearchSession
    attr_reader :response

    def initialize(_application)
      @response = SearchResponse.new
      @identity = nil
    end

    attr_writer :identity

    def get(_path)
      PROBED << @identity.id
      @response.status = USABLE_IDS.include?(@identity.id) ? 200 : 302
      return unless @response.status == 302

      @response.location = "/login"
      ActiveSupport::Notifications.instrument("halted_callback.action_controller", filter: :authorize_admin)
    end
  end

  USABLE_IDS = [] # rubocop:disable Style/MutableConstant

  before(:all) do
    SearchFixtureRecord.connection.create_table :search_users, force: true do |t|
      t.string :role, null: false
      t.datetime :created_at
    end
  end

  after(:all) { SearchFixtureRecord.connection.drop_table :search_users, if_exists: true }

  before do
    SearchUser.delete_all
    PROBED.clear
    USABLE_IDS.clear
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    allow(ActiveRecord::Base).to receive(:transaction) do |requires_new:, &block|
      expect(requires_new).to be(true)
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    stub_const("ActionDispatch::Integration::Session", SearchSession)
    Karst.config.assume_identity = ->(session, principal) { session.identity = principal }
    Karst.config.clear_identity = ->(session) { session.identity = nil }
    Karst.config.access_sweep_limit = 5
    Karst.config.population_retry_limit = 3
  end

  after do
    Karst.config.assume_identity = nil
    Karst.config.clear_identity = nil
    Karst.config.access_sweep_limit = 25
    Karst.config.population_retry_limit = 3
  end

  def create_user(role:)
    SearchUser.create!(role: role, created_at: Time.now)
  end

  def sources(populations)
    { default: Karst::Access::PrincipalSource.new(name: :default, records: -> { SearchUser.where(role: "plain") },
                                                  populations: populations) }
  end

  def search(populations, application: Object.new)
    described_class.new(path: "/admin/imports", sources: sources(populations), application: application).call
  end

  def states(result)
    result.attempts.to_h { |attempt| [attempt.name, attempt.state] }
  end

  # 1
  it "never evaluates any population when the ordinary sample already found a usable user" do
    plain = create_user(role: "plain")
    USABLE_IDS << plain.id
    admin = create_user(role: "admin")
    evaluated = []

    result = search({ system_admins: lambda {
      evaluated << :system_admins
      SearchUser.where(role: "admin")
    } })

    expect(result.attempts).to be_empty
    expect(evaluated).to be_empty
    expect(probed).to eq([plain.id])
    expect(probed).not_to include(admin.id)
  end

  # 2
  it "returns the verified user from the first successful population and never evaluates later ones" do
    create_user(role: "plain")
    admin = create_user(role: "admin")
    auditor = create_user(role: "auditor")
    USABLE_IDS << admin.id

    result = search({ system_admins: -> { SearchUser.where(role: "admin") },
                      auditors: -> { SearchUser.where(role: "auditor") } })

    expect(states(result)).to eq(system_admins: :usable, auditors: :skipped)
    expect(probed).to include(admin.id)
    expect(probed).not_to include(auditor.id)

    usable = result.all_outcomes.select { |outcome| outcome.status == 200 }
    expect(usable.map { |outcome| outcome.principal.id }).to eq([admin.id])
    expect(usable.first.sampling_reasons).to eq(["population=system_admins"])
  end

  # 3
  it "continues to the next population when the first produced no usable user" do
    create_user(role: "plain")
    admin = create_user(role: "admin")
    auditor = create_user(role: "auditor")
    USABLE_IDS << auditor.id

    result = search({ system_admins: -> { SearchUser.where(role: "admin") },
                      auditors: -> { SearchUser.where(role: "auditor") } })

    expect(states(result)).to eq(system_admins: :no_match, auditors: :usable)
    expect(probed).to include(admin.id, auditor.id)
  end

  # 4
  it "retains grouped observed evidence from every population when none succeeds" do
    create_user(role: "plain")
    admin = create_user(role: "admin")
    auditor = create_user(role: "auditor")

    result = search({ system_admins: -> { SearchUser.where(role: "admin") },
                      auditors: -> { SearchUser.where(role: "auditor") } })

    expect(states(result)).to eq(system_admins: :no_match, auditors: :no_match)
    expect(result.attempted.size).to eq(2)
    expect(result.all_outcomes.map { |outcome| outcome.principal.id }).to include(admin.id, auditor.id)
    expect(result.all_outcomes.map(&:status).uniq).to eq([302])
  end

  # 5
  it "reports an empty population honestly without probing anything" do
    create_user(role: "plain")

    result = search({ system_admins: -> { SearchUser.where(role: "admin") } })

    expect(states(result)).to eq(system_admins: :empty)
    expect(result.attempted).to be_empty
  end

  # 6
  it "does not crash the analysis when a population callable raises" do
    create_user(role: "plain")
    admin = create_user(role: "admin")
    USABLE_IDS << admin.id

    result = search({ broken: -> { raise "boom" },
                      system_admins: -> { SearchUser.where(role: "admin") } })

    expect(states(result)).to eq(broken: :unresolved, system_admins: :usable)
    expect(result.attempts.first.error).to include("did not resolve")
  end

  it "reports a population returning a non-relation as unresolved rather than raising" do
    create_user(role: "plain")

    result = search({ bad_shape: -> { [1, 2, 3] } })

    expect(states(result)).to eq(bad_shape: :unresolved)
  end

  # 7
  it "never re-probes a user already tested in the sample or an earlier population" do
    plain = create_user(role: "plain")
    admin = create_user(role: "admin")

    result = search({ everyone: -> { SearchUser.where(role: %w[plain admin]) },
                      admins_again: -> { SearchUser.where(role: "admin") } })

    expect(probed.tally.values).to all(eq(1))
    expect(probed).to contain_exactly(plain.id, admin.id)
    expect(states(result)).to eq(everyone: :no_match, admins_again: :already_tried)
  end

  it "still reaches a full population candidate cap of fresh users despite duplicates" do
    plain = create_user(role: "plain")
    admins = Array.new(3) { create_user(role: "admin") }

    search({ mixed: -> { SearchUser.where(role: %w[plain admin]).order(:id) } })

    expect(probed).to eq([plain.id] + admins.map(&:id))
  end

  # 8
  it "never exceeds population_retry_limit records for a single population" do
    create_user(role: "plain")
    admins = Array.new(5) { create_user(role: "admin") }
    Karst.config.population_retry_limit = 2

    result = search({ system_admins: -> { SearchUser.where(role: "admin").order(:id) } })

    expect(result.attempts.first.result.outcomes.size).to eq(2)
    expect(probed.last(2)).to eq(admins.first(2).map(&:id))
  end

  it "stops trying populations once the total retry request budget is reached" do
    create_user(role: "plain")
    %w[a b c].each { |role| 2.times { create_user(role: role) } }
    Karst.config.access_sweep_limit = 3
    Karst.config.population_retry_limit = 2

    result = search({ a: -> { SearchUser.where(role: "a") }, b: -> { SearchUser.where(role: "b") },
                      c: -> { SearchUser.where(role: "c") } })

    # 1 sampled user, then budget 3: population a takes 2, b takes the last 1, c cannot run.
    expect(states(result)).to eq(a: :no_match, b: :no_match, c: :budget_exhausted)
    expect(result.population_request_count).to eq(3)
  end

  # 9
  it "preserves halted callback evidence through the orchestration layer" do
    create_user(role: "plain")
    create_user(role: "admin")

    result = search({ system_admins: -> { SearchUser.where(role: "admin") } })

    population_outcomes = result.attempts.first.result.outcomes
    expect(population_outcomes.map(&:halted_callback)).to eq([:authorize_admin])
    expect(result.initial.outcomes.map(&:halted_callback)).to eq([:authorize_admin])
  end

  # 10
  it "preserves rollback and write isolation evidence through the orchestration layer" do
    create_user(role: "plain")
    create_user(role: "admin")

    result = search({ system_admins: -> { SearchUser.where(role: "admin") } })

    expect(result.attempts.first.result.database_isolation).to eq(:same_connection_rollback_attempted)
    expect(result.all_outcomes).to all(have_attributes(database_rollback_attempted: true))
    expect(result.all_outcomes).to all(have_attributes(writes_observed: false))
  end

  # 11
  it "behaves exactly like an ordinary sweep when no population is configured" do
    plain = create_user(role: "plain")

    result = search({})

    expect(result.attempts).to be_empty
    expect(probed).to eq([plain.id])
    expect(result.all_outcomes).to eq(result.initial.outcomes)
  end

  # 12
  it "only ever executes configured populations, never a merely discovered class method" do
    create_user(role: "plain")
    create_user(role: "admin")
    allow(SearchUser).to receive(:respond_to?).and_call_original

    result = search({})

    # SearchUser.where(role: "admin") is discoverable as a scope-shaped
    # method, but nothing unconfigured is resolved or probed.
    expect(result.attempts).to be_empty
    expect(probed.size).to eq(1)
  end

  it "exposes the total request count and elapsed evidence for both stages" do
    create_user(role: "plain")
    admin = create_user(role: "admin")
    USABLE_IDS << admin.id

    result = search({ system_admins: -> { SearchUser.where(role: "admin") } })

    expect(result.path).to eq("/admin/imports")
    expect(result.http_method).to eq("GET")
    expect(result.population_request_count).to eq(1)
    expect(result.all_outcomes.size).to eq(2)
  end

  it "resolves populations in configuration order, not by name" do
    create_user(role: "plain")
    zeta = create_user(role: "zeta")
    alpha = create_user(role: "alpha")
    USABLE_IDS << alpha.id

    result = search({ zeta: -> { SearchUser.where(role: "zeta") },
                      alpha: -> { SearchUser.where(role: "alpha") } })

    expect(result.attempts.map(&:name)).to eq(%i[zeta alpha])
    expect(probed).to eq([SearchUser.find_by(role: "plain").id, zeta.id, alpha.id])
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
