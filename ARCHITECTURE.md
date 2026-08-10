# Architecture

This document describes how Karst is put together and the policy that governs which Ruby/Rails combinations it supports. See [README.md](README.md) for user-facing behavior and [CONTRIBUTING.md](CONTRIBUTING.md) for the day-to-day development workflow.

## Component map

- `Karst::Buffer` / `Karst::Subscription` — an idempotent `sql.active_record` subscription that converts notifications into immutable `Karst::Sql::Event` objects and retains a bounded, process-local, thread-safe window of recent ones.
- `Karst::Sql::Canonicalizer` / `Sql::Shape` / `Sql::Window` — conservative, non-parsing SQL structural analysis that groups retained events into shapes on demand (`Karst.window`); never mutates or reinterprets the buffer itself.
- `Karst::Spec::Observer` / `Spec::Reporter` — an opt-in RSpec integration that turns real spec execution (via `ActiveSupport::Notifications` and Warden's public hooks) into a deterministic JSON scenario artifact, with no source parsing and no database access.
- `Karst::Spec::Catalog` — a read-only index over that artifact; requires none of RSpec, Rails, or a database to read an already-written catalog.
- `Karst::Web::Middleware` / `Web::Panel` / `Web::Badge` / `Web::Locality` — Karst's development-only HTTP surface: `GET /karst` served directly at the Rack boundary (no engine, route, or controller) plus an optional page-local badge injected into eligible host HTML responses.
- `Karst::Access::PrincipalSampler` — an optional, bounded-query candidate-selection step ahead of `Access::Sweep`. Over an Active Record relation/class it replaces "first 25 rows" with deterministic principals chosen to cover distinct observed boolean/enum/nullable-foreign-key/low-cardinality-scalar database *states* (not behavior -- it never executes a route); over any other Enumerable it falls back to the same bounded-first strategy `Sweep` itself uses. A tenant/account/organization-shaped foreign key is excluded by name regardless of nullability or cardinality, and its total query volume per call is capped by `PrincipalSampler.query_budget(limit)`, enforced at every query-issuing site rather than merely estimated. Deliberately a separate class from `Sweep`: it only selects candidates and never executes a route.

Each area is deliberately narrow and composable; none of them depends on the others' internals beyond the public objects listed above.

## Compatibility policy

**Supported core: Ruby >= 2.7, Rails >= 6.1.** This is a CI-backed claim, not an aspiration: a legacy job runs the real integration suite against Ruby 2.7 and Rails 6.1 on every push and pull request, alongside modern targets (see [CI](#ci)). Karst does not claim support for a Ruby/Rails combination CI does not exercise.

The guiding rule: **core Karst functionality works on Rails 6.1 even where an optional UI convenience does not.** Nothing in Karst raises, at load time or at request time, because a modern-Rails-only API is unavailable. Where a capability genuinely cannot be provided safely on an older stack, that one capability degrades quietly; nothing else is weakened to compensate, and modern Rails never loses anything to accommodate the older floor.

### Capability degradation

| Rails / Rack       | `require "karst"` | Runtime SQL evidence | Spec Observer | Scenario Catalog | `/karst` panel | Page-local badge |
|---------------------|:---:|:---:|:---:|:---:|:---:|:---:|
| 6.1 / Rack 2         | yes | yes | yes | yes | yes | **unavailable** |
| 7.0 / Rack 2         | yes | yes | yes | yes | yes | **unavailable** |
| 7.1, 7.2, 8.x / Rack 3 | yes | yes | yes | yes | yes | yes |

The badge is the one capability that degrades. `Karst::Web::Badge` only ever rewrites a Rack response body that reports itself bufferable via Rack's own `to_ary` idiom (the same check `Rack::ETag` relies on for the same reason). Under Rack 2, `ActionDispatch`'s response body wrapper never exposes `to_ary`, so every response reports non-bufferable and Badge leaves it untouched — this is a real, per-response runtime check, not a hardcoded Rails-version branch, so it needs no maintenance as new Rack/Rails combinations appear. `/karst` itself does not depend on badge injection at all: it is a small, independent Rack middleware branch keyed on `PATH_INFO`, so it is unaffected. Karst never monkey-patches `ActionView`, never consumes a streaming body to work around this, and never weakens `Content-Length`, CSP, or host middleware semantics to force badge parity onto Rack 2.

### Value objects: `Karst::Value`

Ruby 2.7 has no `Data.define` (added in Ruby 3.2). Every former `Data.define` site now goes through `Karst::Value.define`, a small internal helper built on `Struct.new(..., keyword_init: true)`: Struct already provides structural equality, keyword construction, and `#members`; the one thing it does not provide for free is immutability, so `Value.define` freezes every instance its class produces. This is a shallow freeze, matching `Data.define`'s own contract exactly — a member holding a mutable object (an `Array`, say) is not deep-frozen, and Karst does not need it to be. There is no version branching here: `Karst::Value` is used uniformly on every supported Ruby, so `Data.define` semantics never need to be reverse-engineered from two different code paths.

### Request-local state: `Karst::ExecutionContext`

The page badge and the spec observer both need request-local (not global, not thread-shared-and-racy) correlation storage: evidence captured inside a notification callback, read back out after the call returns. Modern Rails provides exactly this via `ActiveSupport::IsolatedExecutionState`, added in Rails 7.0. `Karst::ExecutionContext` is the seam:

- When `ActiveSupport::IsolatedExecutionState` is defined, `Karst::ExecutionContext` delegates directly to it — modern Rails keeps using its own preferred primitive, with no extra indirection cost.
- Otherwise (Rails 6.1), it falls back to `ThreadLocalStore`, a plain per-thread `Hash` reached through `Thread#thread_variable_get`/`thread_variable_set` — deliberately not `Thread#[]`/`[]=`, which are fiber-local and would silently miss context under a Fiber scheduler.

The fallback mirrors `IsolatedExecutionState`'s own default `:thread` isolation level: storage is shared by every Fiber running on one OS thread, not isolated per Fiber. Karst's own usage (one badge or spec correlation captured and read back within a single synchronous request or example) never spans multiple concurrently-scheduled Fibers, so this has no observable effect on Karst's supported behavior — it is documented so a future caller does not assume Fiber isolation the fallback cannot provide.

Both backends share the same three-method contract (`[]`, `[]=`, `delete`), cleanup happens in the caller's own `ensure` block exactly as before, and neither backend introduces global mutable state: each thread only ever sees its own slot, so concurrent Puma requests cannot cross-contaminate each other's context.

### No scattered version checks

Compatibility decisions live behind exactly two narrow seams — `Karst::Value` and `Karst::ExecutionContext` — plus one capability-detected `require` (`Karst::Subscription` requires `"logger"` before `"active_support"`; see its source comment for why Rails 6.1 needs that ordering). Feature code elsewhere does not branch on `Rails.version` or `RUBY_VERSION`; where a modern constant might not exist, the one call site checks `defined?` for the capability itself rather than comparing version numbers.

### CI

- `unit-test` — Ruby 3.2, the root `Gemfile` (RSpec + RuboCop against everything except `spec/integration`).
- `rails-integration` matrix — `spec/integration` against a version-pinned `Gemfile` per row, each a real Rails application booted through Rack: Rails 6.1 on Ruby 2.7, Rails 7.0 and 7.1 on Ruby 3.2, Rails 7.2 and 8.0 on Ruby 3.3. Every row is a required, blocking job.

The Rails 6.1 row is what backs the compatibility claim in this document: it boots a real `Rails::Application`, exercises `GET` against ordinary routes and `/karst`, and runs the scenario observer/catalog round trip, all against genuine Ruby 2.7 syntax and Rails 6.1 APIs — not an assumption that "this probably still works."
