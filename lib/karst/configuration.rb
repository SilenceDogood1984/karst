# frozen_string_literal: true

require_relative "access/principal_source"
require_relative "access/approved_populations"
require_relative "access/selected_principal_sources"
require_relative "identity/devise_support"

module Karst
  # Raised when an initializer sets a configuration option Karst has removed.
  # A NoMethodError subclass, so a removed option fails exactly like an
  # ordinary typo would -- but with a message naming the removal and what
  # replaced it. Karst never reinterprets a removed option as something else.
  class RemovedConfiguration < NoMethodError; end

  # Process-level settings that control Karst's implemented behavior.
  #
  # Karst is designed so that a conventional application configures none of
  # this. A single-model Devise app is inferred outright, candidate
  # populations are approved locally at /karst/populations rather than
  # written here, and every limit below already has a bounded default. What
  # remains is for exceptional applications: custom (non-Devise)
  # authentication, identity spread across several models, and a handful of
  # deliberately unprominent bounds. See docs/advanced-configuration.md.
  class Configuration
    # `enabled` is the only option an ordinary application ever sets. The
    # rest are escape hatches for custom (non-Devise) authentication --
    # principals, assume_identity, clear_identity, principal_label, and the
    # browser Test-as pair -- and are documented as such.
    attr_accessor :enabled, :principals, :assume_identity, :clear_identity, :principal_label,
                  :assume_browser_identity, :clear_browser_identity

    # principal_populations is an escape hatch (committed, reviewable
    # populations for CI); the four bounds after it are advanced tuning an
    # ordinary developer should never need to see.
    #
    # configured_principal_sources is internal: what the application
    # explicitly configured, before Devise inference or local approvals are
    # folded in. Read only by Karst::Identity to distinguish "configured"
    # from "inferred"; not part of the documented configuration surface.
    attr_reader :principal_populations, :access_sweep_limit, :population_retry_limit,
                :principal_candidate_pool_size, :usable_access_outcome, :configured_principal_sources

    # What Karst treats as "this user can use the page": an observed 200 with
    # no contrary evidence. Older/custom outcome-like values may expose only
    # a status; an absent optional evidence field means Karst did not observe
    # that evidence, just as an explicit nil does, and must not make the
    # policy itself crash.
    DEFAULT_USABLE_ACCESS_OUTCOME = lambda do |outcome|
      unobserved = ->(attribute) { !outcome.respond_to?(attribute) || outcome.public_send(attribute).nil? }
      outcome.status == 200 && unobserved.call(:exception_class) && unobserved.call(:halted_callback)
    end

    MAX_ACCESS_SWEEP_LIMIT = 100

    # How many records a single candidate population may contribute when
    # Karst automatically retries it after an ordinary sample found nothing
    # usable (see Karst::Access::Search). Kept deliberately small: the point
    # of a population retry is to answer "does this population reach the
    # behavior at all," which one or two records already settle -- not to
    # survey the population. The total number of extra requests a retry may
    # issue is bounded separately, by access_sweep_limit, so adding
    # populations can never make an analysis cost more than roughly twice an
    # ordinary sweep.
    MAX_POPULATION_RETRY_LIMIT = 10

    # Conservative hard ceiling on how many recent principals a
    # representative-sampling candidate pool may ever cover. This bounds the
    # cost of the one bounded pool query the sampler issues, independent of
    # how large the underlying table actually is.
    MAX_PRINCIPAL_CANDIDATE_POOL_SIZE = 10_000

    # Options Karst used to expose, mapped to what an application should do
    # instead. Karst is pre-1.0 and prefers a clean surface to accumulated
    # accidental complexity -- but a removed option must say so out loud
    # rather than be silently ignored or quietly reinterpreted.
    REMOVED = {
      buffer_size: "runtime SQL capture was removed; Karst reports evidence from the requests it " \
                   "actually runs, and no longer keeps a process-wide sql.active_record buffer",
      principal_dimensions: "sampling states are derived from the schema automatically; there is " \
                            "nothing to declare, and rare users are reached through candidate " \
                            "populations approved at /karst/populations",
      artifact_source: "artifact scenarios were removed; Karst analyzes routes, not record sweeps",
      access_scenario: "artifact scenarios were removed; Karst analyzes routes, not record sweeps"
    }.freeze

    def initialize
      @enabled = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.development? || Rails.env.test? : false
      @access_sweep_limit = 25
      @principal_candidate_pool_size = 1_000
      @population_retry_limit = 3
      @usable_access_outcome = DEFAULT_USABLE_ACCESS_OUTCOME
      @principal_populations = {}
      @configured_principal_sources = nil
      %i[@principals @assume_identity @clear_identity @principal_label
         @assume_browser_identity @clear_browser_identity].each { |hook| instance_variable_set(hook, nil) }
    end

    # An application-authored hint about meaningful candidate populations for
    # whatever config.principals returns -- a Hash of name => zero-argument
    # callable, each expected to return an ActiveRecord::Relation scoped to
    # that same model, for example:
    #
    #   config.principal_populations = {
    #     system_admins: -> { User.system_admins },
    #     auditors: -> { User.auditors }
    #   }
    #
    # This is the committed-to-source form of what /karst/populations already
    # captures locally, and is needed only where machine-local approval state
    # is deliberately not consulted (CI) or where populations should be
    # reviewable code. Karst never infers that a population grants access or
    # produces any UI state; it only tries records from it (see
    # Karst::Access::PrincipalSampler/CandidatePopulation). nil/{} (the
    # default) considers no configured populations at all. Karst does not
    # attempt to verify that a callable's body is a "real" Rails named scope
    # -- it only checks what calling it actually returns. Applications
    # representing identity as more than one model configure populations per
    # source instead (see config.principal_sources).
    def principal_populations=(populations)
      @principal_populations = Access::PrincipalSource.normalize_populations(:default, populations)
    end

    def principal_sources=(sources)
      @configured_principal_sources = Access::PrincipalSource.normalize(sources)
    end

    # The effective, normalized principal population(s) Karst may sample
    # from or resolve into: explicit config.principal_sources when
    # configured, otherwise a bare config.principals (plus any
    # config.principal_populations) wrapped as one implicit :default source,
    # otherwise -- when neither is configured -- one inferred Devise model
    # wrapped the same way (see Karst::Identity::DeviseSupport), otherwise --
    # with several Devise models and nothing explicit -- whatever a
    # developer has locally selected at /karst (see
    # Access::SelectedPrincipalSources, one source per selected model, each
    # keyed by its own Devise scope), or nil when none of those apply. A
    # Hash of Symbol => PrincipalSource.
    #
    # This is also where locally approved discovered populations (see
    # Karst::Access::ApprovedPopulations) join the effective configuration,
    # after each source's own explicitly configured populations. Every
    # adapter -- the panel, `bin/rails karst:verify`, the MCP verify_access
    # tool -- reads this one method, so none of them knows or can diverge on
    # what a "approved population" is. Resolved on every call rather than
    # memoized: an approval revoked, or a scope deleted, must stop being
    # executed on the next analysis without a server restart.
    def principal_sources
      Access::ApprovedPopulations.merge(configured_or_inferred_sources)
    end

    def access_sweep_limit=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_ACCESS_SWEEP_LIMIT
        raise ArgumentError, "access_sweep_limit must be between 1 and #{MAX_ACCESS_SWEEP_LIMIT}"
      end

      @access_sweep_limit = value
    end

    def principal_candidate_pool_size=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_PRINCIPAL_CANDIDATE_POOL_SIZE
        raise ArgumentError,
              "principal_candidate_pool_size must be between 1 and #{MAX_PRINCIPAL_CANDIDATE_POOL_SIZE}"
      end

      @principal_candidate_pool_size = value
    end

    def population_retry_limit=(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_POPULATION_RETRY_LIMIT
        raise ArgumentError, "population_retry_limit must be between 1 and #{MAX_POPULATION_RETRY_LIMIT}"
      end

      @population_retry_limit = value
    end

    def usable_access_outcome=(policy)
      raise ArgumentError, "usable_access_outcome must be callable" unless policy.respond_to?(:call)

      @usable_access_outcome = policy
    end

    private

    # A removed option fails loudly and says what replaced it, rather than
    # reaching Ruby's generic "undefined method" and leaving a developer to
    # guess whether Karst renamed, moved, or silently ignored it.
    def method_missing(name, *)
      removal = REMOVED[name.to_s.delete_suffix("=").to_sym]
      return super unless removal

      raise RemovedConfiguration,
            "config.#{name.to_s.delete_suffix('=')} was removed from Karst: #{removal}"
    end

    def respond_to_missing?(name, include_private = false)
      REMOVED.key?(name.to_s.delete_suffix("=").to_sym) || super
    end

    def configured_or_inferred_sources
      return @configured_principal_sources if @configured_principal_sources
      return default_principal_source(@principals) if @principals

      inferred = Identity::DeviseSupport.unambiguous_mapping
      return default_principal_source(-> { inferred.model.all }) if inferred

      # Several Devise models and nothing explicit: fall back to whatever a
      # developer has locally selected at /karst (see
      # Access::SelectedPrincipalSources), still nil when nothing has been
      # selected or every selection has gone stale -- Karst never guesses.
      Access::SelectedPrincipalSources.sources
    end

    def default_principal_source(records)
      { default: Access::PrincipalSource.new(name: :default, records: records,
                                             populations: @principal_populations) }
    end
  end
end
