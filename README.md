# Karst

Karst is a runtime evidence engine for Rails.

## What is Karst?

Karst is intended to capture what actually happened while a Rails application ran and make that evidence useful. It starts from observed behavior rather than guesses about what code might do.

## Quick start

```sh
# Gemfile
gem "karst", group: :development

bundle install
bin/rails karst:install
bin/rails server
```

Then visit `/karst`.

If your app uses a conventional single-model Devise setup (one Devise-authenticatable
model, commonly `User`), Karst automatically uses that model and Warden for access
probes and "Test as" -- no identity configuration required. If Karst finds more than
one Devise model, or none, it says so directly on the `/karst` panel instead of
guessing; see [Identity adapters](#identity-adapters) for exactly what "automatic"
means, how the Devise model and Warden scope are determined, and how to configure
things explicitly for custom authentication.

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

### The automatic Devise/Warden path

Karst does not "understand authentication." It detects specific, stable framework
metadata and uses Warden's own runtime identity API only when it can prove the
mapping -- it never guesses.

When `config.principals` is not explicitly set, Karst reads `Devise.mappings`
(populated by `devise_for` in `config/routes.rb`, the same metadata Devise itself
relies on for `current_user`/`authenticate_user!`). If it finds exactly one
Devise-registered model, that model becomes the effective principal source
(conceptually `User.all`, evaluated lazily like any other source -- Karst never
counts or scans the table to make this determination). If it finds more than one
Devise model, automatic principal selection is unavailable and the `/karst` panel
says exactly which models it found instead of picking one; configure
`config.principals` explicitly to resolve the ambiguity.

Independently, when `config.assume_identity`/`config.clear_identity` (probe) or
`config.assume_browser_identity`/`config.clear_browser_identity` (browser "Test as")
are not explicitly set, Karst derives the Warden scope for a principal directly from
Devise's mapping for that principal's own class -- never a hardcoded `:user`, so
`AdminUser` correctly resolves to `:admin_user` and so on -- and calls Warden's
public `set_user(principal, scope: scope)` / `logout(scope)` on the probe's isolated
integration session or, for "Test as", the real local browser request. If Devise is
loaded but the scope for the effective principal can't be determined safely, Karst
refuses to guess and reports the limitation rather than assuming `:user`.

Explicit configuration always wins and is never partially combined with inference:
setting `config.principals` to a custom scope does not require also configuring the
identity hooks by hand -- Karst still infers Warden scope for whatever model that
scope resolves to, as long as it is one Devise itself maps (for example,
`config.principals = -> { Admin.all }` still gets automatic probe/browser identity
for the `:admin` scope). Setting `config.assume_identity`/`config.clear_identity`
explicitly disables automatic *probe* identity only; automatic browser identity is
unaffected unless its own hooks are also set explicitly, and vice versa. Setting
only one of a pair (`config.assume_identity` without `config.clear_identity`, or the
reverse) is a configuration error, not a partial fallback to inference.

None of this weakens Karst's existing safety boundaries: automatic browser identity
still only operates through Karst's local-development-only, CSRF-protected browser
identity path, still resolves principals only through the effective `config.principals`
source, and is still unavailable outside `Rails.env.development?`.

### Custom or non-Devise authentication

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
not an authorization conclusion. By default, an outcome is usable only when it
is an observed 200 response with no observed exception and no observed halted
callback. Other statuses, exceptions, and halted callbacks
remain evidence, but are not stronger proof that the page can be used.
Applications can narrowly replace that policy without changing or filtering
the sweep evidence:

```ruby
Karst.configure do |config|
  config.usable_access_outcome = lambda do |outcome|
    outcome.status == 204 # An application-specific policy, if deliberately desired
  end
end
```

Every outcome remains in the bounded sweep result. Non-usable status groups,
redirects, exceptions, timings, and write/rollback warnings remain available
under **Other observed outcomes**. If none of the sampled candidates produces
a usable outcome, the panel says exactly that; it does not claim that no user
can access the page.

### Explicit artifact scenarios

Applications can add a deliberately application-authored artifact population
and scenario. Karst does not discover records, relationships, paths, or the
meaning of a successful response:

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

`expect` accepts only `status`, an exact query-free `redirect`, and
`body_includes`. They are observable response predicates, not authorization
assertions. Multiple predicates must all match. Response bodies are inspected
for the configured marker but are not retained in evidence.

Artifact sources require a limit from 1 through 1,000. Karst applies that
limit to an Active Record relation before enumeration (and lazily takes the
same bound from another Enumerable). A scenario additionally caps actual
principal × artifact requests at `combination_limit` (1 through 100), while
principal selection retains the existing representative principal bound.
`stop_on_match: true` is the default and returns after the first verified
combination; set it to false to retain every observation up to the combination
cap. Every request still uses a fresh identity session and rollback-only
transaction, and exceptions remain mismatch observations.

For an Import QA case, the host application can define separate explicitly
scoped sources (for example, recent imports with sheets) and scenarios with
the desired path and marker. `Import`, `Sheet`, ownership, and what makes an
import useful remain entirely application-configured; Karst only reports the
principal, artifact, concrete GET, observed response, expected predicates,
and whether those observations matched.

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
sweep instead of taking whatever rows happen to sort first. It first uses
configured dimensions as application-authored semantic hints. When none is
configured, it falls back to covering
distinct *observed database states* within the bounded recent-user pool --
boolean columns, `enum` columns, presence/absence of a nullable foreign key,
and low-cardinality scalar columns. Discovery happens in memory only after the
pool's single `LIMIT`-bounded query; it never scans or counts the full table.
This fallback is schema-state diversity, not behavioral diversity: the sampler
never executes a route, so it has no evidence about how any of these principals actually behave -- that evidence exists only once
`Access::Sweep` runs.

A conservative, name-based filter unconditionally excludes anything resembling
email, name, phone, address, token, password, or other sensitive columns,
regardless of cardinality. Separately, a foreign key shaped like a
tenant/account/organization boundary (`tenant_id`, `account_id`, and similar)
is excluded by name as well, independent of nullability or cardinality --
cardinality alone cannot be what keeps such a column out, since a *nullable*
one would otherwise reach presence/absence sampling without ever going through
the cardinality check.

Query volume is exactly one bounded recent-pool query, independent of table
size; `Karst::Access::PrincipalSampler.query_budget` states that bound
explicitly. Every stratification decision after that is made in memory over
the pool, so schema fallback issues no discovery queries at all. Candidate
populations are not sampled here -- they are
[a second search stage](#automatic-population-retry) owned by
`Karst::Access::Search`, and cost one bounded query each only if the ordinary
sample found nothing usable. An Active Record source with a
composite or missing primary key
raises `Karst::Access::PrincipalSampler::UnsupportedPrimaryKey` (a
`Karst::Access::Error`) rather than failing obscurely mid-query; pass an
already-materialized `Array`/Enumerable of principals instead to use bounded-
first sampling in that case. Selection is deterministic and never escapes the
relation `config.principals` returned -- an already tenant-scoped relation
stays tenant-scoped. The sampler only selects candidates: it runs no route,
compares no outcomes, and its result feeds `Karst::Access::Sweep` exactly like
any other bounded principal source. Any other Enumerable source falls back to
the existing bounded-first strategy, unchanged.

### CLI verification

Run the same bounded `Karst::Access::Search` workflow used by `/karst` from a
shell (the method may be omitted because GET is the only supported method):

```sh
bin/rails karst:verify GET /admin/imports/123
bin/rails karst:verify GET /admin/imports/123 --json
```

The human form is compact terminal output. The JSON form is a stable evidence
interface intended for tools and scripts. Its top-level `schema_version` is
currently `1` and will change when a breaking output change occurs. Neither
form includes response bodies, record attributes, SQL, cookies, sessions, or
query strings.

Exit codes are `0` when a verified usable principal was found, `1` when the
bounded verification completed without one (JSON is still emitted), and `2`
for input, setup, or configuration errors. HTTP response statuses are evidence
in the output and are never used as process exit codes.

### Candidate populations, principal sources, and compatibility dimensions

Candidate populations are the preferred way to describe principals worth
trying, and are searched automatically after an ordinary sample fails.
Configured dimensions shape that ordinary sample; generic schema discovery
remains a zero-configuration fallback used only when no dimension is
configured. Real
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

#### Candidate populations: `config.principal_populations`

Real applications already contain vocabulary for meaningful subsets of
principals that schema-state diversity alone cannot reliably find -- a
`system_admins` scope, an `auditors` scope, a `responders` scope. A configured
population is tried regardless of how many columns exist and, unlike fallback
schema discovery and configured dimensions, which are scoped to the bounded
recent-N `principal_candidate_pool_size` pool, is queried against the full
configured relation, so a population that matters but is not recent (a
`system_admins` account created years ago) is never invisible just because
it fell out of the pool. Populations are not mixed into the ordinary
sample; they are a deliberate second stage that runs only when the sample
found nothing usable (see
[Automatic population retry](#automatic-population-retry)):

```ruby
Karst.configure do |config|
  config.principals = -> { User.all }
  config.principal_populations = {
    system_admins: -> { User.system_admins },
    auditors: -> { User.auditors },
    responders: -> { User.responders }
  }
end
```

**A population is a hint, never a claim.** Configuring
`config.principal_populations` tells Karst "these records are worth
trying" -- not "these records satisfy the behavior" and not "this
population grants access." Karst never infers that a population causes any
authorization or UI behavior; only `Access::Sweep`'s actual runtime
execution observes what a request does. The panel never states
`system_admin scope grants access` or anything like it -- only that a
principal was *sampled from* that population.

Each value in `config.principal_populations` is a zero-argument callable --
typically `-> { Model.some_scope }`, but any callable that returns an
`ActiveRecord::Relation` scoped to the same model works identically.
**Karst does not, and cannot, verify that the callable's body came from
Rails' own `scope :name, -> { ... }` macro -- Active Record exposes no
public registry that would distinguish a named scope from an ordinary
handwritten class method.** Karst only checks the one thing it can actually
observe: calling the configured callable returns a same-model relation. A
callable that raises, that requires an argument, or that returns something
else entirely (another model's relation, a plain value) is silently
skipped rather than raised: a mistake in configuration degrades the
candidate pool, it does not break the sweep. Every configured population
costs at most one `LIMIT`-bounded query, bounded by
`config.population_retry_limit` (plus a small allowance so already-tested
users cannot consume that budget, itself hard-capped) -- never a `COUNT`,
and never full materialization, regardless of the population's real size.
Populations are tried one at a time, in configuration order, and only until
one succeeds, so no population can crowd out another.
Karst evaluates the callable and materializes its bounded relation inside a
rollback-only transaction on the source model's Active Record connection. It
observes the same `INSERT`, `UPDATE`, and `DELETE` SQL evidence as an access
sweep and rejects a population that emits a write, even though rollback was
attempted. This is deliberately reported only as same-connection database
rollback: it cannot contain jobs, mail, HTTP requests, files, Redis, writes on
other connections, or any other non-database effect. Candidate evaluation is
therefore execution evidence, not a claim that the callable is side-effect
free.
When the configured relation already specifies its own order, Karst keeps
it; only when the relation has no order of its own does Karst add a
deterministic primary-key fallback so results stay reproducible. A user
already tested in the ordinary sample, or in an earlier population, is
never probed again; its provenance records the population it was reached
through -- shown on the **Sampled for** line:

```
Sampled for:
population=system_admins · role=local_admin
```

An application representing identity as more than one model configures
populations per source instead of (or alongside) the flat form above:

```ruby
config.principal_sources = {
  authors: { records: -> { Author.all }, populations: { admins: -> { Author.admins } } },
  readers: -> { Reader.all }
}
```

This is deliberately generic under the hood
(`Karst::Access::CandidatePopulation`: source, name, bounded records,
provenance label) so the same mechanism can later resolve populations over
non-principal models -- `Subscription.renewable`, `Import.with_sheets` --
without a rewrite. This release wires it into principal search only.

#### Automatic population retry

Analyzing a route runs one search (`Karst::Access::Search`), in two stages.
The ordinary bounded sample runs first. Only if it observes no usable
outcome does Karst automatically try each **approved** population, in
configuration order, stopping at the first verified success:

```
GET /admin/imports

25 users tested · including 1 user from 1 candidate population · 2.4s
Sample: 25 recent users, none usable · halted at authorize_admin

Usable users — 1
  User #27   Observed 200 OK      [ Test as ]
  Sampled for: population=system_admins

Candidate populations
  system_admins — User #27 → 200 OK ✓
  auditors      — not tried — a usable user was already found
  responders    — not tried — a usable user was already found
```

A population qualifies for automatic execution only by being **configured**
-- `config.principal_populations`, or a `config.principal_sources[...]`
`:populations` entry. A name merely *discovered* at `/karst/populations` is
never executed automatically; discovery only produces a snippet for you to
paste.

The retry is bounded twice over: at most `config.population_retry_limit`
records per population (default 3, maximum 10), and at most
`config.access_sweep_limit` extra requests in total across every population,
so enabling populations can never make an analysis cost more than roughly
twice an ordinary sweep. Each population costs one additional `LIMIT`-bounded
query -- never a `COUNT`, never full materialization. A user already tested
in the sample or an earlier population is never probed twice.

When no population produces a usable user, every one of them is still
reported, honestly and separately: `no matching records`, `could not be
resolved`, `every candidate was already tested above`, or the observed
outcomes it did produce (including any halted callback). A population that
matches nothing, returns the wrong shape, or raises is reported that way
rather than aborting the analysis.

#### Compatibility: `config.principal_dimensions`

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
(`:system_admin?`), or a callable of one argument. Configured dimensions remain
supported and are evaluated over the bounded recent-user pool. They shape
which users the *ordinary sample* covers; candidate populations are what
Karst searches when that sample finds nothing usable. Generic schema
discovery runs only when no dimension is configured -- it never supplements
the ones that are. Given a pool of 900 `responder`, 50
`local_admin`,
30 `group_admin`, 15 `reseller`, and 5 `system_admin` accounts and a limit of
25, Karst deliberately tries to include a representative of every configured
role value before simply filling the rest with more responders.

Every retained dimension form -- a column, Rails boolean predicate, computed
predicate, or callable -- is evaluated in Ruby over the already query-bounded
candidate pool `PrincipalSampler` derives for large-table
safety (see above), never per-row against the full table.

A dimension named (or, for a `Symbol`/`String` accessor, reading an
attribute named) like `email`, `name`, `phone`, `token`, `password`,
`address`, or `credential` is rejected with `ArgumentError` as soon as it is
configured. Karst dimensions are for coarse state, not user identity data --
this cannot be checked for a callable accessor, since its body cannot be
inspected, so a callable that itself reads PII is a configuration mistake
Karst cannot catch on your behalf.

#### Discovering and curating candidate populations

Writing `config.principal_populations` by hand works well once you know
which scopes matter. On a large application -- dozens or hundreds of
models, many with several scopes -- finding them by reading source is
tedious. `Karst::Access::PopulationDiscovery` offers an explicit,
conservative discovery step: it parses application model source with Ruby's
standard-library `Ripper` AST parser and lists statically named Rails `scope`
declarations whose lambda has no parameters. Ordinary class methods and
dynamic scope names are never candidates, and optional, splat, or keyword
parameters are conservatively excluded. Ripper was chosen instead of Prism
because it ships with every supported Ruby version, including Ruby 2.7.

Discovery currently includes scopes declared directly on application models.
Scopes contributed by concerns may not appear. It never executes a scope or
other model method, never issues a query, and never runs automatically on an
ordinary `/karst` request -- only when explicitly triggered.

Two ways to trigger it:

```
bin/rails karst:populations
```

prints every discovered model and its candidate scope names to the
terminal. Or visit `/karst/populations` (linked from the main `/karst`
panel) for a browsable, curatable page: models are grouped and collapsed by
default (`<details>`, no frontend framework -- a little vanilla JS only
powers client-side search/filter), so an application with 150 models and
500 candidate scopes never renders as one giant checkbox dump.
Checking a scope and clicking **Preview** runs a separate, explicit,
`LIMIT 3`-bounded query (never a `COUNT`, never full materialization) to
show a handful of matching records -- still just a hint, never a claim that
the population grants access.

Selecting populations and clicking **Generate configuration snippet**
produces ready-to-paste Ruby -- `config.principal_populations = { ... }`,
or `config.principal_sources = { ... }` when more than one configured
principal source is involved (keeping same-named populations on different
models distinguishable, e.g. `Author.admins` vs. `Reader.admins`). Karst
never writes this into your application's files automatically; you stay in
control of what actually gets committed. A selected population belonging to
a model that isn't (yet) a configured principal source is reported back
honestly as left out of the snippet, rather than silently dropped -- the
discovery/candidate representation is deliberately generic (model name +
method name), so the same UI can support curating *artifact* populations
(`Subscription.renewable`) later without a rewrite; this release only wires
selections into principal sampling.

**Automatic retry.** Approved populations are tried automatically -- see
[Automatic population retry](#automatic-population-retry) below. There is no
separate button to press.

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

When Warden has already been loaded and no explicit identity hooks are configured,
Karst can alternatively use the public `set_user` and `logout` APIs on an existing
Rack `env["warden"]` proxy -- with an explicit `scope:` derived from Devise's own
mapping when Devise is present (see [Identity adapters](#identity-adapters) above),
or without one for a plain, non-Devise Warden setup. Warden is not required or
eagerly loaded. A bare `ActionDispatch::Integration::Session` does not expose an
initialized Warden proxy generically; configure the explicit hooks above for that
case rather than relying on app-specific Warden internals.

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
  config.population_retry_limit = 3
end
```

Karst is enabled by default in Rails development and test environments and disabled in other Rails environments. It defaults to disabled outside Rails.

When enabled, Karst subscribes automatically after the Rails application initializes. `Karst.subscribe!` and `Karst.unsubscribe!` provide idempotent manual control, primarily for tests. `Karst.subscribed?` reports whether Karst currently owns a subscription.

`population_retry_limit` bounds how many records a single configured candidate population may contribute to an automatic retry. It must be an Integer between 1 and 10 and defaults to 3. The total number of extra requests every population may add is bounded separately by `access_sweep_limit`.

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

`bin/rails generate karst:install` is optional, convenience scaffolding for a Rails host application -- it is never required. Karst remains fully configurable by hand (see [Identity adapters](#identity-adapters) above), and an application that already configures `Karst.configure` manually has nothing to gain from running it.

For a conventional single-model Devise application, the generated initializer needs no changes at all -- the automatic Devise/Warden path described under [Identity adapters](#identity-adapters) takes over as soon as Rails boots. What the generator does not do is guess at a *custom* authentication mechanism: Karst cannot safely infer how an arbitrary non-Devise application authenticates, so it never wires up a working login flow on your behalf there.

The generator creates three things:

- `config/initializers/karst.rb` -- leads with the automatic Devise/Warden path, then documents every hook described under [Identity adapters](#identity-adapters) (`config.principals`, `config.assume_identity`, `config.clear_identity`, `config.assume_browser_identity`, `config.clear_browser_identity`) as commented-out overrides for the ambiguous-Devise or custom-authentication case. The examples in the comments are examples, not assumptions about this application's `User` model, session keys, or auth library.
- `app/controllers/karst_identity_controller.rb` -- a small, explicitly named `KarstIdentityController` that exists only so a *custom* `config.assume_identity`/`config.clear_identity` pair has a real request/response cycle to establish and clear authentication through, for applications not on the automatic Devise/Warden path. `create` first resolves the submitted principal strictly through `Karst::Identity.resolve` -- never a bare `Model.find`, so a probe request can never reach outside whatever `config.principals` returns -- then raises `NotImplementedError` with a clearly marked `TODO` until a developer replaces that part with this application's real sign-in code operating on the already-resolved principal. `destroy` raises the same way until wired to this application's real sign-out code. It is unused, and safe to delete, on the automatic Devise/Warden path.
- Development-only routes for that controller, inserted into `config/routes.rb` inside `if Rails.env.development?`. Running the generator again does not duplicate this block.

On the automatic Devise/Warden path, installation is complete as generated. For custom authentication, installation is not complete until the `KarstIdentityController` TODOs are replaced with this application's real identity semantics; the generator prints next steps as a reminder rather than claiming that work is done.

## Contributing

Contributions and design discussion are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the evidence expected in a change.
