# frozen_string_literal: true

module Rails
  module Command
    module Karst
      # Shared by every Karst Rails::Command: boots the host application the
      # same way Rails' own commands do (Rails::Command::Actions#boot_application!
      # on Rails >= 7.1, #require_application_and_environment! before that),
      # without depending on either method name existing across Karst's whole
      # supported Rails range. `require_application!` (from
      # Rails::Command::Actions, already included into Rails::Command::Base)
      # plus Rails.application.require_environment! is exactly what both of
      # those version-specific wrappers do internally.
      module Boot
        private

        def boot_karst_application!
          require_application!
          Rails.application.require_environment! if defined?(APP_PATH)
        end
      end
    end
  end
end
