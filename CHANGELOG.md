# Changelog

All notable changes to Karst are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]

### Added

- Documented and acceptance-tested support for Rails 8 generated authentication.
- Added local selection of the user models Karst should test when a Devise application has multiple mappings.
- Added inline, local approval of discovered candidate populations after an unsuccessful ordinary sample.
- Added `config.population_retry_limit` for bounding approved-population retries.

### Changed

- Candidate-population approval now happens inline in the failed `/karst` result, followed by an immediate retry.
- `/karst/populations` is limited to inspecting and revoking stored approvals, including stale approvals.
- MCP support is opt-in instead of a runtime dependency of the gem.
- The product surface is simplified around route-access verification: an ordinary bounded sample followed, when needed, by a separate bounded search of approved candidate populations.
- `config.enabled` now gates all of Karst's development surfaces.

### Removed

- The `Karst::Spec::*` observer, catalog, and scenario subsystem.
- `Karst::Access::ResourceEvidence` and inferred resource-relationship presentation.
- Candidate-population preview and Ruby-snippet export.
- The `karst:populations` rake task.
- Redundant population-management and discovery UI superseded by inline approval.
- The unused runtime SQL buffer and its public `Karst.buffer` and `Karst.window` analysis surface.
- Unused artifact scenarios and configurable principal dimensions.

## [0.1.0]

### Added

- Initial release of route-access verification through `/karst`, `bin/rails karst:verify`, and the MCP `verify_access` tool.
- Bounded sampling of existing users with observed status, redirects, halted callbacks, exceptions, and database writes.
- Candidate-population discovery, preview, configuration export, and approval through the original population-management workflow and `karst:populations` rake task.
- Browser **Test as** and **Stop testing as** workflows, a page-local badge on Rack 3, and custom-authentication generator scaffolding.
- Automatic single-model Devise support, explicit multi-model/custom-authentication configuration, and access-search rollback isolation.
- The opt-in RSpec observer/catalog/scenario subsystem and inferred resource-relationship evidence.
- Runtime SQL capture through a bounded buffer and `Karst.window` analysis.
- Ruby 2.7+ and Rails 6.1+ compatibility.

### Changed

- Reframed the primary interface around finding an existing user who can reach a selected route.
- Candidate populations became an automatic second search stage after the ordinary sample found no usable user.

[0.2.0]: https://github.com/chdsbd/karst/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/chdsbd/karst/releases/tag/v0.1.0
