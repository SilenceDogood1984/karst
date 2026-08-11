# frozen_string_literal: true

require_relative "../value"

module Karst
  module Access
    # Renders a developer's curated selection of
    # Karst::Access::PopulationDiscovery::Candidate into a Ruby config
    # snippet they can copy into their own Karst.configure block. Karst
    # never writes to the host application's files on its own -- the
    # developer stays in control of what actually gets committed (see
    # README "Curation / persistence").
    module PopulationConfigSnippet
      # wired is the subset actually rendered into `code` (every selected
      # candidate whose model matches a configured principal source).
      # unwired is every selected candidate that is not wired into
      # anything yet -- present so the UI can say so honestly instead of
      # silently dropping a selection (see README "Principal vs artifact
      # populations": this release only wires principal populations).
      Result = Value.define(:code, :wired, :unwired)

      class << self
        def generate(candidates)
          unique = candidates.uniq { |candidate| [candidate.model_name, candidate.method_name] }
          wired, unwired = unique.partition(&:principal_source)
          Result.new(code: render(wired), wired: wired, unwired: unwired)
        end

        private

        def render(wired)
          return "# Select at least one population above to generate a configuration snippet.\n" if wired.empty?

          by_source = wired.group_by(&:principal_source)
          by_source.size == 1 && by_source.keys.first == :default ? flat(by_source.fetch(:default)) : nested(by_source)
        end

        def flat(candidates)
          "config.principal_populations = {\n#{entries(candidates, indent: 2)}\n}\n"
        end

        def nested(by_source)
          sources = by_source.map do |source, group|
            "  #{source_key(source)}: {\n    populations: {\n#{entries(group, indent: 6)}\n    }\n  }"
          end.join(",\n")
          "config.principal_sources = {\n#{sources}\n}\n"
        end

        # Sorted by model then method so the same selection always renders
        # byte-identical output, regardless of checkbox submission order.
        def entries(candidates, indent:)
          pad = " " * indent
          sorted = candidates.sort_by { |candidate| [candidate.model_name, candidate.method_name.to_s] }
          sorted.map { |candidate| entry(candidate, pad) }.join(",\n")
        end

        def entry(candidate, pad)
          "#{pad}#{candidate.method_name}: -> { #{candidate.model_name}.#{candidate.method_name} }"
        end

        def source_key(source)
          source.to_s =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/ ? source : source.inspect
        end
      end
    end
  end
end
