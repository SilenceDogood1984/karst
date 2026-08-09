# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "spec_helper"
require "karst/value"

RSpec.describe Karst::Value do
  subject(:point_class) { described_class.define(:x, :y) }

  describe ".define" do
    it "builds a Struct-based class with exactly the declared members" do
      expect(point_class.superclass).to eq(Struct)
      expect(point_class.members).to eq(%i[x y])
    end

    it "constructs instances from keyword arguments and exposes members as readers" do
      point = point_class.new(x: 1, y: 2)

      expect(point.x).to eq(1)
      expect(point.y).to eq(2)
      expect(point.members).to eq(%i[x y])
    end

    it "rejects positional construction, matching Data.define's keyword-first call sites" do
      expect { point_class.new(1, 2) }.to raise_error(ArgumentError)
    end

    it "has structural equality based on class and member values" do
      expect(point_class.new(x: 1, y: 2)).to eq(point_class.new(x: 1, y: 2))
      expect(point_class.new(x: 1, y: 2)).not_to eq(point_class.new(x: 1, y: 3))
    end

    it "freezes every instance it produces" do
      point = point_class.new(x: 1, y: 2)

      expect(point).to be_frozen
    end

    it "raises FrozenError when a caller attempts to mutate a member" do
      point = point_class.new(x: 1, y: 2)

      expect { point.x = 99 }.to raise_error(FrozenError)
      expect(point.x).to eq(1)
    end

    it "does not deep-freeze a member holding a mutable object" do
      list_class = described_class.define(:items)
      mutable = [1, 2]

      value = list_class.new(items: mutable)

      expect(value).to be_frozen
      expect(value.items).not_to be_frozen
      expect { value.items << 3 }.not_to raise_error
    end

    it "supports attaching instance methods through a block, like Data.define" do
      range_class = described_class.define(:low, :high) do
        def span
          high - low
        end
      end

      expect(range_class.new(low: 2, high: 9).span).to eq(7)
    end
  end
end

# rubocop:enable Metrics/BlockLength
