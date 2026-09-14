# Reservation maximum-shape r3 implementation evidence

Date: 2026-09-10. Implementation lane; **not measurement-result or independent
audit approval**. Base source snapshot: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Approved contract: `reservation-max-shape-measurement-r3.md`, SHA-256
`2320b84909c1d0eec24e317af2bedf5bc33c3fc81fc87e7c2149a8b0de57dd77`.
Independent GPT-5.6 Sol approval: `reviews/reservation-max-shape-measurement-r3-sol.md`,
SHA-256 `1c06799ac0e2414937fc560170cb009f077b96a48149525179adf57e52ef3267`.

## Owned change

Only
`phase3-binary/Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift`
was changed for the measurement implementation. Its implementation-source
SHA-256 is
`69fa2294b0036e4a35bc7d2ec63eecf89b36fb4fb23e5f46a14c7da8de9a5e21`.
No production runtime, other test, fixture input, record/event/byte shape,
reservation budget, helper budget, clock, byte cap, artificial latency, or
acceptance criterion changed.

The setup ceiling is 1,500 monotonic seconds, started immediately before the
1,024-record construction loop. It is checked before and after every record and
immediately before active-index publication. Each 128-record checkpoint reports
completed records, cumulative and latest-block seconds, block seconds per
record, validated primary bytes, and current filesystem availability. A setup
deadline abort reports those fields and leaves the exact-root deferred cleanup
active.

`InvariantObservation`, `require`, `requireValue`, `validate`, and `abort` are
test-only control-flow helpers. Every guard failure emits exactly one
`RESERVATION_MAX_ABORT` line with scenario, applicable attempt, phase,
invariant, expected value, and actual value; records the useful XCTest failure;
and immediately throws the assigned measurement error. Fixture, state,
counter, and preservation mismatches throw `unexpectedProgress`. The two
unchanged under-eight-second feasibility predicates throw
`perRecordFeasibility`; resource/setup failures retain `insufficientDisk` and
`setupDeadline`. Existing production errors still propagate.

## Decision-boundary mapping

| Boundary before later work | Throwing evidence now required |
| --- | --- |
| Each terminal record publication | Exact 2,048 events and 4,194,304 bytes; intended running/cancelled and terminal state; no committed, cancel-requested, or cleanup-required state; production decode and allocated-origin validation; present primary/origin metadata. |
| First reservation call | Exactly 1,024 distinct sorted active allocated entries; absent baseline maintenance; exact saved 4-MiB queued primary; present selector; maximum decode below eight seconds; present receipt provenance/index receipt; production retirement proof and locked validation; combined capture/proof validation below eight seconds. |
| Each next reservation attempt | The prior call's typed `busy`, elapsed time at least eight seconds, exact six phase-counter predicates, more than 65 honest `bulk_read` callbacks, byte-identical index, identical pinned index metadata, and absent maintenance state pass one complete throwing observation set. |
| Terminal-to-queued write | All 2,048 pinned primary/origin metadata items match; all retired/result/seal/cleanup/success-binding/staging artifacts and recommendations remain absent; final terminal primary and origin digests match the validated pre-call receipt. |
| First queued reservation call | Replacement bytes equal the exact saved 4-MiB primary; updated metadata remains pinned; digest equals saved bytes and allocated initial-primary binding; provenance is allocated; the record has one queued event, unset `startedAt`, unchanged freshness predicate, and no terminal/committed/cancel-requested/cleanup-required state; production locked receipt validation succeeds. |
| Completion | The same full preservation boundary passes after the third queued call, and final queued primary/origin digests equal the validated queued receipt. |

There are no remaining `XCTAssert*`, `XCTUnwrap`, or continuation-form
`XCTFail` calls in the measurement class. The sole `XCTFail` is inside `abort`
and is immediately followed by a throw, so no failed measurement guard can
reach a later reservation call or the queued transition.

## Validation and handoff

The implementation lane ran:

```text
cd phase3-binary
swiftc -frontend -parse Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift
```

It exited 0. Scoped `git diff --check` and searches for remaining nonthrowing
XCTest assertions also passed. This is syntax/source evidence only. Per the
coordinated measurement handoff, this lane did **not** run SwiftPM, create the
4-GiB fixture, make any production reservation call, or claim a starvation
result. The root execution owner retains the sole approved selected-test run,
full-output archival, output SHA-256, exact six-call interpretation, and final
combined audit.
