# frozen_string_literal: true

require_relative "../value"

module Karst
  module Access
    # The one definition of "these probes observed the same thing", shared by
    # Access::Result#groups, the CLI/MCP evidence document, the human CLI
    # summary, and the /karst panel -- so no surface can split or merge
    # outcomes differently from another.
    #
    # A group is keyed by what Karst observed about the *request*: the
    # response, where it dispatched, what it wrote, and whether the configured
    # usable_access_outcome policy accepts it. Everything about the *probe*
    # that made the request -- who it ran as, how that identity was observed,
    # why that principal was sampled, how long it took -- is deliberately not
    # part of the key: two users halted at the same callback are one outcome
    # observed twice, not two outcomes. Those per-probe details stay attached
    # to each member outcome, so nothing is lost by grouping.
    #
    # Nothing here normalizes observed values (no redirect path rewriting, no
    # status bucketing): two outcomes group only when every semantic field is
    # exactly equal, so grouping can merge equivalent observations but never
    # reinterpret distinct ones as the same.
    module OutcomeGroups
      # Observed facts about the request. Two outcomes that differ in any of
      # these are different outcomes.
      SEMANTIC_FIELDS = %i[status redirect exception_class halted_callback controller action
                           writes_observed write_count database_rollback_attempted].freeze

      # Facts about the probe, not the request's outcome. Volatile (elapsed
      # time), per-identity (principal, identity evidence), or sampling
      # provenance -- never part of group identity.
      PROBE_METADATA = %i[principal identity sampling_reasons elapsed_ms].freeze

      # `usable` is the configured usable_access_outcome verdict, shared by
      # every member (it is part of the key), so a group can always be
      # described as verified usable or not without consulting any one member.
      Group = Value.define(:key, :outcomes, :usable) do
        def count
          outcomes.size
        end

        # Every member agrees on every SEMANTIC_FIELDS value, so any member
        # describes the group; the first one observed is used.
        def representative
          outcomes.first
        end
      end

      class << self
        # Groups `outcomes` and orders the groups deterministically: largest
        # first, then by the semantic key itself, so the same observations
        # produce the same order regardless of the order they were probed in.
        # Members keep the order they were probed in. `usable` is evaluated
        # exactly once per outcome.
        def group(outcomes, usable: Karst.config.usable_access_outcome)
          groups = partition(outcomes, usable).map do |group_key, (verdict, members)|
            Group.new(key: group_key, outcomes: members.freeze, usable: verdict)
          end
          groups.sort_by { |item| [-item.count, sort_key(item.key)] }
        end

        # halted_callback is compared by its string form: Rails reports a
        # named callback as a Symbol, and the serialized evidence reports it
        # as a String, so the two must never become separate groups.
        def key(outcome)
          SEMANTIC_FIELDS.map do |field|
            value = outcome.respond_to?(field) ? outcome.public_send(field) : nil
            field == :halted_callback && !value.nil? ? value.to_s : value
          end
        end

        private

        # semantic key + verdict => [verdict, members in probe order]
        def partition(outcomes, usable)
          outcomes.each_with_object({}) do |outcome, grouped|
            verdict = usable.call(outcome) ? true : false
            (grouped[key(outcome) + [verdict]] ||= [verdict, []]).last << outcome
          end
        end

        # A total order over heterogeneous values (Integer, String, booleans,
        # nil) that never raises: nil sorts first, everything else by its
        # string form.
        def sort_key(values)
          values.map { |value| value.nil? ? [0, ""] : [1, value.to_s] }
        end
      end
    end
  end
end
