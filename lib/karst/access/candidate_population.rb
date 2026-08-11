# frozen_string_literal: true

require_relative "../value"
require_relative "database_isolation"

module Karst
  module Access
    # An application-authored, bounded subset of a model's rows -- for
    # example the rows a configured callable like `-> { User.system_admins }`
    # returns. A population is a hint about where meaningful sampling
    # candidates might live; it is never a claim about behavior or
    # authorization -- only Access::Sweep's runtime execution produces that
    # evidence. See README "Candidate populations" for the full boundary
    # this class exists to preserve.
    #
    # Deliberately generic over what a "candidate" represents. Today's only
    # caller (PrincipalSampler) always treats these records as principals,
    # but nothing here assumes that -- a future artifact-population caller
    # (Subscription.renewable, Import.with_sheets) could resolve populations
    # exactly the same way over a non-principal model, without this class
    # changing at all.
    #
    # This deliberately does not claim that a configured callable is a "real"
    # Rails named scope. Active Record exposes no reliable, public way to
    # distinguish a method defined via the `scope` macro from an ordinary
    # handwritten class method, so Karst only validates the one thing it can
    # actually observe: calling the configured callable returns an
    # ActiveRecord::Relation scoped to the same model being sampled. Whether
    # that relation came from `scope :system_admins, -> { ... }` or a plain
    # `def self.system_admins; ...; end` makes no difference here.
    # rubocop:disable Metrics/BlockLength
    CandidatePopulation = Value.define(:source, :name, :records, :provenance) do
      class << self
        # Resolves one configured name => callable pair into a bounded,
        # already-queried population, or nil when calling the callable does
        # not yield an ActiveRecord::Relation scoped to source_klass (wrong
        # type, wrong model, or the callable itself raising -- including
        # requiring an argument Karst never supplies). Invalid populations
        # are skipped, never raised: a misconfigured population should
        # degrade the candidate pool, not break the sweep. Issues at most
        # one SELECT query, always LIMIT-bounded -- never a COUNT, never full
        # materialization, regardless of how many rows the underlying
        # relation matches. Evaluation and materialization happen inside a
        # rollback-only transaction on the source model's connection. A
        # candidate that emits mutating SQL is rejected even though Karst
        # attempted to roll that transaction back.
        def resolve(name:, callable:, source_klass:, limit:)
          evaluation = evaluate(callable, source_klass, limit)
          return nil unless usable_evaluation?(evaluation)

          records = evaluation.value
          return nil unless records

          new(source: source_klass, name: name.to_sym, records: records, provenance: "population=#{name}")
        rescue StandardError
          nil
        end

        private

        def evaluate(callable, source_klass, limit)
          DatabaseIsolation.call(connection_class: source_klass) do
            relation = callable.call
            next unless relation.is_a?(ActiveRecord::Relation) && relation.klass == source_klass

            bounded(relation, source_klass, limit)
          end
        end

        def usable_evaluation?(evaluation)
          evaluation.exception.nil? && evaluation.write_count.zero? && evaluation.database_rollback_attempted
        end

        # Only imposes primary-key ordering as a deterministic fallback when
        # the configured relation has none of its own -- an application's
        # own meaningful order (e.g. most-recently-flagged first) is
        # respected rather than silently overridden.
        def bounded(relation, klass, limit)
          ordered = relation.order_values.empty? ? relation.order(klass.primary_key) : relation
          ordered.limit(limit).to_a
        end
      end
    end
    # rubocop:enable Metrics/BlockLength
  end
end
