# frozen_string_literal: true

require_relative "../value"

module Karst
  module Identity
    # Reads Devise's own routing-registered mapping metadata to determine
    # which model(s) Devise protects and which Warden scope each one uses --
    # never by scanning ObjectSpace, guessing from a model's name (User,
    # Account, ...), or inferring from column names (encrypted_password,
    # email, ...).
    #
    # `Devise.mappings` is populated by `devise_for` in config/routes.rb (the
    # same metadata Devise itself relies on for `authenticate_user!`,
    # `current_user`, and friends), so by the time a real request reaches
    # Karst, every conventional Devise application already has it populated.
    module DeviseSupport
      # One Devise-registered model/Warden-scope pair, straight from
      # Devise's own mapping -- never guessed.
      Mapping = Value.define(:model, :scope)

      class << self
        def available?
          !!(defined?(Devise) && Devise.respond_to?(:mappings))
        end

        # Every Devise-registered mapping currently known to the framework.
        # Empty when Devise is unavailable or has registered nothing yet.
        def mappings
          return [] unless available?

          Devise.mappings.values.filter_map { |mapping| build(mapping) }
        rescue StandardError
          []
        end

        # The single unambiguous Devise mapping, or nil when there are zero
        # or more than one -- multiple Devise models are a deliberate
        # ambiguity boundary Karst never guesses across.
        def unambiguous_mapping
          candidates = mappings
          candidates.first if candidates.size == 1
        end

        # The Devise mapping for one specific model class (including a
        # subclass of a mapped model, e.g. STI), if Devise itself registers
        # it. Used once a principal model is already known -- from an actual
        # principal instance or an explicitly configured source -- so this
        # never has to guess which of several Devise models is intended.
        def mapping_for(model)
          return nil unless model.is_a?(Class)

          mappings.find { |mapping| model <= mapping.model }
        end

        private

        def build(devise_mapping)
          model = devise_mapping.to if devise_mapping.respond_to?(:to)
          scope = devise_mapping.name if devise_mapping.respond_to?(:name)
          return nil unless model.is_a?(Class) && scope

          Mapping.new(model: model, scope: scope)
        rescue StandardError
          nil
        end
      end
    end
  end
end
