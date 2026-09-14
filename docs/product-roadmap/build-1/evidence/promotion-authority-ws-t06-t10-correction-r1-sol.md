# Promotion authority WS T06/T10 correction evidence (r1)

Date: 2026-09-10

This is bounded test evidence for the M2/M3 corrections in
`reviews/promotion-authority-test-mapping-r1-sol.md` (SHA-256
`0590b696122d801a198c6db7c942805af449e6919d3d955bb9351035cb73d49e`).
The approved authority is `promotion-authority-addendum-r3.md` (SHA-256
`6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4`).
This lane changed test code only; it did not change production runtime.

## M2 transport correction

- `TestPostRegistrationAcknowledgmentEnqueueFailureCapturesClosingSession`
  drives the real v1 and v2 registration handlers. The actual post-registration
  acknowledgment enqueue is forced to fail after the session is captured. Both
  handlers return empty provider/session IDs, while deferred `closeConnection`
  publishes closing before raw socket close and before eventual map cleanup.
- `TestRefusedRegistrationAndPreauthCloseDoNotInvalidateIncumbent` proves a
  refused duplicate and a pre-auth raw close do not invalidate the exact live
  incumbent.
- `TestClosingPreservesPendingFramesAndExactlyOneGracefulClose` holds a real
  in-flight frame, leaves another frame pending, and observes both text frames
  followed by exactly one normal Close frame.
- `TestClosingRealGracefulProbeTimeoutWriterFailureOverlap` composes the real
  writer, `writeProbe` timeout, graceful `closeSession`, writer-failure handler,
  terminal cleanup, and close-event accounting. It observes one normal close
  event and one scheduled graceful fallback.

## M3 guarded-store correction

- `TestPromotionGuardWSAuthoritySourceLockFirst` separately holds the WS
  authority-installation and session-publication write locks before the real
  composed guard attempt, over memory and SQLite stores. Each attempt fails
  promptly without event or replay mutation, then the owner mutates and a later
  promotion succeeds.
- `TestPromotionCommitFailureAndReconciliation/real-INSERT-rejection` uses an
  actual SQLite `BEFORE INSERT ... RAISE(ABORT)` trigger. It is distinct from
  post-insert rollback and the deferred foreign-key COMMIT failure. No positive
  event or replay reservation is created, every owner witness releases, and a
  later promotion succeeds after removing the trigger.
- Post-insert rollback, panic, cancellation after acquisition, COMMIT failure,
  and ambiguous completion have explicit witnesses for signed-feed,
  buyer-billing, settlement-config, Tier2 publication, and Tier2 catalog state,
  in addition to the real WS authority/publication/session/pool pins.
- Known ambiguous completion checks complete four-event history, CAS and replay
  identity, two reconciliations, and idempotent replay without a duplicate.
  Unavailable reconciliation repeats twice and never returns a positive claim.
- `TestPromotionSQLiteWriteLockWaitHoldsNoAuthorityPins` remains the separate
  real external `BEGIN IMMEDIATE` wait proof; its content hash is unchanged.

## Bounded T11 WS composition supplied with this lane

- `TestAdmissionTransportRealProducersInvalidateBuyerSelection` exercises one
  real `closeSession` producer through default buyer selection and one held
  scheduled trust closure through exact pinned selection with a ready revival.
- `TestAdmissionTransportCallbackStateTable` covers valid exact, empty/wrong
  provider ID, empty/wrong assigned ID, absent session map, closing, and
  terminal-closed callback states.
- `TestAdmissionTransportOldTimerCannotDisplaceReadmittedReplacement` uses
  SQLite durability. The same candidate is revoked by a real buyer readback,
  re-offered with refreshed discovery/evaluation identity, promoted for a real
  replacement session, checked for exact old-event replay and distinct stale
  expected-event CAS rejection, then subjected to the captured old timer.
  Actual default and pinned buyer selection both reach the replacement.

## Fresh verification

Final targeted race command:

```text
go test -race ./internal/ws -run 'Test(PromotionGuardWSAuthoritySourceLockFirst|PromotionSQLitePostInsertBoundary|PromotionCommitFailureAndReconciliation|PromotionSQLiteWriteLockWaitHoldsNoAuthorityPins|PostRegistrationAcknowledgmentEnqueueFailureCapturesClosingSession|RefusedRegistrationAndPreauthCloseDoNotInvalidateIncumbent|ClosingPreservesPendingFramesAndExactlyOneGracefulClose|ClosingRealGracefulProbeTimeoutWriterFailureOverlap|AdmissionTransportRealProducersInvalidateBuyerSelection|AdmissionTransportCallbackStateTable|AdmissionTransportOldTimerCannotDisplaceReadmittedReplacement)$' -count=1 -timeout=180s
```

Result: PASS, 11 top-level tests / 28 terminal leaves, package time 7.661s,
zero failures, skips, or race reports.

An earlier combined race run found an unsynchronized callback assignment in the
new acknowledgment-failure fixture. It was corrected by installing the callback
before starting the handler and publishing the captured session through an
atomic pointer. The isolated acknowledgment race test then passed in 1.939s,
and the verbose combined rerun passed in 6.175s before the final 7.661s run.
The failed run is not represented as passing evidence.

The preserved failing invocation was the final command above with `-v` added.
It exited 1 after 4.482s: the race detector reported the v1 leaf reading
`admissionCloseConn.onClose` from deferred `closeConnection` concurrently with
the test assigning that callback after registration capture. The v2 leaf and
every other selected top-level test passed in that run. This was a test-fixture
race; the preinstalled callback and atomic captured-session handoff removed it.

`gofmt -d` produced no output for the six owned WS test files. Tracked and
untracked `git diff --check` scans produced no whitespace diagnostics.
`go vet ./internal/ws` also passed with no diagnostics.

## Test file snapshot

| File | SHA-256 |
| --- | --- |
| `model_admission_transport_test.go` | `d83c5304d56af948e4987acfa7a89b7447d4ea66d2af55a13d6951972eb33b7c` |
| `model_admission_guard_test.go` | `f33acd54086464f4d0c2deafd5396c26009268694cfc9045332fb8cc4dbe3713` |
| `model_admission_commit_boundary_test.go` | `5466bceb51449e9ba729b22f9b2089c4517044ca378b2ad144945bf39cf4213b` |
| `model_admission_sqlite_wait_test.go` | `dfc06d87b7eb309d4e72e5e4561b752b28f0634baf73bc6ef1b78fef84f2d913` |
| `model_admission_transport_export_test.go` | `5c637afe26c77fdd0269371e8f993e9374e7ac61c36d8bc21841ad13f22a9658` |
| `model_admission_transport_buyer_composition_test.go` | `5ffd9ce76328bfc7ce8240d6086479d0f73850480378ef635d829b5634abbbf4` |

The parent lane still owns the broad coordinator gate and required combined
code, security, and architecture audits.
