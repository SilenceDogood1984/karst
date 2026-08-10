# Karst

Karst is a runtime evidence engine for Rails.

## What is Karst?

Karst is intended to capture what actually happened while a Rails application ran and make that evidence useful. It starts from observed behavior rather than guesses about what code might do.

## Philosophy

- Prefer runtime observation to static inference.
- Require evidence for every claim.
- Prefer silence to false certainty.
- Make every recommendation traceable to captured evidence.
- Favor small, composable primitives.

Observation comes before recommendation.

## Why runtime evidence?

Static analysis can describe possible behavior. Runtime evidence describes behavior that occurred in a particular execution. Karst will preserve that distinction so developers can evaluate findings in their real application context.

## Current capabilities

Karst owns an idempotent Active Support subscription to `sql.active_record` and converts valid notifications into immutable SQL event objects. Recent events are inspectable newest last:

```ruby
Karst.buffer.to_a
```

The buffer is bounded, transient, in-process evidence retention, not analysis. Its default capacity is 2,000 events; when full, it discards the oldest events first. Restarting the process clears the evidence, and multiple application processes each have a separate buffer.

Karst's first analysis surface derives one snapshot of that retained evidence on demand:

```ruby
window = Karst.window
```

`Karst.window` reads `Karst.buffer` exactly once and returns an immutable `Karst::Sql::Window` built entirely from that single read — nothing about it changes if the live buffer changes afterward. A `Window` has:

- `shapes` — a frozen Array of `Karst::Sql::Shape`, one per distinct query shape observed in the snapshot, ordered by count descending, then total duration descending, then fingerprint ascending. Each `Shape` aggregates count, cache hits, duration statistics, and up to three sample `Sql::Event` objects (first, slowest, latest) for events whose SQL Karst could safely canonicalize.
- `declined` — a frozen Array of the original `Sql::Event` objects, in original order, whose SQL Karst declined to canonicalize. These are excluded from `shapes` entirely; Karst does not group or interpret them.
- `event_count` — the number of events in the snapshot. Always equal to `shapes.sum(&:count) + declined.size`.
- `capacity` — the retained-buffer capacity that applied to this snapshot.
- `saturated` — `true` when `event_count == capacity`. A saturated window means the buffer was full at snapshot time, so older events may already have been evicted; counts and durations describe only what remains retained, not lifetime totals.

A `Window`'s counts and durations apply only to that Window. Fingerprints are a derived identity for grouping observed SQL shapes within a process, not a proof of semantic equivalence, and may change across Karst versions.

In Rails development, Karst serves a read-only evidence panel at `GET /karst` through a small Rack middleware — no engine, route, or controller. The panel's primary workflow answers "which existing principal can I use to test what I'm looking at": a compact route identity (method, path, controller/action) sits at the top, followed by the **Analyze** action described below and, once run, the usable principals it found. Spec evidence (read from `tmp/karst/scenarios.json` through `Karst::Spec::Catalog`, showing statuses, redirects, principal types, outcomes, and spec provenance for a controller/action) and Runtime SQL Window counts are supporting diagnostics, collapsed by default under **Diagnostics**. The spec evidence summary distinguishes a missing or invalid artifact from a ready catalog with no matching scenarios.

## Identity adapters

Karst does not assume that application identity is a `User`, Active Record, or
Warden object. Applications may independently configure a lazy candidate source
and the hooks used by a controlled integration session:

```ruby
Karst.configure do |config|
  config.principals = -> { Account.active }
  config.assume_identity = lambda do |session, account|
    session.post "/karst_test_login", params: { account_id: account.id }
  end
  config.clear_identity = ->(session) { session.delete "/karst_test_logout" }
  # Optional and only evaluated when a descriptor is requested:
  config.principal_label = ->(account) { "QA account #{account.id}" }
end

Karst::Identity.with(integration_session, account) do
  integration_session.get "/private"
end # clear_identity always runs, including when the block raises
```

`config.principals` is called only by `Karst::Identity.principals`; Karst does
not enumerate, sample, or materialize its result. Both identity hooks must be
configured together. This lets an application use a test-only endpoint or any
other session-local mechanism without giving Karst passwords, emails, tokens,
or authentication secrets.

`Karst::Identity.describe(principal)` returns an immutable descriptor containing
only model/class name, `id`, and a display label. The default label is the safe
`"Account #44"` form and never calls `to_s` or reads arbitrary attributes.

Access results can optionally hand the real browser session to the host for
manual QA. Browser hooks are deliberately separate from integration-probe
hooks because they receive the current Rack request and mutate its session:

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

When both hooks are configured, each usable observed principal has a prominent
**Test as** button. Other outcomes remain collapsed as raw evidence and do not
offer that primary action. Karst resolves the submitted descriptor only
through a configured principal source (`config.principals`, or
`config.principal_sources` -- see [Explicit principal sources and
dimensions](#explicit-principal-sources-and-dimensions) below), invokes the
hook, and redirects to the exact analyzed
local path with its query string removed. **Stop testing as** invokes the clear
hook and therefore clears to whatever identity (normally anonymous) the host
defines; generic restoration of a previous identity is not attempted.

Because `/karst` is served before Action Controller, Rails authenticity-token
helpers are not reliably available there. Karst instead stores a random nonce
in the existing Rack session and requires a constant-time match on every
browser identity POST. The feature remains restricted to local development
requests; it requires a writable host session, never accepts external return
URLs, and is unavailable unless both browser hooks are configured.

## Experimental observed-access sweep

Karst can sequentially probe the exact current GET path with the first bounded
set returned by `config.principals`. Configure the principal source and both
identity hooks above, open a host page, follow its Karst badge (or open `/karst`
with route context), and explicitly select **Analyze 25 principals** (or
**Analyze 25 representative principals** -- see below). Opening the panel never
starts a sweep. The results are **observed outcomes**, not authorization
claims: status, query-free redirect destination or exception class, safe
`Karst::Identity.describe` label, elapsed time, and database-write evidence are
grouped without response bodies.

The panel promotes **usable principals** above the remaining observed outcomes
so its primary answer is who can be used to test the current page. “Usable” is
a host-configurable presentation policy over an observed HTTP outcome; it is
not an authorization conclusion. By default, statuses from 200 through 299 are
usable, while redirects, exceptions, and outcomes without a status are not.
Applications can narrowly replace that policy without changing or filtering
the sweep evidence:

```ruby
Karst.configure do |config|
  config.usable_access_outcome = lambda do |outcome|
    outcome.status && (200..299).cover?(outcome.status)
  end
end
```

Every outcome remains in the bounded sweep result. Non-usable status groups,
redirects, exceptions, timings, and write/rollback warnings remain available
under **Other observed outcomes**. If none of the sampled candidates produces
a usable outcome, the panel says exactly that; it does not claim that no user
can access the page.

The default `config.access_sweep_limit` is 25 and can be set from 1 through the
hard ceiling of 100. Active Record relations receive `limit` before they are
materialized; other Enumerables are consumed lazily only up to the bound. There
is no count query, random sampling, route discovery, resource substitution, or
parallel execution. Target query strings are discarded, exact resource IDs are
preserved, and external/protocol-relative URLs and every method except GET are
rejected.

### Representative principal sampling

When `config.principals` returns an Active Record relation or model class, the
panel's Analyze button runs `Karst::Access::PrincipalSampler` ahead of the
sweep instead of taking whatever rows happen to sort first. It selects up to
`access_sweep_limit` principals biased toward covering distinct *observed
database states* -- boolean columns, `enum` columns, presence/absence of a
nullable foreign key, and other low-cardinality scalar columns (10 or fewer
observed distinct values, checked with one bounded `DISTINCT ... LIMIT` query
per candidate column, never a full-table scan or `COUNT(*)`). This is
schema-state diversity the sampler observed in the database, not behavioral
diversity: the sampler never executes a route, so it has no evidence about how
any of these principals actually behave -- that evidence exists only once
`Access::Sweep` runs.

A conservative, name-based filter unconditionally excludes anything resembling
email, name, phone, address, token, password, or other sensitive columns,
regardless of cardinality. Separately, a foreign key shaped like a
tenant/account/organization boundary (`tenant_id`, `account_id`, and similar)
is excluded by name as well, independent of nullability or cardinality --
cardinality alone cannot be what keeps such a column out, since a *nullable*
one would otherwise reach presence/absence sampling without ever going through
the cardinality check.

Query volume is bounded by the number of dimensions and the configured limit,
not by table size, so it behaves the same whether the underlying table has a
thousand rows or a million; `Karst::Access::PrincipalSampler.query_budget(limit)`
states that bound explicitly and it is enforced at every query-issuing call
site, not merely estimated -- a call may return fewer than `limit` principals
if the budget is exhausted, but never issues more queries than the budget
declares. An Active Record source with a composite or missing primary key
raises `Karst::Access::PrincipalSampler::UnsupportedPrimaryKey` (a
`Karst::Access::Error`) rather than failing obscurely mid-query; pass an
already-materialized `Array`/Enumerable of principals instead to use bounded-
first sampling in that case. Selection is deterministic and never escapes the
relation `config.principals` returned -- an already tenant-scoped relation
stays tenant-scoped. The sampler only selects candidates: it runs no route,
compares no outcomes, and its result feeds `Karst::Access::Sweep` exactly like
any other bounded principal source. Any other Enumerable source falls back to
the existing bounded-first strategy, unchanged.

### Explicit principal sources and dimensions

`config.principals` and generic schema discovery are a good default, but real
applications represent identity very differently -- one `User` model with an
explicit role column, several distinct principal models (`Author`, `Reader`),
relational roles (`User`/`Membership`/`Organization`), or an authorization
framework where role-like semantics do not exist as one column at all. Karst
does not try to invent one universal role model; instead it separates three
concerns:

- **Principal source** -- "which records may Karst consider at all?"
- **Principal dimension** -- "which coarse states should Karst deliberately
  represent while sampling within a source?"
- **Observed access** (the sweep outcome described above) -- "what actually
  happened when Karst executed the route?"

A fourth concern, **authorization evidence** ("does this state actually grant
access?"), is deliberately out of scope for this version. A dimension is
sampling evidence, not an authorization claim: Karst may report
`role=local_admin` next to a usable principal; it never states or implies
that `local_admin` is what let the request through.

#### Dimensions: `config.principal_dimensions`

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

Each dimension is a plain attribute (`:role`), a boolean predicate
(`:system_admin?`), or a callable of one argument. Configured dimensions take
priority over `PrincipalSampler`'s generic schema discovery and are tried
first; generic discovery still runs afterward for any column no configured
dimension already names, so an application with no extra configuration keeps
today's behavior exactly. Given a pool of 900 `responder`, 50 `local_admin`,
30 `group_admin`, 15 `reseller`, and 5 `system_admin` accounts and a limit of
25, Karst deliberately tries to include a representative of every configured
role value before simply filling the rest with more responders.

A dimension backed by a real column (including Rails' own auto-generated
`<boolean column>?` predicate method, which returns exactly the column's
value) is discovered the same bounded way generic dimensions are -- one
`DISTINCT ... LIMIT` query, never a full scan. A dimension with no backing
column -- a computed predicate or a callable -- cannot be translated to SQL,
so it is instead evaluated once, in Ruby, over the same already
query-bounded candidate pool `PrincipalSampler` derives for large-table
safety (see above), never per-row against the full table.

A dimension named (or, for a `Symbol`/`String` accessor, reading an
attribute named) like `email`, `name`, `phone`, `token`, `password`,
`address`, or `credential` is rejected with `ArgumentError` as soon as it is
configured. Karst dimensions are for coarse state, not user identity data --
this cannot be checked for a callable accessor, since its body cannot be
inspected, so a callable that itself reads PII is a configuration mistake
Karst cannot catch on your behalf.

#### Multiple principal models: `config.principal_sources`

```ruby
Karst.configure do |config|
  config.principal_sources = {
    authors: { records: -> { Author.all }, dimensions: { premium: :premium? } },
    readers: -> { Reader.all }
  }
end
```

Each source is a name plus a records callable (evaluated lazily, exactly
like `config.principals`) and optional dimensions of its own. Sources are
never materialized together -- Karst never builds `Author.all.to_a +
Reader.all.to_a` -- each stays independently queryable and keeps its own
model identity throughout, so `Author #12` and `Reader #12` are never
confused even though their ids collide. `config.principals` (plus any
`config.principal_dimensions`) remains fully supported and is normalized
internally into one implicit `:default` source, so every downstream
consumer -- sampling, `Identity.resolve`, the panel -- only ever has to
handle "one or more sources."

`Karst::Access::PrincipalSelection` runs `PrincipalSampler` independently
per source and allocates the combined candidates within one overall
`access_sweep_limit`: every non-empty source is guaranteed at least one
candidate, and remaining room is filled round-robin across sources (each
contributing its own dimension-covering candidates before plain fill), so
one source running out never blocks another from filling the rest of the
budget, and a two-source table never receives 25 candidates each for 50
total probes. Each Active Record source separately derives its own bounded
`principal_candidate_pool_size` candidate pool -- a two-source table with a
pool size of 1,000 samples from up to 1,000 recent rows *per source*, not
1,000 split across both.

When more than one source is configured, a selected candidate's evidence
also carries `source=<name>` alongside any dimension reasons, since the
source name now adds real information; a single (or implicit `:default`)
source never shows it, since a model name alone already disambiguates.

`Karst::Identity.resolve(model_name:, id:)` tries each configured source in
order and returns the first match, stopping immediately once one source's
model name matches -- a later source is never even evaluated. For an Active
Record source this is still a single scoped primary-key query, never
enumeration; a submitted model name that matches no configured source
resolves nothing, and no submitted model name is ever constantized.

The panel's usable-principal cards show a compact secondary line when
sampling evidence is available, deliberately below the observed outcome and
above any resource evidence so it augments a usable principal without
competing with **Test as** or **Related state** for attention:

```
Sampled for:
role=local_admin · premium=true
```

Every principal receives a fresh `ActionDispatch::Integration::Session` and is
assumed and cleared only through `Karst::Identity`. Each synchronous request is
wrapped in `ActiveRecord::Base.transaction(requires_new: true)` and deliberately
rolled back. Results report `database_isolation` as
`:same_connection_rollback_attempted` and each outcome records
`database_rollback_attempted: true`; neither field is a containment guarantee.
The fixture verifies rollback for writes made through the same Active
Record connection in the in-process integration request; Karst does **not**
claim isolation for additional databases/connections. SQL notifications are
also inspected for `INSERT`, `UPDATE`, and `DELETE` evidence.

For Rails applications, that integration session targets a deliberately small
probe endpoint: `ActionDispatch::Cookies`, the application's configured session
middleware, `ActionDispatch::Flash`, and the application's routes, with the
application's `env_config` request defaults. This is sufficient for normal
controller dispatch, callbacks, cookies, session, and flash on Rails 6.1–8;
those Rails versions do not require another middleware for those semantics.
Karst therefore does not recursively call `Rails.application` or copy unrelated
host middleware. The session uses the route URL host when configured, otherwise
an exact host allowed by `config.hosts`, and finally Rails' generic development
host allowance. Host authorization remains enabled for ordinary browser
requests.

The rollback cannot isolate email, jobs, network requests, files, Redis, other
processes, or third-party APIs. GET endpoints can still cause those effects.
Use this experimental workflow only on development data and routes whose
non-database behavior is understood; `/karst` remains development-only and
local-only. The Analyze form is handled at Karst's Rack boundary rather than by
a Rails controller, so it does not use Rails authenticity tokens; its execution
boundary is the directly observed peer address plus the development environment.
Nonlocal and non-development POST requests fall through to the host unchanged,
and GET requests never start a sweep.

When Warden has already been loaded, Karst can alternatively use the public
`set_user` and `logout` APIs on an existing Rack `env["warden"]` proxy. Warden is
not required or eagerly loaded. A bare `ActionDispatch::Integration::Session`
does not expose an initialized Warden proxy generically; configure the explicit
hooks above for that case rather than relying on app-specific Warden internals.

The normal development workflow needs no manual controller/action entry: open any page in your Rails app, and Karst adds a small "Karst" badge fixed near a screen corner, already scoped to the controller/action that rendered the page (derived from a real `process_action.action_controller` notification, never guessed from the URL). Click it to jump straight to that route's observed scenarios — `/author/projects` links directly into `Author::ProjectsController#index`, with the count of observed scenarios shown on the badge itself when the catalog is ready. The badge only appears on genuine, rewritable HTML page responses — never on JSON, redirects, Turbo Stream responses, file downloads, or `/karst` itself — and it degrades to a plain, unstyled link under a host Content-Security-Policy that forbids inline styles; Karst never rewrites the host's own CSP header to work around this. On a Rack 2 stack (Rails 6.1 and, on Rack 2, Rails 7.0) the response body Karst would need to rewrite isn't safely bufferable, so the badge is unavailable there; `/karst` itself is unaffected. See [Compatibility](#compatibility) below.

You can still reach the panel directly with query parameters, as a fallback: `/karst?controller=Author::ProjectsController&action=index`.

Access is limited to true loopback peers and, under WSL, the single host-side default gateway used by a Windows browser; forwarding headers and private address ranges are not trusted. Nonlocal requests and every path other than `/karst` fall through unchanged to the host application (aside from the badge link Karst adds to eligible HTML responses). The controller/action context is always derived from real request evidence, not the query string: the standalone panel request is never attributed to a host controller/action, and the badge link never carries the host page's own query string.

### Exact-resource state evidence

`Karst::Access::ResourceEvidence` is a separate, read-only step you can run after a sweep, for one outcome you have already selected (for example, the one principal that observed `200` where every other bounded principal observed `302`). Given that outcome and the sweep's exact path, `ResourceEvidence.for_outcome(outcome:, path:, http_method: "GET")` reports simple, directly observed foreign-key relationships between the exact resource that route addresses and that exact principal -- for example, that `Document#22`'s `user_id` column equals `User#27`'s id. `Result#to_text` renders this as plain evidence:

```
User #27
Observed 200

Related state:
Document #22
  user_id → User #27
```

This is evidence, not an authorization claim -- it never states or implies *why* the outcome occurred, only which foreign-key columns, if any, point from one given record to the other's id. Only foreign-key-shaped columns (ending in `_id`) are ever inspected, so no other attribute -- name, email, token, or anything else -- is ever read or shown; only a direct column-value comparison between the two given records is made, never a join, a `has_many` traversal, or any multi-hop graph walk.

The panel runs this downstream evidence step for usable outcomes and displays a
**Related state** block when a direct relationship is available. A missing or
limited resolution simply omits that block; it does not hide the usable
principal. Principal descriptors are resolved only through a configured
principal source (`config.principals` or `config.principal_sources`), so even
a valid model name and database id cannot expand Karst's configured principal
universe.

The sweep itself still performs no route discovery or resource substitution (see above): `ResourceEvidence` is a distinct, downstream, opt-in step that never changes what a sweep executes. Resolving the exact resource from a route path is attempted only through Rails' own route recognition plus its controller-to-model naming convention, and only trusted when every step succeeds unambiguously -- a recognized route with an `:id` segment, a controller name that classifies to a real loaded Active Record model, and a record that actually exists for that id. Anything softer (an unrecognized route, a controller with no conventional model, a missing record, or a principal outside the configured source) is reported back as a `limitation` string rather than guessed at; `Result#to_text` renders it as `Unavailable: <reason>` instead of silently fabricating a relationship. `ResourceEvidence.new(resource:, principal:).call` is available directly when you already hold both actual records and want to skip route resolution entirely.

## Configuration

Configure Karst in a Rails initializer:

```ruby
Karst.configure do |config|
  config.enabled = true
  config.buffer_size = 2_000
  config.access_sweep_limit = 25
end
```

Karst is enabled by default in Rails development and test environments and disabled in other Rails environments. It defaults to disabled outside Rails.

When enabled, Karst subscribes automatically after the Rails application initializes. `Karst.subscribe!` and `Karst.unsubscribe!` provide idempotent manual control, primarily for tests. `Karst.subscribed?` reports whether Karst currently owns a subscription.

`buffer_size` must be a positive Integer and defaults to 2,000. It is read when `Karst.buffer` is first created; changing configuration afterward does not resize or replace that process-level buffer.

## Roadmap

Development will proceed from small evidence-capture primitives to traceable analysis and, only where the evidence supports it, recommendations. Concrete capabilities will be documented as they are designed and shipped.

## Compatibility

Karst supports Ruby 2.7+ and Rails 6.1+; see [ARCHITECTURE.md](ARCHITECTURE.md#compatibility-policy) for exactly which combinations CI proves and how optional features degrade.

Some development UI conveniences depend on Rack/Rails response behavior. When Karst cannot safely inject its page-local badge (Rack 2, in practice Rails 6.1 and Rails 7.0), `/karst` remains available directly, and every other capability — evidence capture, the scenario catalog, the spec observer — is unaffected.

## Installation

Add Karst to your bundle. Active Support is its only runtime dependency; requiring Karst does not load Rails or Active Record.

```sh
bundle add karst
bin/rails generate karst:install
```

`bin/rails generate karst:install` is optional, convenience scaffolding for a Rails host application -- it is never required. Karst remains fully configurable by hand (see [Identity adapters](#identity-adapters) above), and an application that already configures `Karst.configure` manually has nothing to gain from running it. What it does not do is guess: Karst cannot safely infer how an arbitrary application authenticates, so it never wires up a working login flow on your behalf.

The generator creates three things:

- `config/initializers/karst.rb` -- a documented but entirely commented-out initializer with placeholders for every hook described under [Identity adapters](#identity-adapters): `config.principals`, `config.assume_identity`, `config.clear_identity`, `config.assume_browser_identity`, and `config.clear_browser_identity`. The examples in the comments are examples, not assumptions about this application's `User` model, session keys, or auth library.
- `app/controllers/karst_identity_controller.rb` -- a small, explicitly named `KarstIdentityController` that exists only so Karst's isolated probe session has a real request/response cycle to establish and clear authentication through. `create` first resolves the submitted principal strictly through `Karst::Identity.resolve` -- never a bare `Model.find`, so a probe request can never reach outside whatever `config.principals` returns -- then raises `NotImplementedError` with a clearly marked `TODO` until a developer replaces that part with this application's real sign-in code (session-based, Devise, Warden, or anything else) operating on the already-resolved principal. `destroy` raises the same way until wired to this application's real sign-out code. Karst does not implement a generic authentication mechanism for you.
- Development-only routes for that controller, inserted into `config/routes.rb` inside `if Rails.env.development?`. Running the generator again does not duplicate this block.

Installation is not complete until those TODOs are replaced with this application's real identity semantics; the generator prints next steps as a reminder rather than claiming the work is done. Automatic support for common auth libraries (Devise, Warden) is future work, not part of this generator.

## Contributing

Contributions and design discussion are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the evidence expected in a change.
