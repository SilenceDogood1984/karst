# frozen_string_literal: true

require_relative "value"
require_relative "identity/warden_adapter"

module Karst
  # Framework-neutral identity seam for controlled probes. It deliberately
  # does not discover or enumerate principals; callers own that policy.
  module Identity
    class Error < StandardError; end
    class Unavailable < Error; end
    class ConfigurationError < Error; end

    PrincipalDescriptor = Value.define(:model_name, :id, :display_label)

    # Delegates identity operations to the application's configured hooks.
    class ConfiguredAdapter
      def initialize(assume_hook, clear_hook)
        @assume_hook = assume_hook
        @clear_hook = clear_hook
      end

      def assume(session, principal)
        @assume_hook.call(session, principal)
      end

      def clear(session)
        @clear_hook.call(session)
      end
    end
    private_constant :ConfiguredAdapter

    class << self
      def principals
        source = Karst.config.principals
        raise Unavailable, "no principal source is configured" unless source
        raise ConfigurationError, "config.principals must be callable" unless source.respond_to?(:call)

        source.call
      end

      def with(session, principal)
        active_adapter = adapter
        # The hook may establish identity and then raise, so cleanup becomes
        # mandatory before invoking it rather than only after it returns.
        assumed = true
        active_adapter.assume(session, principal)
        yield
      ensure
        active_adapter.clear(session) if active_adapter && assumed
      end

      def clear(session)
        adapter.clear(session)
      end

      def describe(principal)
        model_name = model_name_for(principal)
        id = id_for(principal)
        label_hook = Karst.config.principal_label
        if label_hook && !label_hook.respond_to?(:call)
          raise ConfigurationError, "config.principal_label must be callable"
        end

        label = label_hook ? label_hook.call(principal) : "#{model_name} ##{id}"
        PrincipalDescriptor.new(model_name: model_name, id: id, display_label: label)
      end

      # Resolves only principals exposed by the configured source. In
      # particular, this never constantizes a submitted model name or performs
      # an unrestricted model lookup.
      def resolve(model_name:, id:)
        principals.each do |principal|
          descriptor = describe(principal)
          return principal if descriptor.model_name == model_name.to_s && descriptor.id.to_s == id.to_s
        end
        nil
      end

      def browser_supported?
        Karst.config.assume_browser_identity.respond_to?(:call) &&
          Karst.config.clear_browser_identity.respond_to?(:call)
      end

      def assume_browser(request, principal)
        raise Unavailable, "browser identity hooks are not configured" unless browser_supported?

        Karst.config.assume_browser_identity.call(request, principal)
      end

      def clear_browser(request)
        raise Unavailable, "browser identity hooks are not configured" unless browser_supported?

        Karst.config.clear_browser_identity.call(request)
      end

      private

      def adapter
        assume_hook = Karst.config.assume_identity
        clear_hook = Karst.config.clear_identity
        return configured_adapter(assume_hook, clear_hook) if assume_hook || clear_hook
        return WardenAdapter.new if defined?(Warden::Manager)

        raise Unavailable, "no identity hooks are configured and Warden is unavailable"
      end

      def configured_adapter(assume_hook, clear_hook)
        unless assume_hook.respond_to?(:call) && clear_hook.respond_to?(:call)
          raise ConfigurationError,
                "config.assume_identity and config.clear_identity must both be callable"
        end
        ConfiguredAdapter.new(assume_hook, clear_hook)
      end

      def model_name_for(principal)
        if principal.class.respond_to?(:model_name)
          principal.class.model_name.name.to_s
        else
          principal.class.name.to_s
        end
      end

      def id_for(principal)
        raise ConfigurationError, "principal must expose an id" unless principal.respond_to?(:id)

        principal.id
      end
    end
  end
end
