# Product Build 2 adversarial plan review

**Review revision:** 1  
**Reviewer:** independent native GPT-5.6 Sol, high reasoning  
**MacProvider review commit:** `6fd48066af4c052c77f41e8aedd2110a483d2bab`  
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`  
**Malibu read-only base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`  
**Plan SHA-256:** `c5a68ba5b275f969dad0010f547e866b5621d16846f8ad16c342d6cb7df09b53`  
**Test-spec SHA-256:** `cbb4c5a58eb3e9cec2dc0419ba2e998bd1a4d8626da4997573bf572b45a9e6a4`  
**Baseline SHA-256:** `be9131d12ef5974938adf8a4fe552362141fec53f97092f7c952fef2b20a6947`  
**Checkpoint SHA-256:** `a669aaf5bc3bdf9796faee452377fe6ff595b9044cdd7446710439ed5775435d`

## Verdict

**FAIL — implementation remains prohibited.**

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 4 |
| Medium | 4 |
| Low | 0 |
| Info | 0 |

The plan correctly keeps buyer approval subordinate to operator admission, requires acceptable-identity filtering before encryption, preserves provider plaintext disclosure, forbids ciphertext failover, separates fixture evidence from actual MLX evidence, and keeps verified-model/reward claims excluded. The findings below prevent the required zero-Critical/High/Medium gate.

## Findings

### H1 — The fresh-reservation status contract is impossible with the proposed evidence pair

**Severity:** High

**Evidence:** The plan records the envelope digest locally only after envelope construction and before the inference send, then says public status accepts only `provider_binding_digest` and `envelope_digest` and reports fresh `reserved` state (`prd-implementation-plan-r1.md:45-47`, `:163-169`). T-L07 requires one wrong digest to fail closed while fresh `reserved` remains queryable (`test-spec-r1.md:146-148`). At reservation time the coordinator has not seen an envelope; the current row stores `envelope_digest` only at consume (`phase4-coordinator/internal/relayblind/store.go:178-209`, `:454-496`). Current status therefore indexes by an already-bound envelope digest and cannot find a reserved row (`store.go:754-772`).

**Consequence:** No implementation can simultaneously prove that a caller supplied the correct envelope digest for a never-consumed reservation and reject a wrong digest. Ignoring the digest for `reserved` violates T-L07; requiring it makes crash-before-send recovery unable to report the required state. This also leaves the journal's safe action ambiguous at the most important send boundary.

**Required correction:** Choose and normatively freeze one coherent protocol. Either (a) make `reserved` status capability-authenticated by a reservation secret/binding and explicitly report the envelope as unbound without claiming to verify its digest, with state-specific negative tests, or (b) add a separate idempotent, non-dispatching envelope-bind transition durably recording the digest before the inference send. Define crash cuts before/after that transition, replay behavior, retention, and safe actions. Remove the contradictory wrong-envelope assertion for states in which the coordinator cannot possess an authoritative envelope digest.

### H2 — The cross-language trust-profile contract is not exact or numerically representable

**Severity:** High

**Evidence:** C1 says the digest uses a “new domain-separated binary framing” and “normative order,” but does not define the domain bytes, length encoding, integer width/endianness, string encoding, array framing, or route-specific mutation schemas (`prd-implementation-plan-r1.md:101-109`). It also leaves revision/time ceilings undefined. The existing Go pin parser accepts signed 64-bit Unix values, and coordinator authority deliberately constructs an internal pin with `math.MaxInt64` (`phase4-coordinator/internal/relayblind/crypto.go:404-419`; `authority.go:76-85`). JavaScript `Number` cannot exactly represent integers above 2^53-1. T-C01/T-C02 demand Go/JavaScript parity and “overflow” rejection but provide no normative boundary or BigInt/decimal-string rule (`test-spec-r1.md:38-44`).

**Consequence:** Go and Malibu can accept the same JSON yet hash different profile bytes, or the browser can silently round a valid Go value. The profile digest is the buyer-selection authority, so this is a trust-binding failure rather than a cosmetic interoperability defect. Slice 0 cannot be considered a reviewed normative contract while these bytes remain a future choice.

**Required correction:** Put the exact framing in the gated plan/spec before runtime work: domain bytes, field order, per-field type and maximum, length prefixes, byte order, string character set/normalization policy, pin/array framing, and exact digest input. Define every route's closed request and response fields. Cap all JSON numbers at a stated cross-runtime safe ceiling or require canonical decimal strings/BigInt parsing. Add shared positive and negative vectors at 2^53-1, 2^53, Int64 limits, time/revision maxima, empty/max arrays, duplicate keys, and alternate numeric spellings.

### H3 — The claimed atomic selection has no feasible pool/SQLite concurrency protocol

**Severity:** High

**Evidence:** C3 requires one `BEGIN IMMEDIATE` transaction to validate the profile, select the “current serving WebSocket candidates,” validate the key, and insert the reservation, with no response from a pre-transaction pool choice (`prd-implementation-plan-r1.md:120-132`). The current pool is an independent in-memory registry whose `Snapshot` copies state under its own mutex (`phase4-coordinator/internal/pool/provider.go:2906-2917`), while current selection takes that snapshot and performs separate store queries before `CreateReservation` (`phase4-coordinator/internal/buyer/relay_blind.go:207-222`, `:243-259`). The plan defines neither a pool generation/token nor lock ordering between the pool mutex and SQLite writer. T-S04/T-S05 ask for linearization barriers but do not state what event is the linearization point (`test-spec-r1.md:108-114`).

**Consequence:** Implementers must either hold the global pool lock while waiting on SQLite, risking liveness/deadlock and blocking heartbeats, or use a stale pre-transaction snapshot contrary to the plan's literal contract. Tests could pass a chosen interleaving without proving the production lock order or selection authority.

**Required correction:** Define the exact two-authority algorithm and lock order. A viable shape is a bounded pool snapshot containing immutable `(provider_id, assigned_session, model, routability, generation)` tuples, followed by a SQLite `BEGIN IMMEDIATE` intersection with the exact active profile and durable key rows, with no pool lock or network call held under the DB writer; then a bounded generation/session recheck before response and the existing consume/final-arm checks. Specify which transition linearizes buyer approval, which staleness is allowed, and how a failed post-commit pool recheck fences the row. Add deadlock/liveness, heartbeat churn, writer-busy, generation rollover, and cancellation tests.

### H4 — Profile invalidation is not joined to gateway quota and settlement recovery

**Severity:** High

**Evidence:** Replacement/revocation atomically rejects coordinator `reserved` and `consumed_predispatch` rows (`prd-implementation-plan-r1.md:38-43`, `:134-144`), while T-L01 merely says predispatch rows “burn and refund as applicable” (`test-spec-r1.md:122-124`). Gateway quota is a separate SQLite authority created after coordinator consume (`phase5-gateway/internal/router/relay_blind_success.go:175-213`) and its recovery hold is armed later (`:264-274`). Existing reconciliation refunds only after finding a gateway active reservation and obtaining a coordinator `rejected` status (`relay_blind_success.go:419-440`). The plan does not define the cross-store crash protocol, convergence bound, status retention dependency, or behavior when mutation invalidation happens before/after quota creation and settlement-hold arming.

**Consequence:** A profile mutation can leave quota held indefinitely, or a new implementation can refund too early while a concurrent final arm is still possible. Either outcome breaks the advertised safe recovery and ordinary settlement contract. A unit assertion that the coordinator row became `rejected` does not prove the buyer's economic state converged exactly once.

**Required correction:** Define the complete state table for mutation versus consume, account/wallet quota admission, settlement-hold arm, coordinator final arm, and gateway crash/restart. Require durable coordinator rejection retention through the maximum gateway reconciliation horizon and a gateway-owned idempotent reconciliation path that can discover every affected held row without a push notification. State bounded convergence/alert behavior and ensure only authoritative coordinator terminal rejection refunds. Add crash tests at each cross-store cut for API-key and wallet sessions, including duplicate reconciliation, store unavailability, and restart.

### M1 — Authenticated initial pin delivery remains an unowned prerequisite

**Severity:** Medium

**Evidence:** J1 starts with the buyer receiving pins through an unspecified authenticated channel and independently confirming fingerprints (`prd-implementation-plan-r1.md:18-24`). No implementation slice owns that channel or a signed/versioned public-bundle artifact. The existing runbook still requires manual delivery through a separate operator channel (`docs/runbooks/relay-blind-pilot-key-custody.md:11-18`). T-W02 begins at browser import and confirmation, so it cannot prove the intended A bundle was authentically delivered (`test-spec-r1.md:226-230`). Coordinator operator-map intersection prevents an arbitrary identity but does not stop substitution of another operator-approved provider identity.

**Consequence:** The proposed “supported” provisioning journey has a trust-critical manual gap. A substituted B pin can be valid to the coordinator and silently alter buyer-approved selection unless the missing independent fingerprint channel is real.

**Required correction:** Name the provisioning authority and artifact lifecycle. Define how a buyer obtains the exact public bundle and expected fingerprint, how signer/version/freshness/revocation are checked if the artifact is signed, and what remains an operator qualification blocker if delivery stays manual. Add substitution, stale bundle, cross-account invitation, rotation, and compromised-channel tests. Do not let coordinator profile reads become the trust bootstrap.

### M2 — Wallet status/recovery authentication is absent from the signed-route contract

**Severity:** Medium

**Evidence:** The plan allows a wallet session to use a provisioned profile and exposes a public status route (`prd-implementation-plan-r1.md:61`, `:112-118`, `:157-163`), but C3 and T-C05 specify semantic signing only for reservation profile headers (`:120-128`; `test-spec-r1.md:50-56`). Current wallet canonical route profiles include the reservation route but no relay-blind public status route (`phase5-gateway/internal/auth/wallet.go:370-377`). T-L07 mentions wrong sessions but does not require a canonical signed status body/route, request ID, or replay behavior (`test-spec-r1.md:146-148`).

**Consequence:** Wallet buyers can execute a request yet lack a specified authenticated recovery call, or implementation may add an ad hoc route whose body/headers are not protected consistently with SPEC-040.

**Required correction:** Define the canonical wallet status route and exact semantic/body digest binding, allowed headers, request-ID/replay rules, session/account checks, and mutation prohibition. Add positive and tamper tests for status body, route, account, session, timestamp, signature, duplicate headers, and replay.

### M3 — Required capacity and retention bounds have no normative values or dependencies

**Severity:** Medium

**Evidence:** C1 promises bounded profiles, pins, operations, revisions, and tombstone retention without defining limits or configuration validation (`prd-implementation-plan-r1.md:103-110`). T-P05 requires retention through “maximum pin/reservation/replay windows,” although pin expiry is not bounded in the proposed contract, and T-P06 asks to test unspecified maxima (`test-spec-r1.md:82-88`). The current identity-pin validator accepts any increasing signed-64-bit interval (`phase4-coordinator/internal/relayblind/crypto.go:404-419`).

**Consequence:** The store schema, purge queries, configuration, test fixtures, and denial-resistance acceptance cannot be implemented consistently. Premature pruning can revive an identifier or lose replay/idempotency evidence; unbounded retention can exhaust SQLite.

**Required correction:** Freeze positive maxima and retention equations for profiles/account, revisions/profile, pins, operation rows/bytes, tombstones, list pages, audit rows, and status/replay evidence. Bound buyer-pin validity or explicitly include its finite maximum in retention. Define fail-closed startup validation and behavior at each cap, then test exact boundary, over-boundary, pruning, restart, and clock-skew cases.

### M4 — Client/browser journal failure and multi-actor semantics are not defined

**Severity:** Medium

**Evidence:** C7 lists file protections and bounded JSONL storage but does not specify append/compaction atomicity, what happens at capacity, how a corrupt tail is handled, or whether failure before send is terminal (`prd-implementation-plan-r1.md:165-169`). T-G04 lists fault cases without expected state/action (`test-spec-r1.md:168-170`). Browser storage uses local storage with no cross-tab ownership/lease or compare-and-swap rule, while T-W04/T-W05 require reload recovery and one send (`test-spec-r1.md:236-242`).

**Consequence:** A full/corrupt journal can permit an unjournaled send or permanently suppress safe new work; two CLI processes or browser tabs can race transaction transitions and weaken the one-send evidence. Tests can exercise errors without proving fail-closed behavior.

**Required correction:** Define an explicit client transaction state machine and durable-write prerequisites. Failure to persist the pre-send record must prevent the inference send. Specify fsync/rename/compaction and corrupt-tail recovery, lock scope, capacity behavior, retention, and exact safe action after each failure. For Malibu, define tab ownership/lease or a single-writer CAS protocol and test double-click, two tabs, reload at every write/send cut, quota exhaustion, storage exceptions, and corrupted records.

## Required next gate

Revise both the PRD/implementation plan and paired test specification. The next independent review must receive the exact new digests and both repository revisions. Implementation remains prohibited until a fresh GPT-5.6 Sol review reports zero Critical, High, and Medium findings.

## Review method and evidence boundary

This was a read-only code-grounded review of the submitted artifacts and the stated MacProvider and Malibu revisions. It inspected coordinator pool selection, relay-blind durable state/status, gateway consume/quota/settlement recovery, wallet semantic-header routing, Malibu transport/retry/storage behavior, and the existing pin-custody runbook. No implementation or runtime acceptance test was performed, and no historical or fixture evidence was promoted.
