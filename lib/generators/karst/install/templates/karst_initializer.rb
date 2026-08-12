# frozen_string_literal: true

# Karst usually requires no initializer for Devise. This escape hatch exists
# because this application uses custom authentication. Complete each TODO;
# see docs/advanced-configuration.md for the full contract.
Karst.configure do |config|
  config.principals = -> { Account.active } # TODO: use this app's principal scope

  config.assume_identity = lambda do |session, principal|
    descriptor = Karst::Identity.describe(principal)
    session.post "/karst_test_login", params: { principal_type: descriptor.model_name, principal_id: descriptor.id }
  end
  config.clear_identity = ->(session) { session.delete "/karst_test_logout" }

  # TODO: replace :account_id with this app's browser-session identity.
  config.assume_browser_identity = ->(request, principal) { request.session[:account_id] = principal.id }
  config.clear_browser_identity = ->(request) { request.session.delete(:account_id) }
end
