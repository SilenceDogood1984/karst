# frozen_string_literal: true

require "digest"
require "spec_helper"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Sql::Window do
  def reset_karst_runtime!(capacity:)
    Karst.unsubscribe!
    Karst.instance_variable_set(:@config, Karst.const_get(:Configuration, false).new)
    Karst.remove_instance_variable(:@buffer) if Karst.instance_variable_defined?(:@buffer)
    Karst.remove_instance_variable(:@subscription) if Karst.instance_variable_defined?(:@subscription)
    Karst.config.buffer_size = capacity
  end

  def push(event)
    Karst.buffer.call(event)
  end

  def event(sql, duration_ms, cached: false, started_at: 0.0)
    Karst::Sql::Event.new(
      name: nil, sql: sql, cached: cached, duration_ms: duration_ms, monotonic_started_at: started_at
    )
  end

  before { reset_karst_runtime!(capacity: 2_000) }
  after { Karst.unsubscribe! }

  describe "shape" do
    it "is an immutable Data with exactly the documented members" do
      expect(described_class.superclass).to eq(Data)
      expect(described_class.members).to eq(%i[shapes declined event_count capacity saturated])
    end
  end

  describe "empty window" do
    it "returns empty shapes and declined with a zero event_count and no saturation" do
      Karst.buffer.clear

      window = Karst.window

      expect(window.shapes).to eq([])
      expect(window.declined).to eq([])
      expect(window.event_count).to eq(0)
      expect(window.saturated).to be(false)
      expect(window.capacity).to eq(2_000)
    end
  end

  describe "all declined" do
    it "puts every Event in declined and produces no shapes" do
      reset_karst_runtime!(capacity: 10)
      push(event("SELECT * FROM users WHERE name = 'unterminated", 1.0))
      push(event("SELECT * FROM users WHERE token = 'also unterminated", 1.0))

      window = Karst.window

      expect(window.shapes).to eq([])
      expect(window.declined.size).to eq(window.event_count)
      expect(window.event_count).to eq(2)
    end
  end

  describe "mixed successful/declined" do
    it "routes successful events only to shapes and declined events only to declined, with no overlap" do
      reset_karst_runtime!(capacity: 10)
      grouped_one = event("SELECT * FROM users WHERE id = 1", 1.0)
      grouped_two = event("SELECT * FROM users WHERE id = 2", 2.0)
      declined_event = event("SELECT * FROM users WHERE name = 'unterminated", 1.0)
      [grouped_one, grouped_two, declined_event].each { |candidate| push(candidate) }

      window = Karst.window

      expect(window.shapes.size).to eq(1)
      expect(window.shapes.first.count).to eq(2)
      expect(window.declined).to eq([declined_event])
      expect(window.event_count).to eq(window.shapes.sum(&:count) + window.declined.size)

      shape_events = window.shapes.flat_map(&:samples)
      expect(shape_events).not_to include(declined_event)
      expect(window.declined).not_to include(grouped_one, grouped_two)
    end
  end

  describe "reconciliation invariant" do
    it "always satisfies event_count == shapes.sum(&:count) + declined.size" do
      reset_karst_runtime!(capacity: 50)
      20.times { |i| push(event("SELECT * FROM users WHERE id = #{i % 4}", i.to_f)) }
      5.times { |i| push(event("SELECT * FROM users WHERE name = 'unterminated #{i}", i.to_f)) }

      window = Karst.window

      expect(window.event_count).to eq(25)
      expect(window.event_count).to eq(window.shapes.sum(&:count) + window.declined.size)
    end
  end

  describe "saturation" do
    it "is saturated and reports only retained events when writes exceed capacity" do
      reset_karst_runtime!(capacity: 3)
      5.times { |i| push(event("SELECT * FROM users WHERE id = #{i}", i.to_f, started_at: i.to_f)) }

      window = Karst.window

      expect(window.event_count).to eq(3)
      expect(window.capacity).to eq(3)
      expect(window.saturated).to be(true)
      expect(window.shapes.sum(&:count) + window.declined.size).to eq(3)
    end

    it "is not saturated when retained events are fewer than capacity" do
      reset_karst_runtime!(capacity: 10)
      3.times { |i| push(event("SELECT * FROM users WHERE id = #{i}", i.to_f, started_at: i.to_f)) }

      window = Karst.window

      expect(window.event_count).to eq(3)
      expect(window.capacity).to eq(10)
      expect(window.saturated).to be(false)
    end
  end

  describe "shape ordering" do
    it "sorts by count desc, then duration total desc, then fingerprint asc" do
      reset_karst_runtime!(capacity: 100)

      most_common = "SELECT * FROM most_common WHERE id = 1"
      slower_tied = "SELECT * FROM slower_tied WHERE id = 1"
      faster_tied = "SELECT * FROM faster_tied WHERE id = 1"
      fingerprint_a = "SELECT * FROM fingerprint_a WHERE id = 1"
      fingerprint_b = "SELECT * FROM fingerprint_b WHERE id = 1"

      2.times { push(event(most_common, 1.0)) }
      push(event(slower_tied, 20.0))
      push(event(faster_tied, 5.0))
      push(event(fingerprint_a, 3.0))
      push(event(fingerprint_b, 3.0))

      window = Karst.window

      expect(window.shapes.first.count).to eq(2)

      remaining = window.shapes.drop(1)
      expect(remaining.map(&:duration_ms_total)).to eq([20.0, 5.0, 3.0, 3.0])

      tied = remaining.last(2)
      expect(tied.map(&:canonical_sql)).to contain_exactly(
        "SELECT * FROM fingerprint_a WHERE id = ?", "SELECT * FROM fingerprint_b WHERE id = ?"
      )
      expected_order = tied.map(&:fingerprint).sort
      expect(tied.map(&:fingerprint)).to eq(expected_order)
      expect(tied.map { |shape| Digest::SHA256.hexdigest(shape.canonical_sql)[0, 16] }).to eq(tied.map(&:fingerprint))
    end
  end

  describe "declined ordering" do
    it "preserves original buffer order for declined events regardless of duration" do
      reset_karst_runtime!(capacity: 10)
      first_declined = event("SELECT * FROM a WHERE name = 'unterminated", 50.0, started_at: 1.0)
      second_declined = event("SELECT * FROM b WHERE name = 'unterminated", 1.0, started_at: 2.0)
      push(first_declined)
      push(second_declined)

      window = Karst.window

      expect(window.declined).to eq([first_declined, second_declined])
      expect(window.declined.first).to equal(first_declined)
      expect(window.declined.last).to equal(second_declined)
    end
  end

  describe "cached events" do
    it "preserves cached_count from Shape aggregation" do
      reset_karst_runtime!(capacity: 10)
      push(event("SELECT * FROM users WHERE id = 1", 1.0, cached: true))
      push(event("SELECT * FROM users WHERE id = 2", 1.0, cached: false))

      window = Karst.window

      expect(window.shapes.first.cached_count).to eq(1)
    end
  end

  describe "immutability" do
    it "freezes the Window, its shapes Array, and its declined Array; never copies Events" do
      reset_karst_runtime!(capacity: 10)
      grouped = event("SELECT * FROM users WHERE id = 1", 1.0)
      declined_event = event("SELECT * FROM users WHERE name = 'unterminated", 1.0)
      push(grouped)
      push(declined_event)

      window = Karst.window

      expect(window).to be_frozen
      expect(window.shapes).to be_frozen
      expect(window.declined).to be_frozen
      expect(window.shapes).to all(be_frozen)
      expect(window.shapes.first.samples.first).to equal(grouped)
      expect(window.declined.first).to equal(declined_event)
    end
  end

  describe "snapshot isolation" do
    it "reflects only the snapshot taken from Buffer#to_a, even if the live buffer changes during analysis" do
      reset_karst_runtime!(capacity: 100)
      push(event("SELECT * FROM a WHERE id = 1", 1.0))
      push(event("SELECT * FROM b WHERE id = 1", 1.0))

      reached_grouping = Queue.new
      proceed = Queue.new
      allow(Karst::Sql::Shape).to receive(:group).and_wrap_original do |original, events|
        reached_grouping << true
        proceed.pop
        original.call(events)
      end

      window = nil
      worker = Thread.new { window = Karst.window }
      reached_grouping.pop

      push(event("SELECT * FROM c WHERE id = 1", 1.0))

      proceed << true
      worker.join

      expect(window.event_count).to eq(2)
      expect(Karst.buffer.to_a.size).to eq(3)
    end
  end

  describe "concurrent capture" do
    it "does not raise and stays internally reconciled while other threads write concurrently" do
      reset_karst_runtime!(capacity: 200)
      errors = Queue.new
      stop = false

      writer = Thread.new do
        i = 0
        until stop
          push(event("SELECT * FROM users WHERE id = #{i}", (i % 5).to_f))
          i += 1
        end
      rescue StandardError => e
        errors << e
      end

      windows = Array.new(20) do
        Karst.window
      rescue StandardError => e
        errors << e
        nil
      end

      stop = true
      writer.join

      expect(errors).to be_empty
      windows.compact.each do |window|
        expect(window.event_count).to eq(window.shapes.sum(&:count) + window.declined.size)
        expect(window.event_count).to be <= window.capacity
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
