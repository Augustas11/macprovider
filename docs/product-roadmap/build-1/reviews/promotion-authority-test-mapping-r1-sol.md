# S2 promotion-authority admission test mapping — independent Sol review R1

Verdict: **admission coverage closure is blocked: 0 Critical, 0 High, 3 Medium**. This is a test-mapping audit against the approved S2 contract, not a runtime defect finding and not the final combined Build 1 audit. Each Medium finding below identifies an explicit acceptance clause for which the inspected tests do not provide the required proof.

Authority reviewed:

- `promotion-authority-addendum-r3.md`, SHA-256 `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4`
- `implementation-S2.md`, SHA-256 `49955e7ee24cd71d1644e46c1b26d8a06ff78d1f0c2aee0c132282570f1d7b0d`
- `test-spec-r4.md`, SHA-256 `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be`
- approved HTTP composition addendum `s2-http-teardown-test-addendum-r1.md`, SHA-256 `0b4c178cf0ac083d2295d4d05478d89470a50343580679b81284b87bad9bce35`

Base and current HEAD were both `914f7cafcdbcfc1805a10f4f34167218341d5587`. Source snapshot: `2026-09-10T11:23:16Z` in the assigned `product-build-1` worktree. The worktree already contained the Build 1 implementation under review; hashes in the manifest delimit this audit's evidence. I inspected source and tests only. I did not run tests, builds, or services and did not modify runtime or test files. This report is the sole audit artifact added by this review.

## MEDIUM — S2-ADM-M1: T11 does not yet prove all required live consumers, stores, and replacement races

### Evidence

R3 T11 (`promotion-authority-addendum-r3.md:471–530`) requires memory and SQLite stores with real WS callback wiring; fresh independent calls to direct `ResolveModelAdmissionAuthority`, binding and require-binding, actual `selectProvider` default and pinned branches, queued recheck, and HTTP composition; exact found-but-ineligible behavior; revocation-only write failure; replacement re-admission with delayed old teardown/stale CAS; and closing publication while downstream route persistence or dispatch is blocked.

The current package-local matrix is narrower:

- `buyer/model_admission_transport_authority_test.go:29–56` always creates `NewMemoryModelAdmissionStore`. The private consumer matrix therefore supplies no SQLite proof. The separate SQLite HTTP integration test cannot substitute for direct resolver, binding, or selection entry points.
- `buyer/model_admission_route_export_test.go:15–60` maps its “direct binding” path to `requireBYOMRouteSnapshotBinding`, not direct `byomRouteSnapshotBinding`, and has no direct `ResolveModelAdmissionAuthority` path. Its “pinned” path calls `validatePinnedProviderForRequest`; it does not execute the actual header-driven pinned branch of `selectProvider`. The matrix's actual `selectProvider` path uses the default branch.
- `retainedPositiveAdmissionStore.AppendModelAdmissionDecision` at `buyer/model_admission_transport_authority_test.go:23–27` rejects every decision. T11 requires a wrapper that rejects **only revocation writes** and delegates all reads and non-revocation writes. The existing wrapper both over-faults the store and prevents an ordinary successful-revocation control from being mapped at the same private boundary.
- The replacement fixture proves old callback false and replacement callback true, then tests old evidence rejection. It does not establish a separately valid positive event for the replacement, demonstrate actual selection restoration, retain and fire the old timer around that event, or prove an old expected-event CAS cannot revoke the replacement's new event. The transport-only old-session test cannot establish durable event/CAS isolation.
- `TestAdmissionTransportObservationRetainsNoPins` establishes that the availability callback itself is short and lock-free. It does not block real route persistence or dispatch after observation, start actual closing while that downstream work is blocked, and prove closing publication completes before the downstream barrier is released.
- The current callback negatives cover empty IDs and a wrong assigned ID, but T11 calls for one explicit table covering empty/wrong provider ID, empty/wrong assigned ID, absent map, terminal closed, closing, and the valid exact available session.
- The private matrix publishes its closing case through direct `CloseModelAdmissionTransport`. Other suites independently prove real teardown producers, and the integration test composes scheduled blacklist with a real HTTP buyer request, but T11 still requires representative real `closeSession` and scheduled operator/trust route compositions with cleanup/timers held and no earlier revoking read.

The runtime distinction is material. `buyer/model_admission_authority.go:23–33` is the direct current-authority check. `buyer/model_admission.go:112–124` then converts live unavailability to found-but-ineligible and attempts durable revocation. `buyer/route_snapshot.go:77–81` requires that binding before `InsertRouteSnapshot`, creating the exact place where a downstream barrier can prove the availability callback did not retain a promotion/publication pin.

### Consequence

The current passing route fixtures cannot prove the complete T11 claim. A SQLite-only revocation problem, untested resolver or actual pinned-selection branch, replacement stale-CAS bug, or lock retained from observation into route persistence/dispatch could survive while the present memory/default-path matrix passes.

### Required minimum correction

Extend the existing fixtures rather than creating a producer-by-consumer Cartesian suite:

1. Parameterize the package-local private consumer fixture over memory and SQLite. Give each first consumer a fresh positive event. Add direct resolver, direct binding with exact found/ineligible output, require-binding, actual default and actual pinned `selectProvider`, and keep queued recheck. Immediately before each call, assert unexpired source leases, exact stored session, nonnil registry connection, ready/busy eligibility, and unchanged captured authority.
2. Replace the fault wrapper with one that rejects only `State == "revoked"` decisions and delegates every other operation. At binding and actual paid selection boundaries, cover both ordinary revocation and revocation-write failure in both stores; inspect the attempted expected-current-event CAS, complete history/latest event, and a subsequent fresh readback.
3. Add a bounded representative real-producer composition: held real `closeSession` and one scheduled operator/trust producer, with ready-state revival where specified, exercised through binding or actual selection. Reuse the approved buyer-failure HTTP composition. Do not repeat every T10 producer for every private consumer.
4. Add the exact callback table. Add replacement cases in both stores in which old evidence refuses the replacement, a separately valid replacement event restores actual route eligibility, and delayed old timer/revocation work neither closes the new session nor revokes its newer event through stale CAS.
5. Add one real downstream interleaving at route snapshot persistence or dispatch: let observation return, block downstream work, begin actual closing, require closing publication to complete, then release the downstream barrier. Preserve the existing guard-held regression or identify a test that proves pinned promotion/readback never calls the normal locking registry getter.

## MEDIUM — S2-ADM-M2: the required real v1/v2 post-registration acknowledgment failure is manually simulated

### Evidence

The approved special rule (`promotion-authority-addendum-r3.md:100–104`) requires real v1 and v2 post-registration acknowledgment enqueue failures, captured independently even when the handler returns empty provider and assigned IDs. The current `registeredDeferredClose` producer at `ws/model_admission_transport_test.go:151–154` manually stores a constructed session in `registeredSessions` and calls `closeConnection`. That proves the helper's behavior after manual capture; it never executes either real registration path or the acknowledgment enqueue failure that causes empty IDs.

Production has a specific vulnerable sequence:

- `server.go:1956–1998` registers the v1 session, then queues `hello_ack`; enqueue failure returns `("", "")`.
- `server.go:2546–2627` registers the v2 session, then queues `auth_response`; enqueue failure likewise returns empty IDs.
- `server.go:3396–3433` stores the real session in both the provider-session map and `registeredSessions` and starts its writer.
- `server.go:1566–1582` defers raw connection closure and only schedules ordinary `handleDisconnect` cleanup when the returned IDs are nonempty.
- `model_admission_transport.go:75–82` is the compensating path: deferred `closeConnection` must load the registered session and publish `beginClosing` before socket close despite empty returned IDs.

The broader T10 graceful regression clauses are also only partially mapped. `TestClosingPreservesGracefulCloseFrame` decodes a normal close frame but does not prove exactly one Close amid pending/in-flight frames. `TestClosingFullQueueFallbackAndOverlaps` overlaps direct close helpers, not the actual writer-failure and probe-timeout producers, and does not count one terminal cleanup/event. `TestClosingDuplicateAndOldSessionIsolation` protects a replacement from an old timer but does not exercise refused registration or pre-auth close against a valid incumbent. Those cases are expressly required at R3 lines 451–463 and are not supplied merely by enumerating the 19 teardown producers elsewhere.

### Consequence

The precise empty-ID regression that motivated `registeredSessions` capture remains unproved end to end. A change could preserve the helper unit test while losing capture in v1 or v2 registration, running deferred raw close before closing publication, or incorrectly marking an incumbent closing on a refused/pre-auth connection. Writer/timeout overlap could also duplicate terminal cleanup or corrupt the graceful frame sequence without failing the current direct-helper overlap test.

### Required minimum correction

1. Drive the real v1 and v2 handshake/registration functions. Deterministically make the actual acknowledgment enqueue fail after successful registration. Observe the empty-ID return path, retain the captured registered session, and prove deferred `closeConnection` publishes closing before the raw connection closes and before eventual registry/map cleanup. Assert the exact old session becomes unavailable.
2. Add a deterministic refused-registration/pre-auth close case proving the incumbent exact session remains available.
3. Complete the bounded transport regressions with one frame-sequence case that has pending/in-flight data and observes exactly one normal Close, and one overlap using the real graceful-close, writer-failure, probe-timeout, and terminal cleanup paths with cleanup/event counts and no panic/double close.

These tests occur before completed positive artifact admission or exercise transport invariants independent of its store. They do not need multiplication over both admission stores, both promotion boundaries, or all teardown producers.

## MEDIUM — S2-ADM-M3: T06 lacks WS source-lock-first cases, actual INSERT rejection, and full-owner fault-release proof

### Evidence

R3 T06 (`promotion-authority-addendum-r3.md:401`) requires holding each owner write lock before a guard attempt; separate SQLite connection and write-transaction occupation; insert failure, COMMIT failure/uncertainty, canceled context, and panic through the guarded store; and proof that every pin releases and later mutation/promotion succeeds.

The guard is a composed acquisition chain. `ws/model_admission_authority.go:78–124` try-pins, in order, `modelAdmissionAuthorityMu`, `sessionPublicationMu`, the exact session writer, the pool provider, and the subordinate prepared authority guard. Its rollback releases every acquired element in reverse order. The current evidence leaves three specific holes:

- `TestPromotionGuardContentionAndCancellation` (`ws/model_admission_guard_test.go:267–295`) holds the session writer, cancels before acquisition, and injects a failed subordinate guard. Pool, Tier2, buyer, and billing tests independently exercise their owners, but no test holds `modelAdmissionAuthorityMu` or `sessionPublicationMu` for a lock-first attempt through this real composed guard. The availability-callback test holding publication/session mutexes is a different API and cannot substitute.
- `TestPromotionSQLitePostInsertBoundary` (`ws/model_admission_commit_boundary_test.go:101–160`) injects error and panic **after a successful INSERT**, which proves transaction rollback but not actual INSERT rejection. The deferred foreign-key case proves a real COMMIT failure, and the SQLite wait tests separately cover connection and `BEGIN IMMEDIATE` wait without authority pins. An actual `INSERT` failure remains absent.
- The post-insert/fault fixture uses a no-op subordinate authority guard. It therefore cannot prove release of the complete buyer/feed/billing/settlement/Tier2 owner chain after cancellation following acquisition, panic, insert failure, COMMIT failure, or uncertain completion. The uncertain-commit case checks latest state, but not complete history plus repeated reconciliation needed to prove one known durable outcome exactly once and no positive claim for an unknown outcome.

### Consequence

A partial-acquisition leak in either WS source lock, or a release bug that appears only after the complete owner chain has been acquired, could pass the current tests. A duplicate durable event concealed by latest-state equality could also satisfy the present uncertain-commit assertion.

### Required minimum correction

1. Add lock-first cases for `modelAdmissionAuthorityMu` and `sessionPublicationMu` through the real composed promotion guard. Each must return promptly without loops, event append, or replay reservation, then prove guard reacquisition and owner mutation succeed after release.
2. Add an actual SQLite INSERT rejection, for example a test-only aborting trigger, distinct from the existing post-insert rollback and deferred-COMMIT failures. Verify no target-positive event/reservation and successful later mutation/promotion.
3. For context cancellation after full acquisition, panic, insert failure, COMMIT failure, and ambiguous completion, use the real complete authority preparer or explicit release witnesses for every owner. Prove all owners can mutate/reacquire afterward and that a subsequent promotion succeeds where the store outcome permits it.
4. Extend uncertainty coverage to complete event/CAS/replay history and repeat reconciliation, proving one durable known commit exactly once and no positive claim for an unknown outcome.

One complete full-owner composition per distinct fault class, plus the two missing WS source-lock-first cases, is sufficient. The contract does not require fault × every owner × every mutable value × every teardown producer.

## Required corrections that should not become Cartesian expansions

The approved evidence is intentionally compositional. The following expansions are unnecessary and would add runtime without closing a distinct contractual risk:

- **No T08 teardown producer × revocation fault multiplier.** Offer, retry, replay, throttled retry, and status converge on shared `refreshArtifactAdmissionStatus`, whose revocation/readback logic has no producer discriminator. The producer matrices prove all real producers publish closing with cleanup held; the readback-race suite separately proves CAS conflict and store-error handling. T11 must still provide the later paid-route refusal identified in M1.
- **No T11 consumer × every T10 producer × both persistence outcomes multiplier.** Each required consumer needs a fresh fixture, both stores, and ordinary/fault revocation. Representative real local and scheduled producers plus the separate full producer inventory provide the intended composition.
- **No T06 fault × owner × value × producer multiplier.** Add the two missing WS source-lock-first cases and one complete owner-chain release proof for each distinct fault boundary.
- **No signed feed/config source × every transport/store race multiplier.** The real signed-loader tests establish each source deadline; the shared deadline's store-boundary tests establish exact expiration behavior. R3 lines 389–392 require real loaders for signed-source cases, not signed material in every transport fixture.
- **No acknowledgment-failure × admission store/boundary multiplier.** A failed acceptance enqueue follows registration before completed positive artifact admission; the admission-store axes do not change the capture invariant.
- **No artificial single-provider artifact-positive HTTP-forwarding hybrid.** The approved HTTP addendum correctly separates the actual HTTP 530/302 producer composition from the artifact route consumer because one provider cannot simultaneously satisfy the mutually exclusive primary artifact WS and HTTP-forwarding preconditions. Preserve the two compositions joined by real WS closing/availability callbacks.

## Gate disposition

| Gate | Count | Disposition |
|---|---:|---|
| Critical | 0 | Clear for this bounded mapping audit |
| High | 0 | Clear for this bounded mapping audit |
| Medium | 3 | **Blocked** until M1–M3 are implemented and freshly verified |

Minimum closure is the correction set above, followed by targeted `-race -count=1` runs for the affected buyer/WS packages and integration composition, with exact selected test names/counts recorded in `implementation-S2.md`. Existing broad T01–T09 and T10 producer matrices should remain unchanged unless a new failure demonstrates a shared fixture defect. Final closure still requires the repository's broader coordinator tests, vet/lint/spec gates, and combined code/security/architecture audit specified by the project instructions.

## Snapshot manifest

| Path | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/promotion-authority-addendum-r3.md` | `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4` |
| `docs/product-roadmap/build-1/implementation-S2.md` | `49955e7ee24cd71d1644e46c1b26d8a06ff78d1f0c2aee0c132282570f1d7b0d` |
| `phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go` | `e609ee0e8352726b6e77c936971807539f91a670ca206942d65afa5559ac8b85` |
| `phase4-coordinator/internal/buyer/model_admission_route_export_test.go` | `35a2663b1112afb58eb53bff6131baaa6597193f8d782a2b5564366b46f73d53` |
| `phase4-coordinator/internal/buyer/model_admission_authority.go` | `aa568bb750e4387e8f1f6b35305b7e5fee32c8ec0bf7431c58020fcfa4b05b15` |
| `phase4-coordinator/internal/buyer/model_admission.go` | `5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549` |
| `phase4-coordinator/internal/buyer/route_snapshot.go` | `09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f` |
| `phase4-coordinator/internal/ws/model_admission_transport_test.go` | `63aeb7be1a4da4a3c1f90b7f4c303f93507c3dd646c7320bf306f8e26bafc567` |
| `phase4-coordinator/internal/ws/model_admission_guard_test.go` | `b3951d92df7bc56be0a88dc9733b93f379745d170eff741ed0b4e791b5171f50` |
| `phase4-coordinator/internal/ws/model_admission_commit_boundary_test.go` | `f648ee82d76069370ab50753037ee95e83a31969ec24bb546561c36d578429fd` |
| `phase4-coordinator/internal/ws/model_admission_sqlite_wait_test.go` | `dfc06d87b7eb309d4e72e5e4561b752b28f0634baf73bc6ef1b78fef84f2d913` |
| `phase4-coordinator/internal/ws/model_admission_owner_stress_test.go` | `233f8018672a3e654d3d07babf4fd68d06622d7a759a06d5c7bb1f482d851ffb` |
| `phase4-coordinator/internal/ws/model_admission_ws_owner_matrix_test.go` | `808151318cb7b49558138f78b0953c9755a9c62615401a8868f95b79a230831a` |
| `phase4-coordinator/internal/ws/model_admission_http_teardown_matrix_test.go` | `763cece79046d03cb1451b7967d267adbb66860808366143b3fa0ad0e85284b9` |
| `phase4-coordinator/internal/ws/model_admission_readback_race_test.go` | `3c4d2ad00747c15a1b63a1a3b5890e82f020941d7c476bec32a1de99ccc1a68b` |
| `phase4-coordinator/internal/ws/model_admission_authority.go` | `4a9fd8ff1f2dfc5bc2ce20305d3138b179dda68cfc6d61eca8939455110c85d1` |
| `phase4-coordinator/internal/ws/model_admission.go` | `29ccde75f132363c31f0a306bf5dcf7ca4cf56b2f0302a92fb4706633d48363b` |
| `phase4-coordinator/internal/ws/model_admission_transport.go` | `e551eac5f7f0085c080f2c8841fda318203cd42ddff0bf35e8f54d70adc3a692` |
| `phase4-coordinator/internal/ws/server.go` | `ff38f9a545c08e2705f90c07326342040723675a7b6e3b77bcd150ed287f4299` |
| `test/integration/build1_closing_route_test.go` | `873bb97c04c3a7243ab55c54e037c2188a99c0966d325ddf1e8ab1bcc46c3fd0` |
