# frozen_string_literal: true

require "json"
require "rack/utils"

module Karst
  module Reproduction
    # Renders one Karst::Reproduction::Observation as a runnable cURL command.
    #
    # The command contains exactly what Karst sent, with redacted values
    # replaced by placeholders -- never a header, parameter, or credential
    # Karst invented to make the command look complete. If the request needs
    # an API key Karst never sent, the command will not contain one; the
    # recipe's observed execution (the halted callback that stopped the
    # request) is what tells the engineer that, and it is honest evidence
    # rather than a guess.
    module Curl
      # A deliberately generic local default. Callers that know the
      # developer's real origin (the /karst panel does) pass it in; nothing
      # here ever bakes in a deployed host, which would be neither portable
      # nor safe to paste into a ticket.
      DEFAULT_BASE_URL = "http://localhost:3000"

      # Methods curl infers from the request shape anyway; spelling them out
      # adds noise without adding meaning.
      IMPLIED_METHODS = ["GET"].freeze

      class << self
        def render(observation, base_url: DEFAULT_BASE_URL)
          parts = ["curl#{method_flag(observation)} #{quote(url(observation, base_url))}"]
          header_flags(observation).each { |flag| parts << flag }
          data = data_flag(observation)
          parts << data if data
          parts.join(" \\\n  ")
        end

        def url(observation, base_url = DEFAULT_BASE_URL)
          query = Rack::Utils.build_nested_query(observation.query_params)
          suffix = query.to_s.empty? ? "" : "?#{query}"
          "#{base_url.to_s.chomp('/')}#{observation.url_path}#{suffix}"
        end

        private

        def method_flag(observation)
          method = observation.http_method.to_s.upcase
          IMPLIED_METHODS.include?(method) ? "" : " -X #{method}"
        end

        def header_flags(observation)
          observation.headers.map { |name, value| "-H #{quote("#{name}: #{value}")}" }
        end

        def data_flag(observation)
          case observation.body_representation
          when :json then "-d #{quote(JSON.pretty_generate(observation.body_params))}"
          when :form then "-d #{quote(Rack::Utils.build_nested_query(observation.body_params))}"
          when :opaque then "-d #{quote('<BODY>')}"
          end
        end

        # Single quotes are the only shell quoting that treats every byte
        # literally, so a JSON body full of double quotes, backslashes, and
        # "$" needs no per-character escaping -- only the single quote
        # itself, which closes the literal, emits an escaped quote, and
        # reopens it.
        def quote(value)
          "'#{value.to_s.gsub("'", "'\\\\''")}'"
        end
      end
    end
  end
end
