# Product Build 2 R8 adversarial plan review

**Review model:** native GPT-5.6 Sol, high reasoning

**Verdict:** FAIL — implementation remains prohibited

**Finding counts:** Critical 0, High 2, Medium 1, Low 0, Info 4

**Reviewed MacProvider commit:** `c927ff9425c504353ae5b71e747d97a101d8185c`

**MacProvider implementation base recorded by the plan:** `1d2c930bad81704dd0acc0322226725d8b64aceb`

**Current fetched `origin/main`, deliberately not incorporated:** `c123ae2d2d08053612d940b3077994f7c4d709d7`

**Reviewed Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Artifact identity

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r8.md` | `007b6527db673626c50298bfe2c39cb7de30f0fd03e59216a077c3dfc82fd30a` |
| `test-spec-r8.md` | `c437d153df0238a172a5aeddaf29fca93aad51e8414ac910de3f200afea01815` |
| `finding-dispositions-r8.md` | `ec7a2f89f47d6611b2fa9a647e8cd57057939097c47f628d579dbfa6362b1bb2` |
| `checkpoint-r8.md` | `ebc4d27b9bfb62263c9b43a6cb6071f095e566347d3bfaca8f9f62e333b4cbf9` |
| failed predecessor `reviews/plan-r7-sol.md` | `a48ea052c9846976ef42bc0ac508a332aa45bb318a14c92247ee7d27729dd32a` |

All five submitted artifacts matched the requested bytes before review. The worktree was clean at the reviewed commit. The branch remains pinned to its historical implementation base; the one newer `origin/main` commit changes only SPEC-039 execution-prompt documentation and was correctly recorded without being incorporated. Malibu was inspected from its exact pinned git object without changing that repository.

## High findings

### H1 — The rollback design permits a monitored-but-rollbackable witness to freshly attest stale state

**Severity:** High

**Evidence:** C3C allows the production witness head to be either unrollbackable **or externally monitored** (`prd-implementation-plan-r8.md:323-325`). Coordinator startup compares only its SQLite singleton with a freshly signed witness head; it additionally mentions a witness below a client/operator monitor watermark, but defines no authoritative monitor-watermark store, input API, signature/frame, startup fetch, update CAS, retention domain, or rule that prevents proof issuance/admission until that watermark is consulted (`:331-336`). The disaster-recovery paragraph says immutable versions and operator monitor watermarks must later prove one unique latest head, but this is a recovery assertion rather than a detection/enforcement protocol. T-P05 repeats that assertion after rolling back the witness and supplies no mechanism that makes the coordinator know the rollback occurred (`test-spec-r8.md:102`).

**Consequence:** A backend satisfying the explicitly permitted “externally monitored” branch can restore an older head while retaining its signing key. If the coordinator SQLite snapshot is restored to the same generation, both stores agree and the witness can sign a fresh challenge-bound proof for stale state. A fresh client has no higher local watermark. Monitoring may alert after the fact, but nothing in the frozen protocol forces the coordinator or witness to consult that alert/watermark before admitting private work, so a signer, bundle, pin, or profile revoked after the restored generation can become usable again. The R7 rollback finding is therefore not closed for one of R8's two allowed production witness classes.

**Required correction:** Either require a head primitive whose monotonicity cannot be rolled back within the witness signing/serving authority, or freeze the external-monitor path as an executable second authority. Define its exact head frame and signature, service/storage/credential independence, append/update CAS, startup and per-proof consultation, outage behavior, backup/restore, rotation, retention, and the rule that prevents the witness and coordinator from signing/accepting a generation below it. Add a joint old-SQLite + old-witness restore test for fresh and previously anchored clients, and prove zero private admission before the independent watermark is read and matched. Rerun the full plan gate.

### H2 — Invitation issuance still has no executable idempotency or result contract

**Severity:** High

**Evidence:** C2 lists `POST /admin/relay-blind/trust-invitations` and its field names, says it writes idempotently, and makes first issuance assign the account's permanent capacity shard (`prd-implementation-plan-r8.md:175-184`). It never assigns the request version literal, defines how `invitation_id` is chosen, freezes the success status/body/version, defines a canonical request/response digest, identifies the operation-row schema/capacity, states the `(actor,operation_id)` replay and cross-actor rules, or gives crash/response-loss recovery semantics. C2A's exact digest, operation row, replay, response extent, and error contract applies expressly to “every C2A mutation”; invitation issuance remains in C2 and is excluded (`:186-208`). The accepted-event table merely says an invitation “adds <=2 KiB” (`:591`), while T-P00 asks for exact invitation issue/replay/shard behavior through C2/C2A (`test-spec-r8.md:64-70`) that the plan never supplies.

**Consequence:** Slice 1 cannot produce the promised closed schema/error manifest or implement first-invitation shard assignment without inventing trust-authority bytes. After a lost response or crash, implementations may generate a second invitation, consume another invitation row, disagree about whether the permanent shard assignment committed, or return a regenerated response. Actor changes and reused operation IDs likewise have no frozen outcome. This is a security-sensitive operator lifecycle mutation and the entry point for all 256 tenant shards.

**Required correction:** Give invitation issuance the same executable treatment as the other operator mutations: exact request version and canonical body, client- or server-owned invitation ID rule, exact success status/body/version, request and response digest frames, actor/idempotency key and cross-actor behavior, fixed operation/result capacity and charge, transaction linearization with shard assignment, error precedence, retention/pruning, and byte-identical replay/recovery at every transaction and response cut. Add first delivery, exact/changed/cross-actor replay, concurrent first invitations for one account, shard-last-slot races, crash at every persistence boundary, and lost-response restart tests.

## Medium findings

### M1 — Provider-scoped tokens have no closed absent/collision encoding

**Severity:** Medium

**Evidence:** C5 hashes each approved mapping tuple as `pinframe_fingerprint, mapping_presence, provider_id, configured_identity_public_key, collision_state`, requiring strings to use nonempty `u16str` and keys to use `b32` (`prd-implementation-plan-r8.md:359-366`). For an unmapped fingerprint there is no provider ID or configured key to encode; for a collision/ambiguity there can be multiple provider IDs/keys but the displayed tuple has only one of each. No tagged-union branch, zero/empty sentinel, or ordering of collision members is defined. The provider decision tuple similarly includes assigned session, fingerprint, models, and flags for every approved provider including the explicitly required absent state, without defining the absent branch's exact values/frame. C1 allows empty strings only for explicitly named sentinels (`:119`), and none is named here. T-S01 demands exact absent/ineligible and mapping/collision digest vectors (`test-spec-r8.md:122`) but cannot derive unique bytes from the plan.

**Consequence:** Two conforming implementations can hash different tokens for the same absent or ambiguous authority state, and the coordinator implementation must invent whether a colliding mapping chooses one provider, enumerates all providers, or fails closed. This weakens the reviewability of the R7 provider-scoped-generation correction and can produce false stability, false churn, or an unsafe arbitrary mapping choice at the precise collision boundary the token is intended to bind.

**Required correction:** Define closed tagged unions for unmapped, uniquely mapped, and collision states; enumerate and sort every collision member or define one canonical collision digest; state that non-unique mapping yields no eligible candidate; and define the exact absent/ineligible provider-state frame and sentinels. Freeze positive and one-field mutation vectors for each branch and race mapping changes across every P/D barrier.

## R7 correction verification

| R7 finding | R8 result |
|---|---|
| H1 traditional `F_SETLK` is not process-wide authority serialization | Corrected at plan level. C8A adds a process-lifetime capacity-one gate, retained canonical BSD `flock` descriptions, reverse unwind, `Store.Close`, and late-Keychain rules. T-G02 covers same/cross-process contention, unrelated closes, panic/`Goexit`, exec, repeated Close, and late completion. A fresh local macOS primitive check confirmed that independently opened same-process BSD flocks conflict and an unrelated descriptor close does not release the held lock. Exact runtime ownership remains subject to implementation review. |
| H2 retained revoked targets contradict emergency-slot accounting | Corrected at plan level. C9 defines target-local `active_revocable`/`retained_revoked` predicates, bound/sealed/free transitions, exact post-kind tuples, startup recomputation, and a complete 8,200-generation history. T-P04 checks the full bijection, retained references, restarts, replay, and pruning. |
| H3 in-database signatures cannot detect complete rollback | Not closed. C3C adds the necessary independent witness for an unrollbackable-head backend, but H1 shows that its separately allowed monitored-only backend has no executable independent watermark enforcement. |
| H4 signer/bundle/pin lifecycle lacks executable contracts | The named R7 signer activation, bundle upload, and signer/bundle/pin revoke routes are materially corrected with exact C2A schemas, actor authentication, replay, CAS, capacity, witness, and crash rules. H2 identifies the adjacent invitation operator mutation, required by the same journey and exact-lifecycle acceptance, that remains non-executable. |
| H5 shared buyer operation caps permit global denial | Corrected at plan level. C9 assigns 256 nonborrowable coordinator and gateway shards, makes revocation/DELETE capacity fixed, and tests hostile saturation of 255 accounts while the last account retains service. Physical feasibility remains correctly deferred to the mandatory DDL/oracle gate. |
| H6 global generation lets an unapproved provider starve approved reservations | The scoping model is corrected: per-provider generations and approved projections make unrelated churn invisible, and post-selection checks bind only the selected provider. M1 prevents the exact absent/collision token bytes from being considered fully frozen. |

## Informational observations

1. Subject to M1, R8 preserves selection before encryption: the coordinator selects from the buyer-approved intersection, and the client verifies the returned fingerprint before creating an ephemeral key, nonce, request ID, or ciphertext. Consume/final-arm remain selected-provider scoped; public send is at most once and ciphertext is never redirected or failed over.
2. Pin revocation is target-local and the C9 slot bijection no longer depends on retained bundle/profile references. Bundle upload intentionally requires an existing fingerprint target to match byte-for-byte and permanently forbids a revoked/reused fingerprint. This makes validity/model changes require a new identity fingerprint and fresh buyer approval; the operational identity-rotation burden should be called out in the eventual runbook, but it is not treated as a gate finding because the plan consistently makes that restriction explicit.
3. Pinned MacProvider still globally sorts `pool.Snapshot()` and selects the first serving/tunneled/model-matching provider in `phase4-coordinator/internal/buyer/relay_blind.go::selectRelayBlindProvider`; the pinned relay-blind store has no Build 2 profile, invitation, external witness, shard, or approved-set token authority. Pinned Malibu still uses `BASE = '/api/mp'`, retries selected ordinary-chat failures, inherits a public Vite proxy when preview is used, and has no browser-automation dependency. R8 correctly keeps these as planned work and requires an isolated no-retry private transport plus a TLS-loopback real-browser harness.
4. T-H01/T-H02 correctly require physical Apple Silicon, a supported cached artifact, real `ModelRuntime` tokenization/generation, an encrypted end-to-end request, streaming/cancellation, and ordinary settlement. Deterministic Swift fixtures and MLX selftests cannot satisfy actual-MLX acceptance. No actual-MLX evidence exists at this plan gate and none is claimed.

## Disposition and next gate

R8 does **not** satisfy the required zero Critical/High/Medium plan gate. No Product Build 2 SPEC, schema, vector, coordinator, gateway, Go client/CLI, Swift provider, or Malibu implementation is authorized from these bytes. R9 must close the two High and one Medium findings without weakening buyer-approved selection, durable local confirmation, rollback resistance, exact mutation recovery, revocation availability, tenant isolation, provider-scoped selection, no ciphertext retry/failover, provider-plaintext and response-relay disclosure, signed rejection-only refunds, ordinary settlement, browser evidence, or actual-MLX acceptance. The exact DDL/response-oracle/witness-backend/physical-measurement/error-inventory second gate remains mandatory after a future full-plan revision reaches zero Critical, High, and Medium findings.

## Review boundary

This was a code-grounded read-only plan review. It independently inspected the exact submitted R8 artifacts; pinned MacProvider selection and relay-blind store surfaces; pinned Malibu API, retry, proxy, and package surfaces; and local supported-macOS BSD `flock` behavior. No implementation, unit, integration, browser, MLX, deployed-service, or production test was run. No `d-inference` source, operator secret, private key, credential, deployment, release, production service, or economic state was accessed or changed.
