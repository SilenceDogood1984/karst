# Changelog

All notable changes to Karst will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once releases begin.

## [Unreleased]

### Added

- Initial project documentation, contributor tooling, and continuous integration.
- Configuration and an idempotent, deliberately inert `sql.active_record` subscription lifecycle.
- Automatic subscription after Rails initialization when Karst is enabled.
- Immutable, minimal SQL events constructed internally from valid `sql.active_record` notifications.
- Bounded, thread-safe, process-local retention of recent events through `Karst.buffer`.
- Experimental, conservative SQL canonicalization independent of event capture, preserving structural casts and list cardinality while normalizing supported literals, whitespace, and ordinary comments.
- Internal deterministic query-shape identity: a SHA-256-based fingerprint over canonicalized SQL, with declared `IN (?+)` placeholder-list arity equivalence, feeding an immutable `Karst::Sql::Shape` that aggregates count, cache hits, duration statistics, and up to three sample events (first, slowest, latest) per shape.
- `Karst.window`, Karst's first public analysis API: one immutable `Karst::Sql::Window` snapshot per call, derived from exactly one `Karst.buffer.to_a` read and grouped into `shapes` (deterministically ordered by count, then duration, then fingerprint) and `declined` events, with `event_count`, `capacity`, and `saturated` reporting whether older events may already have been evicted from the retained window.
- `Buffer#capacity`, exposing the fixed capacity of the retained buffer so `Karst.window` can report it.
- `GET /karst`, a development-only HTTP evidence surface served by a small Rack middleware (no engine, route, or controller) that presents `Karst.enabled?`, `Karst.subscribed?`, and basic `Karst.window` counts. Loopback-only, gated by `Rails.env.development?` at both insertion and request time, and transparent to every other request.
- `Karst::Spec::Observer`, an opt-in RSpec integration (`require "karst/spec/observer"`) that turns real spec execution into a deterministic JSON scenario catalog: for every example that reaches a browser-facing (HTML) Rails request, it records the request's method, recovered route pattern, controller/action, format, status, and redirect target (with any query string stripped, since redirect targets can carry the same class of secret as request paths), alongside the Warden principal immediately before and after that request and whether it changed -- raw evidence rather than a "setup versus subject" classification, since a single request offers no reliable signal for telling a signup or checkout-completion route that happens to authenticate apart from a login route. Also records the example's stable id, file/line, nested description, and outcome. Built entirely from `ActiveSupport::Notifications` and Warden's public hooks; never parses spec source, route-helper arguments, or FactoryBot calls, and never persists into the host application's database.

### Changed

- Marked configuration, buffer, subscription, and the experimental SQL canonicalizer as private implementation constants.
