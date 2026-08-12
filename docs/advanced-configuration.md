# Advanced configuration

Almost nothing here is part of installing Karst. A conventional single-model Devise application configures none of it — see [README.md](../README.md). This document is for the exceptions: custom authentication, identity spread across several models, populations committed as code, and a few bounds an ordinary developer should never need to change. See [ARCHITECTURE.md](../ARCHITECTURE.md) for how these pieces are implemented.

If you are looking for an option that used to be here, check [Removed configuration](#removed-configuration) at the end.

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

## Authentication identifiers in local human output

Without `config.principal_label`, Karst normally labels a principal `Model #id`.
For a Devise-mapped model, Karst may make the **local HTML panel and human CLI**
more recognizable by reading the model's single, explicitly declared
`authentication_keys` field (for example, `email`) and showing
`user@example.com · User #27`. Email is a `mailto:` link in HTML.

This is deliberately evidence-based rather than a column-name heuristic. Karst
does not scan for `name`, `phone`, `address`, tokens, passwords, or likely login
columns. No identifier is read when Devise is unavailable, the principal's
model is not mapped by Devise, the declared key is missing, its value is nil or
empty, or Devise declares multiple authentication keys. Multiple keys fail
closed because Karst cannot determine which key is appropriate to disclose.

Framework-inferred identifiers are **never serialized in `--json` output or MCP
output**; those interfaces retain `Model #id`. A callable
`config.principal_label` still overrides inference completely, is not being
deprecated here, and remains explicit application consent for that configured
label to appear in all existing outputs.

## Multiple user models: `config.principal_sources`

Some apps represent identity as more than one model (`Author`, `Reader`) rather than one `User` with a role column:

```ruby
Karst.configure do |config|
  config.principal_sources = {
    authors: { records: -> { Author.all }, populations: { admins: -> { Author.admins } } },
    readers: -> { Reader.all }
  }
end
```

Each source is a name plus a lazily-evaluated `records:` callable, and optional `populations:` of its own. Those are the only two keys a source spec accepts; anything else raises `ArgumentError` rather than being quietly ignored. Sources are never merged together — Karst keeps each independently queryable and never confuses `Author #12` with `Reader #12`. `config.principals` (plus `config.principal_populations`) remains fully supported; it's normalized internally into one implicit `:default` source, so this is additive, not a breaking change to the simple form in the main README.

Candidates are split across sources within one overall `access_sweep_limit`: every non-empty source gets at least one candidate, and the rest fill round-robin so one source running dry never starves another.

## Several Devise models, selected locally

`config.principal_sources` above is the way to commit multiple sources as reviewable Ruby. If your app simply has more than one Devise model (`User`, `Admin`) and nothing configured, Karst still refuses to guess which one(s) to test — but you don't have to write an initializer to resolve that. The `/karst` panel shows every Devise-detected model as a checkbox right where the old "configure `config.principals`" message used to sit:

```
Karst found 2 user types: Admin, User.

Which should Karst test?

[ ] Admin
[ ] User

[Save]
```

Checking one model behaves exactly like a single-model Devise app always has. Checking more than one produces exactly what `config.principal_sources` would: one independently queryable source per model, each keyed by its own Devise/Warden scope (`User` → `:user`, `Admin` → `:admin`) — never collapsed into a combined source, and probe/browser identity always uses the correct scope for whichever source actually produced a given principal.

The selection is saved to `tmp/karst/principal_source_selection.json`, relative to `Rails.root` — the same machine-local, git-ignored, development/test-only mechanism candidate-population approval already uses (see [Curating candidate populations](#curating-candidate-populations) below): a bare model name, nothing else, revalidated against Devise's own current `Devise.mappings` on every read. A selected model Devise no longer maps (removed, renamed) is silently dropped rather than trusted, and if that empties the selection entirely, Karst is ambiguous again and asks once more. An explicitly configured `config.principals`/`config.principal_sources` always wins outright over a saved selection, exactly like it wins over Devise inference. Once saved, `/karst`, `bin/rails karst:verify`, and the MCP `verify_access` tool all pick it up automatically, with no separate wiring — and both return the same actionable, structured error before anything is selected.

## Representative sampling

Nothing here is configurable — it is documented so you can read Karst's output, not so you can tune it.

When `config.principals` (or a source's `records:`) returns an Active Record relation, Karst doesn't just take whichever rows sort first. It fetches one bounded, recent pool (`principal_candidate_pool_size`, default 1,000 rows, exactly one query) and then, in memory over that pool, tries to cover a handful of different observed states: boolean columns, enum columns, presence/absence of a nullable foreign key, and low-cardinality scalar columns (2–10 distinct values). Anything that looks like PII by name (email, phone, address, token, password, and similar) is excluded outright, as is anything shaped like a tenant/account/organization foreign key.

That produces the `Sampled for: role=local_admin` line next to a usable user. It is sampling evidence, never an authorization claim — Karst never states or implies that the role is what let the request through.

When the right user is too rare for this to reach — a role held by three people out of 400,000 — that is what candidate populations are for, and they are a separate, later search stage with its own reporting.

## Curating candidate populations

Writing `config.principal_populations` by hand works well once you know which scopes matter. On a large app, finding them by reading source is tedious — so Karst separates **discovery** (automatic, executes nothing) from **approval** (always an explicit developer action).

**Discovery.** `Karst::Access::PopulationDiscovery` parses application model source with Ruby's standard-library `Ripper` AST parser and lists statically named, zero-argument Rails `scope` declarations. It never calls a scope, never queries anything, and never mutates application state. Only scopes declared directly on a model are found; scopes contributed by a `concern` may not appear. Discovery is not approval — Karst finding `User.system_admins` says only that such a scope exists, never that it grants access.

**Approval.** When an analysis finds no usable user and unapproved candidates exist, `/karst` links to `/karst/populations`: candidates grouped by model, collapsed and searchable. Pressing **Approve selected groups** persists the checked selection to `tmp/karst/approved_populations.json`, relative to `Rails.root`:

```json
{ "version": 1, "approved": [{ "model": "User", "scope": "system_admins" }] }
```

Deliberately machine-local, git-ignored development state, not project configuration — delete the file to reset every approval. It holds **only model and scope names**, never user data, never a `-> { ... }` lambda, and Karst never evaluates its contents; an entry is only ever compared, as a string, against what current discovery still confirms. This is what keeps the file from becoming an arbitrary-method allowlist: a hand-edited entry naming an ordinary class method (`destroy_all`) is never confirmed, and an approval whose scope was renamed, given parameters, or deleted stops being executed the moment the source changes — shown as stale on the review page rather than silently dropped.

An approval only ever becomes executable for a model that is already a configured or Devise-inferred principal source (the class always comes from that source, never from the file), and only in development/test — production never reads the file. `config.principal_populations`/`config.principal_sources[...] :populations` keeps working unchanged and wins outright over an approval of the same name; Karst compares by name only, since it never inspects a configured callable's body. Approved populations reach `Access::Search` the same way configured ones do, so `/karst`, `bin/rails karst:verify`, and the MCP `verify_access` tool all pick them up automatically with no adapter-specific wiring.


## Full configuration reference

This is the entire public configuration surface. Every entry is either an escape hatch for an application Karst cannot infer, or a bound with a working default.

### Normal

```ruby
config.enabled = true    # default: development/test only
```

The single switch that turns Karst's whole development surface off — `/karst`, the page badge, `bin/rails karst:verify`, and the MCP `verify_access` tool all refuse to run when it is false. Karst is off in production regardless.

### Escape hatches

| Option | For |
| --- | --- |
| `principals` | Custom or non-Devise authentication ([above](#custom-or-non-devise-authentication)) |
| `assume_identity` / `clear_identity` | Signing a probe session in and out; must be configured together |
| `assume_browser_identity` / `clear_browser_identity` | Browser **Test as** under custom authentication |
| `principal_label` | A display label for a non-Active-Record principal |
| `principal_sources` | Identity spread across several models ([above](#multiple-user-models-configprincipal_sources)) |
| `principal_populations` | Populations committed as reviewable code, or needed in CI ([above](#curating-candidate-populations)) |

### Bounds

Defaults are chosen to be safe on a large application; changing them is rarely the right fix.

```ruby
config.access_sweep_limit = 25                # users tried per search (1–100)
config.principal_candidate_pool_size = 1_000  # recent-row pool for sampling (1–10,000)
config.population_retry_limit = 3             # records tried per population (1–10)
config.usable_access_outcome = ->(outcome) { outcome.status == 200 && ... }
```

Each numeric bound raises `ArgumentError` outside its range rather than clamping. `usable_access_outcome` lets you redefine what counts as "usable" without changing what evidence is captured — for example, treating a `204` as usable for an API endpoint. The default is: HTTP 200, no observed exception, no halted callback.

## Removed configuration

Karst is pre-1.0 and prefers a clean surface to accumulated accidental complexity. These options existed in earlier product directions and are gone. Setting one raises `Karst::RemovedConfiguration` (a `NoMethodError`) naming the removal — Karst never silently ignores a removed option or reinterprets it as something else.

| Removed | Why, and what to do instead |
| --- | --- |
| `config.principal_dimensions` | Sampling states are derived from your schema automatically ([above](#representative-sampling)); there is nothing to declare. A user too rare for the ordinary sample is reached through a candidate population, which reports itself as evidence. |
| `config.artifact_source` / `config.access_scenario` | Artifact scenarios swept application records rather than routes, and had no place in the current product. Karst analyzes routes. |
| `config.buffer_size` | Runtime SQL capture is gone: Karst kept a process-wide `sql.active_record` buffer that no Karst surface reported any more. `Karst.buffer`, `Karst.window`, `Karst::Sql::*`, and `Karst.subscribe!`/`unsubscribe!`/`subscribed?` are removed with it. Karst now installs no notification subscriber at boot, so it costs a host application nothing per query. Database writes during a probe are still observed and reported — that has always used its own scoped, per-probe subscription. |

A `dimensions:` key inside a `config.principal_sources` spec raises `ArgumentError` for the same reason.

## Safety detail

- `/karst`, the badge, and browser Test As only run for loopback requests (and, under WSL, the single detected host-side gateway a Windows browser appears from) while `Rails.env.development?` is true. Forwarding headers and other private-network addresses are never trusted.
- Every probe runs inside `ActiveRecord::Base.transaction(requires_new: true)` and is always rolled back. This only isolates writes made through the same Active Record connection in that request — not jobs, mail, external HTTP calls, files, Redis, or other database connections.
- Population callables are evaluated inside that same rollback-only transaction; a population whose callable itself performs a write is rejected even though rollback was attempted, because Karst observed `INSERT`/`UPDATE`/`DELETE` SQL from it.
- Every search is bounded: at most `access_sweep_limit` requests for the ordinary sample, and the automatic population retry stage can add at most that many again — so enabling populations can roughly double a search's cost, never more.
- Karst never looks up a user outside a configured principal source. Submitting an arbitrary model name/id to **Test as** resolves nothing unless that model is one of your configured sources.
