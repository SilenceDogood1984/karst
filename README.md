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

In Rails development, Karst serves a read-only scenario panel at `GET /karst` through a small Rack middleware — no engine, route, or controller. The panel reads `tmp/karst/scenarios.json` through `Karst::Spec::Catalog` and shows the statuses, redirects, principal types, outcomes, and spec provenance observed for a controller/action. It distinguishes a missing or invalid artifact from a ready catalog with no matching scenarios. Runtime SQL Window counts remain available as secondary evidence.

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

The sweep itself still performs no route discovery or resource substitution (see above): `ResourceEvidence` is a distinct, downstream, opt-in step that never changes what a sweep executes. Resolving the exact resource from a route path is attempted only through Rails' own route recognition plus its controller-to-model naming convention, and only trusted when every step succeeds unambiguously -- a recognized route with an `:id` segment, a controller name that classifies to a real loaded Active Record model, and a record that actually exists for that id. Anything softer (an unrecognized route, a controller with no conventional model, a missing record) is reported back as a `limitation` string rather than guessed at; `Result#to_text` renders it as `Unavailable: <reason>` instead of silently fabricating a relationship. `ResourceEvidence.new(resource:, principal:).call` is available directly when you already hold both actual records and want to skip route resolution entirely.

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

Add Karst to your bundle and require `karst`. Active Support is its only runtime dependency; requiring Karst does not load Rails or Active Record.

## Contributing

Contributions and design discussion are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the evidence expected in a change.
