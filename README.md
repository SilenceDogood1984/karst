# Karst

Karst finds a real, existing user who can reach a page in your Rails app — by actually running the route as your users and reporting what happened.

"Which user can access this page?" is normally answered by reading role checks and `before_action` filters by hand, or asking around until someone remembers a working login. Karst answers it by running the real route, through your real Rails request stack, as a bounded set of real users — and shows you the evidence: HTTP status, redirect, halted callback, exception.

```text
GET /admin/imports/123

Ordinary sample
25 users tested · none verified usable
halted at authorize_admin

system_admins
User #27 → 200 OK ✓

[ Test as User #27 ]
```

That's the whole product. Everything below is how to get there.

## Quick start

```ruby
# Gemfile
gem "karst", group: :development
```

```bash
bundle install
bin/rails server
```

Open `/karst` in your browser.

Using Devise with one user model? That's usually it — Karst finds it automatically through Devise's own routing metadata, with no configuration. If Karst finds more than one Devise model, it asks you to pick which one(s) to test right there on the `/karst` panel — no initializer, no restart. If it finds none at all, it says so instead of guessing.

Custom or non-Devise authentication needs a few lines of setup — see [Custom authentication](#custom-authentication) below.

## How it works

1. Open any page in development. Karst adds a small **Karst** badge in the corner, already scoped to the controller/action that rendered it.
2. Click it (or visit `/karst` directly) and press **Who can use this?**. Karst runs the route through your real Rails stack as a bounded set of existing users — 25 by default — inside a database transaction it rolls back.
3. If none of those work, Karst automatically tries a few users from any [candidate populations](#candidate-populations) you've approved, such as `system_admins`.
4. Every result shows what actually happened: status, redirect, halted callback, exception, and observed database writes.
5. Found a usable user? Click **Test as** to become them in your own browser and keep working.

## Candidate populations

Sometimes the right user is rare and won't show up in a normal recent-user sample. Karst can find these groups itself — no configuration needed. When the ordinary sample comes up empty, `/karst` says so:

```
No verified usable user found
Karst found 3 application-defined user groups that could be tried. [ Review candidate groups ]
```

Open `/karst/populations`, check the groups Karst may try (`system_admins`, `auditors`, ...), and press **Approve**. From then on, approved groups are searched automatically — through `/karst`, the CLI, and MCP alike — until one produces a usable user. Approving is a hint, never a claim: Karst only reports that a user was *sampled from* `system_admins`, never that the group is what granted access.

Need populations committed as reviewable code, or applied outside your own machine (CI)? `config.principal_populations` does that and always takes precedence over an approval of the same name — see [docs/advanced-configuration.md](docs/advanced-configuration.md#curating-candidate-populations) for discovery, approval, and precedence details.

## What Karst shows you

For every user it tries, Karst reports:

- HTTP status and redirect target
- the halted Rails callback, if the request was stopped by one
- any raised exception
- observed database writes
- which user was tested, and which configured population (if any) produced them

When it can, Karst also shows how the tested user relates to the resource on the page — for example, `Document #22 → user_id → User #27`.

Karst reports observations, not authorization conclusions. If Rails halted at `authorize_admin`, Karst reports that callback name; it does not claim the user lacks permission unless your application says so itself.

## CLI

```bash
bin/rails karst:verify GET /admin/imports/123
bin/rails karst:verify GET /admin/imports/123 --json
```

Runs the same search as `/karst` from a shell. Exit code `0` means a usable user was found, `1` means the search completed without one, `2` means a setup error. The `--json` form is a stable, schema-versioned evidence document meant for scripts and tools.

## Coding agents

MCP support is optional. Add its runtime dependency to your application's
Gemfile and install it before starting the server:

```ruby
gem "mcp", "~> 0.9.0"
```

```bash
bundle install
bin/rails karst:mcp
```

```json
{
  "mcpServers": {
    "karst": { "command": "bin/rails", "args": ["karst:mcp"] }
  }
}
```

Claude Code or another [MCP](https://modelcontextprotocol.io) client can call `verify_access` and get back exactly the evidence `karst:verify --json` prints. An agent can guess who *should* have access by reading code; only Karst can show who actually does. The agent picks the path and method — it can't choose a user, skip the rollback, or use Test As.

## Configuration

Usually, you don't. A conventional Devise app needs no initializer at all: the user model comes from Devise's own routing metadata, sampling states come from your schema, and candidate populations are approved at `/karst/populations` rather than written down.

The one option worth knowing is the off switch:

```ruby
Karst.configure { |config| config.enabled = false }  # on by default in development and test
```

Everything else is for exceptional applications — custom authentication, several user models, populations committed as code for CI, and a few bounds most developers never touch. All of it lives in [docs/advanced-configuration.md](docs/advanced-configuration.md).

## Custom authentication

Not using Devise, or authenticating some other way? Tell Karst how to sign a user in and out for a probe request:

```ruby
Karst.configure do |config|
  config.principals = -> { Account.active }
  config.assume_identity = lambda do |session, account|
    session.post "/karst_test_login", params: { account_id: account.id }
  end
  config.clear_identity = ->(session) { session.delete "/karst_test_logout" }
end
```

The compatibility-preserving `bin/rails generate karst:install` command optionally scaffolds this custom-authentication escape hatch. Replace its `TODO`s with your app's real sign-in/sign-out code. A conventional single-model Devise app needs none of its initializer, controller, or routes. Browser **Test as** needs a second, similar pair of hooks (`config.assume_browser_identity` / `config.clear_browser_identity`) — see [docs/advanced-configuration.md](docs/advanced-configuration.md).

## Safety

Karst is for local development only — `/karst`, the badge, and Test As only work from loopback requests while `Rails.env.development?` is true. Every search is bounded (25 users by default, 100 max), and every probe runs inside a database transaction Karst rolls back.

That rollback only covers writes made through the same Active Record connection. Jobs, mail, external HTTP calls, files, Redis, and other database connections aren't covered — a route that triggers those can still cause real side effects even though its own database writes are undone.

## Compatibility

Ruby 2.7+, Rails 6.1+. Every core capability (`/karst`, CLI, MCP, access search) works across that whole range; the page-local badge needs Rack 3 (Rails 7.1+) and is simply absent on Rails 6.1/7.0 — `/karst` itself is unaffected. See [ARCHITECTURE.md](ARCHITECTURE.md#compatibility-policy) for the CI-backed matrix.

## Contributing

Contributions and design discussion are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
