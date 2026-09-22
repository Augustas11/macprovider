# Product Build 4 plan revision v3 — independent adversarial review (Sol)

## Integrity and scope

- Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-4`
- Expected and observed `HEAD`: `1d2c930bad81704dd0acc0322226725d8b64aceb`
- Expected and observed merge base with `origin/main`: `1d2c930bad81704dd0acc0322226725d8b64aceb`
- `implementation-plan-v3.md` expected and observed SHA-256: `3329ea2d547338a68d8049fde4613fb7c37860aa40fb99b0c21b8c3eb67880eb`
- `test-spec-v3.md` expected and observed SHA-256: `b3c8485b035366aef24a5f540ff5f668079271fbd70bb82beba870b7958c4469`

This review assessed planning completeness only. It inspected the plan, test specification, current implementation and tests, `SPEC-002`, `SPEC-005`, `SPEC-008`, `SPEC-015`, `SPEC-021`, `SPEC-022`, `SPEC-036`, `SPEC-040`, `SPEC-041`, `SPEC-042`, `AUTHORITY.json`, and `CONFORMANCE.json`. It does not treat planned behavior as implemented and does not require implementation while the stated Build 2 and Build 3 dependencies remain unavailable.

## Disposition

**PASS.** Revision v3 closes the remaining v2 High and Medium planning findings and preserves the dependency gate. Phase A and source implementation remain blocked until accepted Build 2 identity/client contracts and Build 3 production-observation, stable-identity, and economics contracts are available, incorporated into the governing SPEC amendments, and re-reviewed.

## Closure assessment

### H1 — observation trust failures cannot settle as zero usage

**Severity:** Closed; no finding.

**Evidence:** The plan reserves `zero_settled` for authenticated zero-use outcomes and routes missing, invalid, stale, or unverifiable observation evidence to quarantine with no positive verification, reward, or payout. The money-state table covers capture, verification, deadline, and terminal-state behavior. The test specification exercises authenticated zero-use separately from trust failure, including restart and deadline paths. This matches the trust-failure quarantine rules in SPEC-022 and SPEC-036.

**Consequence:** Observation evidence cannot be converted into a benign zero-charge terminal state merely because the evidence needed to establish use is absent or untrusted.

**Required correction:** None.

### H2 — durable receipt verification material and revocation finality

**Severity:** Closed; no finding.

**Evidence:** The plan requires a durable `AcceptedReceiptKeySnapshotV1` captured at accepted request start. It contains the receipt-key authority and source, key identifier, raw Ed25519 public-key bytes, canonical authenticated source record or proof, record digest, generation, validity interval, revocation watermark, and retention deadline. Verification reauthenticates the captured source record, rederives the identifier and digest, binds it only to the immutable attempt and route, and forbids fallback to the provider payload, receipt payload, or live registry. Restart, rotation, expiry, live-key eviction, archive corruption, and archive unavailability are explicit cases. This closes the gap exposed by the current verifier, which receives raw public-key material separately, and by the current pool registry, which eventually evicts previous keys.

The routine/emergency revocation table is closed across the money and finality boundary: precommit routine or emergency revocation rejects before dispatch and refunds; routine rotation or expiry after commit uses the authenticated archived key; an emergency revocation effective before commit quarantines a still-nonterminal attempt even if learned later; an emergency action after a terminal decision cannot rewrite the first terminal result. Accepted governance must distinguish routine from emergency actions and provide authenticated monotonic effective times. The test specification covers all rows, races, restart behavior, corruption, and terminal finality.

**Consequence:** A receipt remains verifiable from immutable authenticated request-start evidence after rotation or live-registry eviction, while emergency revocation has deterministic precommit and postcommit financial behavior without retroactive terminal-state rewriting.

**Required correction:** None beyond landing the dependency-gated SPEC and authority contracts before implementation.

### H3 — dispatch linearization and authenticated cross-service recovery

**Severity:** Closed; no finding.

**Evidence:** The plan now separates the two authoritative boundaries. SPEC-041 consumption occurs before quota mutation. The gateway's serialized storage transaction owns quota and reservation mutation and creates the durable `dispatch_armed` cutoff required by SPEC-040. It then sends an authenticated, exact-binding, single-use `GatewayDispatchArmV1`. The coordinator authenticates the arm, verifies freshness and bindings, writes its durable outbox, performs the coordinator-owned final provider-generation and routeability fence, and commits the nonblocking enqueue. The gateway does not attempt to share or reproduce the coordinator fence. Lost arm/status messages, gateway and coordinator crashes, `dispatch_uncertain`, authenticated coordinator status, refund holds, and the prohibition on retrying provider dispatch are explicit. The test specification uses real gateway and coordinator stores and deterministic barriers around each boundary, including forged, stale, replayed, and mismatched arms.

This ordering agrees with SPEC-040's gateway `dispatch_armed` linearization rule, SPEC-041's consume-before-quota rule, and SPEC-042's requirement that the final provider-generation fence stay with the pool authority at dispatch.

**Consequence:** The plan has one gateway authorization cutoff and one coordinator dispatch fence, with authenticated recovery between them. No crash path relies on an ambiguous shared transaction, unverified status, or a second provider dispatch.

**Required correction:** None.

### M1 — observation digest producer and authenticated reconstruction

**Severity:** Closed; no finding.

**Evidence:** The plan assigns observation production to the coordinator/provider-session boundary, defines canonical authenticated capture and digest material, persists it before settlement use, and rejects reconstruction from mutable live state. The test specification includes tamper, substitution, replay, restart, and producer-authentication cases. The design is consistent with SPEC-036's immutable request-start composite and trust-failure behavior.

**Consequence:** Settlement inputs have a named producer and a reproducible authentication path instead of an unexplained digest field.

**Required correction:** None.

### M2 — migration and rollback closure

**Severity:** Closed; no finding.

**Evidence:** The plan supplies a staged compatibility/readiness matrix, explicit fail-closed conditions, versioned stores and records, mixed-version rejection, rollback prerequisites, and a rollback rule that does not reinterpret already-armed, uncertain, or terminal attempts. The test specification exercises upgrade, rollback, old-reader/new-writer, new-reader/old-writer, and retained-record cases.

**Consequence:** Rollout and rollback cannot silently erase evidence, broaden dispatch eligibility, or recompute money outcomes under a different contract.

**Required correction:** None.

### M3 — protected physical evidence contract

**Severity:** Closed; no finding.

**Evidence:** The plan defines signed physical-test evidence with bounded provenance, timestamps, identities, configuration and version facts, result digests, and verification rules. It distinguishes evidence required for acceptance from ordinary logs. The test specification includes protected-evidence verification for the two-Mac flow, recovery behavior, and timing assertions.

**Consequence:** Physical acceptance evidence is reviewable and tamper-evident rather than dependent on mutable operator logs.

**Required correction:** None.

### M4 — exhaustive mixed-version monotonicity

**Severity:** Closed; no finding.

**Evidence:** The plan defines four component capability bits—client, gateway, coordinator settlement backend, and provider session—and five store capability bits. Their Cartesian product has `2^(4+5) = 512` capability rows. Crossing each row with four cache states produces exactly 2,048 generated rows. Every row must be monotone: removing a required capability or making a relevant store/cache state older or uncertain may only preserve or reduce eligibility, never enable dispatch. The test specification generates the complete matrix and adds real integration cases for nonadjacent versions, three-old-component combinations, and mixed store/cache states.

**Consequence:** Compatibility evidence is not limited to adjacent-version examples and covers the combinations most likely to expose permissive fallback.

**Required correction:** None.

### M5 — bound retention policy, privacy conflicts, and tombstones

**Severity:** Closed; no finding.

**Evidence:** The plan binds each accepted attempt to a signed retention-policy identifier, version, and field/viewer matrix. It computes per-field minimum retention from replay defense, key verification, active and pending dispatch, reconciliation, disputes, accounting, and audit obligations. Admission is rejected before routeability when any required minimum exceeds the privacy maximum for any field/viewer pair. The matrix covers plaintext and ciphertext, acceptable sets, authenticated references, pool and manifest data, selected-provider data, receipt-key snapshots, observations, outbox/journal records, receipt/accounting records, and logs. Viewer classes are closed with default deny. Field/viewer transitions, exact maximum-deletion behavior, derived copies, indices, backups, and non-reconstructive tombstones are explicit. The test specification exercises every field/viewer pair, the unsatisfiable min/max case, time and rotation, restart, dispute, uncertainty, transition, erasure, and tombstone behavior.

This meets SPEC-042's requirement for a pool-bound field-level retention matrix while retaining SPEC-041's narrow privacy wording.

**Consequence:** Retention cannot drift independently of the accepted pool contract, and admission cannot create an attempt whose recovery obligations are incompatible with its promised privacy ceiling.

**Required correction:** None.

## Informational findings

### I1 — dependency gate is correctly non-bypassable

**Severity:** Informational.

**Evidence:** The plan identifies the exact accepted Build 2 and Build 3 inputs it needs, classifies current pool/scoped relay-blind behavior as partial, missing, or blocked, and prohibits Phase A and source work until those contracts are incorporated and a fresh review reaches zero Critical, High, and Medium findings. Current AUTHORITY and CONFORMANCE records still show relevant requirements as declared, pending, unknown, or decision-required rather than landed production authority.

**Consequence:** This PASS approves the revised plan's completeness; it does not authorize runtime activation or imply that dependency-owned contracts exist.

**Required correction:** None. Preserve the gate and repeat the review against the accepted dependency artifacts.

### I2 — current restrictions remain deliberate and consistent

**Severity:** Informational.

**Evidence:** The plan preserves current pool-request rejection, the settlement-enforcement restriction, and exclusion from positive verification, rewards, and payout. It keeps the privacy statement exact: request content is hidden from relays, the provider reads the request, and responses are visible to relays. It does not claim end-to-end confidentiality, response confidentiality, anonymity, or a v0.4 receipt amendment. These constraints agree with current gateway/coordinator rejection code and the governing SPEC boundaries.

**Consequence:** Planning approval cannot be read as permission to expose the unfinished path, weaken economic safeguards, or advertise a broader privacy property.

**Required correction:** None.

## Exact counts

- Critical: 0
- High: 0
- Medium: 0
- Low: 0
- Informational: 2

**PASS — C=0, H=0, M=0.**
