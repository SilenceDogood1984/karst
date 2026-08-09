# frozen_string_literal: true

require "digest"
require "karst"

# rubocop:disable Metrics/BlockLength
RSpec.describe Karst::Sql::Shape do
  describe "public constant visibility" do
    it "keeps Shape public and its grouping transformation private" do
      expect(Karst::Sql.const_defined?(:Shape, false)).to be(true)
      expect(described_class).to be_a(Class)
      expect(described_class.superclass).to eq(Data)
      expect(described_class.members).to eq(
        %i[fingerprint canonical_sql count cached_count duration_ms_min duration_ms_max duration_ms_total samples]
      )
      expect(described_class.private_methods).to include(:group, :normalize_in_lists, :build, :select_samples)
      expect(described_class.public_methods(false)).not_to include(:group, :normalize_in_lists, :build, :select_samples)
    end
  end

  def event(sql, duration_ms, cached: false, started_at: 0.0)
    Karst::Sql::Event.new(
      name: nil,
      sql: sql,
      cached: cached,
      duration_ms: duration_ms,
      monotonic_started_at: started_at
    )
  end

  def group(events)
    described_class.send(:group, events)
  end

  describe "fingerprint identity" do
    it "produces a deterministic 16-character lowercase hex fingerprint using SHA-256" do
      events = [event("SELECT * FROM users WHERE id = 1", 1.0)]

      shapes, = group(events)
      shape = shapes.first
      fingerprint_sql = "SELECT * FROM users WHERE id = ?"

      expect(shape.fingerprint).to eq(Digest::SHA256.hexdigest(fingerprint_sql)[0, 16])
      expect(shape.fingerprint).to match(/\A[0-9a-f]{16}\z/)
    end

    it "is deterministic across repeated calls with the same ordered input" do
      events = [
        event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0),
        event("SELECT * FROM users WHERE id = 2", 9.0, started_at: 2.0)
      ]

      first_shapes, = group(events)
      second_shapes, = group(events)

      expect(first_shapes.map(&:fingerprint)).to eq(second_shapes.map(&:fingerprint))
    end

    it "produces no shape and no fingerprint for declined canonicalization" do
      events = [event("SELECT * FROM users WHERE name = 'unterminated", 1.0)]

      shapes, declined = group(events)

      expect(shapes).to be_empty
      expect(declined).to eq(events)
    end
  end

  describe "required equivalence" do
    it "groups differing integer literals together" do
      events = [
        event("SELECT * FROM users WHERE id = 1", 1.0),
        event("SELECT * FROM users WHERE id = 999", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(1)
      expect(shapes.first.count).to eq(2)
    end

    it "groups differing string literals together" do
      events = [
        event("SELECT * FROM users WHERE email = 'a@example.com'", 1.0),
        event("SELECT * FROM users WHERE email = 'b@example.com'", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(1)
    end

    it "shares fingerprint identity across IN-list cardinality" do
      events = [
        event("SELECT * FROM users WHERE id IN (1)", 1.0),
        event("SELECT * FROM users WHERE id IN (1, 2)", 1.0),
        event("SELECT * FROM users WHERE id IN (1, 2, 3, 4)", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(1)
      expect(shapes.first.count).to eq(3)
    end
  end

  describe "required non-equivalence" do
    it "keeps ORDER BY direction distinct" do
      events = [
        event("SELECT * FROM users ORDER BY created_at ASC", 1.0),
        event("SELECT * FROM users ORDER BY created_at DESC", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(2)
    end

    it "keeps distinct qualified columns separate" do
      events = [
        event("SELECT users.id FROM users", 1.0),
        event("SELECT accounts.id FROM accounts", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(2)
    end

    it "keeps distinct casts separate" do
      events = [
        event("SELECT '26f'::uuid", 1.0),
        event("SELECT '26f'::text", 1.0)
      ]

      shapes, = group(events)

      expect(shapes.size).to eq(2)
    end
  end

  describe "IN-list normalization" do
    def normalize(sql)
      described_class.send(:normalize_in_lists, sql)
    end

    it "collapses IN placeholder-list arity" do
      expect(normalize("SELECT * FROM users WHERE id IN (?)")).to eq("SELECT * FROM users WHERE id IN (?+)")
      expect(normalize("SELECT * FROM users WHERE id IN (?, ?)")).to eq("SELECT * FROM users WHERE id IN (?+)")
      expect(normalize("SELECT * FROM users WHERE id IN (?, ?, ?)")).to eq("SELECT * FROM users WHERE id IN (?+)")
    end

    it "collapses NOT IN placeholder-list arity the same way" do
      expect(normalize("SELECT * FROM t WHERE x NOT IN (?, ?, ?)")).to eq("SELECT * FROM t WHERE x NOT IN (?+)")
    end

    it "does not touch identifiers that merely contain the letters IN" do
      expect(normalize("SELECT INVOICE FROM things")).to eq("SELECT INVOICE FROM things")
    end

    it "does not normalize an IN subquery" do
      sql = "SELECT * FROM t WHERE id IN (SELECT id FROM users)"

      expect(normalize(sql)).to eq(sql)
    end

    it "does not normalize a VALUES list" do
      sql = "INSERT INTO logs (a, b) VALUES (?, ?), (?, ?)"

      expect(normalize(sql)).to eq(sql)
    end

    it "does not normalize an unrelated parenthesized placeholder list" do
      sql = "SELECT COALESCE(?, ?) FROM users"

      expect(normalize(sql)).to eq(sql)
    end

    it "preserves the raw sample Events' original IN arity even though the fingerprint is shared" do
      events = [
        event("SELECT * FROM users WHERE id IN (1)", 1.0),
        event("SELECT * FROM users WHERE id IN (1, 2, 3, 4)", 2.0)
      ]

      shapes, = group(events)
      shape = shapes.first

      expect(shape.samples.map(&:sql)).to contain_exactly(
        "SELECT * FROM users WHERE id IN (1)",
        "SELECT * FROM users WHERE id IN (1, 2, 3, 4)"
      )
    end
  end

  describe "canonical_sql identity" do
    it "displays the IN-arity-collapsed identity SQL that backs the fingerprint, not a pre-collapse variant" do
      events = [event("SELECT * FROM users WHERE id IN (1, 2, 3)", 1.0)]

      shapes, = group(events)
      shape = shapes.first

      expect(shape.canonical_sql).to eq("SELECT * FROM users WHERE id IN (?+)")
      expect(shape.fingerprint).to eq(Digest::SHA256.hexdigest(shape.canonical_sql)[0, 16])
    end

    it "is deterministic regardless of which arity arrives first" do
      one = event("SELECT * FROM users WHERE id IN (1)", 5.0, started_at: 1.0)
      two = event("SELECT * FROM users WHERE id IN (1, 2)", 9.0, started_at: 2.0)
      four = event("SELECT * FROM users WHERE id IN (1, 2, 3, 4)", 3.0, started_at: 3.0)

      forward_shapes, = group([one, two, four])
      reversed_shapes, = group([four, two, one])

      expect(forward_shapes.size).to eq(1)
      expect(reversed_shapes.size).to eq(1)
      expect(forward_shapes.first.canonical_sql).to eq("SELECT * FROM users WHERE id IN (?+)")
      expect(forward_shapes.first.canonical_sql).to eq(reversed_shapes.first.canonical_sql)
      expect(forward_shapes.first.fingerprint).to eq(reversed_shapes.first.fingerprint)
    end
  end

  describe "shape aggregation" do
    it "computes count, cached_count, and duration statistics" do
      events = [
        event("SELECT * FROM users WHERE id = 1", 5.0, cached: false, started_at: 1.0),
        event("SELECT * FROM users WHERE id = 2", 20.0, cached: true, started_at: 2.0),
        event("SELECT * FROM users WHERE id = 3", 1.0, cached: true, started_at: 3.0)
      ]

      shapes, = group(events)
      shape = shapes.first

      expect(shape.count).to eq(3)
      expect(shape.cached_count).to eq(2)
      expect(shape.duration_ms_min).to eq(1.0)
      expect(shape.duration_ms_max).to eq(20.0)
      expect(shape.duration_ms_total).to eq(26.0)
    end

    it "counts cache hits toward duration statistics rather than excluding them" do
      events = [event("SELECT * FROM users WHERE id = 1", 42.0, cached: true, started_at: 1.0)]

      shapes, = group(events)
      shape = shapes.first

      expect(shape.count).to eq(1)
      expect(shape.duration_ms_min).to eq(42.0)
      expect(shape.duration_ms_max).to eq(42.0)
      expect(shape.duration_ms_total).to eq(42.0)
    end
  end

  describe "sample selection" do
    it "keeps one sample when only one Event was observed" do
      only = event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0)

      shapes, = group([only])

      expect(shapes.first.samples).to eq([only])
    end

    it "keeps two samples, in first/latest order, when the latest Event is also the slowest" do
      first = event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0)
      latest_and_slowest = event("SELECT * FROM users WHERE id = 2", 20.0, started_at: 2.0)

      shapes, = group([first, latest_and_slowest])

      expect(shapes.first.samples).to eq([first, latest_and_slowest])
    end

    it "keeps three samples, in first/slowest/latest order, for three distinct roles" do
      first = event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0)
      slowest = event("SELECT * FROM users WHERE id = 2", 50.0, started_at: 2.0)
      latest = event("SELECT * FROM users WHERE id = 3", 8.0, started_at: 3.0)

      shapes, = group([first, slowest, latest])

      expect(shapes.first.samples).to eq([first, slowest, latest])
    end

    it "does not sort samples by duration" do
      first_and_slowest = event("SELECT * FROM users WHERE id = 1", 100.0, started_at: 1.0)
      middle = event("SELECT * FROM users WHERE id = 2", 5.0, started_at: 2.0)
      latest = event("SELECT * FROM users WHERE id = 3", 1.0, started_at: 3.0)

      shapes, = group([first_and_slowest, middle, latest])

      expect(shapes.first.samples).to eq([first_and_slowest, latest])
    end
  end

  describe "immutability" do
    it "returns a frozen Shape with frozen fingerprint, canonical_sql, and samples" do
      events = [event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0)]

      shapes, = group(events)
      shape = shapes.first

      expect(shape).to be_frozen
      expect(shape.fingerprint).to be_frozen
      expect(shape.canonical_sql).to be_frozen
      expect(shape.samples).to be_frozen
    end

    it "references the original Event objects in samples rather than duplicating them" do
      only = event("SELECT * FROM users WHERE id = 1", 5.0, started_at: 1.0)

      shapes, = group([only])

      expect(shapes.first.samples.first).to equal(only)
    end
  end

  describe "declined events" do
    it "leaves declined Events untouched and in their original input order" do
      first_declined = event("SELECT * FROM users WHERE name = 'unterminated", 1.0, started_at: 1.0)
      grouped = event("SELECT * FROM users WHERE id = 1", 1.0, started_at: 2.0)
      second_declined = event("SELECT * FROM users WHERE token = 'also unterminated", 1.0, started_at: 3.0)

      _shapes, declined = group([first_declined, grouped, second_declined])

      expect(declined).to eq([first_declined, second_declined])
      expect(declined.first).to equal(first_declined)
      expect(declined.last).to equal(second_declined)
    end
  end

  describe "Event regression" do
    it "leaves Sql::Event unchanged by fingerprinting" do
      expect(Karst::Sql::Event.members).to eq(%i[name sql cached duration_ms monotonic_started_at])
    end
  end
end
# rubocop:enable Metrics/BlockLength
