# Promotion authority R2 — independent architecture plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium, 0 Low.** R2 closes PROMO-ARCH-M1 at plan level. One integration gap remains between its new monotonic session availability and the retained paid-route revalidation/test contract. This is not a zero-C/H/M approval.

Exact proposal SHA-256: `494a93e351df87e1cdd4617eee8e0e1dd0912a9299a512300ba33a684eded6f5` (verified).
Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Snapshot UTC: 2026-09-10T09:07:58.111032+00:00. Static plan/source review only; no runtime tests, source edits or subagents. Only this report was written. S1 billing acceptance is separate and is neither reopened nor used as S2 approval.

## PROMO-ARCH-M1 — closed at plan level

**Prior severity:** Medium. **Evidence:** R2 transport inventory/protocol, lines 68–152, constructor wiring at 401–410 and S2-T10.

A separate monotonic closing publication now precedes local hard close and commitment to a closure timer. It participates in the selected session's writeMu guard without shutting down the writer channel. Subsequent promotion and fresh readback reject closing even when registry/map/read-loop cleanup is paused or a readiness update attempts to revive the same assigned session. Graceful Close/control frames remain serialized by the existing writer; timers capture only the old exact session/socket. Network IO, logging, event recorders, failure fanout and callbacks stay outside publication locks.

The inventory covers the earlier raw WS close paths and the newly identified buyer `closeProviderConn` at `buyer/server.go:8502`. That function currently closes a registry connection after a reversible unavailable mark; r2 routes it through a constructor-wired exact-session WS invalidation callback and refuses to enable guarded artifact promotion without that wiring. Temporary map absence during registration cannot be treated as permanent exclusion. The source search also confirmed scheduled operator rejection and trust eviction; these must publish before the outer 200-ms timer, not merely when it eventually calls closeSession.

**Consequence after correction:** A completed local invalidation can no longer precede a successful guard while leaving the session logically open. A teardown overlapping a held guard must wait to publish; it cannot close the socket or arm a definite-close timer while waiting. The separate closing state avoids losing graceful frame delivery.

**Required correction:** None remaining for the original M1 mechanism. Implement the complete inventory, including post-registration error exits. In current v1/v2 handshake paths, an acknowledgment enqueue failure may return empty IDs after registration; outer handleConn cleanup cannot infer registration from those return values. R2's explicit registration/session capture requirement must cover those exits, and the producer tests must not assume eventual disconnect already runs. This is an implementation obligation under r2's all-post-registration-close rule, not approval of unchanged source behavior.

## PROMO2-ARCH-M1 — artifact route revalidation cannot observe the new closing authority

**Severity:** Medium. **Confidence:** High.

**Evidence:** R2 retains the read-only authority resolver for routing (selected correction), states that new paid routing uses its existing gates (transport semantics item 3), and requires later paid-route rejection in T02/T08. It introduces closing awareness specifically in the WS promotion/fresh-readback guard and the lock-free session availability predicate. The proposed buyer callback at lines 401–410 publishes closure, but supplies no read-side session availability to buyer artifact authority.

Actual `buyer/model_admission.go:112–127` calls `ResolveModelAdmissionAuthority` when validating a persisted artifact admission for a new route. That resolver's transport checks at `buyer/model_admission_authority.go:26–41` are registry Resolve, nonnil Conn and ready/busy state. It has no access to WS closing/closed state. Registry `Conn` at `pool/provider.go:2624` only checks provider/session identity and a nonnil connection reference. The current WS `isOpen` consumer at `ws/server.go:1040` is `canaryBuyerServing`, the canary floor predicate; it is not this buyer route check. `enqueueFrame` at `ws/relay.go:409–421` only rejects terminal closed, and r2 intentionally preserves enqueue during graceful closing.

**Concrete interleaving:** Persist a valid settlement_capable event. Publish closing through real closeSession, hold its hard-close timer, and keep registry/map cleanup paused so the exact provider remains ready and stored. Before any offer/status/retry readback revokes that event, run the buyer artifact route binding directly. All existing resolver evidence can still compare equal: the connection reference, registry state, feeds, rates, receipt identity and original probe are unchanged. Thus the existing route revalidation can still return eligible while the proposed session availability is already false. A ready update after buyer failure or scheduled eviction gives the same state. The graceful writer may still accept new frames during this interval.

**Consequence:** The new authority discriminator is enforced for promotion and status but absent from the claimed later route check. Tests that first run status/readback can conceal this by revoking the event before checking the route. This does not claim that receipts, immutable settlement validation or financial units are bypassed; it permits fresh artifact route eligibility for a session already committed to teardown and contradicts the retained T02/T08 outcome.

**Required correction:** Extend the proposed integration contract so read-only artifact authority/route revalidation consults the same exact-session monotonic availability source, or a rigorously equivalent shared predicate. A narrow constructor-wired WS read-side availability callback can check the captured provider ID plus assigned session and reject missing/closing/closed sessions; it must not silently resolve a newer session by provider ID. Missing required capability fails closed for the artifact authority service. Share the availability meaning rather than inventing a second mutable closing flag.

This does not require holding promotion pins during routing/inference or making all route selection a new global transaction. The required observation is bounded: invalidation already published before a later route check must be seen, while overlapping changes retain the existing observation semantics. Avoid invoking a locking getter recursively inside the fully pinned promotion path; it should use its lock-held view. Preserve legacy route interpretation and the graceful writer behavior rather than making all control-frame enqueue fail just to force a route error.

**Required tests:** For both storage variants, retain the actual positive event, invoke a real graceful/scheduled/buyer teardown producer, and pause raw close plus eventual registry/map cleanup. Check the buyer route binding and actual paid selection BEFORE any fresh status/offer/retry path can revoke the event. Assert immediate ineligibility despite registry ready/non-nil Conn and an unexpired unchanged evidence tuple; then assert existing CAS revocation/readback behavior. Repeat a ready update after closing, exact-session replacement/old-timer isolation, missing availability wiring, and unchanged valid legacy/no-drift paths. Do not substitute dispatch socket failure or a previously revoked event for route-authority rejection.

## Complete retained-contract assessment

The admission-first ordering remains feasible: memory serialization or SQLite connection plus BEGIN IMMEDIATE is acquired before owner pins. All subsequent source-owner acquisitions are try-lock-only with immediate prefix release on contention. Session map helpers release their publication lock before pool changes, session close, callbacks or IO. Closing acquires only the selected writeMu, releases it before cleanup, and adds no writeMu-to-rekey blocking path. Existing reverse pool/Tier2 callbacks still require private lock-held views and lock-free availability readers. The new protocol does not justify calling ordinary locking getters while the promotion guard is held.

Tier2 singleton replacement and selected catalog state remain separately pinned; feeds and rewards require ownership copies; the exact buyer store/config snapshot and separately owned settlement mode remain guarded. The proposed TryPinSettlementConfig API preserves the current CadenceDays-zero default behavior and is compatible with the actual scalar/string-only SettlementConfig. The rewards RateCard remains a map and requires copying. Independent reference verification and immutable billing snapshot verification stay outside the guarded append; no second DB connection or full resolver may be introduced inside it.

An outer release closure survives the sqliteutil.Transact callback and therefore can hold authority through COMMIT or deferred rollback, unlike a callback-local defer. Real connection/BEGIN waits precede locks; partial guard failure does not reserve replay keys. Error, cancellation, panic and uncertain COMMIT require cleanup then identity-based readback, not blind replay. The background rollback and OS calls may stall: the 250-ms target is explicitly not a hard preemption guarantee, and T06/T07 must measure actual guard-held durability, global registry/frame-enqueue impact and release. Failing realistic timing tests requires design revision as specified.

Real clock/context validation before insertion, minimum authority deadline, original probe lease preservation and post-commit fresh observation retain the expiry boundary. Historical committed events may outlive authority; responses cannot call them current after expiry. Latest-event serialization, exact event CAS, at-most-one revocation/read retry and no positive body on unresolved readback errors cover offer/retry/status, original/retry replay, throttled retry and second-promotion failure. Response IO occurs after pins are released. Reopen cannot obtain session authority from persisted records alone.

S2-T10 is a substantive improvement: real producer calls, both invalidation/guard orderings, paused cleanup, injected timers, writer-error ordering, exactly captured old sockets, graceful frame decoding, duplicate shutdown and registration isolation. T01–T09 remain mandatory. Add the independent route-order test above so stale capability cannot be hidden by a preceding readback revocation. Before implementation, obtain a new exact-digest zero-C/H/M gate and make the planned SPEC-047 clarification. Complete combined implementation audits and actual tests remain required; this review establishes no physical MLX, distributed coordinator fencing, production or economic acceptance.

## Source snapshot

Manifest SHA-256: `a120e5eb0a8732031d799b973624fb4e554184247d0015358c5926b6a01db25b`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/promotion-authority-addendum-r2.md` | `494a93e351df87e1cdd4617eee8e0e1dd0912a9299a512300ba33a684eded6f5` |
| `docs/product-roadmap/build-1/reviews/promotion-authority-r1-astra.md` | `d92f339b00587dc10c385f259d76f3c414521012e5ec11904f5ef587aa0d90b7` |
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
| `phase4-coordinator/internal/billing/store.go` | `5619b7460967de6722ce550ed17520f6471ff32d96f09b81fdaecb86bb8f243d` |
| `phase4-coordinator/internal/billing/snapshot.go` | `323c4fbb6d9d875f03e5bb3e40eb4eccedf1231c86eea223a704257fe004ab53` |
| `phase4-coordinator/internal/config/config.go` | `80fb1e12fcff2bd77a08b2068c5a1abc061e08d2f5af4f01d96e4411f72652cd` |
| `phase4-coordinator/internal/sqliteutil/transact.go` | `bf513c81dbfb3bc7d441ba1c6f1bbbbf37810ba5b7a9d4f565af81ef461ad349` |
| `phase4-coordinator/internal/tier2/catalog.go` | `70a2deb02946c2722d17b42c46b6037c9d669c2a64cc47ad24b2e1b0a0d93042` |
| `phase4-coordinator/cmd/coordinator/main.go` | `f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d` |
