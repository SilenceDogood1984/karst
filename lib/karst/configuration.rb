# frozen_string_literal: true

module Karst
  # Process-level settings that control Karst's implemented behavior.
  class Configuration
    attr_accessor :enabled

    def initialize
      @enabled = defined?(Rails) ? Rails.env.development? || Rails.env.test? : false
    end
  end
end
