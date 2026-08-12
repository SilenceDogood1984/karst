# frozen_string_literal: true

require "rails/generators"

module Karst
  module Generators
    # `bin/rails generate karst:install`
    #
    # Scaffolds a compact initializer plus the development-only probe
    # identity controller/routes a *custom* (non-Devise) identity
    # configuration can drive. See the generated files themselves for what
    # each seam is responsible for.
    #
    # This generator does not need to detect Devise/Warden itself: that
    # detection happens at runtime, from Devise's own routing metadata (see
    # Karst::Identity::DeviseSupport), not at generation time. A conventional
    # single-model Devise application needs nothing from this generator.
    # The initializer, identity controller, and routes exist only for
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

      desc "Scaffolds the custom-authentication escape hatch (not needed for conventional Devise apps)."

      DEVELOPMENT_ROUTES = <<~ROUTES
        if Rails.env.development?
          post   "/karst_test_login",  to: "karst_identity#create"
          delete "/karst_test_logout", to: "karst_identity#destroy"
        end
      ROUTES
      private_constant :DEVELOPMENT_ROUTES

      NEXT_STEPS = <<~STEPS

        You usually do not need this generator. Use it only when Karst cannot
        infer your application's custom authentication.

        1. Configure your principal source:
           config/initializers/karst.rb

        2. Implement probe identity setup/clear:
           app/controllers/karst_identity_controller.rb

        3. Implement browser Test-as identity hooks:
           config/initializers/karst.rb

        Then start Rails and visit /karst. See docs/advanced-configuration.md.

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
        say "Karst custom-authentication scaffold created.", :green
        say NEXT_STEPS
        say "Complete the TODOs with this application's real identity semantics.", :yellow
      end
    end
  end
end
