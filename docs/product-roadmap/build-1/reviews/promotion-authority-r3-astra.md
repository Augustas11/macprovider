# Promotion authority R3 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.** R3 closes PROMO2-ARCH-M1 and preserves the earlier PROMO-ARCH-M1 correction. No additional blocking architecture defect was identified in this exact design. This approves the plan for implementation; original S2 is not implementation-closed until the combined code and required tests pass.

Exact proposal SHA-256: `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4` (verified).
Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Snapshot UTC: 2026-09-10T09:13:00.448874+00:00. Static source/plan review; no runtime tests, services, source edits or subagents. Only this review was written. S1 billing acceptance remains separate; neither S1 nor concurrent tests supply evidence for unimplemented S2 behavior.

## PROMO2-ARCH-M1 — closed at plan level

**Prior severity:** Medium. **Evidence:** R3 “Buyer artifact route observation,” S2-T11, and current buyer call chain.

R3 requires a constructor-wired WS-owned read callback for exact nonempty provider/assigned-session identity. It checks the current registry assignment, exact stored session and the same monotonic closing/closed publications used by the commit guard. There is no buyer-cached state or provider-controlled availability assertion. Missing read or close capability prevents installation of the guarded artifact service, and missing read capability also rejects direct resolver/route use of a previously persisted artifact event. Callback configuration is immutable after construction; installer validation cannot be bypassed by treating an ordinary resolver callback as guarded capability.

The integration reaches the existing route authority boundary: `buyer/model_admission.go:112–127` invokes `ResolveModelAdmissionAuthority` and returns found-but-ineligible on its error regardless of revocation outcome. That helper is used by `byomDefaultPaidRoutingEligible` at line 21. Actual selection reaches it through `buyer/server.go:6963` pinned validation, lines 7171/7219 queued rechecks and line 7406 eligibility context; `buyer/route_snapshot.go:79` independently requires the binding before snapshot construction. The proposal therefore targets production consumers, not a parallel predicate tested in isolation.

Every normal resolver call must now require exact-session availability. A prior closing publication is visible even when registry state is ready, Conn is nonnil, raw close is delayed and the historical event is still positive. Old-session map remnants cannot make a replacement validate old evidence: callback assignment checks plus existing captured session/receipt/feed/rate comparisons remain mandatory. Positive availability is only one necessary predicate, not standalone admission authority.

The callback returns no lock/pin and releases its short registry read before downstream parsing, database work, selection or inference. Normal pre-resolution may invoke it; pinned promotion and fresh response use the private lock-held view of the same publications to avoid recursive registry read deadlock. This is a coherent two-access-mode contract, not a second closing authority. Changes overlapping an observation retain existing observation semantics; previously completed invalidation must be seen at the next check.

**Consequence after correction:** Artifact route eligibility no longer depends on eventual socket failure, registry cleanup or a prior status call successfully revoking the event. A failed revocation write preserves historical evidence but cannot turn unavailable live authority into an eligible route.

**Required correction:** None remaining at plan level. S2-T11 must be implemented as specified. Each independent entry point gets a fresh signed fixture with the positive event still latest; it cannot inherit a revocation caused by an earlier setup check. The real default/pinned/queued/HTTP paths must reject selection before dispatch, and the wrapper rejecting only revocation writes must leave the positive event stored while selection still refuses it. Missing wiring, replacement/old timer, ready revival, legacy and no-drift controls are required. The test proving closing can publish while later route persistence/dispatch is blocked prevents accidentally carrying promotion locks into inference.

## Original PROMO-ARCH-M1 — closure preserved

R3 retains R2's full post-registration invalidation inventory and separate monotonic closing state under session writeMu. Every local definite close or closure timer publishes ineligibility first unless earlier permanent exact-session invalidation already excludes it. The buyer raw close at `buyer/server.go:8502` uses a WS-owned exact-session callback; transient map absence or a reversible unavailable mark is not sufficient proof. Constructor wiring is required before enabling artifact promotion.

The new explicit v1/v2 acknowledgment enqueue-failure requirement closes the source-specific implementation trap: current handshake paths can return empty IDs after registration, so outer handleConn deferred cleanup cannot rely on those return values. R3 captures the registered session separately and adds the actual handshake failure producers to T10. Known read/write failures publish before diagnostic/fanout/result callbacks and raw closure; probe timer creation itself remains non-invalidating.

Graceful closing remains separate from terminal channel shutdown. The writer can drain control/Close frames outside the publication lock; hard failure, queue-full and repeated shutdown remain idempotent and never restore eligibility. Timers capture old exact sockets. Promotion's try-lock acquisition avoids waiting on an inverted teardown order; no writeMu holder may acquire rekey/registry/map/DB or invoke network IO/callbacks before releasing publication. T10 retains actual producer ordering, paused cleanup, decoded graceful Close frames, duplicate closure, full-queue and replacement isolation tests.

## Complete guard, persistence and response assessment

The admission store is serialized first: memory mutex or reserved SQLite connection plus BEGIN IMMEDIATE. Pool/feed/config/session pins are acquired afterward with try-lock-only prefix unwind, so connection/write-lock waits do not hold authority. All mutable owners remain covered: resolver installation, WS map and session, registry identity/receipt/gates/sanctions, owner-copied feeds and rewards, effective billing store/snapshot, separately owned settlement mode, Tier2 singleton publication and selected catalog state. No mutable alias may escape ownership protection. Full verification/loading stays outside; lock-held comparison uses captured verified values and private views.

Current `sqliteutil.Transact` commits after its callback and performs deferred rollback on failure/panic. An outer release closure can retain pins through actual commit or rollback without modifying the generic helper. Context/clock validation immediately before insertion uses the original probe lease and minimum authority deadline. Elapsed durability can leave a historical event whose authority is now expired; final fresh observation must suppress it. Uncertain COMMIT requires identity/idempotency reconciliation after cleanup, not blind positive retry. Guard contention before insertion cannot consume decision replay keys.

The 250-ms guarded durability target remains a measured availability requirement, not an OS preemption promise. Even with nonblocking acquisition, INSERT/COMMIT/rollback can delay registry mutations and frame enqueue. T06/T07 must separate DB wait from actual pin-held time and force contention, cancellation, panic and ambiguous completion. Healthy timing failure requires a revised design, not releasing pins before commit or reporting skipped work as passed.

Latest-event serialized fresh readback remains required for offer, retry, status, replay, throttled retry, CAS failure and partial two-step promotion. Exact event CAS still handles withdrawal/reoffer/revocation. At-most-one revocation/read retry prevents unbounded recovery; unresolved storage/authority returns no positive body. Readback releases serialization before ordinary revocation or uses a same-transaction helper, never recursive memory locking or another SQLite connection. Response IO follows lock release. The route callback adds a current observation without changing historical settlement evidence or creating perpetual response validity.

The ordinary artifact-positive append path must reject missing guarded-store capability; trusted fixture composition cannot introduce a production bypass. Genuine legacy/non-artifact paths retain their interpretation, and persisted reopen cannot create live session authority. The planned SPEC-047 clarification and all T01–T11 outcomes remain required before final acceptance, followed by complete combined code/security/architecture audits. No physical MLX, production, distributed multi-coordinator fencing or financial acceptance is established by this plan review.

## Source snapshot

Reviewed the full retained proposal through its revision history, exact R3 delta, both prior findings, source-owner/SQLite seams and actual buyer resolver/selection/snapshot consumers. No implementation test claim is made.

Manifest SHA-256: `ca82fa08f074a372a571c25cfc0769c260a5c3d501c4c0ebf0fc21e25a3dbb3b`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/promotion-authority-addendum-r3.md` | `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4` |
| `docs/product-roadmap/build-1/reviews/promotion-authority-r2-astra.md` | `6674ed5b23a551e874a0af42a8deca1af0b811fae7d241551b2c93aa46ab0ff8` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `specs/SPEC-047-network-model-admission.md` | `42c8bcc9d71984741714e0f2c77aef1fc609424e35459b30517f20ea228b8522` |
| `phase4-coordinator/internal/ws/model_admission_authority.go` | `c634f7b5c0671b65528d25636743718e1d1bc3a23b5849b055239ea5bf9cf39b` |
| `phase4-coordinator/internal/ws/model_admission.go` | `379913f313ecef918883bf554f90f582a880c3efa49079e622bd5f5f6d29117d` |
| `phase4-coordinator/internal/ws/model_admission_retry.go` | `9edd8750696c67ec42e4f4d1dc9b5508240519cfd4a8d24c6614660c1ccde4f4` |
| `phase4-coordinator/internal/ws/server.go` | `03dc78cd089dc3f9b0d9755f7e84c4c978c63cb37067915f2e5dab7b9109d175` |
| `phase4-coordinator/internal/ws/relay.go` | `ec54e518d0a46c5885b7aa53e76512034342fc976daab70adf9e48a02f7b2fb8` |
| `phase4-coordinator/internal/ws/admin_endpoints.go` | `d128925a5e755b53c6f90f8bf9e64f08fabe3c4a20e7f1441d6da12a777a0166` |
| `phase4-coordinator/internal/ws/admin_hardware_trust.go` | `915cf7c3880b3ff6b8c98d6fdc4d28f1a2a63e72876e73c5a6660479603bfa7f` |
| `phase4-coordinator/internal/ws/trust_revalidation.go` | `6cd246967796c147de76be807e3a7ceb4724d8572c41f29c2384843407d171c7` |
| `phase4-coordinator/internal/pool/provider.go` | `8778beeabd63d4d7fa259c6c68f61836c604907b3f16c6f5e0ced486acab9e6b` |
| `phase4-coordinator/internal/buyer/model_admission_authority.go` | `36776909256a4bb1ee0531efe157f185fa103163a7c8f9164968a1b01b75b94a` |
| `phase4-coordinator/internal/buyer/model_admission.go` | `5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549` |
| `phase4-coordinator/internal/buyer/autotune_feeds.go` | `898f16a533db9868777226799f282e7db5fd8b4a378c1ca4a653f65d2449988a` |
| `phase4-coordinator/internal/buyer/server.go` | `aceb3c5dc037336ff415aa01ec7143f0b801d30ed3ea4186855a84c8037a1107` |
| `phase4-coordinator/internal/buyer/route_snapshot.go` | `09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f` |
| `phase4-coordinator/internal/billing/store.go` | `5619b7460967de6722ce550ed17520f6471ff32d96f09b81fdaecb86bb8f243d` |
| `phase4-coordinator/internal/billing/snapshot.go` | `323c4fbb6d9d875f03e5bb3e40eb4eccedf1231c86eea223a704257fe004ab53` |
| `phase4-coordinator/internal/config/config.go` | `80fb1e12fcff2bd77a08b2068c5a1abc061e08d2f5af4f01d96e4411f72652cd` |
| `phase4-coordinator/internal/sqliteutil/transact.go` | `bf513c81dbfb3bc7d441ba1c6f1bbbbf37810ba5b7a9d4f565af81ef461ad349` |
| `phase4-coordinator/internal/tier2/catalog.go` | `70a2deb02946c2722d17b42c46b6037c9d669c2a64cc47ad24b2e1b0a0d93042` |
| `phase4-coordinator/cmd/coordinator/main.go` | `f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d` |
