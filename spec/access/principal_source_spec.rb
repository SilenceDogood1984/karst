# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Access::PrincipalSource do
  describe "#initialize" do
    it "requires records to be callable" do
      expect { described_class.new(name: :authors, records: []) }
        .to raise_error(ArgumentError, /must be callable/)
    end

    it "defaults to no dimensions" do
      source = described_class.new(name: :authors, records: -> { [] })
      expect(source.dimensions).to eq({})
    end

    it "normalizes a raw dimensions Hash" do
      source = described_class.new(name: :authors, records: -> { [] }, dimensions: { premium: :premium? })
      expect(source.dimensions[:premium]).to be_a(Karst::Access::PrincipalDimension)
    end

    it "defaults to no populations" do
      source = described_class.new(name: :authors, records: -> { [] })
      expect(source.populations).to eq({})
    end

    it "keeps a populations Hash of Symbol => callable as-is" do
      admins = -> { [] }
      source = described_class.new(name: :authors, records: -> { [] }, populations: { admins: admins })
      expect(source.populations).to eq(admins: admins)
    end

    it "rejects a populations value that is not a Hash of Symbol => callable" do
      expect { described_class.new(name: :authors, records: -> { [] }, populations: { admins: "not callable" }) }
        .to raise_error(ArgumentError, /populations must be a Hash of Symbol => callable/)
    end

    it "symbolizes the name" do
      source = described_class.new(name: "authors", records: -> { [] })
      expect(source.name).to eq(:authors)
    end
  end

  describe "#evaluate" do
    it "calls the records callable lazily, not at construction time" do
      calls = 0
      source = described_class.new(name: :authors, records: lambda {
        calls += 1
        [1, 2]
      })
      expect(calls).to eq(0)

      expect(source.evaluate).to eq([1, 2])
      expect(calls).to eq(1)
    end
  end

  describe ".normalize" do
    it "returns nil for nil" do
      expect(described_class.normalize(nil)).to be_nil
    end

    it "raises for a non-Hash argument" do
      expect { described_class.normalize([1, 2]) }.to raise_error(ArgumentError, /must be a Hash/)
    end

    it "accepts a bare callable per source" do
      normalized = described_class.normalize(authors: -> { [] })

      expect(normalized[:authors]).to be_a(described_class)
      expect(normalized[:authors].dimensions).to eq({})
    end

    it "accepts a Hash spec with :records and :dimensions" do
      normalized = described_class.normalize(
        authors: { records: -> { [] }, dimensions: { premium: :premium? } }
      )

      expect(normalized[:authors].dimensions).to have_key(:premium)
    end

    it "accepts a Hash spec with :records and :populations" do
      normalized = described_class.normalize(
        authors: { records: -> { [] }, populations: { admins: -> { [] } } }
      )

      expect(normalized[:authors].populations).to have_key(:admins)
    end

    it "accepts string keys within a Hash spec" do
      normalized = described_class.normalize(authors: { "records" => lambda {
        []
      }, "dimensions" => { premium: :premium? } })

      expect(normalized[:authors].dimensions).to have_key(:premium)
    end

    it "raises for a source spec that is neither callable nor a Hash" do
      expect { described_class.normalize(authors: 42) }
        .to raise_error(ArgumentError, /must be callable or a Hash with :records/)
    end

    it "raises when a Hash spec has no records at all" do
      expect { described_class.normalize(authors: { dimensions: {} }) }
        .to raise_error(ArgumentError, /must be callable/)
    end

    it "keeps multiple sources independently keyed and in configured order" do
      normalized = described_class.normalize(authors: -> { [] }, readers: -> { [] })
      expect(normalized.keys).to eq(%i[authors readers])
    end

    it "is idempotent over its own output" do
      once = described_class.normalize(authors: -> { [] })
      twice = described_class.normalize(once)

      expect(twice[:authors]).to equal(once[:authors])
    end
  end
end
# rubocop:enable Metrics/BlockLength
