# frozen_string_literal: true

require_relative "value"
require_relative "identity/devise_support"
require_relative "identity/warden_adapter"
require_relative "access/selected_principal_sources"

module Karst
  # Framework-neutral identity seam for controlled probes. It deliberately
  # does not discover or enumerate principals; callers own that policy.
  #
  # For a conventional single-model Devise application, Karst can also infer
  # everything below automatically from Devise's own routing metadata and
  # Warden's public runtime API -- see DeviseSupport and WardenAdapter.
  # Explicit configuration (config.principals/config.principal_sources,
  # config.assume_identity/config.clear_identity,
  # config.assume_browser_identity/config.clear_browser_identity) always
  # overrides inference; inference never partially combines with explicit
  # configuration for the same seam.
  # rubocop:disable Metrics/ModuleLength
  module Identity
    class Error < StandardError; end
    class Unavailable < Error; end
    class ConfigurationError < Error; end

    PrincipalDescriptor = Value.define(:model_name, :id, :display_label)

    # Compact, inspectable report of why Karst's zero-config Devise/Warden
    # path is or isn't active. `status` is one of:
    #
    #   :ready_automatic -- principal source, probe identity, and browser
    #                        identity are all inferred; no configuration
    #                        required.
    #   :ready_mixed      -- at least one of principal source / probe
    #                        identity / browser identity is explicitly
    #                        configured and the rest are safely inferred
    #                        (e.g. an explicit config.principals selecting
    #                        one of several Devise models).
    #   :ready_explicit   -- principal source, probe identity, and browser
    #                        identity are all explicitly configured.
    #   :ambiguous        -- more than one Devise model was detected and no
    #                        explicit config.principals/principal_sources
    #                        selects one.
    #   :unavailable      -- Karst could not identify enough of an
    #                        authentication integration to run the primary
    #                        workflow without explicit configuration.
    #
    # `message` is nil whenever the caller's own local hint text already
    # says everything Karst can usefully add (the two ready states, and
    # :unavailable with no principal source at all -- every hint call site
    # already has its own "nothing is configured" wording for that). It is
    # populated only when Karst has something more specific to say: which
    # Devise models are ambiguous, or that a principal source exists but
    # probe/browser identity still couldn't be wired up automatically.
    SetupState = Value.define(:status, :message)

    # Delegates identity operations to the application's configured hooks.
    class ConfiguredAdapter
      def initialize(assume_hook, clear_hook)
        @assume_hook = assume_hook
        @clear_hook = clear_hook
      end

      def assume(session, principal)
        @assume_hook.call(session, principal)
      end

      def clear(session)
        @clear_hook.call(session)
      end
    end
    private_constant :ConfiguredAdapter

    # rubocop:disable Metrics/ClassLength
    class << self
      def principals
        source = Karst.config.principals
        return called_principal_source(source) if source

        inferred = DeviseSupport.unambiguous_mapping
        return inferred.model.all if inferred

        raise Unavailable, "no principal source is configured"
      end

      # The effective, normalized principal population(s): a Hash of Symbol
      # => Karst::Access::PrincipalSource, covering an explicit
      # config.principal_sources, a bare config.principals (wrapped as one
      # implicit :default source), and -- when neither is configured -- one
      # inferred Devise model (see Karst::Configuration#principal_sources).
      # Every multi-source-aware caller (Identity.resolve,
      # Access::PrincipalSelection, the panel) reads this instead of
      # config.principals directly.
      def principal_sources
        sources = Karst.config.principal_sources
        raise Unavailable, "no principal source is configured" unless sources

        sources
      end

      def with(session, principal)
        active_adapter = adapter(principal)
        # The hook may establish identity and then raise, so cleanup becomes
        # mandatory before invoking it rather than only after it returns.
        assumed = true
        active_adapter.assume(session, principal)
        yield
      ensure
        active_adapter.clear(session) if active_adapter && assumed
      end

      def clear(session)
        adapter.clear(session)
      end

      def describe(principal)
        model_name = model_name_for(principal)
        id = id_for(principal)
        label_hook = Karst.config.principal_label
        if label_hook && !label_hook.respond_to?(:call)
          raise ConfigurationError, "config.principal_label must be callable"
        end

        label = label_hook ? label_hook.call(principal) : "#{model_name} ##{id}"
        PrincipalDescriptor.new(model_name: model_name, id: id, display_label: label)
      end

      # Resolves only principals exposed by a configured source. In
      # particular, this never constantizes a submitted model name or
      # performs an unrestricted model lookup.
      #
      # Tries each configured Karst::Access::PrincipalSource in order and
      # returns the first match; a model name that does not belong to any
      # configured source resolves nothing, without ever touching that
      # source's records. For an Active Record relation/class source, a
      # matching model name resolves through a scoped primary-key query
      # against that exact relation instead of enumerating it -- a source
      # may cover hundreds of thousands of rows, and this must stay a single
      # bounded query regardless of table size. The relation's own WHERE
      # clauses (tenant scoping, soft deletes, and so on) still apply, so a
      # principal outside a configured relation is never resolved. A generic
      # Enumerable source (no scoped-query capability) keeps the original
      # enumerate-and-compare behavior, bounded to that one source.
      def resolve(model_name:, id:)
        principal_sources.each_value do |source|
          resolved = resolve_within_source(source, model_name: model_name, id: id)
          return resolved if resolved
        end
        nil
      end

      def browser_supported?
        explicit_browser_hooks? || automatic_browser_identity_available?
      end

      # Returns the Devise/Warden scope this browser identity was actually
      # assumed under (nil for explicit hooks, or for a non-Devise bare
      # Warden proxy) -- see Karst::Web::BrowserIdentity, which retains it
      # for the lifetime of the browser session so #clear_browser below never
      # has to guess which of several selected sources produced the
      # principal being cleared.
      def assume_browser(request, principal)
        raise Unavailable, "browser identity hooks are not configured" unless browser_supported?

        if explicit_browser_hooks?
          Karst.config.assume_browser_identity.call(request, principal)
          nil
        else
          warden_adapter = inferred_adapter(principal)
          warden_adapter.assume(request, principal)
          warden_adapter.scope
        end
      end

      # `scope`, when given, is the exact scope #assume_browser returned for
      # the identity actually being cleared (see
      # Karst::Web::BrowserIdentity) -- used in preference to
      # #scope_for_effective_source, which cannot always determine one on
      # its own with no principal in hand and several selected sources. Karst
      # still refuses to guess when neither is available.
      def clear_browser(request, scope: nil)
        raise Unavailable, "browser identity hooks are not configured" unless browser_supported?

        if explicit_browser_hooks?
          Karst.config.clear_browser_identity.call(request)
        else
          inferred_adapter(nil, scope: scope).clear(request)
        end
      end

      # See SetupState above. Cheap and side-effect free: touches only
      # already-established configuration/metadata plus, at most, calling a
      # configured principals/principal_sources callable the same way the
      # panel already does on every render to type-check its result (see
      # Access::PrincipalSampler.representative_capable?) -- never to
      # enumerate or query it.
      def setup_state
        return SetupState.new(status: :ambiguous, message: ambiguous_message) if ambiguous_principal_source?
        return SetupState.new(status: :unavailable, message: nil) unless principal_source_ready?
        return SetupState.new(status: :unavailable, message: unavailable_message) unless identity_channels_ready?

        SetupState.new(status: ready_status, message: nil)
      end

      private

      def resolve_within_source(source, model_name:, id:)
        records = source.evaluate
        relation = active_record_relation(records)
        return resolve_scoped(relation, model_name: model_name, id: id) if relation

        resolve_enumerated(records, model_name: model_name, id: id)
      end

      def active_record_relation(source)
        return source if defined?(ActiveRecord::Relation) && source.is_a?(ActiveRecord::Relation)
        return source.all if defined?(ActiveRecord::Base) && source.is_a?(Class) && source < ActiveRecord::Base

        nil
      end

      # A model-name mismatch is checked before ever touching the database:
      # each source is trusted to name one authoritative model, so a request
      # for a different model name is rejected without issuing a query
      # rather than attempting (and failing) a primary-key lookup against
      # the wrong table.
      def resolve_scoped(relation, model_name:, id:)
        klass = relation.klass
        return nil unless model_name_for_klass(klass) == model_name.to_s

        primary_key = klass.primary_key
        return nil unless primary_key.is_a?(String)

        relation.find_by(primary_key => id)
      end

      def resolve_enumerated(source, model_name:, id:)
        source.each do |principal|
          descriptor = describe(principal)
          return principal if descriptor.model_name == model_name.to_s && descriptor.id.to_s == id.to_s
        end
        nil
      end

      def identity_channels_ready?
        (explicit_probe_hooks? || automatic_identity_available?) &&
          (explicit_browser_hooks? || automatic_browser_identity_available?)
      end

      # Only called once every channel is already known to be ready (see
      # #identity_channels_ready? above), so this purely classifies *how*
      # each one got there -- inferred, explicit, or a mix of both (see
      # SetupState).
      def ready_status
        explicit = [!Karst.config.principals.nil?, explicit_probe_hooks?, explicit_browser_hooks?]
        return :ready_automatic if explicit.none?
        return :ready_explicit if explicit.all?

        :ready_mixed
      end

      def called_principal_source(source)
        raise ConfigurationError, "config.principals must be callable" unless source.respond_to?(:call)

        source.call
      end

      def adapter(principal = nil)
        assume_hook = Karst.config.assume_identity
        clear_hook = Karst.config.clear_identity
        return configured_adapter(assume_hook, clear_hook) if assume_hook || clear_hook

        inferred_adapter(principal)
      end

      def configured_adapter(assume_hook, clear_hook)
        unless assume_hook.respond_to?(:call) && clear_hook.respond_to?(:call)
          raise ConfigurationError,
                "config.assume_identity and config.clear_identity must both be callable"
        end
        ConfiguredAdapter.new(assume_hook, clear_hook)
      end

      # Builds a Warden-backed adapter for the automatic Devise/Warden path.
      # With a specific `principal`, scope comes straight from that
      # principal's own class -- the most direct evidence available, and
      # correct even when a source mixes multiple Devise-mapped subclasses,
      # regardless of how many principal_sources are configured. Without one,
      # `scope:` (when the caller already knows exactly which identity is
      # being cleared -- see #clear_browser) wins; otherwise scope falls back
      # to the single effective principal source's model -- see
      # #scope_for_effective_source. Devise loaded with no resolvable scope
      # refuses to guess rather than risk operating under the wrong Warden
      # scope.
      def inferred_adapter(principal, scope: nil)
        raise Unavailable, "no identity hooks are configured and Warden is unavailable" unless warden_available?
        return WardenAdapter.new unless DeviseSupport.available?

        resolved = scope || (principal ? DeviseSupport.mapping_for(principal.class)&.scope : scope_for_effective_source)
        unless resolved
          raise Unavailable,
                "Karst could not determine this principal's Devise/Warden scope automatically; " \
                "configure config.assume_identity/config.clear_identity " \
                "(or config.assume_browser_identity/config.clear_browser_identity)"
        end

        WardenAdapter.new(scope: resolved)
      end

      # Probe-identity eligibility. Preserves the pre-existing bare-Warden
      # fallback (no Devise, no scope) for a non-Devise application already
      # relying on Karst's isolated integration session -- see WardenAdapter.
      def automatic_identity_available?
        return false unless warden_available?
        return true unless DeviseSupport.available?

        every_effective_source_scoped?
      end

      # Browser-identity eligibility. Deliberately stricter than probe
      # eligibility above: automatically mutating the developer's *real*
      # browser session is only safe once Karst can prove the Devise
      # scope -- a bare bootstrapped Warden proxy with no scope is never
      # enough here, unlike the isolated probe session.
      def automatic_browser_identity_available?
        return false unless warden_available? && DeviseSupport.available?

        every_effective_source_scoped?
      end

      # True once every currently effective principal source resolves to its
      # own known Devise/Warden scope -- the single-source case this always
      # covered (see #scope_for_effective_source), plus several sources when
      # each is independently Devise-mapped, exactly what
      # Access::SelectedPrincipalSources builds from a local multi-model
      # selection. Per-principal scope resolution (#inferred_adapter with a
      # principal already in hand) is already correct for any number of
      # sources; this governs only "no principal yet" eligibility and the
      # bare-clear fallback, so it still refuses to guess when a source is
      # not provably Devise-scoped.
      def every_effective_source_scoped?
        sources = safe_principal_sources
        return false unless sources&.any?

        sources.values.all? { |source| devise_scope_for_source(source) }
      end

      def devise_scope_for_source(source)
        model = model_from_source(source)
        model && DeviseSupport.mapping_for(model)&.scope
      end

      def scope_for_effective_source
        model = effective_principal_model
        model && DeviseSupport.mapping_for(model)&.scope
      end

      # The model backing the *single* effective principal source, when one
      # can be determined without risk. Per-principal scope resolution (the
      # common case, with an actual principal instance already in hand)
      # never goes through this path at all, and is unaffected by how many
      # sources are configured -- see #every_effective_source_scoped? above
      # for the multi-source "no principal in hand" case.
      def effective_principal_model
        sources = safe_principal_sources
        return nil unless sources && sources.size == 1

        model_from_source(sources.values.first)
      end

      # A relation/class, exactly the same type-check the panel already
      # relies on for representative sampling, or the class of the first
      # element of an already materialized Array (safe to inspect without
      # issuing a query; evaluating the source callable itself is the same
      # already-accepted pattern the panel uses every render, see
      # Access::PrincipalSampler.representative_capable?). An unmaterialized
      # Enumerable/lazy source yields nil rather than guessing further --
      # automatic Warden scope resolution is unavailable there, by design
      # (see Identity::DeviseSupport and README).
      def model_from_source(source)
        records = source.evaluate
        active_record_model_from(records) || (records.first.class if records.is_a?(Array) && !records.empty?)
      rescue StandardError
        nil
      end

      def active_record_model_from(records)
        return records.klass if defined?(ActiveRecord::Relation) && records.is_a?(ActiveRecord::Relation)
        return records if defined?(ActiveRecord::Base) && records.is_a?(Class) && records < ActiveRecord::Base

        nil
      end

      def safe_principal_sources
        principal_sources
      rescue Error
        nil
      end

      def warden_available?
        defined?(Warden::Manager)
      end

      def explicit_probe_hooks?
        !!(Karst.config.assume_identity || Karst.config.clear_identity)
      end

      def explicit_browser_hooks?
        Karst.config.assume_browser_identity.respond_to?(:call) &&
          Karst.config.clear_browser_identity.respond_to?(:call)
      end

      def ambiguous_principal_source?
        return false if Karst.config.principals || Karst.config.configured_principal_sources
        return false if Access::SelectedPrincipalSources.mappings.any?

        DeviseSupport.mappings.size > 1
      end

      def principal_source_ready?
        !Karst.config.principals.nil? || !Karst.config.configured_principal_sources.nil? ||
          !DeviseSupport.unambiguous_mapping.nil? || Access::SelectedPrincipalSources.mappings.any?
      end

      def ambiguous_message
        names = DeviseSupport.mappings.map { |mapping| mapping.model.name }.sort.join(", ")
        "Karst detected multiple Devise models (#{names}). Select which one(s) to test at /karst, " \
          "or configure config.principals/config.principal_sources explicitly."
      end

      def unavailable_message
        "Karst found a principal source but could not automatically wire up probe/browser identity for it. " \
          "Configure config.assume_identity/config.clear_identity and " \
          "config.assume_browser_identity/config.clear_browser_identity."
      end

      def model_name_for(principal)
        model_name_for_klass(principal.class)
      end

      def model_name_for_klass(klass)
        klass.respond_to?(:model_name) ? klass.model_name.name.to_s : klass.name.to_s
      end

      def id_for(principal)
        raise ConfigurationError, "principal must expose an id" unless principal.respond_to?(:id)

        principal.id
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
  # rubocop:enable Metrics/ModuleLength
end
