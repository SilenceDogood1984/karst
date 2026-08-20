# frozen_string_literal: true

require "rails/command"
require "karst/cli/reproduction"
require_relative "../boot"

module Rails
  module Command
    module Karst
      # Rails command entry point for the shared Reproduction adapter.
      class ReproduceCommand < Base
        include Karst::Boot

        class_option :json, type: :boolean, default: false, desc: "Emit stable JSON evidence"
        class_option :body, type: :string, desc: "Request body to send"
        class_option :content_type, type: :string, desc: "Content type of --body (required with --body)"
        class_option :header, type: :array, default: [], desc: "Request header, as 'Name: value' (repeatable)"
        class_option :anonymous, type: :boolean, default: false,
                                 desc: "Send without assuming any application identity"
        class_option :base_url, type: :string, desc: "Base URL for the generated cURL command"

        desc "Issue one local request and print a reproducible, redacted recipe for it"
        def perform(*arguments)
          method, path = parse(arguments)
          boot_karst_application!
          exit(reproduction(method, path).call)
        rescue ArgumentError => e
          document = { schema_version: 1, error: { type: "input_error", message: e.message } }
          puts(options[:json] ? JSON.generate(document) : "Karst cannot reproduce this request:\n#{e.message}")
          exit(2)
        end

        private

        def reproduction(method, path)
          ::Karst::CLI::Reproduction.new(
            path: path, http_method: method, body: options[:body], content_type: options[:content_type],
            headers: headers, anonymous: options[:anonymous], base_url: options[:base_url], json: options[:json]
          )
        end

        def headers
          Array(options[:header]).each_with_object({}) do |entry, result|
            name, value = entry.to_s.split(":", 2)
            raise ArgumentError, "expected --header 'Name: value'" if value.nil?

            result[name.strip] = value.strip
          end
        end

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
