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

### Changed

- Marked configuration, buffer, subscription, and the experimental SQL canonicalizer as private implementation constants.
- Reject changes to `buffer_size` after the process-level buffer has been initialized.
