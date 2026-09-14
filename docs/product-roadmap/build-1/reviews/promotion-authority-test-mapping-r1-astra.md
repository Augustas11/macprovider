# S2 test mapping — independent architecture review R1

Verdict: **coverage closure remains blocked: 0 Critical, 0 High, 3 Medium, 0 Low**. This is a bounded test-shape review, not the combined implementation audit or Build 1 approval. No runtime defect is inferred solely from a missing test. The three Medium findings identify explicit approved acceptance clauses for which the inspected tests do not yet supply the required proof.

Reviewed authority: `promotion-authority-addendum-r3.md`, SHA-256 `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4`; approved HTTP composition addendum SHA-256 `0b4c178cf0ac083d2295d4d05478d89470a50343580679b81284b87bad9bce35`; existing `test-spec-r4.md` SHA-256 `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be`. Base and current HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Source snapshot: 2026-09-10T11:04:50Z, in the explicitly assigned product-build-1 worktree. Others are editing; hashes below delimit the observations. Read-only source inspection; no tests, builds, services, runtime changes or delegation. Only this report was written.

## T08 multiplier decision

**Do not multiply the CAS/store-error cases over all 19 teardown variants. The existing independent proofs compose.** R3 T08 (line 403) requires the real producers, the listed handler paths, and revocation CAS/error behavior; it does not specify a Cartesian product of producer identity and persistence failure.

The actual offer handler calls `refreshArtifactAdmissionStatus` after probe/promotion or replay (`model_admission.go:1423`); retry does so after fresh completion or reservation replay (`model_admission_retry.go:200`); status uses the same helper (`model_admission.go:1513`). The helper (`model_admission_authority.go:185–251`) has no producer discriminator. Once the exact session is unavailable, its two-attempt current-read/revocation path depends on event/store results, not which teardown published closing. The real-producer matrix independently proves that each producer reaches this monotonic state with cleanup withheld, including observation-before-publication ordering.

`TestAdmissionReadbackAfterPromotionRace` supplies 28 leaves across both stores: post-promotion offer/retry with successful revocation or CAS-then-store-error (including replay); original offer replay, retry replay and status with success, a real withdrawal winning CAS, or CAS-then-store-error; and throttled retry. It asserts no invented positive body/event, retained event history under failed revocation, exact retry-reservation bytes and no repeated probe. The broader 59-leaf selection additionally includes 24 T03 CAS-winner and 7 T09 compatibility/reopen leaves. Those 59 are not all fault cases.

`TestAdmissionHTTPTeardownPromotionMatrix` supplies 380 leaves (19 variants × two boundaries × offer/retry × memory's two orders plus SQLite's three orders). `TestAdmissionHTTPTeardownReadbackMatrix` supplies 228 leaves (19 × three replay/status paths × two orders × two stores). Its fresh distinct offers/retries are actual protocol-conflict/error assertions, not new positive-admission successes. `TestAdmissionHTTPTeardownThrottledRetryMatrix` supplies 38 leaves (19 × two stores). The latter asserts that throttling reaches no admission read, observation, decision, guarded append or retry reservation. The actual limiter precedes all those operations; there is no reachable throttle observation-first or revocation-store-error branch to manufacture.

Thus the complete integration-owned selection is **705 = 380 + 228 + 38 + 59**, preserving its compositional boundary. The integration owner reports the 667 selection passed under race in 230.274s and the separate 38 throttle leaves passed under race in 12.414s. These are reported runs, not a fresh 705-leaf run by this reviewer. No further producer/fault Cartesian expansion is required to close this question. Later paid-route refusal remains dependent on completing T11 below.

## PROMO-TEST-M1 — T11 route-specific requirements are only partly exercised

**Severity:** Medium.

**Evidence:** R3 lines 471–532 explicitly require both admission stores, fresh independent consumers, actual default and pinned selection, exact binding outcomes, revocation-only fault injection, replacement re-admission/stale-CAS isolation and closing while downstream work is blocked.

Current `buyer/model_admission_transport_authority_test.go:28–56` unconditionally creates a memory admission store and seeds positive decisions with the real buyer preparer. Lines 147–210 run five scenarios through seven fresh entry points with real WS handshake/read/close wiring. These are valuable improvements over a mocked availability callback. However:

- The private consumer matrix has no SQLite admission variant. The separate real-service SQLite HTTP test does not execute those private entry points.
- `model_admission_route_export_test.go:16–61` lacks direct `ResolveModelAdmissionAuthority` and direct found-but-ineligible `byomRouteSnapshotBinding` assertions. Its “direct binding” case tests only require-binding's error. Its “pinned” case calls `validatePinnedProviderForRequest`; it does not drive the actual `selectProvider` pinned branch required by the plan.
- `retainedPositiveAdmissionStore.AppendModelAdmissionDecision` (lines 22–26) rejects every decision, not only revoked decisions. All negative route fixtures use it; normal successful revocation plus subsequent fresh readback is not checked at each private binding/selection boundary.
- The closing case directly invokes `CloseModelAdmissionTransport` (line 166). Real `closeSession` and scheduled operator/trust closure are proven in other transport tests, and scheduled blacklist plus first HTTP selection is proven by `TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation`; the missing T11 package-local composition still must establish those route preconditions with held timers/cleanup and unchanged ready exact-session authority. The separately approved public HTTP 530/302 → real WS closing composition is valid and must not be replaced with an impossible artifact-positive HTTP-forwarding request.
- Replacement reconnects and checks old/new availability, but does not retain/fire the old timer around replacement admission, establish a valid new positive event restoring route eligibility, or attempt delayed old teardown/revocation against that new event. `TestClosingDuplicateAndOldSessionIsolation` checks transport availability only; it cannot prove event/CAS isolation.
- `TestAdmissionTransportObservationRetainsNoPins` checks the callback while session/publication mutexes are held, but never blocks real downstream route persistence/dispatch and starts actual closing there. It also does not itself cover the complete exact-tuple table or the pinned promotion/readback normal-getter regression required by T11. T07's pending registry writer supplies useful shared lock-order evidence, not the missing downstream routing interleaving.

**Consequence:** The reported 35 fresh route fixtures cannot be mapped to all explicit T11 acceptance clauses. A route-branch, SQLite revocation, replacement-event or retained-lock regression could remain undetected despite that matrix passing.

**Required bounded correction / suggested owner:** Promotion owner; own the buyer route test and test bridge plus narrowly needed WS test-only bridges. Extend the existing fixture, rather than multiply unrelated owner/producer matrices:

1. Parameterize the private entry-point fixture over memory/SQLite. Add direct resolver and found/ineligible binding assertions, and drive actual `selectProvider` default and pinned paths; retain queued recheck and require-binding coverage. Each tested first consumer gets an independent positive fixture. Verify unexpired original leases, exact stored session, nonnil registry connection, ready state and unchanged captured authority immediately before it.
2. Use a wrapper rejecting **only** revocation decisions and delegating every other method. Cover ordinary revocation and revocation failure for binding and actual paid selection in both stores; inspect the attempted CAS, latest history and subsequent fresh readback. Existing first real HTTP normal/fault cases can remain the HTTP evidence, without rebuilding that service matrix for every private consumer.
3. Add the required held real `closeSession` and scheduled operator/trust route compositions and readiness revival, using representative binding/actual-selection entry points with the specified stores. Reuse the independently approved buyer-failure composition. The plan does not require every T11 auxiliary case × every T10 producer × every fault.
4. Add one explicit exact-callback table (empty/wrong provider, empty/wrong assigned ID, absent map, terminal closed, closing, valid). Add replacement-event/old-map/old-timer/stale-CAS cases in both stores: old evidence refuses the new session, a separately valid replacement event restores real selection, and delayed old work cannot revoke or close it.
5. Add the actual route downstream-blocking interleaving: return from availability observation, block route persistence or dispatch, start actual closing, and require publication before releasing the downstream barrier. Retain/identify a pinned promotion/readback test with a pending registry writer proving the normal locking getter is not recursively invoked. Preserve the existing genuine legacy and no-drift selection/snapshot controls.

## PROMO-TEST-M2 — Real handshake failure and transport regression clauses are not fully mapped

**Severity:** Medium.

**Evidence:** R3 lines 100–104 explicitly add both real v1/v2 post-registration acknowledgment enqueue-failure paths, including empty IDs returned to `handleConn`. The producer called `registeredDeferredClose` (`ws/model_admission_transport_test.go:151–154`) manually inserts into `registeredSessions` and calls `closeConnection`. It proves the helper after manual capture, not either actual registration/ack failure path or preservation of capture when the handshake returns empty IDs.

R3 lines 450–464 additionally require exact graceful-frame compatibility, overlapping real graceful/writer/timeout/terminal teardown, one terminal cleanup/event, and refused-registration/pre-auth isolation of an incumbent. `TestClosingPreservesGracefulCloseFrame` decodes one frame and then permits hard close, but does not count exactly one Close against serialized pending frames. `TestClosingFullQueueFallbackAndOverlaps` repeats `closeSession`, `closeTransport` and `close` in 16 goroutines; it does not overlap the real writer-failure and timeout producers or count terminal cleanup/events. `TestClosingDuplicateAndOldSessionIsolation` replaces a session, but does not attempt a refused registration/pre-auth close against a still-valid incumbent. The 19-producer matrix does not silently supply those omitted regression interleavings.

**Consequence:** The capture bug that originally required special empty-ID handling, accidental incumbent invalidation and cross-producer shutdown/frame regressions are not locked by the claimed full T10 evidence.

**Required bounded correction / suggested owner:** Authority owner for actual v1/v2 handshake failure/capture and refused-registration/pre-auth incumbent isolation; promotion owner for the remaining targeted graceful/overlap assertions. Drive real handshake registration and fail the actual acknowledgment enqueue, observe empty identity return and closing publication before deferred socket close, hold eventual cleanup and assert no live authority. Reuse the tested close helper's store/guard matrix; do not add an unjustified 19-producer Cartesian expansion for a registration path that cannot have a completed ordinary admission before acknowledgment. Add a bounded real writer-failure/probe-timeout/grace/terminal overlap with terminal outcome counts, and a deterministic frame-sequence assertion including exactly one normal Close and serialized pending frames. If an existing regression already asserts a clause, map its exact test and fresh race result rather than duplicate it. Existing successful probe tests can establish that timer creation alone is non-invalidating.

## PROMO-TEST-M3 — T06 fault cleanup and owner-first contention proof is incomplete

**Severity:** Medium.

**Evidence:** R3 line 401 requires each owner write lock before a guard attempt; separate SQLite connection and write-transaction waits; insert/COMMIT failure, uncertainty, cancellation and panic; all pins released and successful subsequent work.

Current `TestPromotionGuardContentionAndCancellation` (`ws/model_admission_guard_test.go:267`) holds only the session writer, cancels before acquisition, and injects a failing subordinate guard. Pool, Tier2 and billing tests independently cover their owner contention; buyer setter tests exercise pending-owner refusal. There is no corresponding lock-first test of WS `modelAdmissionAuthorityMu` and `sessionPublicationMu` through the actual composed guard. The callback-read test holding `sessionPublicationMu` exercises a different API.

`TestPromotionSQLitePostInsertBoundary` tests post-insert rollback/panic/expiry and checks the session pin. The real deferred-FK COMMIT failure test verifies subsequent promotion. Connection/write waits are separately covered. Neither a real INSERT rejection nor the complete acquired owner chain's release after each injected fault is demonstrated by the current no-op-subguard WS fixture. The uncertain-commit test checks latest state, but its “exactly one durable positive” assertion does not inspect complete history or repeat reconciliation to prove the stated once-only outcome.

**Consequence:** Explicit partial-acquisition and post-acquisition cleanup paths can leak a source lock or reserve event identity without the current tests detecting it; latest-state equality alone can conceal duplicate durable history.

**Required bounded correction / suggested owner:** Promotion owner, coordinating any test-only owner-lock access with authority/root billing owners. Add table-driven guard attempts with the two missing WS owner write locks held; assert bounded rejection, no event/replay reservation and successful reacquisition. Add actual SQLite INSERT failure (distinct from post-insert rollback and deferred COMMIT failure). For cancellation after acquisition, panic, insert/commit failure and ambiguous completion, use a complete real owner pin or composed release witnesses and demonstrate all owners can mutate/reacquire and subsequent promotion succeeds where appropriate. Extend existing uncertainty leaves with complete event/CAS/replay history and repeated reconciliation proving one durable known commit and no positive unknown claim. These are fault/lock-owner cases, **not** fault × every mutable value × every teardown producer.

## Whole T01–T11 disposition and minimum closure checklist

| Requirement | Mapping / disposition |
|---|---|
| T01–T02 | The signed 24-owner HTTP matrix supplies 480 leaves with both positive boundaries, offer/retry and both stores; it checks histories/CAS/replay, authentic owner publication and later buyer refusal. The transport matrix supplies the distinct real teardown axes. No extra signed-feed × teardown multiplier is required: R3 lines 389–392 require real signed loaders for signed feed/config cases, not a signed loader in every transport-only fixture. T10 exceptions and T11 route gaps remain explicit above. |
| T03 | Existing 24 leaves cover three real event winners, both boundaries/entries/stores. Positive replay after newer withdrawal is also in T09. No additional multiplier identified. |
| T04 | Owned-input tests plus real setter/pool/Tier2 tests and signed owner matrix compose; preserve exact signed integer-rate/no-default controls. No new test shape identified. |
| T05 | Four real signed feed/reference source tests establish the true minimum deadline and exact-boundary refusal; store/probe tests independently exercise insertion/readback/DB wait and original probe preservation. This is a valid source-to-shared-deadline proof, not a need to repeat every store interleaving for every source. Keep honest distinction between frozen-clock just-before store append and ample-budget full promotion. |
| T06 | Close M3 with bounded owner/fault tests and actual full-pin release evidence. |
| T07 | Both stores × four fresh rounds exercise ten simultaneous real writers, buyer-serving callback, 32 ordinary reads, 16 contended pins, eight actual promotion attempts and four buyer denials per round. Report actual held duration separately from DB wait and repeated-attempt bounds. No additional blanket stress multiplier identified. |
| T08 | Existing independent 59 plus 380/228/38 producer proofs suffice as described; no producer × revocation fault expansion. Preserve their separate measured counts. T11 supplies later paid-route proof. |
| T09 | Seven compatibility/reopen leaves plus the separate real-service captured-rate settlement/restart journey cover the required shape. Genuine legacy interpretation remains separate from missing artifact callback. |
| T10 | Keep frozen 705 integration-owned selection; add/map M2's registration and targeted transport regression clauses. Approved HTTP failure composition remains valid. |
| T11 | Close M1 through targeted route fixture expansion and replacement/lock tests, not a replay of the 480/705 suites with every new dimension. |

After these additions, obtain fresh targeted race counts/results for the changed test files, update the implementation reports to their final counts and precise coverage boundaries, and retain the required broad coordinator/gateway/integration/vet/lint/spec checks and cumulative independent audits. `implementation-S2.md` still describes some 18-producer/360/216 additions as pending; it must not label those stale counts or 35 memory-only consumers as full T10/T11 closure. Reported signed-owner 480 PASS (283.514s), eight T07 leaves, four signed-source leaves and eight probe-expiry leaves are useful evidence, not this review's reruns or a final combined gate.

No additional literal axes were identified in this bounded review beyond M1–M3 and the required final evidence/report refresh. This statement does not waive failures discovered by implementation or final combined review.

## Snapshot manifest

Paths below are relative to the assigned worktree. Source lines refer to this snapshot and may shift during authorized follow-up.

| Path | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/implementation-S2.md` | `49955e7ee24cd71d1644e46c1b26d8a06ff78d1f0c2aee0c132282570f1d7b0d` |
| `docs/product-roadmap/build-1/implementation-integration.md` | `5c38b861ddda7704f0aea656ec12a0881dcd2e9542801f2e6204382fdfc87087` |
| `phase4-coordinator/internal/ws/model_admission_http_teardown_matrix_test.go` | `763cece79046d03cb1451b7967d267adbb66860808366143b3fa0ad0e85284b9` |
| `phase4-coordinator/internal/ws/model_admission_readback_race_test.go` | `3c4d2ad00747c15a1b63a1a3b5890e82f020941d7c476bec32a1de99ccc1a68b` |
| `phase4-coordinator/internal/ws/model_admission_transport_test.go` | `63aeb7be1a4da4a3c1f90b7f4c303f93507c3dd646c7320bf306f8e26bafc567` |
| `phase4-coordinator/internal/ws/model_admission_guard_test.go` | `b3951d92df7bc56be0a88dc9733b93f379745d170eff741ed0b4e791b5171f50` |
| `phase4-coordinator/internal/ws/model_admission_commit_boundary_test.go` | `f648ee82d76069370ab50753037ee95e83a31969ec24bb546561c36d578429fd` |
| `phase4-coordinator/internal/ws/model_admission_sqlite_wait_test.go` | `dfc06d87b7eb309d4e72e5e4561b752b28f0634baf73bc6ef1b78fef84f2d913` |
| `phase4-coordinator/internal/ws/model_admission_probe_expiry_test.go` | `38c288bcfb06061b4a86e3945dd66b91d3a4ca5cc4f52d0aa2774967d82d05d0` |
| `phase4-coordinator/internal/ws/model_admission_buyer_owner_matrix_test.go` | `106cc5f1e8d32ca34f2934acbdd191449af40c0c3a6bf9859d310cd6494fd4b0` |
| `phase4-coordinator/internal/ws/model_admission_authority_matrix_export_test.go` | `e128d44e4d1b022a403d99fbac9c85e19f34004de7925f7065ebec648c72b8d0` |
| `phase4-coordinator/internal/ws/model_admission_ws_owner_matrix_test.go` | `808151318cb7b49558138f78b0953c9755a9c62615401a8868f95b79a230831a` |
| `phase4-coordinator/internal/ws/model_admission_owner_stress_test.go` | `233f8018672a3e654d3d07babf4fd68d06622d7a759a06d5c7bb1f482d851ffb` |
| `phase4-coordinator/internal/ws/model_admission_buyer_failure_test.go` | `fb11c8b93edebc50e84bf2f56307ef11110480bc3b16c4f101d31f4352063de6` |
| `phase4-coordinator/internal/ws/model_admission_authority.go` | `4a9fd8ff1f2dfc5bc2ce20305d3138b179dda68cfc6d61eca8939455110c85d1` |
| `phase4-coordinator/internal/ws/model_admission.go` | `29ccde75f132363c31f0a306bf5dcf7ca4cf56b2f0302a92fb4706633d48363b` |
| `phase4-coordinator/internal/ws/model_admission_retry.go` | `7a50600bab47602180b09eb99a6e4158cc7d4b7c042bca5187477d42f3c8a229` |
| `phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go` | `e609ee0e8352726b6e77c936971807539f91a670ca206942d65afa5559ac8b85` |
| `phase4-coordinator/internal/buyer/model_admission_route_export_test.go` | `35a2663b1112afb58eb53bff6131baaa6597193f8d782a2b5564366b46f73d53` |
| `phase4-coordinator/internal/buyer/model_admission_expiry_sources_test.go` | `2eecc9c6471226a1ced5ed93db2515d77db3699ce198fcbc26400c76bb4c2731` |
| `phase4-coordinator/internal/buyer/model_admission_guard_additional_test.go` | `135b0038e30f093d6aac9dbd798eb9fef54488017dd982e0b18219fcc5c9d7b3` |
| `test/integration/build1_closing_route_test.go` | `873bb97c04c3a7243ab55c54e037c2188a99c0966d325ddf1e8ab1bcc46c3fd0` |
