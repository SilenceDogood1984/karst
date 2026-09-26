# frozen_string_literal: true

require "rails/command"
require "karst/cli/verification"
require_relative "../boot"

module Rails
  module Command
    module Karst
      # Rails command entry point for the shared Access::Search adapter.
      class VerifyCommand < Base
        include Karst::Boot

        class_option :json, type: :boolean, default: false, desc: "Emit stable JSON evidence"
        class_option :anonymous, type: :boolean, default: false,
                                 desc: "Probe with no principal established, and verify the " \
                                       "application observed none"
        class_option :as, type: :string,
                          desc: "Run as one specific existing principal instead of sampling one, " \
                                "e.g. --as User:72. Resolved only through Karst's own configured " \
                                "principal source(s); cannot be combined with --anonymous"

        desc "Verify bounded GET access to a local application path"
        # rubocop:disable Metrics/AbcSize
        def perform(*arguments)
          method, path = parse(arguments)
          boot_karst_application!
          exit(::Karst::CLI::Verification.new(path: path, http_method: method, json: options[:json],
                                              identity: (:anonymous if options[:anonymous]),
                                              as: options[:as]).call)
        rescue ArgumentError => e
          document = { schema_version: ::Karst::CLI::Verification::SCHEMA_VERSION,
                       error: { type: "input_error", message: e.message } }
          puts(options[:json] ? JSON.generate(document) : "Karst cannot verify this route:\n#{e.message}")
          exit(2)
        end
        # rubocop:enable Metrics/AbcSize

        private

        def parse(arguments)
          raise ArgumentError, "a local application path is required" if arguments.empty?
          return ["GET", arguments.first] if arguments.size == 1
          raise ArgumentError, "expected METHOD PATH" unless arguments.size == 2

          arguments
        end
      end
    end
  end
end
