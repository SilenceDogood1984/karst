# frozen_string_literal: true

require_relative "principal_dimension"

module Karst
  module Access
    # One allowed principal population Karst may sample from or resolve
    # into -- "which records may Karst consider at all," a different
    # question from Karst::Access::PrincipalDimension ("which observed
    # states should Karst try to cover while sampling within it") and from
    # Karst::Access::CandidatePopulation ("which application-authored
    # relation, within this source, is worth trying first").
    #
    # `records` is a callable Karst evaluates lazily, exactly like the
    # legacy `config.principals` -- never enumerated, sampled, or
    # materialized just by building a PrincipalSource. A single legacy
    # config.principals (plus any config.principal_dimensions/
    # config.principal_populations) is normalized into one implicit
    # `:default` PrincipalSource internally (see
    # Karst::Configuration#principal_sources), so every downstream consumer
    # (PrincipalSelection, Identity.resolve, the panel) only ever has to
    # handle "one or more sources," never a separate single-source case.
    class PrincipalSource
      attr_reader :name, :records, :dimensions, :populations

      def initialize(name:, records:, dimensions: {}, populations: {})
        raise ArgumentError, "principal source #{name.inspect} must be callable" unless records.respond_to?(:call)

        @name = name.to_sym
        @records = records
        @dimensions = PrincipalDimension.normalize(dimensions)
        @populations = self.class.normalize_populations(@name, populations)
      end

      # Evaluates the configured records callable. Never enumerates or
      # queries on its own -- for an Active Record source this only builds a
      # Relation, exactly like Karst::Identity.principals already did for
      # the single-source case.
      def evaluate
        records.call
      end

      # The Active Record class this source's records ultimately belong to,
      # or nil for a source whose evaluated records are not an
      # ActiveRecord::Relation/Class (a plain Array/Enumerable source, or a
      # callable that raises). Only ever builds a Relation to read its
      # #klass -- never queries a row. Used to match a
      # Karst::Access::PopulationDiscovery-discovered model against an
      # already-configured principal source, and by the panel's guided
      # population retry.
      def record_klass
        evaluated = evaluate
        return evaluated if defined?(ActiveRecord::Base) && evaluated.is_a?(Class) && evaluated < ActiveRecord::Base
        return evaluated.klass if defined?(ActiveRecord::Relation) && evaluated.is_a?(ActiveRecord::Relation)

        nil
      rescue StandardError
        nil
      end

      # Accepts a raw Hash of name => (callable, or {records:, dimensions:,
      # populations:}) -- the shape config.principal_sources= receives.
      def self.normalize(sources)
        return nil if sources.nil?
        raise ArgumentError, "principal_sources must be a Hash of name => records/{records:, dimensions:}" unless
          sources.is_a?(Hash)

        sources.each_with_object({}) do |(name, spec), normalized|
          source = spec.is_a?(PrincipalSource) ? spec : from_spec(name, spec)
          normalized[source.name] = source
        end
      end

      def self.from_spec(name, spec)
        return new(name: name, records: spec) if spec.respond_to?(:call)

        unless spec.is_a?(Hash)
          raise ArgumentError, "principal source #{name.inspect} must be callable or a Hash with :records"
        end

        new(name: name, records: fetch_any(spec, :records), dimensions: fetch_any(spec, :dimensions) || {},
            populations: fetch_any(spec, :populations) || {})
      end

      # A configured population is a Hash of name => zero-argument callable
      # expected to return an ActiveRecord::Relation scoped to this same
      # source -- see Karst::Access::CandidatePopulation. Deliberately kept
      # as raw callables here, not wrapped into CandidatePopulation
      # instances: a CandidatePopulation represents one already-*resolved*
      # (queried) population, which only happens once PrincipalSampler
      # actually runs, never at configuration time.
      def self.normalize_populations(source_name, populations)
        return {} if populations.nil?

        valid = populations.is_a?(Hash) && populations.all? { |n, c| n.is_a?(Symbol) && c.respond_to?(:call) }
        unless valid
          raise ArgumentError,
                "principal source #{source_name.inspect} populations must be a Hash of Symbol => callable"
        end

        populations
      end

      def self.fetch_any(hash, key)
        hash.fetch(key) { hash[key.to_s] }
      end
      private_class_method :fetch_any
    end
  end
end
