# Qualification contract spike

## Decision

Karst produces strong behavioral evidence, but does not currently observe the
model decisions needed to derive qualifying application state automatically.
Keep qualification reasoning with a repository-aware agent, state construction
with a separate state engine, and behavioral verification with Karst. Do not
build a Karst-to-Pro state-inference integration from the current observations.

This investigation starts at main `c746180c33d48a77160e94aa5f7e01bebe419028`
on branch `claude/qualification-contract-v1`. The experiment is deliberately
test-only: `spec/support/qualification_contract_spike.rb` projects real request
observations, and `spec/integration/qualification_contract_spike_spec.rb` tests
its boundaries. No public output, runtime hook, MCP tool, dependency, or
production contract was added. The experiment makes no LLM calls, evaluates no
Ruby conditions, and does not load or change Body Double or Pro.

## Evidence audit

Read paths: `mcp/verify_access_tool.rb` -> `CLI::Verification` ->
`Access::Search` -> `Access::Sweep` -> `Access::Probe`; and
`mcp/reproduce_request_tool.rb` -> `Mcp::Reproduction` -> `CLI::Reproduction`
-> `Reproduction::Exercise` -> the same `Access::Probe`.

The authoritative target evidence lives in `Access::Probe::Observation`.
Sweep retains a subset; reproduction also exposes lifecycle and render facts.
The proposed projection uses reproduction observations rather than claiming
that sweep already exposes those extra fields. Identity goes through
`Access::IdentityProbe`, `Identity::Observer`, and `Identity::EvidenceBuilder`.
The configured observation hook or Warden supplies application-resolved
identity; establishing identity alone never proves it.

| Evidence Karst has | Can this support a state predicate? | Certainty and boundary |
| --- | --- | --- |
| Requested principal/model/id | No | Caller intent; not proof that the application used it. |
| Identity establishment succeeded/failed | No | Setup result, separate from actual application identity. |
| Resolved principal/model/id from configured observer or Warden | Only an identity fact | Observed at halt or completion, with source. Does not expose role, tenant, plan, or the conditions for future requests. |
| Identity confirmation | Only agreement of requested and resolved identity | Derived deterministically by existing EvidenceBuilder; includes confirmed, confirmed_anonymous, mismatch, absent, contaminated, unobservable. No probability. |
| Identity changed during request | No state explanation | Comparison of halt/completion observations. The halt observation wins when available; not a history of all transitions. |
| Dispatch controller/action | No | Observed from the target Rack environment, even on a halt. Says where processing began. |
| Router path parameters | Only request binding | Not evidence that a resource belongs to a tenant, exists, or was authorized; not the matched route pattern. |
| HTTP status/redirect | No | Response facts; 200 may render an error page and 302 may be ordinary navigation. Neither proves a policy predicate. |
| Halted callback identifier | Only that this callback halted | Rails notification, not its branch expression, attribute operands, or reason. A name containing `admin` is not a role predicate. |
| Controller completed | No | process_action notification without an exception. Can be true when a before_action halted and the action body never ran. |
| Render virtual path/completion | No | Template attempt/completion, not template contents, feature state, or access conditions. |
| Exception class/phase | No | Observed class; phase is derived from notifications and exception-object/cause matching. Do not infer missing state from error text. |
| Mutating SQL count | No | Target write attempts, not resulting attribute values or qualification. Rollback is not proof of global side-effect containment. |
| Sampler reasons such as `role=admin` | At most a sampled-record fact | PrincipalSampler reads coarse values before the request. Reasons are strings and sampling provenance, not target decision evidence; do not parse them into a qualifying predicate. State may change before or during execution. |
| Approved/named population membership | At most provenance about the sampled source | A relation supplied records; its name is not a model condition or proof it caused the outcome. PopulationDiscovery finds scope declarations, not arbitrary Ruby meaning. |
| Anonymous/member/admin outcome differences | No causal state predicate | Observed counterfactual outcomes for these existing records. Other attributes, associations, cache entries, and external state may differ. |

TargetWindow subscribes only for the target request, guards the executing
thread, and excludes Karst's in-request identity establishment. Halt-time
identity observation is paused out of target instrumentation. Login/logout SQL
does not count as target writes. A raised target cannot inherit the integration
session's earlier login response. These boundaries make verification valuable;
they do not reveal uninstrumented authorization operands. Observer failures are
unknown identity; subscriber failures fail observation rather than assert an
empty successful observation.

## Smallest candidate artifact

The executable projection is an experiment, not a supported API or an addition
to the existing versioned CLI/MCP documents. It contains only target shape,
identity evidence, behavioral facts, an empty qualifying-predicate list, and
explicit unknowns. For a confirmed member request it serializes as:

```json
{
  "schema": "karst.qualification.spike.v1",
  "target": {
    "method": "GET",
    "route_pattern": null,
    "controller": "KarstParityController",
    "action": "member_page"
  },
  "identity": {
    "requested": { "model": "KarstParityPrincipal", "id": 501 },
    "resolved": { "model": "KarstParityPrincipal", "id": 501 },
    "confirmation": "confirmed",
    "confirmed": true,
    "observed_at": "request_completion",
    "source": "configured",
    "changed_during_request": false
  },
  "behavior": {
    "status": 200,
    "controller_completed": true,
    "redirected": false,
    "halted_callback": null,
    "exception_class": null,
    "exception_phase": null,
    "rendered": []
  },
  "predicates": [],
  "unknowns": [
    {
      "question": "What application state qualified this behavior?",
      "reason": "Karst observed the outcome but not the deciding model predicate"
    },
    {
      "question": "What route pattern handled this request?",
      "reason": "The observation contains path parameters, not an observed route pattern"
    }
  ]
}
```

The fixture renders plain text, so there are no ActionView template events.
`route_pattern` is unknown even though an agent can read the fixture's route
declaration. A second route recognition would be a separate inference; the
projection does not pretend it observed that pattern. Concrete paths and
redirect destinations are omitted to avoid exporting path-carried secrets.
`redirected` preserves the presence of the observed redirect destination.

Behavior stays as orthogonal facts, without collapsing halt, redirect, and
render into one outcome enum. There is no `permitted` authorization claim.
Existing `usable_access_outcome` is a configurable interpretation (default:
status 200 with no exception or halted callback), not the application's policy
decision; existing search also checks identity confirmation for usable access.
Successful, identity-confirmed 200 responses are tested without inventing a
permission predicate. A null response after an exception means unobserved,
not a 200 or denial. A missing runtime identity seam adds an identity unknown;
`resolved: null` must always be read with `confirmation`, since anonymous and
unobservable are different states. If the entire identity evidence object is
missing, `identity` itself is null and an explicit unknown explains that both
requested and resolved identity are unknown. This does not imply an anonymous
request and does not discard the available behavioral evidence.

If direct qualification observations ever exist, a predicate would need these
fields (this is a reserved design, **not emitted evidence today**):

| Field | Meaning |
| --- | --- |
| `subject` | Explicit model/entity or application decision subject; never implicitly the requested principal. |
| `path` | Structured field/relationship path, not Ruby, SQL, or a parsed callback name. |
| `operator` | Closed operator vocabulary; start with `eq`, no arbitrary evaluation. |
| `value` | Privacy-reviewed JSON value. A redacted value cannot be used for generation. |
| `basis` | `observed` only when that exact predicate and its decision context were captured. |
| `evidence_ref` | Resolvable reference to the captured subject, operands, result, target phase, and decision event. Not a bare assertion of observation. |

The current observation types contain no such event; consequently the
projection cannot emit even one qualifying predicate. Identity is deliberately
not disguised as a state constraint (`id == 501` is an existing identity, not
a recipe for constructing a suitable new user). There are no fabricated
numeric confidence values. Existing confirmation and exception-phase
derivations keep their existing meanings, separate from predicates. Unknowns
stay unknown rather than `derived` predicates added for richness.

A future generator must reject missing/unresolved evidence references,
redacted operands, unknown qualification, and weaker bases by default. Even
directly observed predicates from one path through a decision do not establish
a necessary or sufficient condition for every request. This spike does not
authorize automatic construction, including the empty conjunction: **an empty
list means no qualification knowledge, not that every state qualifies**.

The fixed insertion order and absence of timing or timestamps make repeated
equivalent observations produce byte-identical JSON. That is semantic
determinism, not a claim that a changing application always responds the same
way or that ids are portable across databases. Model names and ids remain
local identity metadata. Labels, login identifiers, free-text setup/observer
errors, request values, headers, concrete paths, and opaque callback source
locations are withheld. Structural controller/action/template names remain;
this is not an anonymization or unrestricted public export format.

## Real-host experiments

The existing `spec/support/execution_parity_fixture.rb` supplies real Rails
routes, Active Record principals and sessions, signed-cookie login, actual
callbacks, and a role gate. No stubbed request/session or guessed policy
result is used. Fixed test records: `KarstParityPrincipal#501` is the member,
`#502` the admin. These attributes are fixture setup knowledge; they never
enter the qualification artifact. Each named probe signs in through the
fixture's real login request. All targets below use GET and dispatch to
`KarstParityController`.

| Behavior / target / action | Requested principal | Actual principal | Behavioral outcome | Honest qualifying predicates | Unknowns | Body Double representability |
| --- | --- | --- | --- | --- | --- | --- |
| Public `/parity/public`, `public_page` | anonymous | none, confirmed_anonymous | 200, completed | `[]` | Whether all states can access it; route pattern | No qualifying state to map. Anonymous is request identity configuration. |
| Authenticated `/parity/member`, `member_page` | #501 | #501, confirmed | 200, completed | `[]` | Why this principal qualifies; required associations/state; route pattern | No qualifying state to map; existing principal identity alone is not a construction recipe. |
| Role gate `/parity/admin`, `admin_page` | anonymous / #501 / #502 | none / #501 / #502, each confirmed | 401 halted `require_authentication` / 403 halted `authorize_admin` / 200 with no halt | `[]` for all three | Deciding operands, including role equality, despite its presence in source; route pattern | No observed role predicate to translate. Callback and outcome are not representable as exact model state. |
| Redirect `/parity/redirect`, `redirect_page` | #501 | #501, confirmed | 302, redirect observed, completed | `[]` | State needed to trigger redirect or its purpose; route pattern | No qualifying state to map. |
| Exception `/parity/boom`, `boom` | #501 | #501, confirmed | RuntimeError, controller phase, completed=false, status=null | `[]` | State needed to avoid/reproduce exception; route pattern | Exception class is not a construction requirement. |

Additional boundary runs: a no-op assume_identity hook leaves requested #501
absent at the protected route (401, halted); a raising observation hook leaves
identity unobservable even when the real request returns 200. Neither is
allowed to borrow the requested principal as actual identity. A halted
callback still has controller_completed=true, proving why completion is not
action-body success. A synthetic render-event projection test checks retention
of structure; actual template instrumentation is covered by the existing
`target_scoped_evidence_spec.rb`, including template exceptions.

Tenant-scoped resources and feature/subscription decisions are not supplied by
this fixture. `/parity/items/:id` only renders a request id and is explicitly
not treated as resource/tenant evidence. No tenant or feature success is
claimed and no artificial hook was added to make the results look richer.
This is five available test-host behaviors, not a survey of external apps.

## Construction representability report

Read only local documentation in `body_double/docs/agent_contract.md`,
`composed_state_v1.md`, and `state_catalog.md` at
`1045f8c1032908faba854a481b53a4532f8cf4ac`. In particular, the documented
contract exposes catalog field modes including exact values, relationships,
and explicit named construction primitives. Catalog support and runtime
validation still govern whether a request can actually build a model.
This report does not claim compatibility with an uninspected Pro API.

`QualificationConstructionReport` is a test-only report class. It accepts
separately supplied capability lists representing an inspected catalog and
classifies each predicate **assuming its evidence has been validated
externally**. Its positive labels mean only that a proposed predicate matches
a supplied construction capability under that assumption. A truthy or
fabricated `evidence_ref` does not establish that the predicate was observed.
The classifier neither resolves references nor validates their contents, and
its labels do not authorize automatic construction. It neither looks up models
nor reads code nor calls a construction engine. The hypothetical examples below
test its categories;
they are not observations emitted by Karst:

| Predicate/evidence | Classification | Requirement |
| --- | --- | --- |
| Directly observed `User.role eq "admin"` | directly representable | The inspected catalog supports exact `User.role`; mapping would request an exact attribute. |
| Directly observed application state `User.active_membership eq true` with an explicit catalog mapping | requires named construction vocabulary | A reviewed named primitive must promise that state. Do not infer a primitive from its spelling. |
| Pundit returned true, no deciding attributes | not representable | It is a policy result, not an attribute recipe; manually declaring equivalent vocabulary would need separate semantic evidence. |
| Sampler string `role=admin`, derived inference, missing evidence reference, or unsupported field | not representable | No default promotion to observed decision evidence. |
| The actual five experiments' qualifying predicates | zero classification rows | All lists are empty. Nothing can be sent automatically to a constructor. |

The report class checks category eligibility, not evidence-reference integrity
or JSON schema security. Its synthetic reference is a fixture token only.
Production validation and an evidence store are unjustified when the source
provides no decision predicates. Existing-record selection, exact attribute
construction, and verification of authorization are three separate questions.

## Narrow runtime hook options

Qualitative assessment only: no hook was installed or benchmarked. Performance
labels describe expected work, not measured overhead.

| Candidate | Accuracy | Noise | Performance | Framework coupling | Can a read map to the behavioral decision? |
| --- | --- | --- | --- | --- | --- |
| Intercept Active Record attribute/predicate reads | Accurate that a read occurred; poor qualification accuracy | High: rendering, logging, sessions, incidental reads | Work per read; potentially hot path | High: attribute API, enums, custom predicates, cache behavior | No. A read does not reveal comparison operands, Boolean branch use, or causal role. Reject broad monkey-patching. |
| Explicit policy decision notification | Accurate policy subject/action/result when emitted by the app | Low if limited to authorization calls | One bounded event per decision | Medium/high for a Pundit/ActionPolicy adapter; lower for an app-authored event | Captures the decision, usually not deciding model state. Nested policies and external inputs remain unknown. |
| Feature-flag evaluation notification | Accurate evaluated flag/context/result if supplied by provider | Medium: flags also affect presentation | Work per evaluation; payloads must be bounded | Provider-specific | Only with explicit decision linkage; flag reads elsewhere are not proof they qualified access. Evaluation result may be external and not constructible. |
| Existing halted_callback notification | Accurate halt identifier | Low | Already incurred | Rails | Observes the stopping callback, not branch conditions; successful gates emit no symmetric operand evidence. |
| App-authored event at a specific gate carrying operands/result | Best local predicate accuracy when the application correctly emits it | Low with an explicit allowlist | Bounded event/payload per gate | Low framework coupling, substantial application maintenance | Can document a local predicate/decision link; still not global necessity/sufficiency, and sensitive operands need review. |

An optional application-authored decision event is the only plausible narrow
extension for strong operands. It requires applications to describe exactly
what the agent could already read in their policy code, plus an event schema,
target/thread scoping, redaction, and reference storage. A general attribute
tracer would add much more complexity without solving causality. Policy and
flag hooks could improve explanations, but would still mostly produce
decision evidence rather than model construction requirements. There is not
enough benefit here to implement any of them as part of this spike.

## Architecture comparison

A repository-aware Claude/Codex agent can read `authorize_admin` and propose
`role == "admin"`; current Karst cannot discover that expression. The agent
can also inspect tenant scopes, services, subscription comparisons, and
construction vocabulary. Those proposals remain hypotheses: source analysis
can miss runtime identity, callbacks, configuration, data relationships, or
external state. Karst can test the resulting request and show the actual
identity, dispatch, halt, response, render, or exception. That is its stronger
advantage. One verified response proves that attempt, not a universal policy.

Recommended division:

```text
Agent reads code and proposes qualification + target behavior
  -> construction engine resolves explicit supported state
  -> agent supplies resulting existing identity/request to Karst
  -> Karst verifies identity and target behavior
  -> agent revises hypotheses using observed failures and code
```

Existing CLI principal selection and reproduction already provide useful
building blocks. This conclusion does not require expanding MCP or wiring a
new integration. Karst-derived qualification -> automatic construction is not
supported by the evidence. The small artifact is serializable and honest, but
its empty predicate list does not justify maintaining a new production API.
Retain existing behavioral outputs and this reproducible negative experiment.

## Validation

The spike checks anonymous identity, requested-but-absent and unobservable
identity, confirmed identity, successful 200 responses, redirect, callback
halt, controller exception, unknown qualification, absence of fabricated role
predicates, deterministic serialization, privacy exclusions, opaque callbacks,
render structure, and the three conditional representability categories.
Executed with Ruby 3.4.4:

- `bin/test`: RuboCop inspected 161 files without offenses; all 670 unit
  examples passed (seed 13292), using the default Rails 7.0.10 bundle.
- With `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile` and
  `EXPECTED_RAILS_VERSION=8.1`, the shared-process integration suite passed:
  235 examples, zero failures, one expected version-guarded pending example
  (the Rails <= 7.0 view-path registry check; seed 14728). This includes all
  15 spike examples and real template/exception instrumentation checks.
- Under that same Rails 8.1.4 bundle, the isolated golden paths each passed:
  Devise 5 examples (seed 988), multi-Devise 15 (45945), custom authentication
  6 (58566), and Rails-8-style authentication 3 (9648).
- Combined: 934 examples, zero failures, one version-guarded pending example.
  `git diff --cached --check` also passed.

The integration suite uses the same four golden-path file exclusions as CI;
those files must each run in their own process. The initial run using the
default Gemfile without EXPECTED_RAILS_VERSION had five setup failures (two
missing-version-variable assertions and three real multi-Devise subprocesses
without Devise in that bundle). The complete Rails 8.1 bundle and required
environment corrected that run; no product code was changed to make it pass.
The complete cross-version Rails/Ruby and MCP CI matrices were not run.

Review follow-up: added a synthetic `identity: nil` regression and clarified
the classifier's evidence-validity assumption at its definition. Re-ran
`bin/test` (670 examples, zero failures, seed 33202; RuboCop clean) and the
qualification integration file under Rails 8.1.4 (16 examples, zero failures,
seed 50305). The earlier local totals above describe the initial spike run.

QUALIFICATION CONTRACT PARTIAL — USE KARST AS VERIFICATION EVIDENCE, NOT PRIMARY STATE INFERENCE
