# frozen_string_literal: true

require "active_support/parameter_filter"

module Karst
  module Reproduction
    # Everything Karst is willing to show back to a developer about a request
    # it issued passes through here first.
    #
    # The application's own Rails::Application#config.filter_parameters is the
    # authority: Karst builds an ActiveSupport::ParameterFilter from it rather
    # than reimplementing filtering, so a parameter the application already
    # considers sensitive is sensitive here too, including through Rails'
    # own nested-hash and Proc handling. Karst then applies one conservative
    # credential-name net *on top of* that result -- never instead of it --
    # because an application's filter_parameters is tuned for its own logs
    # and routinely misses credentials that only appear in a third-party
    # integration's payload.
    #
    # Header handling is deliberately not symmetric with parameter handling:
    # a credential-bearing header's value is never read, compared, or
    # echoed. It is replaced by a named placeholder purely on the strength
    # of its name, so a generated request always tells the engineer which
    # credential to supply without Karst ever having handled it.
    module Sanitizer
      # ActiveSupport::ParameterFilter's own mask. Rewritten to Karst's
      # angle-bracket form so a recipe uses one visual convention for
      # "you must supply this yourself" rather than two.
      RAILS_MASK = "[FILTERED]"
      MASK = "<FILTERED>"

      # Headers whose value Karst may echo verbatim: they describe the shape
      # of the request, never authorize it. An allowlist, so a header Karst
      # has never considered is handled by the rules below rather than
      # trusted by default.
      SAFE_HEADERS = %w[
        accept accept-charset accept-encoding accept-language cache-control
        content-length content-type host if-match if-none-match origin
        referer user-agent x-request-id x-requested-with
      ].freeze

      # Named placeholders for the headers a Rails application actually
      # authenticates with. The placeholder is chosen from the header name
      # alone; the real value is never inspected.
      CREDENTIAL_HEADERS = {
        "authorization" => "<AUTH_TOKEN>",
        "proxy-authorization" => "<AUTH_TOKEN>",
        "www-authenticate" => "<AUTH_TOKEN>",
        "cookie" => "<SESSION_COOKIE>",
        "set-cookie" => "<SESSION_COOKIE>",
        "api-key" => "<API_KEY>",
        "x-api-key" => "<API_KEY>",
        "x-auth-token" => "<AUTH_TOKEN>",
        "x-access-token" => "<AUTH_TOKEN>",
        "x-csrf-token" => "<CSRF_TOKEN>",
        "x-xsrf-token" => "<CSRF_TOKEN>"
      }.freeze

      # Karst's supplementary net, applied after the application's own
      # filter_parameters. Deliberately credential-shaped rather than a
      # general PII list (Karst::Access::SensitiveAttributeNames already
      # owns that, for a different job): a QA recipe is useless if every
      # ordinary business field is masked, but it is dangerous if one
      # credential is not.
      CREDENTIAL_TOKENS = %w[
        auth authorization bearer certificate cookie credential credentials
        csrf cvv hmac jwt key nonce otp passphrase password passwd pin pwd
        salt secret session sig signature ssn token xsrf
      ].freeze

      # Matched as substrings too, so a run-together name ("apikey",
      # "accesstoken") is caught even though tokenizing cannot split it.
      CREDENTIAL_SUBSTRINGS = %w[password secret token apikey credential signature].freeze

      class << self
        # A deep-filtered copy of any params-like Hash, with String keys.
        #
        # `filters` is the filter_parameters of the application whose request
        # is being reproduced. Karst::Reproduction::Exercise always passes the
        # application it actually issued the request against, rather than
        # letting this class reach for Rails.application: those are the same
        # object in every real application, and reading the global instead
        # would quietly filter one application's parameters with another
        # application's rules.
        def parameters(params, filters: nil)
          return {} if params.nil?

          supplement(rails_filter(filters).filter(stringify(params)))
        end

        # name => value-or-placeholder, with canonical header casing.
        def headers(pairs)
          (pairs || {}).each_with_object({}) do |(name, value), result|
            result[canonical(name)] = header_value(name, value)
          end
        end

        # True when a sanitized value is a placeholder rather than something
        # Karst actually observed. Callers use this to keep "redacted" and
        # "observed" visibly distinct instead of blurring them together.
        def masked?(value)
          value.is_a?(String) && value.start_with?("<") && value.end_with?(">")
        end

        def credential_name?(name)
          normalized = name.to_s.downcase
          return true if CREDENTIAL_SUBSTRINGS.any? { |fragment| normalized.include?(fragment) }

          normalized.split(/[^a-z0-9]+/).any? { |token| CREDENTIAL_TOKENS.include?(token) }
        end

        private

        def header_value(name, value)
          key = name.to_s.downcase.tr("_", "-")
          return value.to_s if SAFE_HEADERS.include?(key)

          placeholder = CREDENTIAL_HEADERS[key]
          return placeholder if placeholder
          return MASK if credential_name?(key)

          value.to_s
        end

        def canonical(name)
          name.to_s.downcase.tr("_", "-").split("-").map(&:capitalize).join("-")
        end

        # Rebuilt per call rather than memoized: a spec (and a reloading
        # development application) can change filter_parameters between
        # requests, and a stale filter here would silently stop masking
        # something the application now considers sensitive.
        def rails_filter(filters)
          ActiveSupport::ParameterFilter.new(Array(filters || rails_filter_parameters))
        end

        def rails_filter_parameters
          return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          Array(Rails.application.config.filter_parameters)
        rescue StandardError
          []
        end

        def stringify(value)
          case value
          when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
          when Array then value.map { |item| stringify(item) }
          else value
          end
        end

        def supplement(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), result|
              result[key] = credential_name?(key) ? MASK : supplement(item)
            end
          when Array then value.map { |item| supplement(item) }
          when RAILS_MASK then MASK
          else value
          end
        end
      end
    end
  end
end
