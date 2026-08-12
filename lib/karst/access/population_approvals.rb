# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../value"

module Karst
  module Access
    # The local, machine-scoped record of which discovered candidate
    # populations a developer has explicitly allowed Karst to execute
    # automatically (see Karst::Access::ApprovedPopulations for how an
    # approval is turned back into something runnable, and
    # Karst::Access::PopulationDiscovery for what can be discovered at all).
    #
    # Deliberately *data*, never code: an entry is a model name and a scope
    # name, and nothing else. Karst never writes a lambda, a snippet, or any
    # other executable Ruby into this file, and never evaluates its contents
    # -- an entry is only ever compared, as a string, against what current
    # source-based discovery independently confirms. That is what keeps this
    # file from degrading into an arbitrary method allowlist: adding
    # `{"model": "User", "scope": "destroy_all"}` by hand approves nothing,
    # because discovery will not confirm it.
    #
    # Stored under the host application's `tmp/` (`tmp/karst/`) on purpose:
    # Rails already treats `tmp/` as machine-local, disposable, and
    # git-ignored, which is exactly the intended lifetime of a local
    # development approval. Deleting the file resets every approval; nothing
    # else in Karst is affected. Karst never edits the host application's
    # initializer or any other committed file.
    #
    # Every read fails closed. A file that is unreadable, is not JSON, is not
    # the expected document shape, carries an unknown schema version, or
    # holds a single unusable entry approves *nothing at all* and reports an
    # error for the panel to show -- rather than partially trusting a
    # document Karst cannot fully account for.
    # rubocop:disable Metrics/ModuleLength
    module PopulationApprovals
      SCHEMA_VERSION = 1

      RELATIVE_PATH = File.join("tmp", "karst", "approved_populations.json")

      # Both names are matched against exactly what PopulationDiscovery can
      # produce -- a real constant path, and a scope name Ripper read from a
      # literal symbol/string in `scope :name, -> { ... }`. Anything else is
      # rejected before it can even be compared to a discovered candidate.
      MODEL_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
      SCOPE_NAME = /\A[a-z_][A-Za-z0-9_]*\z/

      # A bound on how much of this file Karst will consider at all, so a
      # corrupted or maliciously grown document cannot turn every principal
      # source resolution into an unbounded amount of source parsing.
      MAX_ENTRIES = 500

      Entry = Value.define(:model_name, :method_name) do
        def matches?(model_name, method_name)
          self.model_name == model_name.to_s && self.method_name == method_name.to_s
        end

        def display_label
          "#{model_name}.#{method_name}"
        end
      end

      # `entries` is always usable (possibly empty) and always sorted;
      # `error` is a human-readable reason the stored document was rejected
      # or could not be written, or nil.
      Record = Value.define(:entries, :error) do
        def approved?(model_name, method_name)
          entries.any? { |entry| entry.matches?(model_name, method_name) }
        end
      end

      class << self
        def path
          File.join(root, RELATIVE_PATH)
        end

        # The path as a developer should see it: relative to the application
        # root, since that is where they will go looking for (or delete) it.
        def display_path
          RELATIVE_PATH
        end

        def load
          document = JSON.parse(File.read(path))
          parse(document)
        rescue Errno::ENOENT
          empty
        rescue JSON::ParserError
          failed("could not be read as JSON")
        rescue StandardError => e
          failed("could not be read (#{e.class})")
        end

        # Replaces the whole approval set with `entries`, atomically: callers
        # always submit the complete list they intend to keep, so unapproving
        # is simply approving a smaller set, and a partially written file can
        # never be observed.
        def replace(entries)
          normalized = normalize(entries)
          write(normalized)
          Record.new(entries: normalized, error: nil)
        rescue StandardError => e
          Record.new(entries: normalized || [].freeze, error: "approvals could not be saved (#{e.class})")
        end

        private

        def root
          return Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

          Dir.pwd
        end

        def parse(document)
          reason = rejection(document)
          return failed(reason) if reason

          entries = document["approved"].map { |item| entry(item) }
          return failed("holds an entry Karst does not recognize") if entries.include?(nil)

          Record.new(entries: sort(entries.uniq).freeze, error: nil)
        end

        def rejection(document)
          return "is not a Karst approval document" unless document.is_a?(Hash)
          return "was written by an incompatible Karst version" unless document["version"] == SCHEMA_VERSION

          approved = document["approved"]
          return "is not a Karst approval document" unless approved.is_a?(Array)

          "holds more than #{MAX_ENTRIES} entries" if approved.size > MAX_ENTRIES
        end

        def entry(item)
          return nil unless item.is_a?(Hash)

          model_name = item["model"]
          method_name = item["scope"]
          return nil unless model_name.is_a?(String) && method_name.is_a?(String)
          return nil unless MODEL_NAME.match?(model_name) && SCOPE_NAME.match?(method_name)

          Entry.new(model_name: model_name, method_name: method_name)
        end

        def normalize(entries)
          usable = entries.filter_map do |item|
            model_name = item.model_name.to_s
            method_name = item.method_name.to_s
            next unless MODEL_NAME.match?(model_name) && SCOPE_NAME.match?(method_name)

            Entry.new(model_name: model_name, method_name: method_name)
          end
          sort(usable.uniq).first(MAX_ENTRIES).freeze
        end

        # One deterministic order everywhere -- the file, the panel, and the
        # order Karst would try approved populations in -- so the same set of
        # approvals always produces byte-identical storage and the same
        # search behavior, regardless of checkbox submission order.
        def sort(entries)
          entries.sort_by { |item| [item.model_name, item.method_name] }
        end

        def write(entries)
          target = path
          FileUtils.mkdir_p(File.dirname(target))
          temporary = "#{target}.#{Process.pid}.tmp"
          File.write(temporary, "#{JSON.pretty_generate(document(entries))}\n")
          File.rename(temporary, target)
        ensure
          FileUtils.rm_f(temporary) if temporary
        end

        def document(entries)
          {
            "version" => SCHEMA_VERSION,
            "approved" => entries.map { |entry| { "model" => entry.model_name, "scope" => entry.method_name } }
          }
        end

        def empty
          Record.new(entries: [].freeze, error: nil)
        end

        def failed(reason)
          Record.new(entries: [].freeze,
                     error: "#{display_path} #{reason}; Karst approved no populations from it. " \
                            "Delete the file and approve again.")
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
