# frozen_string_literal: true

require "rails/command"
require "karst/cli/verification"

module Rails
  module Command
    module Karst
      # Rails command entry point for the shared Access::Search adapter.
      class VerifyCommand < Base
        class_option :json, type: :boolean, default: false, desc: "Emit stable JSON evidence"

        desc "Verify bounded GET access to a local application path"
        def perform(*arguments)
          method, path = parse(arguments)
          exit(::Karst::CLI::Verification.new(path: path, http_method: method, json: options[:json]).call)
        rescue ArgumentError => e
          document = { schema_version: 1, error: { type: "input_error", message: e.message } }
          puts(options[:json] ? JSON.generate(document) : "Karst cannot verify this route:\n#{e.message}")
          exit(2)
        end

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
