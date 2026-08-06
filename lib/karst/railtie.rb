# frozen_string_literal: true

module Karst
  # Installs Karst after application initializers have configured it.
  class Railtie < Rails::Railtie
    config.after_initialize do
      Karst.subscribe! if Karst.enabled?
    end
  end

  private_constant :Railtie
end
