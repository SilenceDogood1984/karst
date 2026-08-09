# frozen_string_literal: true

require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst.const_get(:Buffer, false) do
  it "keeps ingestion private" do
    event = Object.new
    buffer = described_class.new(capacity: 3)

    expect(buffer).not_to respond_to(:call)
    expect { buffer.call(event) }.to raise_error(NoMethodError, /private method [`']call/)
    expect(buffer.send(:call, event)).to equal(buffer)
    expect(buffer.size).to eq(1)
    expect(buffer.to_a).to eq([event])
  end

  it "exposes the capacity it was constructed with" do
    buffer = described_class.new(capacity: 3)

    expect(buffer.capacity).to eq(3)
  end

  it "rejects invalid capacities" do
    [0, -1, 1.5, "3", nil].each do |capacity|
      expect { described_class.new(capacity: capacity) }.to raise_error(ArgumentError)
    end
  end

  it "repeatedly discards the oldest item at capacity" do
    buffer = described_class.new(capacity: 3)

    (1..7).each { |event| buffer.send(:call, event) }

    expect(buffer.size).to eq(3)
    expect(buffer.to_a).to eq([5, 6, 7])
  end

  it "returns an independent snapshot" do
    buffer = described_class.new(capacity: 3)
    buffer.send(:call, :event)

    buffer.to_a.clear

    expect(buffer.to_a).to eq([:event])
  end

  it "clears retained items and remains reusable at the same capacity" do
    buffer = described_class.new(capacity: 2)
    buffer.send(:call, 1)
    buffer.send(:call, 2)

    expect(buffer.clear).to equal(buffer)
    expect(buffer.size).to eq(0)
    expect(buffer.to_a).to be_empty

    buffer.send(:call, 3)
    buffer.send(:call, 4)
    buffer.send(:call, 5)
    expect(buffer.to_a).to eq([4, 5])
  end

  it "remains bounded and uncorrupted under concurrent writes" do
    capacity = 100
    submitted = (1..1_000).map { Object.new }
    buffer = described_class.new(capacity: capacity)
    errors = Queue.new
    threads = submitted.each_slice(100).map do |events|
      Thread.new do
        events.each { |event| buffer.send(:call, event) }
      rescue StandardError => e
        errors << e
      end
    end

    threads.each(&:join)
    retained = buffer.to_a

    expect(errors).to be_empty
    expect(buffer.size).to eq(capacity)
    expect(retained).not_to include(nil)
    expect(retained).to all(satisfy { |event| submitted.include?(event) })
  end
end
# rubocop:enable Metrics/BlockLength
