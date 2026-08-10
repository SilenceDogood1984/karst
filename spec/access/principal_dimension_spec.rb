# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe Karst::Access::PrincipalDimension do
  DimensionSpecPrincipal = Struct.new(:role, :system_admin, :plan) do
    def system_admin?
      system_admin
    end
  end

  describe "accessor kinds" do
    it "reads a plain attribute" do
      dimension = described_class.new(name: :role, accessor: :role)
      principal = DimensionSpecPrincipal.new("group_admin", false, nil)

      expect(dimension.value_for(principal)).to eq("group_admin")
      expect(dimension.reason(principal)).to eq("role=group_admin")
    end

    it "reads a boolean predicate method" do
      dimension = described_class.new(name: :system_admin, accessor: :system_admin?)
      principal = DimensionSpecPrincipal.new("responder", true, nil)

      expect(dimension.value_for(principal)).to be(true)
      expect(dimension.reason(principal)).to eq("system_admin=true")
    end

    it "invokes a callable with the record" do
      dimension = described_class.new(name: :reseller, accessor: ->(principal) { principal.plan == "reseller" })
      principal = DimensionSpecPrincipal.new("responder", false, "reseller")

      expect(dimension.value_for(principal)).to be(true)
      expect(dimension.reason(principal)).to eq("reseller=true")
      expect(dimension.callable?).to be(true)
    end

    it "rejects an accessor that is neither Symbol/String nor callable" do
      expect { described_class.new(name: :role, accessor: 42) }
        .to raise_error(ArgumentError, %r{must be a Symbol/String attribute or predicate, or a callable})
    end
  end

  describe "#format_value" do
    subject(:dimension) { described_class.new(name: :role, accessor: :role) }

    it "renders strings plainly, without quoting" do
      expect(dimension.format_value("local_admin")).to eq("local_admin")
    end

    it "renders true/false/nil via inspect" do
      expect(dimension.format_value(true)).to eq("true")
      expect(dimension.format_value(false)).to eq("false")
      expect(dimension.format_value(nil)).to eq("nil")
    end

    it "renders other objects via to_s" do
      expect(dimension.format_value(7)).to eq("7")
    end
  end

  describe "sensitive name/accessor rejection" do
    it "rejects a dimension whose own name looks sensitive" do
      expect { described_class.new(name: :email, accessor: :status) }
        .to raise_error(ArgumentError, /looks like a sensitive attribute/)
    end

    it "rejects a dimension whose Symbol accessor looks sensitive even under a safe name" do
      expect { described_class.new(name: :contact, accessor: :email) }
        .to raise_error(ArgumentError, /looks like a sensitive attribute/)
    end

    it "rejects a sensitive predicate accessor stripped of its trailing ?" do
      expect { described_class.new(name: :has_token, accessor: :token?) }
        .to raise_error(ArgumentError, /looks like a sensitive attribute/)
    end

    it "cannot inspect a callable accessor's body, so it is never rejected by name alone" do
      expect { described_class.new(name: :contact, accessor: lambda(&:email)) }.not_to raise_error
    end
  end

  describe "#column_for" do
    # column_for only ever calls klass.columns_hash, so a plain duck-typed
    # stand-in is enough -- no real Active Record class is needed here.
    def klass_with_columns(columns)
      klass = Class.new
      klass.define_singleton_method(:columns_hash) { columns }
      klass
    end

    it "returns the real column when the accessor names one directly" do
      role_column = double("column", type: :string)
      klass = klass_with_columns({ "role" => role_column })
      dimension = described_class.new(name: :role, accessor: :role)

      expect(dimension.column_for(klass)).to equal(role_column)
    end

    it "returns the underlying boolean column for Rails' auto-generated `<column>?` predicate" do
      premium_column = double("column", type: :boolean)
      klass = klass_with_columns({ "premium" => premium_column })
      dimension = described_class.new(name: :premium, accessor: :premium?)

      expect(dimension.column_for(klass)).to equal(premium_column)
    end

    it "returns nil for a `?` predicate over a non-boolean column, since that predicate is a truthiness " \
       "check, not the literal column value" do
      status_column = double("column", type: :integer)
      klass = klass_with_columns({ "status" => status_column })
      dimension = described_class.new(name: :status, accessor: :status?)

      expect(dimension.column_for(klass)).to be_nil
    end

    it "returns nil for a computed predicate with no matching column at all" do
      klass = klass_with_columns({})
      dimension = described_class.new(name: :system_admin, accessor: :system_admin?)

      expect(dimension.column_for(klass)).to be_nil
    end

    it "returns nil for a callable accessor" do
      klass = klass_with_columns({ "role" => double("column", type: :string) })
      dimension = described_class.new(name: :role, accessor: ->(_user) { "x" })

      expect(dimension.column_for(klass)).to be_nil
    end
  end

  describe ".normalize" do
    it "builds a Hash of Symbol => PrincipalDimension from a raw accessor Hash" do
      normalized = described_class.normalize(role: :role, premium: :premium?)

      expect(normalized.keys).to eq(%i[role premium])
      expect(normalized.values).to all(be_a(described_class))
    end

    it "returns an empty Hash for nil" do
      expect(described_class.normalize(nil)).to eq({})
    end

    it "raises for a non-Hash argument" do
      expect { described_class.normalize([:role]) }.to raise_error(ArgumentError, /must be a Hash/)
    end

    it "is idempotent over its own output, reusing already-built dimensions rather than rebuilding them" do
      once = described_class.normalize(role: :role)
      twice = described_class.normalize(once)

      expect(twice[:role]).to equal(once[:role])
    end
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
