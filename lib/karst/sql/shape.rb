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
        # Groups by the identity SQL string itself (not the truncated digest), so a digest
        # collision could never merge two structurally different shapes. The identity SQL is
        # the post-IN-normalization form, and backs both the fingerprint and canonical_sql, so
        # a Shape never mixes an arity-collapsed identity with a pre-collapse displayed string.
        def group(events)
          grouped = {}
          declined = []

          events.each { |event| assign(event, grouped, declined) }

          shapes = grouped.map { |identity_sql, group_events| build(identity_sql, group_events) }

          [shapes.freeze, declined.freeze]
        end

        def assign(event, grouped, declined)
          canonical = Canonicalizer.call(event.sql)
          return declined << event unless canonical

          identity_sql = normalize_in_lists(canonical)
          (grouped[identity_sql] ||= []) << event
        end

        def normalize_in_lists(canonical_sql)
          canonical_sql.gsub(IN_PLACEHOLDER_LIST) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}(?+)" }.freeze
        end

        def build(identity_sql, events)
          new(
            fingerprint: Digest::SHA256.hexdigest(identity_sql)[0, FINGERPRINT_LENGTH].freeze,
            canonical_sql: identity_sql,
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
