# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../value"

module Karst
  module Access
    # The local, machine-scoped record of which ambiguous Devise model(s) a
    # developer has explicitly told Karst to test (see
    # Karst::Access::SelectedPrincipalSources for how this is turned back
    # into runnable Karst::Access::PrincipalSource objects, revalidated
    # against Karst::Identity::DeviseSupport's own current metadata on every
    # read).
    #
    # Deliberately *data*, never code: an entry is a bare model name and
    # nothing else -- never a scope, a class, or any executable Ruby. Karst
    # never constantizes a stored name; it is only ever compared, as a
    # string, against what Devise.mappings currently reports. This is the
    # same never-trust-the-file posture Karst::Access::PopulationApprovals
    # uses for candidate populations, applied one layer earlier: to *which
    # models* Karst may consider at all, not what it may sample from within
    # one already-known model.
    #
    # Stored under the host application's `tmp/` (`tmp/karst/`) for the same
    # reason approved populations are: machine-local, disposable,
    # git-ignored, reset by deleting the file, and consulted only in
    # development/test (see Karst::Access::ApprovedPopulations.local_environment?,
    # reused as-is by Karst::Access::SelectedPrincipalSources -- this is the
    # same local-preference mechanism, not a parallel one).
    #
    # Every read fails closed, exactly like PopulationApprovals: a file that
    # is unreadable, is not JSON, is not the expected document shape, carries
    # an unknown schema version, or holds a single entry that is not a
    # plausible constant name selects nothing at all.
    module PrincipalSourceSelection
      SCHEMA_VERSION = 1

      RELATIVE_PATH = File.join("tmp", "karst", "principal_source_selection.json")

      # Matched only against Karst::Identity::DeviseSupport.mappings' own
      # model names -- a stored name is never constantized and never used to
      # look up an arbitrary constant.
      MODEL_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/

      # A generous bound no realistic application approaches -- exists only
      # so a corrupted or maliciously grown document cannot turn every
      # principal source resolution into unbounded work.
      MAX_ENTRIES = 50

      Record = Value.define(:model_names, :error) do
        def selected?(model_name)
          model_names.include?(model_name.to_s)
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

        # Replaces the whole selection with `model_names`, atomically:
        # callers always submit the complete set they intend to keep, so
        # deselecting a model is simply selecting a smaller set, and a
        # partially written file can never be observed.
        def replace(model_names)
          normalized = normalize(model_names)
          write(normalized)
          Record.new(model_names: normalized, error: nil)
        rescue StandardError => e
          Record.new(model_names: normalized || [].freeze,
                     error: "selection could not be saved (#{e.class})")
        end

        private

        def root
          return Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

          Dir.pwd
        end

        # Rejects the whole document the moment any one entry is unusable,
        # rather than silently dropping just that entry -- a hand-edited
        # file that mostly looks right is exactly the case fail-closed
        # exists for.
        def rejection(document)
          return "is not a Karst selection document" unless document.is_a?(Hash)
          return "was written by an incompatible Karst version" unless document["version"] == SCHEMA_VERSION

          selected = document["selected"]
          return "is not a Karst selection document" unless selected.is_a?(Array)

          "holds more than #{MAX_ENTRIES} entries" if selected.size > MAX_ENTRIES
        end

        def parse(document)
          reason = rejection(document)
          return failed(reason) if reason

          raw = document["selected"]
          unless raw.all? { |name| name.is_a?(String) && MODEL_NAME.match?(name) }
            return failed("holds an entry Karst does not recognize")
          end

          Record.new(model_names: sort(raw.uniq).freeze, error: nil)
        end

        def normalize(model_names)
          usable = model_names.map(&:to_s).grep(MODEL_NAME)
          sort(usable.uniq).first(MAX_ENTRIES).freeze
        end

        def sort(names)
          names.sort
        end

        def write(names)
          target = path
          FileUtils.mkdir_p(File.dirname(target))
          temporary = "#{target}.#{Process.pid}.tmp"
          File.write(temporary, "#{JSON.pretty_generate(document(names))}\n")
          File.rename(temporary, target)
        ensure
          FileUtils.rm_f(temporary) if temporary
        end

        def document(names)
          { "version" => SCHEMA_VERSION, "selected" => names }
        end

        def empty
          Record.new(model_names: [].freeze, error: nil)
        end

        def failed(reason)
          Record.new(model_names: [].freeze,
                     error: "#{display_path} #{reason}; Karst selected no principal sources from it. " \
                            "Delete the file and select again.")
        end
      end
    end
  end
end
