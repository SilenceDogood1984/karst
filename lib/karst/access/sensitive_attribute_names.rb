# frozen_string_literal: true

module Karst
  module Access
    # Shared, deliberately conservative name-based PII filter used everywhere
    # Karst decides whether an attribute name is safe to inspect or display --
    # both generic schema discovery (PrincipalSampler) and explicitly
    # configured evidence (PrincipalDimension). Column/attribute names are
    # never PII-inspected, only compared (case-insensitive, underscore-
    # tokenized) against this list. False positives (skipping a safe name)
    # are free; false negatives are not, so this stays a single source of
    # truth rather than being duplicated per caller.
    module SensitiveAttributeNames
      TOKENS = %w[
        email name first last full phone mobile fax address street city zip
        postal country ssn social security password secret salt encrypted
        token key api credential auth login username url website dob birth
        card cvv iban passport license
      ].freeze

      def self.match?(name)
        name.to_s.downcase.split("_").any? { |token| TOKENS.include?(token) }
      end
    end
  end
end
