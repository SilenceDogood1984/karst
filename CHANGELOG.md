# Changelog

All notable changes to Karst are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Runtime-confirmed identity: every probe outcome now carries an `identity` evidence object separating the *requested* identity (intent), the *established* one (setup), and the *observed* one (what the Rails application itself resolved while running the request). `identity.confirmation` fails closed — `confirmed`, `confirmed_anonymous`, `absent`, `mismatch`, `contaminated`, or `unobservable` — and only the first two are evidence about identity.
- Anonymous probes as a first-class probe kind: `bin/rails karst:verify --anonymous`, and `verify_access(identity: "anonymous")` over MCP. Karst establishes no identity and then verifies the application really did resolve none; stale state that produces a principal anyway is reported as `contaminated`, never as anonymous. An anonymous probe requires no principal source at all.
- `config.observe_identity`, the observation seam for non-Devise authentication. Devise/Warden applications need no configuration: Karst reads the application's own Warden proxy from the probe request.
- Halt-time identity observation: when an access callback halts a request, Karst records the identity the application had established *at that decision*, plus `identity.observed_at` and `identity.changed_during_request`.
- Each outcome now reports the `controller` and `action` the probed request actually dispatched to, and the evidence document carries `provenance` (Karst/Rails/Ruby versions, environment, observation timestamp).
- **Request reproduction.** Answers "something calls this endpoint -- what
  request do I send to exercise the same behavior?". Karst issues exactly one
  caller-specified request through the real application, inside the same
  rolled-back transaction the access sweep uses, and drives that request's
  identity through the same requested/established/observed/confirmed
  lifecycle `verify_access` uses, reporting what it observed: the
  controller/action that dispatched, the router's own route parameters, the
  halted callback, the response, database writes -- plus a cURL command for
  exactly what it sent. Available at `/karst` under **Reproduce request**, as
  `bin/rails karst:reproduce METHOD PATH`, and as the `reproduce_request` MCP
  tool. Secrets never come back out: parameters pass through the application's
  own `config.filter_parameters` (Rails' own `ActiveSupport::ParameterFilter`)
  plus a conservative credential-name net, and credential-bearing headers
  become placeholders such as `<API_KEY>` without their values ever being read.
  See [docs/request-reproduction.md](docs/request-reproduction.md).
- MCP now exposes two tools. `verify_access` is unchanged and stays GET-only.
- Reproduction evidence now reports `execution.controller_completed` (did the
  Rails controller lifecycle finish without raising -- distinct from whether
  it dispatched at all), `execution.exception_phase` (the most specific phase
  -- `controller`, `render`, or `unknown` -- that instrumentation actually
  proves a raised exception occurred in, derived from
  `ActiveSupport::Notifications` events rather than the exception's class or
  message), and `execution.rendered` (the templates, partials, and layouts
  Karst observed being rendered or raising, by structural virtual path only).

### Fixed

- **Stale cross-request response evidence in reproduction.** If a request run
  on the same session immediately before the target (identity establishment,
  most often) completed, and the target then raised before producing a
  response of its own, Karst could report the *earlier* request's status,
  content type, and redirect as if it had observed them for the target --
  because `ActionDispatch::Integration::Session` only updates its
  request/response objects after the target's own `app.call` returns without
  raising. Response evidence (`status`, `response_content_type`, `redirect`)
  is now read only when Karst can prove it belongs to the target request;
  otherwise it is `nil` and named in `unobserved`, exactly like any other
  fact Karst did not observe. See
  [docs/request-reproduction.md](docs/request-reproduction.md).

### Changed

- Optional MCP support now targets the tested MCP 1.5.x series, replacing the
  stale MCP 0.9.x constraint that conflicted with current integrations and
  failed schema validation with JSON 3.x.
- **Evidence schema is now version 2.** The ambiguous `principal` / `verified_principal` keys are gone rather than renamed in place: a consumer reading "principal" and believing it described the request that actually ran is exactly the false attribution this schema exists to make impossible. Outcomes carry `identities` (each with `requested`, `observed`, `confirmation`), and the top level carries `verified_identity`.
- **Reproduction evidence schema is now version 2.** Its `identity` document reports `requested`/`observed`/`confirmation` (a `Karst::Identity::Evidence`) rather than echoing back the identity Karst assumed as if it were what ran; a mismatch, absence, or unobservable outcome now stays visible instead of being reported as "sent as User X."
- **Reproduction evidence schema is now version 3.** `execution` gained `controller_completed`, `exception_phase`, and `rendered` (additive), but `response.status`/`response_content_type`/`redirect` also stopped trusting `session.request`/`session.response` once a target request raised before producing one -- see Fixed, above. A consumer that read those fields after `execution.exception_class` was already set was reading a value from an earlier request; it now reads `nil`, named in `unobserved`.
- A probe whose identity setup fails now still runs and is still observed, and reports the failure as `identity.establishment` rather than as an application exception — "asked for User #123, application saw nobody, halted at `authorize_admin`" is the evidence that matters most there.
- Per-probe write and halted-callback observation now ignores notifications raised on other threads, so a concurrent request in a development server cannot be counted as a probe's own evidence.

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
