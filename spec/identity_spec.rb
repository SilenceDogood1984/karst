# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_record"
require "karst"

KarstIdentitySpecPrincipal = Struct.new(:id)

# A dedicated, isolated Active Record connection -- deliberately not
# ActiveRecord::Base itself -- so this file's schema/fixtures can never
# collide with any other spec file's global AR::Base connection state,
# regardless of randomized spec order.
class IdentitySpecFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class KarstIdentityUser < IdentitySpecFixtureRecord
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Identity do
  after do
    Karst.configure do |config|
      config.principals = nil
      config.assume_identity = nil
      config.clear_identity = nil
      config.principal_label = nil
    end
  end

  it "leaves an unavailable principal source untouched until requested" do
    expect(Karst.config.principals).to be_nil
    expect { described_class.principals }.to raise_error(Karst::Identity::Unavailable, /principal source/)
  end

  it "returns a configured source result without enumerating it" do
    relation = Object.new
    Karst.config.principals = -> { relation }

    expect(described_class.principals).to equal(relation)
  end

  it "validates a principal source only when used" do
    Karst.config.principals = []

    expect { described_class.principals }.to raise_error(Karst::Identity::ConfigurationError, /callable/)
  end

  it "builds a PII-safe descriptor without calling arbitrary to_s" do
    principal = KarstIdentitySpecPrincipal.new(123)
    allow(principal).to receive(:to_s).and_raise("must not be called")

    descriptor = described_class.describe(principal)

    expect(descriptor).to have_attributes(
      model_name: "KarstIdentitySpecPrincipal", id: 123, display_label: "KarstIdentitySpecPrincipal #123"
    )
    expect(descriptor).to be_frozen
  end

  it "uses an explicitly configured label only when describing" do
    calls = 0
    Karst.config.principal_label = lambda do |principal|
      calls += 1
      "Test account #{principal.id}"
    end
    principal = KarstIdentitySpecPrincipal.new(4)
    expect(calls).to eq(0)

    expect(described_class.describe(principal).display_label).to eq("Test account 4")
    expect(calls).to eq(1)
  end

  it "clears an assumed identity after success and after a request exception" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = ->(target, principal) { target.principal = principal }
    Karst.config.clear_identity = ->(target) { target.principal = nil }
    principal = KarstIdentitySpecPrincipal.new(1)

    expect(described_class.with(session, principal) { session.principal }).to equal(principal)
    expect(session.principal).to be_nil
    expect { described_class.with(session, principal) { raise "request failed" } }.to raise_error("request failed")
    expect(session.principal).to be_nil
  end

  it "clears partial identity when the assumption hook itself raises" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = lambda do |target, principal|
      target.principal = principal
      raise "setup failed"
    end
    Karst.config.clear_identity = ->(target) { target.principal = nil }

    expect { described_class.with(session, KarstIdentitySpecPrincipal.new(1)) { nil } }.to raise_error("setup failed")
    expect(session.principal).to be_nil
  end

  it "does not leak sequential principals and supports an explicit clear" do
    session = Struct.new(:principal).new
    Karst.config.assume_identity = ->(target, principal) { target.principal = principal }
    Karst.config.clear_identity = ->(target) { target.principal = nil }
    first = KarstIdentitySpecPrincipal.new(1)
    second = KarstIdentitySpecPrincipal.new(2)

    expect(described_class.with(session, first) { session.principal.id }).to eq(1)
    expect(described_class.with(session, second) { session.principal.id }).to eq(2)
    session.principal = first
    described_class.clear(session)
    expect(session.principal).to be_nil
  end

  it "fails loudly when configured hooks are incomplete" do
    Karst.config.assume_identity = ->(_session, _principal) {}

    expect { described_class.with(Object.new, KarstIdentitySpecPrincipal.new(1)) { nil } }
      .to raise_error(Karst::Identity::ConfigurationError, /both be callable/)
  end

  it "reports identity as unavailable when Warden is absent" do
    hide_const("Warden") if defined?(Warden)

    expect { described_class.clear(Object.new) }.to raise_error(Karst::Identity::Unavailable, /Warden is unavailable/)
  end

  it "uses public APIs on an existing Warden proxy when Warden is present" do
    stub_const("Warden::Manager", Class.new)
    proxy = instance_double("Warden proxy")
    allow(proxy).to receive(:set_user)
    allow(proxy).to receive(:logout)
    principal = KarstIdentitySpecPrincipal.new(8)

    described_class.with({ "warden" => proxy }, principal) { nil }

    expect(proxy).to have_received(:set_user).with(principal)
    expect(proxy).to have_received(:logout)
  end

  # Covers the ~500,000-row dogfood case: resolving a submitted model/id
  # against config.principals must never enumerate the source, and must
  # never resolve anything outside the exact relation the application
  # configured.
  describe "scoped resolution against an Active Record principal source" do
    before(:all) do
      IdentitySpecFixtureRecord.connection.create_table :karst_identity_users, force: true do |t|
        t.integer :tenant_id, null: false
        t.datetime :created_at
      end
    end

    after(:all) do
      IdentitySpecFixtureRecord.connection.drop_table :karst_identity_users, if_exists: true
    end

    before { KarstIdentityUser.delete_all }

    def sql_queries(&block)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    it "resolves a principal via a single scoped primary-key query instead of enumerating the source" do
      target = KarstIdentityUser.create!(tenant_id: 1)
      299.times { |i| KarstIdentityUser.create!(tenant_id: i + 2) }
      Karst.config.principals = -> { KarstIdentityUser.all }

      resolved = nil
      queries = sql_queries { resolved = described_class.resolve(model_name: "KarstIdentityUser", id: target.id) }

      expect(resolved).to eq(target)
      expect(queries.grep(/\ASELECT/i).size).to eq(1)
    end

    it "resolves an older principal inside config.principals even though it sits outside any sampling pool" do
      old_principal = KarstIdentityUser.create!(tenant_id: 1, created_at: 2.years.ago)
      50.times { |i| KarstIdentityUser.create!(tenant_id: i + 2, created_at: Time.current) }
      Karst.config.principals = -> { KarstIdentityUser.all }

      resolved = described_class.resolve(model_name: "KarstIdentityUser", id: old_principal.id)

      expect(resolved).to eq(old_principal)
    end

    it "cannot resolve a principal outside a scoped config.principals relation" do
      in_scope = KarstIdentityUser.create!(tenant_id: 7)
      out_of_scope = KarstIdentityUser.create!(tenant_id: 9)
      Karst.config.principals = -> { KarstIdentityUser.where(tenant_id: 7) }

      expect(described_class.resolve(model_name: "KarstIdentityUser", id: in_scope.id)).to eq(in_scope)
      expect(described_class.resolve(model_name: "KarstIdentityUser", id: out_of_scope.id)).to be_nil
    end

    it "never queries when the requested model name does not match the configured source" do
      user = KarstIdentityUser.create!(tenant_id: 1)
      Karst.config.principals = -> { KarstIdentityUser.all }

      resolved = :unset
      queries = sql_queries { resolved = described_class.resolve(model_name: "SomeOtherModel", id: user.id) }

      expect(resolved).to be_nil
      expect(queries).to be_empty
    end

    it "returns nil for a submitted id that does not exist within the source, without enumerating it" do
      KarstIdentityUser.create!(tenant_id: 1)
      Karst.config.principals = -> { KarstIdentityUser.all }

      expect(described_class.resolve(model_name: "KarstIdentityUser", id: -1)).to be_nil
    end

    it "accepts a bare Active Record class exactly like an already-scoped relation" do
      target = KarstIdentityUser.create!(tenant_id: 1)
      Karst.config.principals = -> { KarstIdentityUser }

      expect(described_class.resolve(model_name: "KarstIdentityUser", id: target.id)).to eq(target)
    end
  end

  describe "principal_sources" do
    it "is unavailable when neither config.principals nor config.principal_sources is configured" do
      expect { described_class.principal_sources }.to raise_error(Karst::Identity::Unavailable, /principal source/)
    end

    it "wraps a bare config.principals as one implicit :default source" do
      Karst.config.principals = -> { [] }

      expect(described_class.principal_sources.keys).to eq([:default])
    end

    it "reflects an explicit config.principal_sources" do
      Karst.config.principal_sources = { authors: -> { [] }, readers: -> { [] } }

      expect(described_class.principal_sources.keys).to eq(%i[authors readers])
    end
  end

  describe "resolve across multiple configured sources" do
    AuthorPrincipal = Struct.new(:id) unless defined?(AuthorPrincipal)
    ReaderPrincipal = Struct.new(:id) unless defined?(ReaderPrincipal)

    after { Karst.config.principal_sources = nil }

    it "resolves a model that only the second configured source exposes" do
      author = AuthorPrincipal.new(1)
      reader = ReaderPrincipal.new(1)
      Karst.config.principal_sources = { authors: -> { [author] }, readers: -> { [reader] } }

      expect(described_class.resolve(model_name: "ReaderPrincipal", id: 1)).to equal(reader)
    end

    it "distinguishes overlapping ids across sources by model name, never returning the wrong model" do
      author = AuthorPrincipal.new(1)
      reader = ReaderPrincipal.new(1)
      Karst.config.principal_sources = { authors: -> { [author] }, readers: -> { [reader] } }

      expect(described_class.resolve(model_name: "AuthorPrincipal", id: 1)).to equal(author)
      expect(described_class.resolve(model_name: "ReaderPrincipal", id: 1)).to equal(reader)
    end

    it "resolves nothing for a model name that matches no configured source, without constantizing it" do
      Karst.config.principal_sources = { authors: -> { [AuthorPrincipal.new(1)] } }

      expect(described_class.resolve(model_name: "System::Admin", id: 1)).to be_nil
    end

    it "stops at the first matching source without ever evaluating a later configured source" do
      later_source_evaluated = false
      later_source = lambda do
        later_source_evaluated = true
        [ReaderPrincipal.new(1)]
      end
      Karst.config.principal_sources = { authors: -> { [AuthorPrincipal.new(1)] }, readers: later_source }

      described_class.resolve(model_name: "AuthorPrincipal", id: 1)

      expect(later_source_evaluated).to be(false)
    end
  end
end
# rubocop:enable Metrics/BlockLength
