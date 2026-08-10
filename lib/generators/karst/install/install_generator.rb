# frozen_string_literal: true

require "rails/generators"

module Karst
  module Generators
    # `bin/rails generate karst:install`
    #
    # Scaffolds the host-specific identity seams Karst cannot safely infer on
    # its own: a documented initializer with placeholder identity hooks, a
    # development-only probe identity controller, and the development-only
    # routes that connect Karst's isolated probe session to it. See the
    # generated files themselves for what each seam is responsible for.
    #
    # This generator is convenience/scaffolding only. Karst remains fully
    # configurable by hand (see README.md); nothing at runtime requires this
    # generator to have been run, and an application that already configures
    # Karst manually has no need to run it.
    #
    # Deliberately does not attempt to detect or wire up Devise, Warden, or
    # any other auth library -- see the "Future work" note in the generated
    # initializer. Idempotent: running it again only touches files whose
    # content actually changed, via Thor's own file-collision handling, and
    # the routes insertion is a no-op once the exact same route block is
    # already present.
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

        1. Configure your principal source:
           config/initializers/karst.rb

        2. Implement probe identity setup/clear:
           app/controllers/karst_identity_controller.rb

        3. Implement browser Test-as identity hooks:
           config/initializers/karst.rb

        4. Start Rails and visit a page, then /karst.

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
        say "Installation is not complete until the TODOs above are replaced with " \
            "this application's real identity semantics -- Karst cannot infer them.", :yellow
      end
    end
  end
end
