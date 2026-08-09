# frozen_string_literal: true

require "digest"

module Karst
  module Sql
    # Immutable aggregate identity for Events that share the same declared query shape.
    Shape = Data.define(
      :fingerprint,
      :canonical_sql,
      :count,
      :cached_count,
      :duration_ms_min,
      :duration_ms_max,
      :duration_ms_total,
      :samples
    )

    # Grouping, fingerprinting, and IN-list normalization are internal; only the Data members above are public.
    class Shape
      FINGERPRINT_LENGTH = 16
      private_constant :FINGERPRINT_LENGTH

      # Matches a confidently recognized IN (?, ?, ...) placeholder list, including NOT IN,
      # so declared cardinality does not fracture identity. Subqueries and VALUES lists never
      # match because their contents are not exclusively comma-separated "?" placeholders.
      IN_PLACEHOLDER_LIST = /\b(IN)\b(\s*)\(\s*\?(?:\s*,\s*\?)*\s*\)/i
      private_constant :IN_PLACEHOLDER_LIST

      class << self
        private

        # events -> [shapes, declined]
        # Groups by the fingerprint SQL string itself (not the truncated digest), so a digest
        # collision could never merge two structurally different shapes.
        def group(events)
          grouped = {}
          declined = []

          events.each { |event| assign(event, grouped, declined) }

          shapes = grouped.map { |fingerprint_sql, bucket| build(fingerprint_sql, bucket) }

          [shapes.freeze, declined.freeze]
        end

        def assign(event, grouped, declined)
          canonical = Canonicalizer.call(event.sql)
          return declined << event unless canonical

          fingerprint_sql = normalize_in_lists(canonical)
          bucket = (grouped[fingerprint_sql] ||= { canonical_sql: canonical, events: [] })
          bucket[:events] << event
        end

        def normalize_in_lists(canonical_sql)
          canonical_sql.gsub(IN_PLACEHOLDER_LIST) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}(?+)" }
        end

        def build(fingerprint_sql, bucket)
          events = bucket[:events]

          new(
            fingerprint: Digest::SHA256.hexdigest(fingerprint_sql)[0, FINGERPRINT_LENGTH].freeze,
            canonical_sql: bucket[:canonical_sql],
            count: events.size,
            cached_count: events.count(&:cached),
            samples: select_samples(events).freeze,
            **duration_stats(events)
          )
        end

        def duration_stats(events)
          durations = events.map(&:duration_ms)

          { duration_ms_min: durations.min, duration_ms_max: durations.max, duration_ms_total: durations.sum }
        end

        # Preserves order: first observed, slowest observed, latest observed.
        def select_samples(events)
          [events.first, events.max_by(&:duration_ms), events.last].uniq
        end
      end
    end
  end
end
