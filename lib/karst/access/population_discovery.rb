# frozen_string_literal: true

require_relative "../value"

module Karst
  module Access
    # Explicit, non-executing discovery of application-authored candidate
    # populations: which application Active Record models exist, and which
    # of their own public class methods are *shaped* like a zero-argument,
    # relation-producing scope. This is a hint about where a developer might
    # look next -- never a claim that a discovered name is a real named
    # scope, returns anything useful, or means anything about authorization.
    # See Karst::Access::CandidatePopulation for why Active Record exposes
    # no reliable registry that would distinguish a real named scope from an
    # ordinary handwritten class method; discovery inherits that same
    # limitation and stays honest about it rather than pretending certainty.
    #
    # Discovery never executes a discovered method, never issues a query,
    # and never infers behavior -- it only introspects already-loaded Ruby
    # class metadata (singleton methods, arity). Turning a discovered name
    # into evidence about whether it actually returns a usable relation is a
    # separate, explicit step (see Karst::Access::PopulationPreview).
    #
    # Intended to run only from an explicit developer action -- the
    # `karst:populations` rake task, or loading /karst/populations -- never
    # automatically on every ordinary /karst request.
    class PopulationDiscovery
      # Framework/internal Active Record models excluded from candidacy --
      # not something a developer authored, and not useful as a principal or
      # artifact population.
      FRAMEWORK_NAMESPACES = %w[ActiveRecord ActiveStorage ActionText ActionMailbox].freeze

      # Method-name shapes that are conventionally not relation-returning
      # finders (mutators, boolean predicates, writers) -- excluded to keep
      # the discovered list honest about what it actually is: a heuristic,
      # not a guarantee. A false negative here (skipping a real scope with
      # an unusual name) is an acceptable, disclosed tradeoff; discovery
      # never claims this list is complete, only that everything on it is
      # at least *shaped* like something callable with no arguments.
      EXCLUDED_SUFFIXES = %w[! ? =].freeze

      # Bounds how many candidate names a single unusually wide model (one
      # with many of its own class methods) can contribute. This is a
      # metadata cap only -- discovery issues no query at all, so it does
      # not depend on row count the way PrincipalSampler's dimension caps
      # do.
      MAX_CANDIDATES_PER_MODEL = 100

      Candidate = Value.define(:model_name, :method_name, :principal_source)

      # candidate_names is a sorted Array of Symbol method names.
      # principal_source is the Symbol name of the configured
      # config.principal_sources entry whose records evaluate to this exact
      # model class, or nil when no configured principal source matches --
      # see Karst::Access::PrincipalSource#record_klass. This is metadata
      # only, computed by re-evaluating already-configured source callables
      # (never a query); it does not change which candidates are
      # discovered, only how the UI labels/routes them (see README
      # "Principal vs artifact populations").
      ModelGroup = Value.define(:model_name, :candidate_names, :principal_source) do
        def candidates
          candidate_names.map do |method_name|
            Candidate.new(model_name: model_name, method_name: method_name, principal_source: principal_source)
          end
        end
      end

      # load_warning is a plain human-readable String (never raised) when
      # eager-loading the application to enumerate its models failed
      # partway through -- discovery still reports whatever models were
      # already loaded rather than failing outright, but says so honestly
      # instead of silently under-reporting.
      Result = Value.define(:model_groups, :load_warning) do
        def candidates
          model_groups.flat_map(&:candidates)
        end
      end

      def call
        Result.new(model_groups: model_groups, load_warning: @load_warning)
      end

      private

      def model_groups
        candidate_models.map do |klass|
          ModelGroup.new(model_name: klass.name, candidate_names: candidate_method_names(klass),
                         principal_source: principal_source_for(klass))
        end.sort_by(&:model_name)
      end

      # Rails may not have autoloaded every model file yet (Zeitwerk loads
      # lazily on first reference) -- eager_load! is the only reliable way
      # to see the full application model set, and calling it here is safe
      # specifically because discovery is always one explicit, developer-
      # triggered action (a rake task, or navigating to /karst/populations),
      # never something invoked on every ordinary /karst page render. A
      # load failure aborts eager_load! itself but not discovery: whatever
      # loaded before the failure is still reported, alongside an honest
      # warning, rather than a silently incomplete list presented as
      # complete.
      def eager_load_application!
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Rails.application.eager_load!
      rescue StandardError => e
        @load_warning = "The application could not be fully loaded (#{e.class}: #{e.message}); " \
                        "discovery may be missing some models."
      end

      def candidate_models
        @candidate_models ||= begin
          eager_load_application!
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.descendants.select do |klass|
              application_model?(klass)
            end.uniq
          else
            []
          end
        end
      end

      def application_model?(klass)
        klass.name && !klass.abstract_class? && !framework_model?(klass)
      end

      def framework_model?(klass)
        FRAMEWORK_NAMESPACES.any? { |namespace| klass.name == namespace || klass.name.start_with?("#{namespace}::") }
      end

      def candidate_method_names(klass)
        own_public_class_methods(klass).select do |name|
          candidate_shape?(klass, name)
        end.sort.first(MAX_CANDIDATES_PER_MODEL)
      end

      # Only methods defined directly on this exact class's singleton class
      # -- inherited methods (including Karst's own configured
      # config.principal_populations callables, which are not methods at
      # all) never appear here. A class method contributed by an
      # ActiveSupport::Concern's `class_methods do ... end` block is added
      # via `extend`, not defined directly, so it is not seen either; this
      # is a known, disclosed gap (see class comment), not a silent one.
      def own_public_class_methods(klass)
        klass.singleton_class.public_instance_methods(false) - base_class_methods
      end

      def base_class_methods
        @base_class_methods ||= ActiveRecord::Base.singleton_class.public_instance_methods(false)
      end

      def candidate_shape?(klass, name)
        label = name.to_s
        return false if label.start_with?("_")
        return false if EXCLUDED_SUFFIXES.any? { |suffix| label.end_with?(suffix) }

        zero_arity?(klass, name)
      end

      # arity <= 0 covers both "exactly zero parameters" (0) and "zero
      # required parameters, plus optional/splat/keyword ones" (negative) --
      # both shapes are callable with no arguments, which is the only shape
      # a population callable (`-> { Model.method_name }`) can ever invoke.
      # A method requiring at least one argument (positive arity) cannot be
      # called this way and is excluded.
      def zero_arity?(klass, name)
        klass.method(name).arity <= 0
      rescue StandardError
        false
      end

      def principal_source_for(klass)
        principal_source_klasses.each do |name, source_klass|
          return name if source_klass == klass
        end
        nil
      end

      def principal_source_klasses
        sources = Karst.config.principal_sources || {}
        @principal_source_klasses ||= sources.each_with_object({}) do |(name, source), memo|
          klass = source.record_klass
          memo[name] = klass if klass
        end
      end
    end
  end
end
