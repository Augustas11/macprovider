# Reservation maximum-shape measurement r3

Status: corrected measurement-only plan for root review. This revision resolves
RMSM2-M1 from the independent Sol review, SHA-256
`579013a6478652ca0af03908ffbd832587a5b996f04fa14a6f5801497bda1628`.
It supersedes r2 only where r2 limited edits to setup instrumentation and left
decision-critical XCTest assertions nonthrowing. All other r2 requirements are
retained exactly, pinned at SHA-256
`2e8991bb8db13e857b5913d1b0a91c49d4729c9758a298564eedb70c2472671b`.
This is still a plan/test-spec correction, not independent approval of a result
or of the R4 structural fallback.

## Preserved measurement contract

Retain the evidence correction that Swift36 failed only during setup after
602.827 seconds, having reached 512/1,024 records at 550.185567459 seconds. It
ran zero reservation calls, so it supports no starvation conclusion. Retain the
evidence-justified 1,500-second monotonic setup ceiling, the initial 12 GiB free
space requirement, per-128 setup/resource observations, and exact-root cleanup.

Retain exactly 1,024 distinct sorted production-valid primary records of exactly
4,194,304 real bytes each. In `terminal_last`, all 1,024 records have exactly
2,048 valid sequential identity-bound events; the first 1,023 remain unresolved
and the last is the valid cancelled reclaimable record. Every primary passes
production `decodeRetentionRecord`, exact allocated-origin/digest/provenance
validation, descriptor-relative publication, and real active-index membership.
After the terminal scenario, only the final primary may change to its saved exact
4-MiB origin-bound queued bytes; it then has its necessary single queued event,
while the preceding 1,023 records retain 2,048 events.

Retain exactly six intended production reservation calls: three
`terminal_last`, followed by three `queued_last`. Every call uses fresh
operation-local receipts and the unchanged default eight-second budget. No
runtime limit, production code, clock, byte cap, helper budget, artificial
latency, fixture size, event shape, or validity rule changes.

## Narrow test-only authorization

The correction may edit only
`Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift`.
In addition to r2's setup ceiling and checkpoint instrumentation, it is
explicitly authorized to replace every decision-critical nonthrowing
`XCTAssert*`/`XCTFail` continuation with a test-only throwing guard or equivalent
throwing helper. This applies throughout the measurement class, not only setup.
No decision-critical failure may allow a later reservation call or the
terminal-to-queued fixture transition.

Each throwing guard must:

1. Evaluate the production-derived observed value without weakening the
   underlying check.
2. Emit one `RESERVATION_MAX_ABORT` diagnostic naming scenario, attempt when
   applicable, phase, failed invariant, expected value, and actual value.
3. Record the XCTest failure with the same useful assertion message.
4. Immediately throw `perRecordFeasibility` for either under-eight-second
   feasibility failure, or `unexpectedProgress` for fixture, counter, state, or
   preservation mismatch.

An existing thrown production error remains an exact logged error and propagates
immediately. `XCTUnwrap` may remain only when its thrown failure already prevents
all later calls and transitions; decision-critical optional state that needs the
required abort diagnostic must instead pass through the throwing guard. The
test must remain red on every abort. Throwing is control-flow enforcement, not
a mechanism for converting contrary evidence into an expected error or pass.

## Required fail-fast boundaries

Before the first reservation call, throwing checks must establish all fixture
shape and production-validation facts used by the experiment, including exact
per-record byte/event counts, 1,024 active-index entries, absence of baseline
`maintenance.json`, valid last-slot receipt/origin/index/retirement proof, maximum
single-record decode below eight seconds, and combined production capture plus
strict proof validation below eight seconds. Either feasibility check throws
`perRecordFeasibility`; every other mismatch throws `unexpectedProgress`. Zero
reservation calls run after such a failure.

After logging each reservation call and before starting the next call, one
throwing validation must require the complete per-call decision set:

- typed `busy` and elapsed time at least the unchanged eight-second budget;
- exactly one `reservation_scan_started`, zero `reservation_scan_complete`,
  zero `retirement_captured`, zero `retention_cursor_published`, and exactly one
  `index_decode`;
- more than 65 `bulk_read` attempts, retaining r1's honest callback semantics;
- byte-identical active index, identical pinned index metadata, and absent
  `maintenance.json`.

Any mismatch logs the exact call observation, records an XCTest failure, throws
`unexpectedProgress`, and prevents the next attempt. A returned reservation,
completed scan, publication, malformed/unsafe error, early return, wrong counter,
changed index, or new maintenance state remains contrary evidence.

After the third `terminal_last` call, and before writing the queued replacement,
a throwing preservation check must validate every pinned primary and origin
metadata item; absence of every forbidden retired/result/seal/cleanup/
success-binding/staging/recommendations artifact; and the final terminal
primary/origin digests against the pre-call receipt. Any mismatch throws
`unexpectedProgress`. The queued replacement writer is unreachable unless this
entire terminal preservation boundary succeeds.

After writing the queued replacement and before the first `queued_last` call,
throwing checks must establish its exact saved bytes and updated metadata,
origin-bound initial-primary digest, allocated provenance, one queued event,
unset `startedAt`, freshness, and absence of terminal/committed/cancel-requested/
cleanup-required state, followed by production locked receipt validation. Any
mismatch throws `unexpectedProgress` and runs zero queued calls.

After the third `queued_last` call, use the same throwing full preservation
check and require the final primary digest to equal the validated queued receipt.
Any mismatch terminates with `unexpectedProgress`. Cleanup still removes only
the exact test-owned root through the existing deferred teardown on success or
throw.

## Interpretation and verification

The six-call acceptance rule is unchanged. Repeated-prefix starvation is
supported only when all six calls complete as typed `busy` with every required
counter/state check passing and both scenario preservation boundaries intact.
An abort may intentionally produce fewer than six call lines; those earlier
lines are retained as contrary or incomplete evidence and cannot be combined
with a later rerun or relabeled as one coherent successful experiment.

Before execution, review the corrected source and map every current
decision-critical assertion in setup, feasibility, `measureThreeCalls`, queued
transition, `assertPreserved`, and final digest validation to an immediate
throwing path. No nonthrowing assertion may precede later measurement work.
The execution owner then runs only:

```bash
cd phase3-binary
swift test --filter 'ModelCatalogReservationCapacityMeasurementTests/testMaximumShapeNaturalStorageReservationProgress'
```

Acceptance still requires one selected test with zero failures, all eight setup
checkpoints, the exact 1,024-record/4-GiB/2,048-event terminal fixture proof, both
under-eight-second feasibility checks, exactly six valid call lines split three
and three, complete preservation, exact cleanup, and archived output SHA-256.
Any `RESERVATION_MAX_ABORT`, thrown error, missing call, assertion failure,
completed scan/allocation, or preservation mismatch is a non-pass reported
exactly.

This planning lane performs no SwiftPM invocation and modifies neither r2 nor
the measurement test or runtime. Root review of r3 authorizes only the narrow
future test correction described above; it does not approve its result.
