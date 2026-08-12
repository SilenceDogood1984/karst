# frozen_string_literal: true

require "rails/generators"

module Karst
  module Generators
    # `bin/rails generate karst:install`
    #
    # Scaffolds a documented initializer plus the development-only probe
    # identity controller/routes a *custom* (non-Devise) identity
    # configuration can drive. See the generated files themselves for what
    # each seam is responsible for.
    #
    # This generator does not need to detect Devise/Warden itself: that
    # detection happens at runtime, from Devise's own routing metadata (see
    # Karst::Identity::DeviseSupport), not at generation time. A conventional
    # single-model Devise application needs nothing from this generator's
    # output beyond the initializer as generated -- see its "golden path"
    # comment block. The identity controller and routes exist only for
    # applications that fall back to a custom `config.assume_identity` /
    # `config.clear_identity` pair.
    #
    # This generator is convenience/scaffolding only. Karst remains fully
    # configurable by hand (see README.md); nothing at runtime requires this
    # generator to have been run, and an application that already configures
    # Karst manually has no need to run it.
    #
    # Idempotent: running it again only touches files whose content actually
    # changed, via Thor's own file-collision handling, and the routes
    # insertion is a no-op once the exact same route block is already
    # present.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/karst.rb, a development-only " \
           "KarstIdentityController, and development-only probe routes."

      DEVELOPMENT_ROUTES = <<~ROUTES
        if Rails.env.development?
          post   "/karst_test_login",  to: "karst_identity#create"
          delete "/karst_test_logout", to: "karst_identity#destroy"
        end
      ROUTES
      private_constant :DEVELOPMENT_ROUTES

      NEXT_STEPS = <<~STEPS

        Conventional single-model Devise apps: nothing else to do -- start
        Rails and visit /karst.

        Everyone else (ambiguous or no Devise model, custom authentication):

        1. Configure your principal source:
           config/initializers/karst.rb

        2. Implement probe identity setup/clear:
           app/controllers/karst_identity_controller.rb

        3. Implement browser Test-as identity hooks:
           config/initializers/karst.rb

        4. Start Rails and visit a page, then /karst.

        5. Optional: browse and curate candidate populations (application
           scopes like `User.system_admins`) at /karst/populations, or run
           `bin/rails karst:populations` from the command line.

      STEPS
      private_constant :NEXT_STEPS

      def copy_initializer
        copy_file "karst_initializer.rb", "config/initializers/karst.rb"
      end

      def copy_identity_controller
        copy_file "karst_identity_controller.rb", "app/controllers/karst_identity_controller.rb"
      end

      def add_development_routes
        # `route` (a Rails::Generators::Actions helper) injects this exact
        # string once via Thor's own force: false collision handling: a
        # second run whose routes.rb already contains this text is a no-op,
        # so this stays safe to run more than once without duplicating
        # routes or requiring bespoke parsing of config/routes.rb.
        route(DEVELOPMENT_ROUTES.chomp)
      end

      def post_install_message
        say ""
        say "Karst installed.", :green
        say NEXT_STEPS
        say "If you configured a custom (non-Devise) identity, installation is not complete " \
            "until the TODOs above are replaced with this application's real identity semantics " \
            "-- Karst cannot infer them.", :yellow
      end
    end
  end
end
