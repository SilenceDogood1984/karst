# Advanced configuration

This document covers Karst configuration beyond the golden path in [README.md](../README.md): custom authentication, multiple user models, curating candidate populations, artifact scenarios, resource evidence, and the full configuration reference. See [ARCHITECTURE.md](../ARCHITECTURE.md) for how these pieces are implemented.

## Custom or non-Devise authentication

Karst does not assume identity is a `User`, an Active Record object, or a Warden session. Configure a lazy candidate source and the hooks a probe session uses to sign in and out:

```ruby
Karst.configure do |config|
  config.principals = -> { Account.active }
  config.assume_identity = lambda do |session, account|
    session.post "/karst_test_login", params: { account_id: account.id }
  end
  config.clear_identity = ->(session) { session.delete "/karst_test_logout" }

  # Optional, only evaluated when a display label is needed:
  config.principal_label = ->(account) { "QA account #{account.id}" }
end
```

`config.principals` is called only by `Karst::Identity.principals` — Karst never enumerates, samples, or materializes its result itself. `assume_identity` and `clear_identity` must be configured together. This lets an app use a test-only login endpoint or any other session-local mechanism without ever handing Karst a password, email, token, or other credential.

`bin/rails generate karst:install` is an optional escape hatch for custom authentication. You usually do not need this generator: conventional single-model Devise apps require no initializer, application controller, or Karst routes. The compatibility-preserving command scaffolds a compact initializer, a `KarstIdentityController` with explicit `TODO`s, and development-only routes. Replace the `TODO`s with your app's real sign-in/sign-out behavior. None of this is required if you already configure Karst by hand.

Browser **Test as** needs a second, separate pair of hooks, because they mutate the real Rack request/session rather than an isolated probe session:

```ruby
Karst.configure do |config|
  config.assume_browser_identity = lambda do |request, account|
    request.session[:account_id] = account.id
  end
  config.clear_browser_identity = lambda do |request|
    request.session.delete(:account_id)
  end
end
```

When both are configured, every usable user in the results gets a **Test as** button. Karst resolves the submitted user only through a configured principal source, then invokes the hook, then redirects back to the exact page you were testing.

Because `/karst` is served at the Rack boundary, before Action Controller, Rails' authenticity-token helpers aren't available there. Karst instead stores a random nonce in the existing Rack session and requires a constant-time match on every identity-changing POST. This path is local-development-only, requires a writable host session, never accepts an external return URL, and stays inactive unless both browser hooks are configured.

## Multiple user models: `config.principal_sources`

Some apps represent identity as more than one model (`Author`, `Reader`) rather than one `User` with a role column:

```ruby
Karst.configure do |config|
  config.principal_sources = {
    authors: { records: -> { Author.all }, dimensions: { premium: :premium? }, populations: { admins: -> { Author.admins } } },
    readers: -> { Reader.all }
  }
end
```

Each source is a name plus a lazily-evaluated `records:` callable, and optional `dimensions:`/`populations:` of its own. Sources are never merged together — Karst keeps each independently queryable and never confuses `Author #12` with `Reader #12`. `config.principals` (plus `config.principal_dimensions`/`config.principal_populations`) remains fully supported; it's normalized internally into one implicit `:default` source, so this is additive, not a breaking change to the simple form in the main README.

Candidates are split across sources within one overall `access_sweep_limit`: every non-empty source gets at least one candidate, and the rest fill round-robin so one source running dry never starves another.

## Representative sampling and dimensions

When `config.principals` (or a source's `records:`) returns an Active Record relation, Karst doesn't just take whichever rows sort first — it tries to cover a handful of different observed states within one bounded, recent pool (`principal_candidate_pool_size`, default 1,000 rows, one query).

By default it looks for boolean columns, enum columns, presence/absence of a nullable foreign key, and low-cardinality scalar columns (2–10 distinct values), in memory, over that one pool. Anything that looks like PII by name (email, phone, address, token, password, and similar) is excluded outright, as is anything shaped like a tenant/account/organization foreign key.

You can tell it explicitly which states matter instead of relying on that schema guess:

```ruby
Karst.configure do |config|
  config.principals = -> { User.all }
  config.principal_dimensions = {
    role: :role,
    system_admin: :system_admin?,
    reseller: ->(user) { user.plan == "reseller" }
  }
end
```

Each dimension is a plain attribute, a boolean predicate method, or a callable of one argument. A dimension named (or reading an attribute named) like `email`, `phone`, `token`, or similar is rejected with `ArgumentError` as soon as it's configured — dimensions are for coarse state, not identity data. Configured dimensions replace the schema guess entirely; they're never combined. This shapes the *ordinary sample* only — candidate populations (below) are a separate, later search stage.

A dimension or population is sampling evidence, never an authorization claim — Karst may report `role=local_admin` next to a usable user; it never states or implies that the role is what let the request through.

## Curating candidate populations

Writing `config.principal_populations` by hand works well once you know which scopes matter. On a large app, finding them by reading source is tedious — so Karst separates **discovery** (automatic, executes nothing) from **approval** (always an explicit developer action).

**Discovery.** `Karst::Access::PopulationDiscovery` parses application model source with Ruby's standard-library `Ripper` AST parser and lists statically named, zero-argument Rails `scope` declarations. It never calls a scope, never queries anything, and never mutates application state. Only scopes declared directly on a model are found; scopes contributed by a `concern` may not appear. `bin/rails karst:populations` prints every discovered model and scope name, marking the approved ones; discovery is not approval — Karst finding `User.system_admins` says only that such a scope exists, never that it grants access.

**Approval.** When an analysis finds no usable user and unapproved candidates exist, `/karst` links to `/karst/populations`: candidates grouped by model, collapsed and searchable. Checking a scope and pressing **Preview** runs one bounded (`LIMIT 3`) query, inside a rolled-back transaction, to show a few matching records — optional, never required to approve. Pressing **Approve selected groups** persists the selection to `tmp/karst/approved_populations.json`, relative to `Rails.root`:

```json
{ "version": 1, "approved": [{ "model": "User", "scope": "system_admins" }] }
```

Deliberately machine-local, git-ignored development state, not project configuration — delete the file to reset every approval. It holds **only model and scope names**, never user data, never a `-> { ... }` lambda, and Karst never evaluates its contents; an entry is only ever compared, as a string, against what current discovery still confirms. This is what keeps the file from becoming an arbitrary-method allowlist: a hand-edited entry naming an ordinary class method (`destroy_all`) is never confirmed, and an approval whose scope was renamed, given parameters, or deleted stops being executed the moment the source changes — shown as stale on the review page rather than silently dropped.

An approval only ever becomes executable for a model that is already a configured or Devise-inferred principal source (the class always comes from that source, never from the file), and only in development/test — production never reads the file. `config.principal_populations`/`config.principal_sources[...] :populations` keeps working unchanged and wins outright over an approval of the same name; Karst compares by name only, since it never inspects a configured callable's body. Approved populations reach `Access::Search` the same way configured ones do, so `/karst`, `bin/rails karst:verify`, and the MCP `verify_access` tool all pick them up automatically with no adapter-specific wiring.

The review page can still generate a ready-to-paste `config.principal_populations = { ... }` (or `config.principal_sources = { ... }`) snippet from your approvals, under **Advanced: export approvals as Ruby** — useful for committing populations as reviewable code, or for CI, where machine-local approval state is deliberately not consulted.

## Resource evidence

When a usable user is found for a route with an `:id` segment (`/admin/imports/123`), Karst separately checks whether that exact resource and that exact user share a direct foreign-key relationship — for example, that `Document#22`'s `user_id` column equals `User#27`'s id. Only columns ending in `_id` are ever inspected, and only a direct column-value comparison is made — never a join or a `has_many` traversal, and no other attribute (name, email, token) is ever read. This is shown as **Related state** on a usable result when available, and simply omitted otherwise.

## Explicit artifact scenarios

Beyond "which user can reach this route," you can define scenarios over other application records ("can any recent import be opened cross-account by an admin who doesn't own it?"):

```ruby
Karst.configure do |config|
  config.artifact_source(:imports, limit: 100) do
    Import.order(created_at: :desc)
  end

  config.access_scenario(
    :cross_admin_import,
    artifact: :imports,
    path: ->(import) { "/admin/imports/#{import.id}" },
    expect: { status: 404 },
    combination_limit: 25,
    stop_on_match: true
  )
end
```

`expect` accepts `status`, an exact query-free `redirect`, and `body_includes`; all given predicates must match. Artifact sources take a limit from 1–1,000; a scenario caps actual user × artifact requests at `combination_limit` (1–100). `stop_on_match: true` (the default) returns after the first verified match. Every request still uses a fresh session and a rolled-back transaction.

## Runtime SQL evidence

Independent of access search, Karst keeps a small, bounded, in-process buffer of recent `sql.active_record` events (default capacity 2,000, oldest evicted first, cleared on restart):

```ruby
Karst.buffer.to_a
window = Karst.window
```

`Karst.window` snapshots the buffer once into an immutable `Karst::Sql::Window`: `shapes` (grouped, aggregated query shapes, most frequent first), `declined` (events Karst couldn't safely group), and `saturated` (true if the buffer was full, meaning older events may already be gone). The `/karst` panel shows this under **Diagnostics**, alongside spec-observed scenarios for the current controller/action when a scenario catalog is present.

## Full configuration reference

```ruby
Karst.configure do |config|
  config.enabled = true                    # default: development/test only
  config.buffer_size = 2_000                # SQL event buffer capacity
  config.access_sweep_limit = 25            # users tried per search (max 100)
  config.principal_candidate_pool_size = 1_000  # recent-row pool for sampling (max 10_000)
  config.population_retry_limit = 3         # records tried per population (max 10)
  config.usable_access_outcome = ->(outcome) { outcome.status == 200 && ... } # default policy
end
```

`usable_access_outcome` lets you redefine what counts as "usable" without changing what evidence is captured — for example, treating a `204` as usable for an API endpoint. The default is: HTTP 200, no observed exception, no halted callback.

## Safety detail

- `/karst`, the badge, and browser Test As only run for loopback requests (and, under WSL, the single detected host-side gateway a Windows browser appears from) while `Rails.env.development?` is true. Forwarding headers and other private-network addresses are never trusted.
- Every probe runs inside `ActiveRecord::Base.transaction(requires_new: true)` and is always rolled back. This only isolates writes made through the same Active Record connection in that request — not jobs, mail, external HTTP calls, files, Redis, or other database connections.
- Population and dimension callables are evaluated inside that same rollback-only transaction; a population whose callable itself performs a write is rejected even though rollback was attempted, because Karst observed `INSERT`/`UPDATE`/`DELETE` SQL from it.
- Every search is bounded: at most `access_sweep_limit` requests for the ordinary sample, and the automatic population retry stage can add at most that many again — so enabling populations can roughly double a search's cost, never more.
- Karst never looks up a user outside a configured principal source. Submitting an arbitrary model name/id to **Test as** resolves nothing unless that model is one of your configured sources.
