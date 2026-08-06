# Active Support notification compatibility

## Decision

Karst Task 2 should use `ActiveSupport::Notifications.monotonic_subscribe("sql.active_record")`. It is available throughout the tested support matrix and supplies monotonic numeric timing values directly. A callback receives exactly five arguments: the event name, monotonic start time, monotonic finish time, transaction ID, and payload.

Keep the returned subscription handle, unsubscribe that handle when stopping, and make stop idempotent. Calling `ActiveSupport::Notifications.unsubscribe(handle)` a second time did not raise in any tested version, but its return value varies and must not be used as a lifecycle signal. Karst must prevent accidental duplicate subscriptions itself: Active Support treats two subscriptions as independent and invokes both.

The production callback must not allow Karst failures to escape. An exception raised by a subscriber is propagated out of `instrument`; other subscribers still ran in this spike, but application instrumentation nevertheless raised. Task 2 should test that its callback catches its own processing errors at the notification boundary, as well as testing single registration and idempotent stop.

## Tested matrix

The executable spike was run on 2026-08-06 against released patch versions:

| Active Support | Ruby | Result |
| --- | --- | --- |
| 7.0.10 | 3.2.3 | pass |
| 7.1.6 | 3.2.3 | pass |
| 7.2.3.2 | 3.3.8 | pass |
| 8.0.5.1 | 3.3.8 | pass |
| 8.1.3.1 | 3.3.8 | pass |

These are Active Support tests, not full Rails-stack tests. That is deliberate: the subscription and synthetic event require only Active Support.

## Exact observations

Every tested version produced the following behavior:

* `monotonic_subscribe` exists.
* Its callback was invoked with five values having classes `String`, `Float`, `Float`, `String`, and `Hash`, respectively.
* The start and finish values were numeric monotonic `Float` values, and finish was not before start.
* A subscriber received the supplied event name (`sql.active_record`) and payload.
* Unsubscribing the returned handle removed the callback: three instrumentations around the unsubscribe operations resulted in only the first callback invocation.
* Unsubscribing the same handle again did not raise.
* Registering the same callback twice resulted in two invocations for one event.
* A callback `RuntimeError` propagated from `ActiveSupport::Notifications.instrument`. A later subscriber was still invoked once before the error reached the instrumenting caller.
* The synthetic `sql.active_record` event worked while `ActiveRecord` was not defined. The event name has no registration dependency on Active Record.

## Differences

There was no material delivery, timing, duplicate-registration, removal, or exception-propagation difference across 7.0, 7.1, 7.2, 8.0, and 8.1.

The unsubscribe return value did differ. In the observed runs, the first unsubscribe returned an `Array` on 7.0, a `Hash` on 7.1 through 8.0, and an `Array` on 8.1; the repeated unsubscribe returned an empty `Array` on 7.0 and `nil` on later versions. These are implementation details. Production code should ignore the return value.

Rails 8.1 therefore introduces no observed change that requires a different architecture. Its changed unsubscribe return shape reinforces the decision not to interpret that value.

## Reproducing the spike

The script activates the version in `AS_VERSION`, emits one JSON report, and exits nonzero if any required behavior differs:

```sh
gem install activesupport -v 7.0.10 --no-document
AS_VERSION=7.0.10 ruby script/notification_compatibility.rb
```

Run that command under each compatible Ruby/version pairing in the table. The JSON includes runtime versions, whether `ActiveRecord` is loaded, callback argument details, counts, unsubscribe outcomes, propagated exception details, and an aggregate `passed` value. Timing numbers naturally vary between runs.

## Implications for Karst Task 2

1. Prefer `monotonic_subscribe` over `subscribe`; no compatibility fallback is needed for the declared floor.
2. Store the opaque handle returned by subscription and pass that handle to `unsubscribe`.
3. Make Karst's start operation single-registration and its stop operation idempotent rather than relying on Active Support to deduplicate or report state.
4. Ignore the return value from `unsubscribe`.
5. Rescue Karst-owned callback failures at the subscriber boundary so instrumentation cannot break application work. Define the reporting strategy separately rather than silently assuming Active Support contains errors.
6. Task 2 tests should assert five callback arguments, numeric ordered timing values, no duplicate callback after repeated start, no callback after stop, repeated-stop safety, and containment of callback processing errors.
7. Synthetic notification tests do not need Active Record merely to instrument the conventional event name; integration tests with real SQL remain a separate concern.

## Remaining unknowns

* This spike does not exercise notifications emitted by a real Active Record adapter or validate the shape of real SQL payloads.
* It does not test concurrency between publish, subscribe, and unsubscribe, re-entrant lifecycle calls, forks, or application reloaders.
* It does not establish a policy for logging, reporting, or retaining errors rescued by Karst's eventual callback.
* It samples the latest patch release in each minor line, not every historical patch release or prerelease.
* It does not test alternative Ruby implementations.
