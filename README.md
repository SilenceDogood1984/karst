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

In Rails development, Karst also serves this same capture state and Window snapshot at `GET /karst` through a small Rack middleware — no engine, route, or controller. Access is limited to true loopback peers and, under WSL, the single host-side default gateway used by a Windows browser; forwarding headers and private address ranges are not trusted. Nonlocal requests fall through to the host application. The page is standalone, not attached to any other page in the host application: Karst's evidence today is process-local, not request-scoped, so the page makes no claim about any particular request, controller, action, route, or user.

## Configuration

Configure Karst in a Rails initializer:

```ruby
Karst.configure do |config|
  config.enabled = true
  config.buffer_size = 2_000
end
```

Karst is enabled by default in Rails development and test environments and disabled in other Rails environments. It defaults to disabled outside Rails.

When enabled, Karst subscribes automatically after the Rails application initializes. `Karst.subscribe!` and `Karst.unsubscribe!` provide idempotent manual control, primarily for tests. `Karst.subscribed?` reports whether Karst currently owns a subscription.

`buffer_size` must be a positive Integer and defaults to 2,000. It is read when `Karst.buffer` is first created; changing configuration afterward does not resize or replace that process-level buffer.

## Roadmap

Development will proceed from small evidence-capture primitives to traceable analysis and, only where the evidence supports it, recommendations. Concrete capabilities will be documented as they are designed and shipped.

## Installation

Add Karst to your bundle and require `karst`. Active Support is its only runtime dependency; requiring Karst does not load Rails or Active Record.

## Contributing

Contributions and design discussion are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the evidence expected in a change.
