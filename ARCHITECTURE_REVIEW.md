# Karst Architectural Review

Review scope: the repository at `9826c91`, with emphasis on the code under `lib/` and its observable API. This review deliberately excludes style, wording, linting, and coverage percentages.

## Overall assessment

**Architectural score: 6.5/10.**

Karst has a strong small core: one notification boundary, one immutable event value, and one bounded process-local store. The implementation avoids frameworks of its own and retains only selected notification data. Those are good foundations for an open-source library.

The current architecture is not yet safe to freeze. Its process-global lifecycle is described as idempotent but is not synchronized, failures at the capture boundary are unconditionally erased, and the event's `started_at` name gives a monotonic-clock value a wall-clock-sounding public name. In addition, implementation classes are public constants even where Karst's module-level facade is intended to own them. These decisions will become substantially harder to correct after consumers build integrations around them.

There are **no Critical issues** in the present, pre-release code. There are two High issues that should be resolved before the architecture is approved for long-term maintenance.

## Things that should not change

1. **Keep the capture model deliberately small.** `Karst::Sql::Event` selects five scalar values rather than retaining the Active Support payload, connection, or arbitrary application objects (`lib/karst/sql/event.rb:6-12`; `lib/karst/subscription.rb:36-46`). This gives the buffer clear ownership and avoids retaining large application graphs.
2. **Keep events immutable value objects.** `Data.define` is an appropriate direct representation here. It gives equality and readers without a custom base class or hierarchy (`lib/karst/sql/event.rb:6-12`).
3. **Keep retention bounded and process-local.** A fixed-capacity in-memory collection is simple and its lifecycle is understandable (`lib/karst/buffer.rb:6-34`). Do not add another storage abstraction in anticipation of future backends.
4. **Keep the Rails integration thin.** The Railtie has one job—install the subscription after application configuration—and is correctly hidden as a constant (`lib/karst/railtie.rb:7-13`).
5. **Keep Active Record out of the require path.** The subscription depends only on Active Support notifications and loads that dependency at use time (`lib/karst/subscription.rb:17-19`).
6. **Keep the top-level facade small.** Configuration, inspection, and lifecycle ownership belong together at the gem boundary (`lib/karst.rb:10-45`). Do not introduce managers, factories, providers, strategies, or service layers around these few operations.

## Public API inventory and permanence decisions

Ruby visibility makes the following observable API available after `require "karst"`. “Hide” below means make the constant private or stop exposing the method before 1.0; it does not require adding a replacement abstraction.

### `Karst`

| API | Decision | Name and permanence |
| --- | --- | --- |
| `Karst.configure { |config| ... }` | **Remain public and document.** This is the conventional configuration boundary and does not expose subscription internals. | `configure` is correct. Freeze its block-based shape before 1.0. |
| `Karst.config` | **Remain public, cautiously.** Callers need read access and initializer assignment already depends on the returned object. It exposes a mutable process singleton, so additions to `Configuration` become permanent API. | `config` is conventional and correct. Freeze only the identity/lifecycle semantics, not a promise that runtime mutation reconfigures initialized objects. |
| `Karst.enabled?` | **Remain public and document.** It is a useful predicate over supported configuration. | Correct predicate name; safe to freeze. |
| `Karst.buffer` | **Remain public and document as the inspection boundary.** Returning the actual mutable buffer exposes `call` and `clear`, not just inspection. Decide before 1.0 whether those mutations are supported consumer behavior. | `buffer` is accurate while this remains a bounded buffer. The returned protocol is already the more consequential API. |
| `Karst.subscribe!` | **Hide unless manual production lifecycle control is an explicit product contract.** It exposes an implementation mechanism and is currently documented as primarily test support. Tests should not force a public production API. | Name correctly signals mutation, but making it public makes notification ownership and idempotence permanent. |
| `Karst.unsubscribe!` | **Hide for the same reason.** It lets any caller globally disable capture for every caller in the process. | Correct internal name; do not freeze publicly yet. |
| `Karst.subscribed?` | **Hide with the lifecycle controls.** It reports an implementation detail rather than a capture capability. | Correct internal name. |
| private `Karst.subscription` | **Keep private.** | The name is precise. Do not expose it or its handle. |

### `Karst::Configuration`

| API | Decision | Name and permanence |
| --- | --- | --- |
| Constant and `.new` | **Hide the constant.** Consumers receive an instance through `Karst.config`; direct construction is not needed for supported configuration. | `Configuration` describes the runtime concept accurately, unlike a pattern name such as `ConfigurationManager`. |
| `enabled`, `enabled=` | **Remain public on the yielded object.** | Names are clear. Decide and document whether mutation is startup-only before 1.0. |
| `buffer_size`, `buffer_size=` | **Remain public on the yielded object.** | The name accurately describes capacity in items. Its “read only on first buffer access” behavior must not remain an implicit trap. |

### `Karst::Buffer`

| API | Decision | Name and permanence |
| --- | --- | --- |
| Constant and `.new(capacity:)` | **Hide the constant and constructor.** Karst owns its one process buffer. Supporting arbitrary user-created buffers needlessly commits the project to construction and receiver semantics. | `Buffer` is a concrete runtime noun and is preferable to `Store`, `Manager`, or `Provider`. |
| `call(event)` | **Keep callable internally; do not promise it publicly.** It exists to satisfy the notification receiver protocol, but exposure through `Karst.buffer` lets callers inject arbitrary objects and violate the implied SQL-event collection invariant. | `call` is correct for a callable receiver but opaque for users. Do not add an alias merely to improve discoverability unless external writes are intentionally supported. |
| `to_a` | **Remain public and document.** This is the useful snapshot/inspection API. | Correct and composable; it clearly communicates allocation of an array snapshot. |
| `clear` | **Make an explicit pre-1.0 decision.** It is useful for process-level control/tests, but it is a global destructive operation. If retained, document it and freeze its atomic clear semantics. Otherwise hide it now. | Correct name. |
| `size` | **Remain public.** | Correct and unsurprising. |

### `Karst::Subscription`

| API | Decision | Name and permanence |
| --- | --- | --- |
| Constant, `.new(receiver:)`, `EVENT_NAME` | **Hide all of them.** This is a well-focused internal object, not a user extension point. Public receiver injection creates an accidental plugin API, including the undocumented rule that receiver exceptions disappear. `EVENT_NAME` is an implementation choice. | `Subscription` is a precise runtime noun. It should exist, but privately. |
| `subscribe!`, `unsubscribe!`, `subscribed?` | **Keep as the private collaborator's internal protocol.** | All three names are correct. They need synchronization rather than renaming. |
| private `receive` | **Keep private.** | `receive` is adequate at a notification callback boundary. No pattern-oriented rename is warranted. |

### `Karst::Sql` and `Karst::Sql::Event`

| API | Decision | Name and permanence |
| --- | --- | --- |
| `Karst::Sql` | **Remain public only as the event namespace.** | `Sql` is a concrete domain name. Ruby convention would spell the acronym `SQL`, but changing it only improves acronym consistency and imposes churn; keep `Sql` unless the project has a firm acronym convention before release. |
| `Karst::Sql::Event` and generated `Data` API (`.new`, `.members`, readers, equality/deconstruction, and related `Data` behavior) | **Remain public and freeze deliberately.** Users necessarily receive these values from `Karst.buffer`. `Data.define` exposes more than five readers, so the superclass choice and member order can become observable even if only readers are documented. | `Event` is too generic by itself but correct within `Sql`. The five field names are the durable contract; resolve `started_at` before 1.0. |

### Other constants

| API | Decision | Name and permanence |
| --- | --- | --- |
| `Karst::VERSION` | **Remain public and freeze.** | Standard gem API. |
| `Karst::Railtie` | **Keep private.** It is already declared with `private_constant` (`lib/karst/railtie.rb:13`). | `Railtie` is the Rails runtime concept and required superclass convention. |

## Class-by-class internal architecture

### `Karst` singleton facade

It has one broad reason to change: the process-level Karst lifecycle. Owning configuration, buffer, and subscription is coherent at this size. It should not be split into a container or coordinator. The problem is not responsibility count but unsynchronized lazy construction and unclear reconfiguration semantics (`lib/karst.rb:16-43`).

### `Karst::Configuration`

This class should exist. It owns validation and defaults, and avoids scattering settings across module accessors. It is not merely wrapping another object. Its values are mutable shared process state, however, while the buffer snapshots one setting on first access. That creates a temporal coupling between configuration and whichever thread first calls `Karst.buffer` (`lib/karst/configuration.rb:6-17`; `lib/karst.rb:24-25`).

### `Karst::Buffer`

This class should exist separately from the subscription: retention policy changes for different reasons than notification attachment/conversion. It owns its array and mutex and returns a copy, so callers cannot mutate the collection itself (`lib/karst/buffer.rb:9-24`). It does retain the event objects by design; because events own frozen string copies, it does not retain notification payload graphs.

The collection's `Array#shift` moves the remaining references whenever full (`lib/karst/buffer.rb:16-17`). At the default capacity that cost occurs for every SQL event after the first 2,000. Do not replace it speculatively, but benchmark realistic sustained query capture before 1.0; change the representation only if evidence shows material callback overhead.

### `Karst::Subscription`

This class should exist separately from `Karst`: it encapsulates the external notification handle and callback conversion. It is not only wrapping Active Support; it translates an unstable external payload into Karst-owned data. It has one reason to change: SQL notification capture semantics.

It unnecessarily supports a nil receiver that silently discards events (`lib/karst/subscription.rb:8-10`). Production always supplies the buffer. Requiring a receiver would make invalid construction fail immediately and would remove a behavior that only broadens an internal constructor.

### `Karst::Sql::Event`

This value type should exist. Folding it into hashes would weaken ownership and shape without deleting meaningful complexity. No additional base event, factory, builder, or hierarchy is justified.

### `Karst::Railtie`

This class exists because Rails requires the integration point. It has exactly one reason to change: Rails boot integration. It should remain as small and private as it is.

## Immediate changes, ranked

### High — synchronize global construction and subscription lifecycle

`@buffer ||=`, `@subscription ||=`, and `Subscription#subscribe!`/`#unsubscribe!` are check-then-act operations without a common lock (`lib/karst.rb:24-43`; `lib/karst/subscription.rb:14-30`). Two threads can construct different buffers or subscriptions. More seriously, two concurrent `subscribe!` calls can install two Active Support listeners and overwrite one handle; the overwritten listener can no longer be unsubscribed and continues retaining its `Subscription` and receiver. A concurrent unsubscribe can also race with installation or clear a newer state.

This violates advertised idempotence, creates duplicate evidence, and can leak a listener for the process lifetime. Make lazy ownership and lifecycle transitions atomic. Keep locking outside the notification callback so the existing buffer lock remains independent.

### High — do not erase every capture failure without observability

`Subscription#receive` rescues `StandardError` across conversion and the receiver call, returning `nil` for programming defects, allocation failures represented as standard exceptions, and receiver bugs (`lib/karst/subscription.rb:36-48`). Containing errors at an instrumentation boundary is correct—Karst should not break the host query—but total silence makes evidence loss indistinguishable from success and can hide regressions indefinitely.

Narrow the expected malformed-input handling and establish one explicit internal failure policy before this callback grows. This is not a request for analytics or a feature; it is a correctness boundary. Do not make arbitrary receiver behavior public while its failures are swallowed.

### Medium — resolve the clock contract before freezing `Sql::Event`

`monotonic_subscribe` supplies monotonic timestamps, and the callback stores the start value as `started_at` (`lib/karst/subscription.rb:19,36-45`). A monotonic value is useful for duration but is not a timestamp that can be interpreted as wall-clock “at.” Once event readers are consumed, renaming or removing one is breaking.

Before 1.0, either give the member a name that explicitly denotes a monotonic clock value or omit it if no present behavior uses it. Do not attempt to convert it to wall time without a demonstrated need. `duration_ms` is correctly derived and named.

### Medium — make configuration initialization semantics explicit and atomic

`buffer_size` is read only while the global buffer is first constructed; later writes report a new configured value while the live buffer retains its old capacity (`lib/karst.rb:24-25`; `lib/karst/configuration.rb:14-17`). The README discloses this, but the object model permits a misleading half-reconfiguration. Concurrent configuration mutation also has no lifecycle boundary.

Choose and enforce the already-implemented startup-only interpretation: configuration must be complete before owned runtime objects are initialized. Avoid adding dynamic resizing or a reconfiguration subsystem. The simplest architecture is to reject or otherwise prevent misleading late writes rather than pretending all accessors are live controls.

### Medium — shrink accidental constants and constructors

`Configuration`, `Buffer`, and especially `Subscription` are public constants loaded by the entry point (`lib/karst.rb:3-7`). Only the configured object, inspected buffer, and emitted event need to cross the supported boundary. Hide constructors/constants that exist solely for internal composition before external gems subclass them, inject receivers, or instantiate parallel lifecycle owners.

Ruby cannot make methods on the returned buffer inaccessible, so separately decide which returned methods are supported. Hiding a constant is still valuable: it says Karst owns construction and reduces subclassing commitments.

### Low — remove the nil receiver fallback

`receiver: nil` creates an inert proc (`lib/karst/subscription.rb:8-10`) even though the only production construction passes `buffer` (`lib/karst.rb:42-43`). Require the collaborator. This deletes a branch, an allocation per inert subscription, and an invalid state without changing implemented production functionality.

### Low — verify full-buffer cost before changing the representation

The full buffer shifts an array on every appended event (`lib/karst/buffer.rb:14-18`), while `to_a` intentionally allocates a snapshot (`lib/karst/buffer.rb:23-25`). Snapshot allocation is correct ownership. Repeated shifting may become capture-path friction, but replacing it now without measurement would be premature optimization. Treat a benchmark showing meaningful overhead—not anticipated scale—as the threshold for change.

## Ownership, thread safety, reload safety, and memory

### Ownership

- Karst retains one configuration, buffer, and subscription at module scope for the process lifetime (`lib/karst.rb:16-43`). That ownership model is simple, but it needs one initialization boundary.
- `Subscription` retains its receiver, callback method object, and Active Support handle (`lib/karst/subscription.rb:8-11`). Active Support in turn retains the callback while subscribed, forming the intended process-lifetime chain. A lost handle from a race turns that chain into an unremovable leak.
- `Buffer#to_a` returns a shallow snapshot (`lib/karst/buffer.rb:23-25`). This correctly protects collection ownership; event immutability makes a deep copy unnecessary.
- Each event duplicates and freezes `name` and `sql` (`lib/karst/subscription.rb:39-42`). This prevents caller mutation and payload retention. It intentionally allocates up to two strings per captured query; that is justified ownership, not waste.
- `Buffer#call` accepts arbitrary objects (`lib/karst/buffer.rb:14-20`). Because callers receive the live buffer, external writes can destroy the assumption that snapshots contain only `Sql::Event` values. Do not describe that invariant publicly unless external mutation is hidden or validated.

### Thread safety

- Individual buffer operations are correctly serialized by one mutex (`lib/karst/buffer.rb:11,15-18,23-33`). `size` followed by `to_a` is not an atomic compound snapshot, which is normal and should not be promised.
- Module memoization, configuration mutation, and subscription transitions are not thread-safe as lifecycle operations. The GVL does not make multi-step logical transitions atomic and does not solve alternate Ruby implementations.
- The callback reads only the stable receiver reference and writes through the buffer's lock, which is a sound hot-path ownership model once lifecycle installation is fixed.

### Reload safety

Installing once in `after_initialize` avoids registering a new listener on every Rails prepare cycle (`lib/karst/railtie.rb:8-10`). That should remain. The process-global objects also survive application code reloads, which is appropriate because they do not retain reloadable application constants or connection objects. Manual concurrent lifecycle calls remain the reload-related hazard, not Rails class reloading itself.

### Memory and allocations

- The event count is bounded, but retained bytes are not: one SQL string can be arbitrarily large. This is inherent in retaining raw SQL and should be acknowledged as part of the existing buffer contract, not addressed with speculative truncation.
- Clearing the buffer releases its references immediately under the lock (`lib/karst/buffer.rb:27-29`). Snapshots previously returned by callers intentionally continue retaining their events.
- `to_a` allocates an array proportional to current size on every inspection. That is the correct price for a safe snapshot. Avoid adding alternate enumerator/view wrappers until a real consumer demonstrates the need.
- The most serious leak is the orphaned Active Support callback possible during racing subscriptions, not the bounded array.

## Delete or hide code

1. Delete the nil receiver fallback and require `receiver:` for the internal `Subscription` constructor.
2. Remove `subscribe!`, `unsubscribe!`, and `subscribed?` from the supported public contract unless a non-test use is explicitly part of Karst's current behavior.
3. Hide the `Subscription`, `Buffer`, and `Configuration` constants from direct external lookup/instantiation while keeping the instances needed through the facade.
4. Do **not** delete `Buffer`, `Subscription`, `Configuration`, `Sql::Event`, or `Railtie`; each currently owns a distinct runtime concern.
5. Do **not** merge `Buffer` into `Subscription`. Capture lifecycle and retention policy have different change drivers and their present boundary is direct rather than abstract.

## Things to watch after 100, 250, and 500 pull requests

Only compounding risks are included here.

### After 100 PRs

- **Event shape accretion.** Every new `Data` member changes construction, equality, deconstruction, memory per event, and downstream consumers. Require present capture behavior to justify each field; do not turn `Event` into a payload mirror.
- **Configuration/runtime divergence.** New accessors will repeat the `buffer_size` trap if it is unclear whether settings are startup-only or live. Establish that rule before adding settings.
- **Facade growth.** Keep `Karst` limited to supported configuration and observation. Do not add forwarding methods merely because an internal collaborator has a method.

### After 250 PRs

- **Receiver becoming an accidental plugin system.** If `Subscription.new(receiver:)` stays public, consumers will rely on callback ordering, exception swallowing, threading, and event delivery guarantees. Hide it now unless that extension point is intentionally permanent.
- **Global test mutation becoming architecture.** Specs currently reset module instance variables directly (`spec/karst_spec.rb:38-43`). As collaborators grow, this encourages more hidden singleton state and order-sensitive tests. Fix lifecycle ownership rather than adding a general reset API.
- **Multiple event families pressuring inheritance.** Preserve concrete namespaced values and direct capture paths; do not introduce a generic event hierarchy until shared runtime behavior actually exists.

### After 500 PRs

- **Compatibility burden from exposed internals.** Public constants, constructors, `Data` behavior, lifecycle controls, and buffer mutation multiply the matrix of behavior contributors must preserve. The supported surface should be frozen narrowly before third-party integrations form.
- **Instrumentation boundary complexity.** A broad rescue around a larger callback will conceal an increasing number of bugs. Keep conversion small, explicit, and failure-isolated rather than growing a processor pipeline.
- **Process lifecycle ambiguity.** Forking servers, threaded boot, reload hooks, and test suites will amplify any unclear distinction between configured, initialized, subscribed, and enabled. A simple atomic startup lifecycle scales better than adding coordinators later.

## Approval decision

**Do not approve the current architecture as frozen for long-term open-source maintenance yet.** Approve its direction and its class boundaries, but require the two High issues—atomic subscription ownership and an explicit non-destructive failure policy—to be resolved before 1.0. Also settle the `started_at` clock contract and hide accidental construction/lifecycle APIs while change is still cheap.

After those changes, the architecture would be suitable for long-term maintenance without redesign: the right enduring shape is still a small Karst facade, a validated configuration, one notification subscription, one bounded buffer, and one immutable SQL event.
