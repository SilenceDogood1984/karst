# frozen_string_literal: true

require_relative "../value"
require_relative "principal_sampler"

module Karst
  module Access
    # Runs Karst::Access::PrincipalSampler independently per configured
    # Karst::Access::PrincipalSource -- never materializing multiple sources
    # together (no `Author.all.to_a + Reader.all.to_a`) -- and allocates the
    # combined candidates within one overall `limit`. The single-source case
    # (including the implicit legacy `:default` source Configuration builds
    # from a bare `config.principals`) behaves identically to calling
    # PrincipalSampler directly: this class only changes behavior once more
    # than one source is actually configured.
    #
    # Allocation policy (deliberately simple, not a general-purpose
    # scheduler): every non-empty source is guaranteed at least one
    # candidate, then remaining room is filled round-robin across sources,
    # each contributing its own candidates in the order PrincipalSampler
    # already prioritizes them (dimension-covering candidates before plain
    # fill). One source running out never blocks another from filling the
    # rest of the budget.
    class PrincipalSelection
      Result = Value.define(:principals, :candidates, :queries, :candidate_pool_size)

      def initialize(sources:, limit: Karst.config.access_sweep_limit,
                     pool_size: Karst.config.principal_candidate_pool_size)
        @sources = sources || {}
        @limit = limit
        @pool_size = pool_size
      end

      def call
        return empty_result if @sources.empty?

        per_source = sample_each_source
        build_result(per_source, allocate(per_source))
      end

      private

      def sample_each_source
        @sources.each_with_object({}) do |(name, source), memo|
          memo[name] = PrincipalSampler.new(source: source.evaluate, limit: @limit, pool_size: @pool_size,
                                            dimensions: source.dimensions).call
        end
      end

      def allocate(per_source)
        names = per_source.keys
        queues = per_source.transform_values { |result| result.candidates.dup }
        selected = []
        index = 0
        until selected.size >= @limit || queues.values.all?(&:empty?)
          take_one(queues, names[index % names.size], selected)
          index += 1
        end
        selected
      end

      def take_one(queues, name, selected)
        queue = queues.fetch(name)
        selected << [name, queue.shift] unless queue.empty?
      end

      def build_result(per_source, allocated)
        multi_source = per_source.size > 1
        candidates = allocated.map { |name, candidate| multi_source ? tag_source(candidate, name) : candidate }

        Result.new(
          principals: candidates.map(&:principal), candidates: candidates,
          queries: per_source.values.sum(&:queries), candidate_pool_size: combined_pool_size(per_source)
        )
      end

      def tag_source(candidate, name)
        PrincipalSampler::Candidate.new(principal: candidate.principal, reasons: candidate.reasons + ["source=#{name}"])
      end

      def combined_pool_size(per_source)
        sizes = per_source.values.filter_map(&:candidate_pool_size)
        sizes.empty? ? nil : sizes.sum
      end

      def empty_result
        Result.new(principals: [], candidates: [], queries: 0, candidate_pool_size: nil)
      end
    end
  end
end
