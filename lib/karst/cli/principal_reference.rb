# frozen_string_literal: true

require_relative "../identity"

module Karst
  module CLI
    # Parses and resolves a human-supplied "--as MODEL:ID" reference (e.g.
    # "User:72") into an existing principal, entirely through
    # Karst::Identity.resolve -- the same configured-source-only lookup the
    # browser's own Test As form already uses (see
    # Karst::Web::BrowserIdentity#assume). There is no bypass here: a model
    # name or id that Identity.resolve does not recognize resolves to
    # nothing, exactly as it would for Test As, rather than falling back to
    # Object#const_get/Model.find against an arbitrary class name.
    module PrincipalReference
      Reference = Struct.new(:model_name, :id)

      # Format-only validation, with no dependency on a booted application or
      # configured principal sources -- callers use this to reject a
      # malformed --as value immediately, before Identity.resolve is even
      # reachable.
      def self.parse(value)
        model_name, id = value.to_s.split(":", 2)
        if model_name.to_s.empty? || id.to_s.empty?
          raise ArgumentError, "--as must be MODEL:ID, e.g. \"User:72\" (got #{value.inspect})"
        end

        Reference.new(model_name, id)
      end

      # Resolves `value` to an existing principal, or raises ArgumentError --
      # never nil, and never a fallback to sampling or to anonymous. A
      # caller who explicitly asked to run as one principal gets that
      # principal or a clear failure, not a silent substitute.
      def self.resolve(value)
        reference = parse(value)
        principal = Identity.resolve(model_name: reference.model_name, id: reference.id)
        return principal if principal

        raise ArgumentError,
              "--as #{value} did not resolve: Karst found no #{reference.model_name} ##{reference.id} " \
              "in its configured principal source(s)"
      end
    end
  end
end
