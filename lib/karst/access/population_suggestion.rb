# frozen_string_literal: true

require_relative "../value"

module Karst
  module Access
    # A small, transparent, name-token heuristic for ranking already-approved
    # populations against one observed runtime signal (typically an
    # Access::Outcome#halted_callback, e.g. :authorize_admin). This never
    # claims causality -- a shared token like "admin" between a halted
    # callback and a population name is not evidence that the population
    # would pass, only a plain-text reason a developer might want to try it
    # first. No AI/NLP: tokens split on underscore/word boundaries, compared
    # by plain substring containment in either direction (so "admin" matches
    # "admins" -- simple, disclosed pluralization tolerance, not stemming),
    # nothing more. Every approved population is always returned, ranked or
    # not -- this never hides a choice, only orders them.
    module PopulationSuggestion
      # Common verb/framework tokens stripped from the *observed* signal
      # only (never from population names themselves) so that, for example,
      # "authorize_admin" contributes the meaningful token "admin", not the
      # near-universal "authorize".
      OBSERVED_STOPWORDS = %w[require ensure check verify authorize authorized authorization authentication
                              authenticate action callback filter before after around].freeze

      # matched_tokens is empty for a population that shares no token with
      # the observed signal -- still a legitimate, always-visible choice,
      # just not a suggested one.
      Suggestion = Value.define(:name, :matched_tokens)

      class << self
        # observed: a Symbol/String/nil (e.g. a halted_callback name).
        # population_names: an Array of approved Symbol population names.
        # Returns { suggested: [Suggestion, ...] (highest overlap first),
        # other: [Suggestion, ...] (no token overlap) } -- every name from
        # population_names appears in exactly one of the two, never dropped.
        def rank(observed:, population_names:)
          observed_tokens = tokenize(observed) - OBSERVED_STOPWORDS
          scored = population_names.map do |name|
            Suggestion.new(name: name, matched_tokens: matched_tokens(observed_tokens, tokenize(name)))
          end
          suggested, other = scored.partition { |suggestion| suggestion.matched_tokens.any? }
          { suggested: suggested.sort_by { |suggestion| -suggestion.matched_tokens.size }, other: other }
        end

        private

        # observed_tokens surfaced here, not name_tokens: this is meant to
        # read as "why the halted signal pointed at this population" (e.g.
        # "name match: admin"), not the other way round.
        def matched_tokens(observed_tokens, name_tokens)
          observed_tokens.select { |token| name_tokens.any? { |name_token| overlap?(token, name_token) } }
        end

        def overlap?(observed_token, name_token)
          observed_token.include?(name_token) || name_token.include?(observed_token)
        end

        def tokenize(value)
          value.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
        end
      end
    end
  end
end
