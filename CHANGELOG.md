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

### Changed

- Marked configuration, buffer, subscription, and the experimental SQL canonicalizer as private implementation constants.
