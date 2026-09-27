# frozen_string_literal: true

require "rack/utils"

module Karst
  module CLI
    # The bounded, human-readable outcome lines for one probe stage (the
    # ordinary sample, one population retry), built from already-computed
    # Access::OutcomeGroups groups.
    #
    # Counts, not conclusions: each line is one semantic outcome group and
    # the number of users that observed it, largest first. The largest group
    # is only ever marked by position -- Karst never calls it "dominant",
    # "most", or "typical", so a close split (12 / 11 / 9) reads as exactly
    # that. When one group is strictly larger than every other, its users are
    # not listed (it is the outcome the rest differ from); every other group
    # names up to MAX_EXAMPLES of its users, which are the ones worth
    # inspecting. When the largest count is tied, no group is singled out and
    # every group names examples.
    #
    # Output stays bounded however many users were tested: at most
    # MAX_OUTCOMES group lines (verified-usable groups are always shown -- they
    # are the answer to the question the sweep asks), one examples line per
    # listed group, and one line summarizing whatever else was observed. The
    # complete per-user evidence stays in `--json`.
    class OutcomeSummary
      MAX_OUTCOMES = 5
      MAX_EXAMPLES = 3

      def initialize(groups, indent: "  ")
        @groups = groups
        @indent = indent
      end

      def lines
        return [] if @groups.empty?

        width = shown.map { |group| group.count.to_s.size }.max
        rows = shown.flat_map { |group| group_lines(group, width) }
        rows << hidden_line if hidden.any?
        rows
      end

      # One outcome group as a single line of observed facts, in Karst's own
      # terms (see Web::Panel#outcome_title and CLI::Verification's
      # response evidence) -- never "denied", "allowed", or any other
      # authorization claim the application itself did not make.
      def describe(group)
        item = group.representative
        parts = [response(item), (dispatch(item) if dispatch_varies?), body_marker(item.body_marker_observed),
                 (writes(item.write_count) if item.writes_observed), ("verified usable" if group.usable)]
        parts.insert(1, "halted at #{item.halted_callback}") if item.halted_callback
        parts.compact.join(" · ")
      end

      private

      def group_lines(group, width)
        line = ["#{@indent}#{group.count.to_s.rjust(width)}  #{describe(group)}"]
        line << "#{@indent}#{' ' * width}    #{examples(group)}" if examples?(group)
        line
      end

      def shown
        @shown ||= @groups.each_with_index.select { |group, index| index < MAX_OUTCOMES || group.usable }
                          .map(&:first)
      end

      def hidden
        @hidden ||= @groups - shown
      end

      def hidden_line
        users = hidden.sum(&:count)
        "#{@indent}+#{hidden.size} more #{hidden.size == 1 ? 'outcome' : 'outcomes'} " \
          "(#{users} #{users == 1 ? 'user' : 'users'}); --json lists every outcome"
      end

      def examples?(group)
        return false if @groups.size == 1

        !(unique_largest? && group.equal?(@groups.first))
      end

      def unique_largest?
        @groups.size == 1 || @groups[0].count > @groups[1].count
      end

      def examples(group)
        labels = group.outcomes.first(MAX_EXAMPLES).map { |item| label(item.principal) }
        remaining = group.count - labels.size
        labels << "+#{remaining} more" if remaining.positive?
        labels.join(", ")
      end

      def label(principal)
        principal ? principal.display_label.to_s : "anonymous request"
      end

      def response(item)
        return "exception #{item.exception_class}" if item.exception_class
        return "no response observed" unless item.status

        status = status_title(item.status)
        item.redirect ? "#{status} → #{item.redirect}" : status
      end

      def status_title(status)
        phrase = Rack::Utils::HTTP_STATUS_CODES[status]
        phrase ? "#{status} #{phrase}" : status.to_s
      end

      # Two groups must never read identically. Dispatch is part of the
      # semantic key but normally uniform for one path, so it is printed only
      # when groups in this stage actually disagree about it.
      def dispatch_varies?
        return @dispatch_varies if defined?(@dispatch_varies)

        @dispatch_varies = @groups.map { |group| dispatch(group.representative) }.uniq.size > 1
      end

      def dispatch(item)
        item.controller ? "#{item.controller}##{item.action}" : "no controller dispatched"
      end

      # Only ever set when a caller asked Sweep to look for a body marker.
      def body_marker(observed)
        return nil if observed.nil?

        observed ? "body marker observed" : "body marker absent"
      end

      def writes(count)
        "#{count} database #{count == 1 ? 'write' : 'writes'}"
      end
    end
  end
end
