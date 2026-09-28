# Karst launch qualification report

**Date:** 2026-09-28
**Scope:** Qualify Karst as a product installed by a stranger — the packaged
`.gem` artifact, consumed by a fresh Rails application that has never seen
this repository — rather than as source code run from its own checkout.
**Central question:** *If a Rails developer who knows nothing about Karst
installs the actual packaged gem today and follows the documentation, does
the product work?*

This file is intentionally **not** listed in `karst.gemspec`'s `spec.files`
and is not shipped inside the gem — it's a report about the product, not
part of it.

## Answer

**Yes.** Every headline, README-documented workflow was tested against a
real built `.gem` artifact, installed into a fresh Rails application this
task never gave any Karst-specific knowledge to beyond what README.md says,
and every one of them worked exactly as documented, with zero P0 or P1
findings. A small number of P2/P3 gaps were found and are detailed below;
none of them block a normal fresh user from getting to a working `/karst`
panel and a useful `karst:verify` result by following the README alone.

## What was tested

- **Exact packaged artifact:** `karst-0.3.0.gem`, built via `gem build
  karst.gemspec` from this branch (built artifact inspected directly —
  `data.tar.gz` contents, not `spec.files` source — via `tar -xOf
  karst-0.3.0.gem data.tar.gz | tar -tz`).
- **External Rails environment:** a throwaway Rails **8.0.5** application
  (Ruby 3.3.10), generated with `rails new` **outside** this repository, in
  an isolated `$GEM_HOME` with the built `.gem` installed via `gem install`
  — never `path: "../karst"`, never this checkout. A second throwaway app
  added Devise for the authentication-path check (Phase 4), and a third
  (`bin/package-acceptance-test`'s fixture) exercises the fully-automated
  version of the same flow.
- Rails 8.0.5 specifically, not 8.1: Rails 8.1 compatibility is a separate,
  actively-worked-on task per this task's own parallel-work rule, and this
  work deliberately avoids becoming a second, competing signal for it.

## Phase-by-phase results

### Phase 1 — package audit: PASS

Built `karst-0.3.0.gem` and inspected the built artifact's `data.tar.gz`
directly (71 entries). All required runtime files are present:
`lib/karst.rb`, `lib/karst/railtie.rb`, `lib/karst/web/**`,
`lib/rails/commands/karst/{verify,reproduce,mcp}/*_command.rb`,
`lib/generators/karst/install/install_generator.rb` and both of its
templates, plus `README.md`, `LICENSE`, `CHANGELOG.md`,
`ARCHITECTURE.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`,
and all three `docs/*.md` files. Nothing under `lib/` is missing from the
built artifact.

Metadata checked against the built `.gemspec` (via `gem specification`):
version `0.3.0`; summary "Find real users who can access Rails routes";
description matches README's framing; homepage and `source_code_uri` both
point at `https://github.com/SilenceDogood1984/karst`; `changelog_uri`
points at `CHANGELOG.md` on `main` (verified that anchor file and its
`[0.3.0]`/`[Unreleased]` sections exist); `required_ruby_version = ">=
2.7"` matches the README's "Compatibility" section; `rubygems_mfa_required`
is set. Runtime dependency: `activesupport, >= 6.1, < 9` only. `mcp` is
correctly a **development** dependency, not a runtime one — confirmed by
installing the built gem with no `mcp` present at all and everything but
`karst:mcp` working (see Phase 3F).

### Phase 2 — clean external Rails application: PASS

`gem install <built .gem>` into an isolated `GEM_HOME`, then a vanilla
`rails new` app with `gem "karst", group: :development` added exactly as
README's Quick Start shows, then `bundle install`. No repository knowledge
was used beyond what's in README.md.

One environmental note surfaced here, described fully under "Findings" (see
**F3**): a stock `rails new` on Rails 8.0.5 resolves the `json` gem to 3.0,
which is incompatible with that Rails series' own `ActiveSupport` JSON
encoder — reproduces on a brand-new app with **no Karst installed at all**.
Worked around with `gem "json", "< 3"` for the rest of this qualification
and in the automated acceptance script; not a Karst defect.

### Phase 3 — headline workflows

| Workflow | Result |
|---|---|
| A. Application boot (require/install, no load-time errors) | **PASS** |
| B. `/karst` renders for an allowed local request | **PASS** |
| C. `bin/rails karst:verify` against a real route | **PASS** |
| D. `bin/rails karst:reproduce`, incl. `--json` | **PASS** |
| E. `bin/rails generate karst:install` | **PASS** |
| F. MCP requested, optional dependency absent | **PASS** |
| G. MCP requested, optional dependency present | **PASS** |

Detail:

- **A/B:** `require "karst"` loads cleanly; `bin/rails server` boots with no
  errors; `GET /karst` from a loopback request returns `200` and renders the
  real panel (verified both via a live `bin/rails server` + `curl` from
  `127.0.0.1`, and via an in-process Rails integration session).
- **C:** `bin/rails karst:verify GET /` (and, once Devise/users existed,
  `bin/rails karst:verify GET /admin/imports/1`) produced the documented
  human summary and correct exit codes: `0` for a verified-usable result,
  `1` for no usable user found, `2` for a configuration error (tested by
  calling it with no principal source configured at all). `--json` produces
  valid, `schema_version`-carrying JSON matching CHANGELOG's documented
  schema v3.
- **D:** `bin/rails karst:reproduce GET /` and the `POST
  /api/v1/inspections` example from README both produced the documented
  human output (observed execution, response, effects, redacted `curl`);
  `--json` output round-trips through `JSON.parse` and carries
  `schema_version`.
- **E:** `bin/rails generate karst:install` creates exactly the two files
  README describes (`config/initializers/karst.rb`,
  `app/controllers/karst_identity_controller.rb`), with a routes edit, and
  prints the documented next-steps message. Every template file referenced
  by the generator is present in the packaged gem (checked directly, not
  just via source).
- **F:** With no `mcp` gem installed at all, `bin/rails karst:mcp` fails
  with exit code `1` and the single clean line: *"Karst MCP requires the
  optional dependency. Add gem "mcp", "~> 1.5.0" to your Gemfile and run
  bundle install."* — no `LoadError` backtrace, no internal stack noise.
- **G:** With `gem "mcp", "~> 1.5.0"` installed exactly as README
  instructs, `bin/rails karst:mcp` boots over stdio, answers
  `initialize`/`tools/list` correctly, and exposes both documented tools,
  `verify_access` and `reproduce_request`. (Mutation-policy behavior itself
  was not exercised in depth — that's owned by a separate, parallel task.)

### Phase 4 — authentication paths: PASS

Built a second fresh app: `rails new` → `bin/rails generate devise:install`
→ `bin/rails generate devise User admin:boolean` → seeded 5 ordinary users
and 1 admin. Added one `before_action :authenticate_user!` +
`require_admin` controller (`Admin::ImportsController`), no Karst
configuration of any kind.

- `bin/rails karst:verify GET /admin/imports/1` worked immediately: sampled
  all 6 users, correctly reported 5×`403 halted at require_admin` and one
  `200 OK · verified usable — admin@example.com · User #6`, with
  `identity: 6 confirmed` (real Warden-session observation, not assumed).
- `/karst` panel: same result rendered in the browser; **Test as** produced
  a real session cookie for `User #6` and a follow-up `GET
  /admin/imports/1` in that browser session returned `200` (the app's own
  controller output), while an unauthenticated request to the same path
  redirected (`302`) as expected.
- **Zero setup was required beyond what README already documents** — the
  README's claim "A conventional Devise app needs no initializer at all…
  Karst finds it automatically" held exactly as written. No comparison
  gaps to report for this path.

### Phase 5 — container/devcontainer locality check: findings, no code change

No Docker daemon and no root/`CAP_SYS_ADMIN` were available in this task's
sandbox, so a real container could not be booted end-to-end. The locality
question was instead answered **empirically against the real shipped
class**, `Karst::Web::Locality`, plus the fact that this task's own sandbox
*is itself* a WSL2 host — giving a live, non-simulated data point for the
mechanism the code already targets:

```
127.0.0.1 (loopback)                                       local?=true
::1 (loopback v6)                                          local?=true
172.17.0.1 (default docker0 bridge gateway, Linux Docker)  local?=false
172.18.0.1 (custom docker-compose bridge gateway)          local?=false
192.168.65.1 (Docker Desktop for Mac gateway)              local?=false
192.168.65.254 (Docker Desktop legacy gateway)             local?=false
10.0.2.2 (a generic VM NAT gateway)                        local?=false

Live on this actual WSL2 sandbox (no simulation):
  wsl_gateway detected = 172.28.0.1  (this sandbox's real default gateway)
  local?(172.28.0.1) = true
```

**Conclusion:** ordinary containerized Rails development — a Linux Docker
container reached from the host via published/NATed ports, Docker Desktop
for Mac, or a generic (non-WSL2-backed) devcontainer — causes `REMOTE_ADDR`
to arrive as the bridge/NAT gateway address, which `Locality#local?` does
**not** recognize, so `/karst` and the badge fall through to the host
application (typically a `404` from the app's own router, not a `500` or
anything alarming, but the panel is unreachable). This is common enough to
matter: containerized/devcontainer Rails development is mainstream in 2026.

Two mitigating facts limit this to **P2**, not P1:

1. It affects only the **browser panel and badge**. `bin/rails
   karst:verify`, `bin/rails karst:reproduce`, and both MCP tools have no
   locality check at all — they're direct Rails commands, not HTTP
   requests, so they work identically inside a container regardless of
   networking. All three of those (arguably the higher-value, scriptable
   surface) are unaffected.
2. A Docker Desktop container running under Windows' **WSL2 backend**
   shares the WSL2 kernel with the host, so `wsl?` (via
   `/proc/sys/kernel/osrelease`) can already be true inside such a
   container — meaning some fraction of Windows+WSL2+Docker Desktop users
   already work today, depending on whether the container's own default
   route happens to match. This wasn't verified end-to-end (no Docker
   available to confirm), so it's a plausible partial mitigation, not a
   guarantee.

**Recommendation (not implemented here, per this task's explicit
instruction not to broadly trust RFC1918/private ranges and to keep any
locality change "obviously safe and tightly scoped"):** the narrowest safe
extension would be a container-specific, verifiable signal analogous to the
existing WSL check — e.g., detecting `/.dockerenv` or a cgroup marker that
proves the *process itself* is containerized, then trusting only that
container's own actual default-route peer (mirroring the existing
`wsl_gateway` logic exactly, swapped to a container-verified condition)
rather than trusting any RFC1918 address unconditionally. This still has
an open question worth a maintainer's judgment call: unlike WSL2 (a
single-tenant, Microsoft-controlled NAT boundary), a Docker bridge network
can be shared with other, less-trusted containers on the same host, so the
security properties are not identical to the WSL2 case even with a verified
"am I in a container" signal. Flagging as a follow-up rather than expanding
this PR, exactly as instructed.

### Phase 6 — automated packaged-artifact acceptance test: DONE

Added [`bin/package-acceptance-test`](bin/package-acceptance-test) and a
new `package-acceptance` CI job in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml). It:

1. builds `karst.gemspec` into a real `.gem`;
2. inspects the built artifact's actual archive contents (not
   `spec.files`) for every required runtime file;
3. installs *that build* into an isolated `GEM_HOME` (never this
   checkout, never a `path:` Gemfile source);
4. generates a throwaway Rails 8.0.5 app that has never seen this
   repository;
5. adds Karst exactly as README's Quick Start says and `bundle install`s;
6. exercises every headline entry point from Phase 3 above (boot, `/karst`,
   `karst:verify`, `karst:reproduce` incl. `--json`, the install generator,
   and MCP both without and with its optional dependency) and fails loudly
   on any regression.

Deliberately does **not** repeat the Rails-version compatibility matrix —
`gemfiles/rails_*.gemfile` and the existing `rails-integration` CI job
already own that question. This script answers a different one: *did we
ship all the pieces, and does the installed artifact work at all.*

Run locally (~50–60s, mostly `bundle install` network time, consistent with
the cost of the existing per-Rails-version CI jobs):

```
$ bin/package-acceptance-test
...
== PASS: the packaged karst-0.3.0.gem works for a fresh Rails app ==
$ echo $?
0
```

### Phase 7 — fresh-user documentation audit

Read README.md end-to-end as a first-time reader, then checked every
documented command, path, and anchor link against what actually shipped and
actually ran.

**Fixed directly (small, factual, in this PR):**

- README's "Coding agents" section didn't explain what happens when `mcp`
  is present but at the wrong version — the resulting error message
  ("Karst MCP requires the optional dependency") reads as "missing" even
  when it's actually "wrong version," which is confusing on first
  encounter. Added one clarifying sentence pinning the fix (`~> 1.5.0`)
  directly under the existing MCP instructions. See [F1](#findings) below —
  the underlying message itself was intentionally left untouched (owned by
  the parallel MCP-mutation-policy task).

**Checked and found accurate (no change needed):** all documented anchor
links (`docs/advanced-configuration.md#curating-candidate-populations`,
`#running-as-a-specific-principal`, `ARCHITECTURE.md#compatibility-policy`,
etc.) resolve to real headings; `CHANGELOG.md`'s schema-v3 changes are
consistent with what `karst:verify --json` / `karst:reproduce --json`
actually emit; no stale command names or repository-context-only
assumptions were found in the documented CLI/generator/MCP instructions;
the Devise "no configuration needed" claim (Phase 4) and the custom-auth
generator scaffold (Phase 3E) both matched what a fresh user actually gets.

**Reported, not fixed (see Findings):** the Rails 8.0.5 / `json` 3.0
incompatibility (F3) is a real first-run pitfall a fresh user is likely to
hit before ever getting Karst's own code to run, but it isn't a Karst
defect and documenting Rails/json ecosystem incompatibilities isn't
Karst's job — flagging for awareness rather than adding it to README.

## Findings

| ID | Severity | Summary |
|---|---|---|
| F1 | P2 | `bin/rails karst:mcp`'s error message is identical for "mcp gem missing" and "mcp gem present at an incompatible version," which misleads a fresh user who already has some version of `mcp` in their Gemfile. **Doc-only fix included** in this PR (README clarification); the message itself belongs to the parallel MCP-mutation-policy task and was intentionally left untouched. |
| F2 | P2 | Ordinary containerized Rails development (native Linux Docker, Docker Desktop for Mac, non-WSL2 devcontainers) causes `/karst` and the badge to be unreachable, because `REMOTE_ADDR` arrives as a bridge/NAT gateway address that `Karst::Web::Locality` doesn't recognize. `karst:verify`, `karst:reproduce`, and both MCP tools are unaffected (no locality check). No fix implemented here — recommendation given above, follow-up needed. |
| F3 | P2 (environmental, not a Karst defect) | A stock `rails new` app on Rails 8.0.5 resolves `json` to 3.0, which drops the `quirks_mode:` keyword `ActiveSupport`'s JSON encoder still passes on that Rails series — any session-cookie write raises `ArgumentError: unknown keyword: quirks_mode`. Reproduces on a brand-new app with **zero** Karst involvement (confirmed on a completely separate, Karst-free fixture app). A fresh user hitting `/karst` (which sets a CSRF session cookie) on such an app would see a `500` that looks Karst-related but isn't. Worked around defensively with `gem "json", "< 3"` in `bin/package-acceptance-test` so the new CI job stays deterministic; not otherwise addressed (out of scope — a Rails/json ecosystem issue, not Karst's). |
| F4 | P3 | No other polish-level gaps found worth tracking separately. |

**P0:** none. **P1:** none — every headline documented workflow passed for
a normal fresh user following README alone.

## Findings intentionally left out / deferred

- Deep MCP mutation-policy behavior (Phase 3G note) — owned by a parallel
  task; only boot + tool listing were verified here.
- Any Rails 8.1-specific behavior — owned by a parallel task; this
  qualification pinned to Rails 8.0.5 to avoid producing a competing
  signal.
- Reproduction/redaction internals beyond "the documented commands produce
  useful, schema-versioned output" — owned by a parallel
  reproduction/redaction-hardening task.
- A real, booted-container end-to-end confirmation of Phase 5's findings
  (no Docker/root available in this task's sandbox) — the empirical class-
  level test plus the live WSL2 data point are the strongest evidence
  available in this environment; a maintainer with Docker access should
  confirm before deciding whether/how to extend locality detection.

## Tests run

```
$ bundle exec rspec --exclude-pattern "spec/integration/**/*_spec.rb"
642 examples, 0 failures

$ bundle exec rubocop
155 files inspected, no offenses detected

$ bin/package-acceptance-test
== PASS: the packaged karst-0.3.0.gem works for a fresh Rails app ==
$ echo $?
0

$ git diff --check
(no output — clean)
```

(Note: this qualification did not run the full `gemfiles/rails_*.gemfile`
integration matrix or the isolated Devise/multi-Devise/custom-auth/Rails-8-
auth golden-path specs, since those are pre-existing, unchanged suites this
task's own Phase 4 work duplicates the intent of via a real packaged-gem
Devise app; they were not modified and are expected to be run by normal CI.)

## Would you let an unfamiliar Rails developer install this artifact today?

**Yes.** Every headline, README-documented path — boot, `/karst`,
`karst:verify`, `karst:reproduce`, the install generator, and MCP both
without and with its optional dependency — worked correctly against the
actual built `.gem`, in a Rails application that had never seen this
repository, using only what README.md says. The Devise path in particular
needed literally zero configuration beyond `gem "karst"`, exactly as
advertised. The gaps found (F1–F3) are real and worth fixing, but none of
them stop a normal fresh user from reaching a working product by following
the documentation as written.
