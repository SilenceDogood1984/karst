# Karst

Karst finds a real, existing user who can reach a page in your Rails app — by actually running the route as your users and reporting what happened.

**Why Karst?** Karst terrain hides complex systems beneath the surface. As a Rails codebase grows, its real runtime paths become similarly difficult to see from the surface. The Karst gem reveals what actually happens underneath.

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

Custom or non-Devise authentication needs a few lines of setup — see [Custom authentication](#custom-authentication) below. Using Rails 8's built-in `bin/rails generate authentication`? See [docs/rails8-authentication.md](docs/rails8-authentication.md) for the exact recipe — Rails' generated authentication has no registry Karst can safely infer from, unlike Devise.

## How it works

1. Open any page in development. Karst adds a small **Karst** badge in the corner, already scoped to the controller/action that rendered it.
2. Click it (or visit `/karst` directly) and press **Who can use this?**. Karst runs the route through your real Rails stack as a bounded set of existing users — 25 by default — inside a database transaction it rolls back.
3. If none of those work, Karst automatically tries a few users from any [candidate populations](#candidate-populations) you've approved, such as `system_admins`.
4. Every result shows what actually happened: status, redirect, halted callback, exception, and observed database writes.
5. Found a usable user? Click **Test as** to become them in your own browser and keep working.

## Working with an existing record

**Karst runs against records already in your development database, however they got there.** Console, seeds, `db:fixtures:load`, FactoryBot run in development/console, your app's own UI, or a tool like Body Double — Karst doesn't care how they were created, and doesn't require Body Double specifically.

That's true of the *path* unconditionally — `/admin/imports/123` is just a string, and any row backing it is fair game. It's true of *identity* only within a boundary: to run a probe as a specific principal (`--as`, or **Test as** on the panel), that record must be one Karst's configured principal source(s) can actually resolve (see [Identity.resolve](docs/advanced-configuration.md#running-as-a-specific-principal)) — an arbitrary development-database row is not automatically assumable as a principal just because it exists.

What Karst does *not* do is start from an object and find routes for you — you still bring the path. The workflow is:

1. **Know a concrete path** — `/admin/imports/123`, from your own knowledge of the app.
2. **Verify it** — `bin/rails karst:verify GET /admin/imports/123`, or press **Who can use this?** at `/karst`.
3. **Optionally run as a specific user** — `--as User:72` on the CLI (see [CLI](#cli) below), or **Test as** on the panel once a usable user is found.
4. **The panel/badge workflow** — every page in development carries a **Karst** badge linking straight to `/karst?controller=...&action=...`, already scoped to what rendered it.

One caveat worth being explicit about: a record created and then rolled back *inside a transactional test spec* never reaches the development database at all, so there's nothing there for Karst to run against. Data loaded into the development database itself — by any of the mechanisms above — is what "existing record" means here.

Karst does not claim to find every route a given user can reach, does not claim to prove nobody else can reach a route, and does not start a search from an arbitrary object. It runs the one route you name, using either Karst's sampled identity or the explicit principal you select, and reports what it observed.

## Candidate populations

Sometimes the right user is rare and won't show up in a normal recent-user sample. Karst can find these groups itself — no configuration needed. When the ordinary sample comes up empty, `/karst` says so:

```
No verified usable user found
Karst found 3 application-defined user groups that could be tried.
```

Select the groups Karst may try (`system_admins`, `auditors`, ...) and press **Approve and rerun** without leaving `/karst`. From then on, approved groups are searched automatically — through `/karst`, the CLI, and MCP alike — until one produces a usable user. Approving is a hint, never a claim: Karst only reports that a user was *sampled from* `system_admins`, never that the group is what granted access.

Approvals are persistent local state. The advanced `/karst/populations` page exists only to inspect and revoke them, including approvals made stale by a renamed scope or changed principal source. It cannot approve new groups; normal route analysis never needs to visit it.

Need populations committed as reviewable code, or applied outside your own machine (CI)? `config.principal_populations` does that and always takes precedence over an approval of the same name — see [docs/advanced-configuration.md](docs/advanced-configuration.md#curating-candidate-populations) for discovery, approval, and precedence details.

## What Karst shows you

For every user it tries, Karst reports:

- HTTP status and redirect target
- the halted Rails callback, if the request was stopped by one
- any raised exception
- observed database writes
- which user was tested, and which configured population (if any) produced them

Karst reports observations, not authorization conclusions. If Rails halted at `authorize_admin`, Karst reports that callback name; it does not claim the user lacks permission unless your application says so itself.

## CLI

```bash
bin/rails karst:verify GET /admin/imports/123
bin/rails karst:verify GET /admin/imports/123 --json
```

Runs the same search as `/karst` from a shell. Exit code `0` means a usable user was found, `1` means the search completed without one, `2` means a setup error. The `--json` form is a stable, schema-versioned evidence document meant for scripts and tools.

Already know which existing record you want to test as — from the console, a seed, `db:fixtures:load`, or your app's own UI? Skip sampling and name it directly:

```bash
bin/rails karst:verify GET /admin/imports/123 --as User:72
```

`--as MODEL:ID` resolves that record through Karst's own configured principal source (the same lookup the panel's **Test as** button uses) and runs the route as exactly that principal — never a bespoke `constantize`/`find`, so a record outside your configured source(s) simply won't resolve. It's human-only: neither `verify_access` nor `reproduce_request` over MCP accepts it, and an agent can never pick a principal through Karst.

## Reproducing a request

Sometimes the question isn't "who can reach this page" but "something calls
this endpoint — what request do I send to exercise the same behavior?".

Karst answers that the same way: it issues **one** request through your real
application, inside a rolled-back transaction, and reports what happened —
plus a cURL command for exactly what it sent.

```bash
bin/rails karst:reproduce POST /api/v1/inspections \
  --content-type application/json \
  --body '{"serial_number":"ABC123","status":"passed"}'
```

```text
Observed execution
  Api::V1::InspectionsController#create
  halted at authenticate_api_key!

Observed response
  401 text/html

Observed effects
  0 database writes (rollback attempted on the same connection)

Reproduce
  curl -X POST 'http://localhost:3000/api/v1/inspections' \
    -H 'Content-Type: application/json' \
    -d '{
    "serial_number": "ABC123",
    "status": "passed"
  }'
```

That halted callback is the endpoint's real gate — observed, not inferred from
reading the controller. Add the credential it wants, send again, and the cURL
you copy is one you have watched work.

`karst:reproduce` takes the same `--as MODEL:ID` as `karst:verify` above, to send that one request as a specific existing record instead of the ordinary sampled one.

Secrets never come back out. Parameters go through your app's own
`config.filter_parameters`, and credential-bearing headers become placeholders
like `<API_KEY>` without their values ever being read. The same thing is
available at `/karst` under **Reproduce request**, and to agents as the
`reproduce_request` MCP tool. See
[docs/request-reproduction.md](docs/request-reproduction.md).

## Coding agents

MCP support is optional. Add its runtime dependency to your application's
Gemfile and install it before starting the server:

```ruby
gem "mcp", "~> 1.5.0"
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

Claude Code or another [MCP](https://modelcontextprotocol.io) client gets two tools:

- `verify_access` — exactly the evidence `karst:verify --json` prints. An agent can guess who *should* have access by reading code; only Karst can show who actually does.
- `reproduce_request` — exactly the evidence `karst:reproduce --json` prints, including the redacted cURL command.

In both cases the agent picks the request — it can't choose a user, skip the rollback, raise a limit, or use Test As. That includes `--as`: it's a CLI-only, human-only option (see [CLI](#cli) above), and neither MCP tool accepts it in any form.

## Configuration

Usually, you don't. A conventional Devise app needs no initializer at all: the user model comes from Devise's own routing metadata, sampling states come from your schema, and candidate populations are approved inline after a failed analysis rather than written down.

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
  # How Karst sees which account the app itself actually ran as:
  config.observe_identity = ->(context) { context.controller&.current_account }
end
```

That last hook is what lets Karst prove a result rather than assume it. Devise applications need no equivalent — Karst reads the application's own Warden session. Without either, Karst reports identity as *unobservable* instead of claiming a request ran as the user it was asked to run as. See [Runtime-confirmed identity](docs/advanced-configuration.md#runtime-confirmed-identity).

The `bin/rails generate karst:install` command optionally scaffolds this custom-authentication escape hatch. Replace its `TODO`s with your app's real sign-in/sign-out code. A conventional single-model Devise app needs none of its initializer, controller, or routes. Browser **Test as** needs a second, similar pair of hooks (`config.assume_browser_identity` / `config.clear_browser_identity`) — see [docs/advanced-configuration.md](docs/advanced-configuration.md).

Using Rails 8's own `bin/rails generate authentication` instead of Devise? [docs/rails8-authentication.md](docs/rails8-authentication.md) is the same escape hatch, filled in with that generator's own `User`/`Session`/`Current` objects.

## Safety

Karst is for local development only — `/karst`, the badge, and Test As only work from loopback requests while `Rails.env.development?` is true. The ordinary sample is bounded to 25 users by default (100 max). If it finds no usable user, approved candidate populations can add a separate bounded retry stage. Every probe runs inside a database transaction Karst rolls back.

That rollback only covers writes made through the same Active Record connection. Jobs, mail, external HTTP calls, files, Redis, and other database connections aren't covered — a route that triggers those can still cause real side effects even though its own database writes are undone.

Access analysis is GET-only, and stays that way: running a mutating method as 25 users would mean 25 real creates. [Request reproduction](docs/request-reproduction.md) is the one place a non-GET request is issued, always exactly once and always because you asked for it.

## Compatibility

Ruby 2.7+, Rails 6.1+. Every core capability (`/karst`, CLI, MCP, access search) works across that whole range; the page-local badge needs Rack 3 (Rails 7.1+) and is simply absent on Rails 6.1/7.0 — `/karst` itself is unaffected. See [ARCHITECTURE.md](ARCHITECTURE.md#compatibility-policy) for the CI-backed matrix.

## Contributing

Contributions and design discussion are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
