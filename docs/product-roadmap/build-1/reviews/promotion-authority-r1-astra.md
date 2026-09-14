# Promotion authority R1 — independent architecture plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium, 0 Low.** The proposed source-owner guard addresses the main S2 read-to-append race, but its WS transport ownership boundary omits existing coordinator-owned socket teardown paths. This is not a zero-C/H/M approval and does not authorize implementation.

Exact proposal SHA-256: `67e3fe8157337bcb40f8fbe6901ca4d3d5966691efaca606195bc96861d44147` (verified).
Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Snapshot UTC: 2026-09-10T08:58:26.924116+00:00. Static independent source/plan review; no source edits, runtime calls/tests, services or subagents. Only this review artifact was written. The lead's concurrent S1 billing edits are outside this plan gate; hashes identify the source observations, not a frozen whole-worktree implementation approval.

## PROMO-ARCH-M1 — session open-state lock does not own local transport invalidation

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal line 45 and steps 3–4 (lines 79–102) require centralizing session map publication and pinning the selected session's `writeMu`, then checking its open state. The actual `providerSession.close` publishes `closedCh`/`closed` under that mutex (`internal/ws/relay.go:323–338`), but several production teardown paths affect the live socket before that publication or without directly publishing it:

- `internal/ws/server.go:3514–3545`, `closeSession`, enqueues the close frame and schedules `session.conn.Close()` after a grace interval. Neither the scheduling path nor its timer first marks the session closed under `writeMu`.
- `internal/ws/server.go:5890–5892`, `handleProviderWriteFailure`, closes the connection before calling `session.close` and deleting the map entry.
- `internal/ws/server.go:5949–5950`, `monitorHeartbeat`, closes the connection and returns. It relies on a later read-loop teardown to publish session/pool invalidity.
- `internal/ws/relay.go:300–306`, `runWriter`, closes the connection before the failure callback or `ps.close`; `writeProbe` similarly closes before `ps.close` at lines 385–388.

The new map guard does not cover these raw connection closures. `isOpen` only reads `closedCh` (`relay.go:345`), while registry `Conn` tests a nonnil connection reference (`pool/provider.go:2624`); neither detects the already closed transport. R1's ownership and test inventory mentions `session.close` and map replacement/deletion, but does not require changing these local teardown producers.

**Concrete interleaving:** Let the heartbeat teardown close the selected connection and return, and pause the read-loop cleanup before it invokes `session.close`/registry mutation. A later promotion acquires every proposed pin: the registry still contains the ready provider and nonnil connection, the session remains stored, and `closedCh` remains open. The last guarded validation therefore accepts a socket whose coordinator-owned close already completed. Alternatively, a previously scheduled `closeSession` timer can close the socket between guarded validation and SQLite COMMIT without contending for any proposed authority pin. This is not the expressly excluded case of an external physical disconnect that the coordinator has not yet observed.

**Consequence:** The promised serialization of current WS transport authority remains incomplete. A positive artifact event and fresh-response observation can still pass after known local transport invalidation. This reproduces S2's capability misstatement despite correct admission CAS and the new guard. Later route/status checks continue containing paid-routing exposure; this finding does not claim a new settlement bypass.

**Required correction:** Define one session-owned logical availability/invalidation publication used by every post-registration coordinator teardown path before it closes or schedules closure of the selected socket, unless an earlier serialized registry/session-map invalidation already excludes that exact session. That publication must participate in the same guard as promotion and fresh readback. A completed local close/invalidation before guard acquisition must be observed; an overlapping invalidation may serialize after the guarded commit. Do not depend on eventual read-loop cleanup to establish invalidity.

Specify how graceful Close-frame delivery is preserved: blindly calling the existing `session.close()` before enqueueing the frame closes the writer channel and would change teardown semantics. A separate closing/ineligible state under the selected session lock, or an equivalent ordered helper, can separate authority invalidation from draining the writer and closing the socket. Keep network IO and callbacks outside authority locks. Enumerate the relevant raw close/timer/failure paths and distinguish pre-authentication or already-replaced/excluded old sessions that cannot authorize promotion. Preserve the proposed nonblocking lock order and avoid adding a reverse blocking acquisition from teardown into admission serialization.

**Required tests:** Extend T01/T02/T08 with real `closeSession` scheduling, heartbeat hard-close, writer failure and probe-timeout teardown. Use barriers/injected timer firing, not sleeps. Pause eventual read-loop cleanup and assert a completed local invalidation before guard acquisition rejects both promotion boundaries and fresh positive readback. While a commit guard is held, assert the serialized invalidation cannot publish until after that commit; subsequently it must exclude the session even if map deletion/registry cleanup remains delayed. Preserve graceful close-frame delivery and one-time channel closure, and run these cases against memory and SQLite with the race detector. Testing only a direct call to `providerSession.close` is insufficient.

## Other architecture assessment

The chosen admission-first, try-lock-only acquisition order is feasible. Memory admission serialization or SQLite connection acquisition plus successful `BEGIN IMMEDIATE` precedes all owner pins. A later contended owner releases the acquired prefix immediately and rolls back without spinning. This avoids waiting on existing inverse pool callbacks, including Tier2 and WS buyer-serving predicates. Owner-local lock-held views are essential: calling `Resolve`, `Conn`, `CanarySanctions`, billing getters or `SnapshotMaterial` again under their locks can deadlock when a writer is pending. A lock-free stored-session getter must remain available to the registry callback; the new publication lock cannot be added indiscriminately to that getter.

The source inventory correctly distinguishes the buyer billing tuple from the billing store's `settlementMu`, and the Tier2 singleton publication from the selected catalog's state lock. Current Tier2 has independent `setDefault`/reset publication and `Configure`/`ConfigureStrict` state mutation. Both must be guarded, while signed file loading remains outside. Feed slices and rewards rate maps need ownership copies at publication and returned snapshot boundaries; copying only the prepared result is not protection from retained aliases mutating the owner. Prepared provider/receipt values likewise need owned data as specified. This review found no additional existing resolver eligibility owner beyond those identified and the transport gap above.

`VerifyArtifactAdmissionConfig` currently performs database reads, so preserving it in pre-resolution and comparing the unchanged effective store/snapshot/rates under the guard is compatible with the prohibition on a second database connection inside the admission transaction. Current billing snapshot publication inserts historical rows; it does not mutate an existing captured row through a live config setter. Full resolver/signature/feed parsing must not accidentally be called again under all pins. Comparison of an unchanged owner-published bundle plus its already verified immutable predicates can provide the guarded recheck without those operations.

`sqliteutil.Transact` reserves one connection, runs its callback, commits afterward, and rolls back on error/panic with a background context. An outer retained release closure can therefore keep pins through actual commit/rollback and connection cleanup without modifying the generic helper. The 250-ms context target is an availability objective, not guaranteed interruption of stalled SQLite/OS cleanup. Holding the global registry read lock and session writer mutex during slow durability can delay heartbeat/state updates, frame enqueue and close; T06/T07 must measure actual guard-held duration and enforce the plan's stop-and-revise rule if healthy contention fails the target. A try-lock acquisition bound alone does not prove commit latency.

The proposed real-clock check immediately before insertion, original probe deadline retention, minimum feed/reference expiry, and final observation suppressing now-expired positives preserve a finite authority lease. Mutability serialization cannot freeze time. A durable event whose authority expires while COMMIT returns remains historical evidence and must not be presented as current. Context cancellation or uncertain COMMIT must reconcile exact event/idempotency identity after transaction cleanup; it cannot justify blind retry or a positive response from the pre-probe event.

R1 appropriately requires one current-response path for offer, retry, status, replay, throttled retry and append failure. Current offer and retry handlers return the chosen event directly, and decision replay currently precedes transition CAS; both facts make this broader readback repair necessary. The proposed latest-event serialization, owner-pinned observation, at-most-one revocation/read retry, and no positive body on unresolved store/authority errors address this. Revocation must use a same-transaction helper or release read serialization before an ordinary append, as specified; no recursive memory mutex or second SQLite connection is permitted. Response network IO occurs after all authority locks are released. Later changes can legitimately serialize after that observation.

Mandatory guarded capability with no ordinary artifact-positive append fallback prevents a partial interface rollout from silently reopening S2. Legacy/non-positive transitions keep their prior semantics; tests must pin them and persisted reopen must not infer a live session from historical events. Prepared guard factories remain coordinator-owned internal capability, never provider assertions. SPEC-047 clarification and all T01–T09 tests remain required, along with complete combined implementation audits. The transport correction requires a new exact-digest plan review before implementation. No physical MLX, production, multi-coordinator fencing or financial acceptance is established here.

## Source snapshot

Manifest SHA-256: `0d16c7bd2d0d4426acc713b9c53e04baa1139474b16a4c08b640d213661eef32`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/promotion-authority-addendum-r1.md` | `67e3fe8157337bcb40f8fbe6901ca4d3d5966691efaca606195bc96861d44147` |
| `docs/product-roadmap/build-1/reviews/go-security-current-r1-astra.md` | `1b18b033438a31adf6ba771755b6343318699e33d93c5b0a597a09727b5e491d` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `specs/SPEC-047-network-model-admission.md` | `42c8bcc9d71984741714e0f2c77aef1fc609424e35459b30517f20ea228b8522` |
| `phase4-coordinator/internal/ws/model_admission_authority.go` | `c634f7b5c0671b65528d25636743718e1d1bc3a23b5849b055239ea5bf9cf39b` |
| `phase4-coordinator/internal/ws/model_admission.go` | `379913f313ecef918883bf554f90f582a880c3efa49079e622bd5f5f6d29117d` |
| `phase4-coordinator/internal/ws/model_admission_retry.go` | `9edd8750696c67ec42e4f4d1dc9b5508240519cfd4a8d24c6614660c1ccde4f4` |
| `phase4-coordinator/internal/ws/server.go` | `03dc78cd089dc3f9b0d9755f7e84c4c978c63cb37067915f2e5dab7b9109d175` |
| `phase4-coordinator/internal/ws/relay.go` | `ec54e518d0a46c5885b7aa53e76512034342fc976daab70adf9e48a02f7b2fb8` |
| `phase4-coordinator/internal/pool/provider.go` | `8778beeabd63d4d7fa259c6c68f61836c604907b3f16c6f5e0ced486acab9e6b` |
| `phase4-coordinator/internal/buyer/model_admission_authority.go` | `36776909256a4bb1ee0531efe157f185fa103163a7c8f9164968a1b01b75b94a` |
| `phase4-coordinator/internal/buyer/model_admission.go` | `5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549` |
| `phase4-coordinator/internal/buyer/autotune_feeds.go` | `898f16a533db9868777226799f282e7db5fd8b4a378c1ca4a653f65d2449988a` |
| `phase4-coordinator/internal/buyer/server.go` | `aceb3c5dc037336ff415aa01ec7143f0b801d30ed3ea4186855a84c8037a1107` |
| `phase4-coordinator/internal/billing/store.go` | `5619b7460967de6722ce550ed17520f6471ff32d96f09b81fdaecb86bb8f243d` |
| `phase4-coordinator/internal/billing/snapshot.go` | `323c4fbb6d9d875f03e5bb3e40eb4eccedf1231c86eea223a704257fe004ab53` |
| `phase4-coordinator/internal/billing/artifact_admission.go` | `10825911f104422c290eb248022d77ecde936fe2f342a4fe5d22a3da5d7c5896` |
| `phase4-coordinator/internal/sqliteutil/transact.go` | `bf513c81dbfb3bc7d441ba1c6f1bbbbf37810ba5b7a9d4f565af81ef461ad349` |
| `phase4-coordinator/internal/tier2/catalog.go` | `70a2deb02946c2722d17b42c46b6037c9d669c2a64cc47ad24b2e1b0a0d93042` |
| `phase4-coordinator/cmd/coordinator/main.go` | `f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d` |
