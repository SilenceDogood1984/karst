# frozen_string_literal: true

require_relative "principal_source"
require_relative "principal_source_selection"
require_relative "approved_populations"
require_relative "../identity/devise_support"

module Karst
  module Access
    # Turns a locally selected set of ambiguous Devise models (see
    # Karst::Access::PrincipalSourceSelection) into ordinary
    # Karst::Access::PrincipalSource objects, one per selected model, each
    # keyed by that model's own Devise/Warden scope -- so selecting both
    # User and Admin produces two independently queryable sources
    # (:user => ..., :admin => ...) exactly like a hand-written
    # config.principal_sources would, never collapsed into one combined
    # source.
    #
    # Every selected name is revalidated against
    # Karst::Identity::DeviseSupport's *current* Devise.mappings on every
    # call: a name the file stores but Devise no longer maps (removed,
    # renamed) is silently dropped here, never constantized, and never
    # trusted on the strength of the file alone. If that drops every
    # selection, Karst is ambiguous again -- the developer is asked to
    # select once more, exactly like the first time.
    module SelectedPrincipalSources
      class << self
        # A Hash of Symbol(Devise scope) => PrincipalSource for every
        # currently valid selected mapping, or nil when local selection does
        # not apply at all (production, nothing selected, or every selected
        # mapping is now stale).
        def sources
          valid = mappings
          return nil if valid.empty?

          valid.to_h do |mapping|
            [mapping.scope, PrincipalSource.new(name: mapping.scope, records: -> { mapping.model.all })]
          end
        end

        # The subset of Karst::Identity::DeviseSupport.mappings a developer
        # has locally selected and that Devise still confirms right now --
        # used both to build #sources above and by Karst::Identity's own
        # ambiguous/ready checks, so neither has to know the storage format.
        # Always [] outside development/test (see
        # Karst::Access::ApprovedPopulations.local_environment?, the same
        # local-preference gate approved populations already use) and on any
        # failure -- selection is an optional convenience layered over
        # Devise's own metadata, never something whose breakage should take
        # down the panel, CLI, or MCP tool.
        def mappings
          return [] unless ApprovedPopulations.local_environment?

          record = PrincipalSourceSelection.load
          return [] if record.model_names.empty?

          current = Identity::DeviseSupport.mappings
          record.model_names.filter_map { |name| current.find { |mapping| mapping.model.name == name } }
        rescue StandardError
          []
        end
      end
    end
  end
end
