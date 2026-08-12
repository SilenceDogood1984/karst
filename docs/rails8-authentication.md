# Rails 8 generated authentication

`bin/rails generate authentication` (new in Rails 8) scaffolds a plain
`User`/`Session` pair, an `ActiveSupport::CurrentAttributes` `Current` class,
and an `Authentication` concern that resumes a session from a signed,
permanent `session_id` cookie. It is not Devise, and it registers itself
nowhere Karst can safely discover: Devise's zero-config path exists only
because `Devise.mappings` is public, framework-owned metadata Devise itself
already relies on for `current_user`/`authenticate_user!`. Rails' generated
authentication has no equivalent registry — there is no framework-provided
list of "the models this app authenticates" or "the concern doing it" for
Karst to read. Guessing from column names (`password_digest`), class names
(`User`, `Session`, `Current`), or `ApplicationController`'s ancestry would
be exactly the kind of heuristic inference Karst deliberately never does for
custom authentication (see [Custom or non-Devise
authentication](advanced-configuration.md#custom-or-non-devise-authentication)).
So this is a small, explicit recipe instead of a one-liner — five short
`Karst.configure` blocks below cover the whole thing, using this
application's own generated `User`, `Session`, and `Authentication`
concern exactly as the generator created them. Nothing here monkey-patches
`Current`, `Session`, or any generated controller.

This is the *complete* minimum configuration; nothing else is required.

## 1. Principal source

```ruby
Karst.configure do |config|
  config.principals = -> { User.all }
end
```

## 2. Probe identity: sign a probe session in

Karst's access search runs each probe through an isolated
`ActionDispatch::Integration::Session`, inside a database transaction Karst
always rolls back — so the cleanest way to sign a probe in is the same way
a real user signs in: create a `Session` row and let the real
`Authentication` concern resume it. Run `bin/rails generate karst:install`
to scaffold the controller and development-only routes below (the generator
is authentication-agnostic; it works the same regardless of what identity
system fills in its `TODO`s):

```ruby
# app/controllers/karst_identity_controller.rb
class KarstIdentityController < ApplicationController
  allow_unauthenticated_access only: :create
  skip_before_action :verify_authenticity_token, raise: false

  def create
    principal = Karst::Identity.resolve(model_name: params[:principal_type], id: params[:principal_id])
    return head(:forbidden) unless principal

    start_new_session_for(principal) # from this app's own Authentication concern
    head :no_content
  end

  def destroy
    terminate_session # from this app's own Authentication concern
    head :no_content
  end
end
```

`start_new_session_for`/`terminate_session` are the exact private helpers
the Rails 8 generator already put in `app/controllers/concerns/authentication.rb`
— this controller calls them, it does not reimplement them. `only: :create`
mirrors the generated `SessionsController`'s own
`allow_unauthenticated_access only: %i[new create]`: signing a probe in must
skip `require_authentication` (nothing is authenticated yet), but signing
one out does not need to, exactly like a real user's logout.

```ruby
Karst.configure do |config|
  config.assume_identity = lambda do |session, principal|
    descriptor = Karst::Identity.describe(principal)
    session.post "/karst_test_login", params: { principal_type: descriptor.model_name, principal_id: descriptor.id }
  end
end
```

## 3. Probe identity: clear it

```ruby
Karst.configure do |config|
  config.clear_identity = ->(session) { session.delete "/karst_test_logout" }
end
```

Karst always calls this after a probe, including when the route being
tested raises — so a probe's `Session` row is created and destroyed inside
the same rollback-only transaction as everything else it does. No probe
identity ever outlives its own analysis. See [the "database writes
observed" note](#note-database-writes-observed-is-honest-not-zero) below
for the one visible side effect of this being a *real* database write,
even though it never persists.

## 4. Browser Test As

Test As mutates the developer's real browser session directly, not through
a sub-request — so it sets the same signed cookie
`start_new_session_for` sets, using a real `Session` row:

```ruby
Karst.configure do |config|
  config.assume_browser_identity = lambda do |request, principal|
    rails_request = ActionDispatch::Request.new(request.env)
    probe_session = principal.sessions.create!(user_agent: "Karst Test As", ip_address: "127.0.0.1")
    rails_request.cookie_jar.signed.permanent[:session_id] =
      { value: probe_session.id, httponly: true, same_site: :lax }
  end
end
```

`request` here is a bare `Rack::Request` (Karst serves `/karst` at the Rack
boundary, before Action Controller) — wrapping its `env` in
`ActionDispatch::Request` is ordinary Rack request-object adaptation, not a
patch to any Rails class, and gives access to the same signed `cookie_jar`
a real controller's `cookies.signed` uses. Because `ActionDispatch::Cookies`
sits above Karst's middleware in the stack, the `Set-Cookie` header this
produces is flushed on the way back out exactly like it would be for a real
controller action.

## 5. Stop Testing As

```ruby
Karst.configure do |config|
  config.clear_browser_identity = lambda do |request|
    rails_request = ActionDispatch::Request.new(request.env)
    Session.find_by(id: rails_request.cookie_jar.signed[:session_id])&.destroy
    rails_request.cookie_jar.delete(:session_id)
  end
end
```

This is the whole recipe. There is no sixth step, and nothing above reaches
into `Current`, `Session`, or a generated controller's internals —
`start_new_session_for`/`terminate_session` are called as the application's
own public-to-its-subclasses methods, exactly as a real controller action
would call them.

## Note: "database writes observed" is honest, not zero

Devise/Warden's Test As and the plain `session[:user_id] = ...` custom-auth
example are memory-only: neither ever performs a database write to sign a
probe in or out, so a route with no writes of its own reports "Database
writes observed: 0". Rails' generated authentication persists a `Session`
row per sign-in, so every probe under this recipe legitimately shows **2**
observed writes (the login `INSERT` and the logout `DELETE`) even when the
route itself never touches the database. This is not a bug and not
something to suppress: Karst reports what actually happened, and an insert
+ delete genuinely happened. It does mean write-count evidence from this
recipe is not directly comparable to a Devise/Warden or memory-only
custom-auth analysis of the same route — a "2 writes observed" result here
can mean only Karst's own probe login/logout wrote anything.

## Acceptance test

[`spec/integration/rails8_auth_golden_path_integration_spec.rb`](../spec/integration/rails8_auth_golden_path_integration_spec.rb)
boots a real `Rails::Application` using exactly this recipe against a
fixture that reproduces the Rails 8 generator's own files
([`spec/support/rails8_auth_application.rb`](../spec/support/rails8_auth_application.rb)),
with an ordinary user population and one rare privileged user, a restricted
route, a real access search, candidate-population discovery/approval, Test
As, Stop Testing As, and an assertion that no row is left behind afterward.
It runs against the real `rails ~> 8.0.0` gemfile
([`gemfiles/rails_8_0.gemfile`](../gemfiles/rails_8_0.gemfile)) in CI.
