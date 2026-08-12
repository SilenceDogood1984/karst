# frozen_string_literal: true

require_relative "population_approvals"
require_relative "population_discovery"

module Karst
  module Access
    # Turns locally approved candidate populations (see
    # Karst::Access::PopulationApprovals) back into ordinary
    # Karst::Access::PrincipalSource populations, so that everything
    # downstream -- Access::Search, the panel, `bin/rails karst:verify`, the
    # MCP `verify_access` tool -- keeps reading exactly one source of truth
    # (Configuration#principal_sources) and needs to know nothing about
    # approval at all.
    #
    # Three independent conditions must hold before an approved entry becomes
    # executable, and any one of them failing silently drops it:
    #
    #   1. Karst is running in a local development/test environment. An
    #      approval file that reaches production (committed by accident,
    #      copied into an image) approves nothing there.
    #   2. The entry's model name matches the Active Record class of an
    #      already-configured (or inferred) principal source. The class is
    #      taken from that source -- never looked up, constantized, or loaded
    #      from the stored name -- so approval can only ever widen sampling
    #      within a model the application already pointed Karst at.
    #   3. Current source-based discovery still confirms that exact
    #      zero-argument `scope` declaration on that class. A scope that was
    #      removed, renamed, or given parameters stops being executed the
    #      moment the source changes, with no file edit required, and a
    #      hand-written entry naming an arbitrary class method is never
    #      confirmed in the first place.
    #
    # Explicit configuration always wins: a population name a source already
    # configures is never replaced or duplicated by an approved entry of the
    # same name, and configured populations keep their configured order ahead
    # of approved ones (see Access::Search, which tries them in exactly this
    # order).
    module ApprovedPopulations
      class << self
        # Returns a Hash of the same shape it was given, with each source's
        # populations extended by whatever its model has approved and
        # confirmed. Returns the argument untouched when nothing applies, so
        # the overwhelmingly common "no approvals" case costs one file stat.
        def merge(sources)
          return sources unless sources && local_environment?

          record = PopulationApprovals.load
          return sources if record.entries.empty?

          discovery = PopulationDiscovery.new
          sources.each_with_object({}) do |(name, source), merged|
            merged[name] = extend_source(source, record.entries, discovery)
          end
        rescue StandardError
          # Approval is an optional convenience layered over configuration
          # Karst already had. If resolving it fails for any reason, the
          # honest degradation is "explicitly configured populations only" --
          # never a broken panel, CLI, or MCP tool.
          sources
        end

        # Every approved entry that is not currently confirmed for any of the
        # given sources, as [Entry, reason] pairs -- the honest "this
        # approval exists but does nothing" list the panel shows. Never
        # executes anything.
        def stale(sources, record: PopulationApprovals.load, discovery: PopulationDiscovery.new)
          klasses = source_klasses(sources)
          record.entries.filter_map do |entry|
            klass = klasses[entry.model_name]
            next [entry, :no_principal_source] unless klass
            next [entry, :not_discovered] unless discovery.confirms?(klass: klass, method_name: entry.method_name)

            nil
          end
        end

        # Karst's local approval workflow is a development affordance and
        # nothing else. Test is included so an application's own test suite
        # (and Karst's) can exercise it; every other environment, production
        # included, ignores the file entirely.
        def local_environment?
          return false unless defined?(Rails) && Rails.respond_to?(:env)

          env = Rails.env
          env.respond_to?(:development?) && (env.development? || env.test?)
        end

        private

        def extend_source(source, entries, discovery)
          klass = source.record_klass
          return source unless klass

          approved = confirmed_populations(klass, entries, discovery, source.populations)
          approved.empty? ? source : source.with_populations(approved)
        end

        # The callable built here closes over the class object Karst already
        # held and a scope name discovery just confirmed -- no eval, no
        # const_get, no stored Ruby. It is an ordinary configured-population
        # callable from this point on, resolved (bounded, rollback-wrapped,
        # write-rejecting) by Access::CandidatePopulation like any other.
        def confirmed_populations(klass, entries, discovery, configured)
          entries.each_with_object({}) do |entry, approved|
            next unless entry.model_name == klass.name

            name = entry.method_name.to_sym
            next if configured.key?(name) || approved.key?(name)
            next unless discovery.confirms?(klass: klass, method_name: name)

            approved[name] = -> { klass.public_send(name) }
          end
        end

        # Deliberately keyed by model name: two principal sources over the
        # same model share that model's approvals, and an approval for a
        # model no source exposes belongs to none of them.
        def source_klasses(sources)
          (sources || {}).each_with_object({}) do |(_name, source), klasses|
            klass = source.record_klass
            klasses[klass.name] = klass if klass&.name
          end
        end
      end
    end
  end
end
