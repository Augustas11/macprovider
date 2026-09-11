# Product Build 2 adversarial plan review

**Review revision:** 2  
**Reviewer:** independent native GPT-5.6 Sol, high reasoning  
**MacProvider review commit:** `65b4c241b0dc52aa12a57d132062e2601a129de1`  
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`  
**Malibu read-only base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`  
**Plan SHA-256:** `b08d9c8e4b38225c21ad96c22266f9ac818ae59cd8ee7e90f775e027b949b5ce`  
**Test-spec SHA-256:** `82368bc0b8fd35d256dcbdd2727b1e0f0a155134a12f076cd4329c2f79c2ceeb`  
**Baseline SHA-256:** `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3`  
**Failed predecessor review SHA-256:** `a0e377960943cac3cdfb17a9d61e49d72f8a1f1d03b3575050dcc9dda623ca49`

## Verdict

**FAIL — implementation remains prohibited.**

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 6 |
| Medium | 4 |
| Low | 0 |
| Info | 0 |

R2 materially improves the prior submission. It makes an unconsumed reservation explicitly envelope-unbound, specifies a viable bounded pool/SQLite double collect without overlapping locks, adds a dedicated signed-bundle and account-invitation bootstrap, covers the wallet status route in the signing profile, joins quota/session recovery durably, and separates deterministic fixtures from actual MLX evidence. Those parts should be retained. The findings below prevent the required zero-Critical/High/Medium gate.

## Findings

### H1 — The supposedly closed cross-runtime schemas contain incompatible null and locator rules

**Severity:** High

**Evidence:** C1 says every new JSON object rejects null fields except the v2 request's nullable `envelope_digest` (`prd-implementation-plan-r2.md:97-103`). C3 nevertheless requires a nullable list `next_cursor` (`:168-172`), and C7 requires nullable `input_tokens` and `completion_tokens` in a new v2 response (`:228-236`). T-C01 then applies the universal null rejection to every new schema (`test-spec-r2.md:19-21`). Separately, C7 defines `provider_binding_digest` as SHA-256 of “the 32-byte random provider-binding string bytes” (`prd-implementation-plan-r2.md:230`), which does not say whether the input is `decoded_32(provider_binding)` or the 43 ASCII bytes of its canonical base64url representation. The current gateway hashes the representation bytes (`phase5-gateway/internal/router/relay_blind_success.go:195-197` in the reviewed base), so that ambiguity is already interoperability-sensitive.

**Consequence:** Go, Swift, and JavaScript cannot all implement both the universal null rule and the required nullable fields. They can also compute different status capabilities from the same reservation. A client that chooses decoded bytes cannot locate the row created by a server that preserves the current ASCII-byte behavior, breaking the only safe recovery path after the send fence.

**Required correction:** Replace the universal null sentence with an exact per-schema presence/nullability table, including whether nullable fields are present as null or omitted. Define the status digest input with literal framing, for example `SHA256(ASCII(canonical_provider_binding))` if compatibility is intended, and add exact Go/Swift/JavaScript locator vectors plus null/absent/wrong-type vectors for every response and request.

### H2 — No durable local authority preserves the buyer's confirmed profile across restart or reload

**Severity:** High

**Evidence:** J1 correctly forbids a fresh client from enabling encryption from a server profile GET alone (`prd-implementation-plan-r2.md:21-29`). Ordinary bundle/invitation/signer-window expiry does not revoke an already activated profile (`:131-135`), so the supported client must preserve evidence of the earlier local confirmation after those activation artifacts expire. C8 defines only a per-request send journal and its prohibited fields (`:238-248`); it does not define a local confirmed-profile store, its exact record, account binding, signer/bundle proof, update/revocation behavior, concurrency, corruption handling, or secure deletion. T-G01 and T-W01 test initial activation and reject GET-only bootstrap, but neither defines restart/reload continuity of a previously confirmed profile (`test-spec-r2.md:145-147`, `:163-165`). At the pinned Malibu revision there is no private trust store at all; `console/api.js` only has ordinary local-storage state and the retrying plaintext transport.

**Consequence:** After a CLI restart or browser reload, an implementation must either trust the coordinator profile read, violating the no-TOFU boundary, require repeated approval indefinitely, or disable a still-valid profile as soon as its one-time invitation/bundle activation window is unavailable. The advertised supported browser and CLI journeys therefore have no implementable continuity contract.

**Required correction:** Define a separate durable local confirmed-profile authority for Go and Malibu. Freeze its closed schema and account/origin binding, exact signed bundle and selected-pin evidence, profile revision/digest, generation/CAS rules, filesystem or IndexedDB ownership, cap/retention, corruption and clearing behavior, and replace/revoke synchronization. Require restart, reload, cross-account, rollback, tamper, stale-server-profile, signer emergency-revocation, and activation-artifact-expiry tests proving server reads synchronize but never bootstrap trust.

### H3 — Economic refunds depend on an “authenticated” coordinator response with no authentication contract

**Severity:** High

**Evidence:** C6 permits an exactly-once account/wallet refund only from an “authenticated” coordinator rejection (`prd-implementation-plan-r2.md:209-224`), but neither C6 nor C7 defines response authentication, channel identity, response signing, replay binding, or the production configuration invariant that supplies it. The v2 response itself has no request nonce, account/session binding, request digest, signature, or MAC (`:228-236`). In the reviewed gateway, the bearer authenticates the gateway to the coordinator, not the response to the gateway (`phase5-gateway/internal/router/relay_blind_success.go:75-91`), and configuration validation accepts any absolute coordinator URL, including non-loopback HTTP (`phase5-gateway/internal/config/config.go:583-587`, `:1124-1129`).

**Consequence:** A misrouted or unauthenticated upstream can forge `rejected` plus `dispatch_proven_absent` and reopen account and wallet budget after work may have dispatched. Tests using an `httptest` server would prove parsing and state transitions without proving the trust boundary that authorizes a monetary refund.

**Required correction:** Normatively choose the authentication authority. Require either a response proof bound to request/account/session/status evidence or a precisely constrained authenticated channel, such as verified HTTPS service identity with production rejection of remote plaintext HTTP and explicitly bounded loopback-only development exceptions. Bind responses against replay/mix-up, define key/CA rotation and outage behavior, and test wrong server identity, redirected/misrouted origin, plaintext remote URL, stale/replayed response, wrong account/session/request, and valid local fixture exceptions. No refund test passes unless this authority is exercised.

### H4 — The client journal has no exact record schema or state-specific recovery locator

**Severity:** High

**Evidence:** C8 names logical states and storage mechanics but never defines the closed JSONL/IndexedDB record fields, transaction identifier, version, generation transition rule, per-state required fields, canonical request digest, or record authentication/rollback chain (`prd-implementation-plan-r2.md:238-248`). It says only `send_fenced` stores both digests. A crash in `reservation_received_unbound` or `envelope_built` still requires a durable `provider_binding_digest`, and after envelope construction also requires the exact `envelope_digest`, to use C7 safely; raw bindings and ciphertext are intentionally prohibited. T-C01 claims every journal schema is closed, while T-G02/G03 and T-W02 require schema, rollback, reload, and crash verdicts that the plan has not specified (`test-spec-r2.md:19-21`, `:149-155`, `:167-169`).

**Consequence:** Independent Go and browser implementations can persist different evidence, accept rollback differently, or reach a crash state with no valid status locator. Tests can exercise storage failures without proving that every pre-send and post-send cut has the data required for the mandated action. A missing locator may push a client toward unsafe resend or permanent unexplained quarantine.

**Required correction:** Freeze versioned record schemas and a state/field/action matrix. At minimum define the CSPRNG transaction ID, account/profile/request binding, provider-binding digest at reservation receipt, envelope digest at build, monotonic generation/predecessor integrity, state owner semantics, timestamps, terminal result class, canonical serialization, and exact prohibited data. Specify atomic transition and compaction behavior for every state and add shared state-machine vectors plus crash/reopen tests proving status is possible whenever promised and old ciphertext is never authorized again.

### H5 — The hard-cap contract cannot preserve the promised emergency revocation and recovery writes

**Severity:** High

**Evidence:** C9 declares hard totals such as 4,096 mutation rows/4 MiB and 8,192 audit rows/8 MiB per account, says every required audit must commit, and also promises that revocation/status/recovery remain available “through reserved emergency capacity” at a hard cap (`prd-implementation-plan-r2.md:250-270`). It never assigns a size to that reserve, says which rows may use it, or states the lower normal-admission threshold. T-P04 asks tests to fill the exact published totals and then prove emergency operations still work (`test-spec-r2.md:61-63`). Retention forbids deleting still-required rows merely to create room.

**Consequence:** If normal mutations can consume all 8,192 audit rows or all 4 MiB, a required revocation audit cannot be written; failing it violates emergency availability, while committing it violates the cap. An implementer cannot satisfy the exact-boundary test without inventing an unreviewed secondary table or hidden overage.

**Required correction:** Define total physical ceilings and explicit normal/emergency partitions for each operation, audit, invitation, tombstone, and recovery table. State which operations consume each reserve, whether an operation can atomically replace eligible evidence, and what happens when the emergency partition itself is full. Test `normal_limit-1`, normal limit, each emergency slot, emergency exhaustion, restart, and retained-reference cases without exceeding the advertised total.

### H6 — Signed wallet status can exhaust replay authority before recovery is complete

**Severity:** High

**Evidence:** C4 requires every wallet status poll to use a new request ID and create a `metadata_only` replay row (`prd-implementation-plan-r2.md:184-186`). C9 promises status/recovery availability but does not include the inherited wallet per-session replay-row/byte caps or any inequality between poll rate, session lifetime, and recovery needs (`:250-270`). SPEC-040 requires the metadata replay ceiling to fail closed and forbids pruning live replay protection (`specs/SPEC-040-wallet-native-buyer-sessions.md:197-212`). Current configuration exposes independently configurable replay row/byte caps and only validates that they are positive (`phase5-gateway/internal/config/config.go:83-107`, `:882-886`); the store rejects a fresh metadata request at the ceiling (`phase5-gateway/internal/storage/sqlite/store.go:2313-2328`). T-C05 tests successful signed polling, and T-Q05 tests coordinator/gateway background convergence, but no test proves that a wallet buyer retains a usable signed status path at replay capacity (`test-spec-r2.md:37-41`, `:135-137`).

**Consequence:** A valid wallet session can consume its replay budget through required status polling and then lose the only buyer-visible recovery action while the request remains held or unknown. Returning a capacity error is safe for replay protection but contradicts the product's actionable recovery promise and can induce manual resubmission.

**Required correction:** Compose Build 2 status polling with SPEC-040 replay capacity explicitly. Define a bounded reserved status partition or another replay-safe status authorization that cannot consume inference replay protection, include it in startup inequalities and retention, and specify behavior at its own exhaustion. Test restrictive valid configurations, maximum-rate polling, long held/unknown states, expiry/revocation, restart, duplicate/mismatched request IDs, and continued inference replay protection.

### M1 — The profile reservation caps are ordered so one published boundary is unreachable

**Severity:** Medium

**Evidence:** Profiles are account-owned and every lookup is account-scoped (`prd-implementation-plan-r2.md:147-172`), yet C9 permits only 512 live profile reservations per account and 2,048 per profile (`:262`). T-P04 requires exact and over-boundary tests for both (`test-spec-r2.md:61-63`). One account-owned profile cannot reach 2,048 live reservations without crossing the account's 512 limit first.

**Consequence:** The 2,048/profile claim cannot be exercised, and implementations may disagree whether the effective limit is 512, 2,048, or a different aggregate scope. Capacity errors and denial-resistance evidence will not match the normative table.

**Required correction:** Make every nested limit reachable, normally by setting the per-profile limit at or below the per-account limit, or redefine the scopes with a concrete ownership model. Add independent exact-boundary tests that do not disable or bypass the other limit.

### M2 — The 300-second recovery convergence claim omits work-duration and scheduler bounds

**Severity:** Medium

**Evidence:** C6 derives a 300-second visit bound from 1,000 rows, batch 100, and interval at most 30 seconds (`prd-implementation-plan-r2.md:224-226`). It does not define whether the interval is measured from pass start or completion, coordinator status timeout, per-row concurrency, transaction timeout, failed-row cost, or whether a stuck pass blocks the next batch. T-Q05 advances a fake clock and repeats the arithmetic but does not require real bounded calls or scheduler semantics (`test-spec-r2.md:135-137`).

**Consequence:** Ten batches can take far longer than 300 seconds under ordinary coordinator latency while tests still pass instantly. The stated alert and evidence-retention inequalities therefore do not prove the advertised recovery service level or oldest-first progress.

**Required correction:** Define pass scheduling, maximum coordinator-call and transaction durations, bounded concurrency, cancellation, and progress after per-row failure. Express the visit bound including work time, update the startup inequality, and test slow/time-out/unavailable coordinator responses with a real scheduler as well as fake-clock retention.

### M3 — The typed error contract is deferred past the plan gate

**Severity:** Medium

**Evidence:** Section 6 says the exact gateway/coordinator/client inventory will be frozen in SPEC-041 later and lists only categories and possible actions (`prd-implementation-plan-r2.md:272-276`). It does not supply the code-to-HTTP/phase/retry/action table that T-C06 says must be identical across coordinator, gateway, Go, and Malibu (`test-spec-r2.md:43-45`). Error precedence controls whether a client may create new work after failure, so it is part of the recovery contract rather than routine wording.

**Consequence:** Slice 0 must invent behavior that can materially change resend safety and user recovery after this plan has supposedly passed. Completeness tests have no approved expected table, and independently developed clients can map the same failure to incompatible actions.

**Required correction:** Put the full versioned error matrix in the next gated plan/test revision, including exact origin layer, HTTP status, phase, retryable bit, action, precedence, disabled/mixed-version behavior, and unknown-error mapping before and after `send_fenced`. Shared fixtures must consume that matrix.

### M4 — The Go journal pathname contract does not yet prove safe ancestry and replacement handling

**Severity:** Medium

**Evidence:** C8 requires a private absolute path, 0700 ancestry, a no-follow regular 0600 lock file, and a no-follow append file (`prd-implementation-plan-r2.md:242-244`). It does not require descriptor-relative no-follow traversal of every ancestor, owner checks, link-count checks, or a stable device/inode identity across lock acquisition, reopen, append, and compaction. T-G02 nevertheless asks for owner, hardlink, ancestor symlink, and replacement-after-open rejection (`test-spec-r2.md:149-151`). The current SPEC-041 pin contract already demonstrates the stronger descriptor-walk pattern required for hostile pathnames (`specs/SPEC-041-relay-blind-request-encryption.md:112`).

**Consequence:** A pathname implementation can pass final-component `O_NOFOLLOW` and mode checks while traversing a swapped/symlinked ancestor or writing through a hardlink. That can expose recovery metadata or let another local actor replace journal authority between validation and append.

**Required correction:** Adopt an exact descriptor-relative ancestry walk and identity contract: acceptable owners, mode/sticky exceptions, `openat`/no-follow rules, retained directory descriptors, `st_nlink`, device/inode recapture points, lock/data ordering, rename validation, and failure behavior. Align the tests with each required check on macOS and document unsupported-platform behavior.

## Prior-finding disposition

| R1 finding | R2 review disposition |
|---|---|
| H1 reserved-status evidence pair | Partially corrected. State-aware unbound behavior is coherent, but H1/H4 above leave the exact locator and persisted recovery evidence incomplete. |
| H2 cross-language framing/range | Partially corrected. Binary framing and the safe-integer ceiling are substantially specified, but H1 contains incompatible nullability and ambiguous status digest bytes. |
| H3 pool/SQLite concurrency | Corrected for plan purposes. The bounded epoch/generation double collect, lock order, lifecycle rechecks, and conservative post-D2 behavior are feasible and testable. |
| H4 profile invalidation/quota recovery | Partially corrected. The durable join and rejection-only refund state table are sound, but H3, H5, H6, and M2 leave refund authority and recovery availability unproven. |
| M1 authenticated initial delivery | Corrected for plan purposes. The dedicated keyring, immutable signed bundle, account-scoped invitation, and explicit production signer qualification gate prevent coordinator-profile TOFU. |
| M2 wallet status signing | Partially corrected. The route/body/header signature is exact, but H6 leaves status unavailable at inherited replay capacity. |
| M3 capacities/retention | Partially corrected. Positive values now exist, but H5, H6, M1, and M2 contain infeasible or incomplete capacity/convergence claims. |
| M4 journal actors/failures | Partially corrected. Send fencing and no-takeover behavior are sound, but H2/H4/M4 leave local trust persistence, exact records, and filesystem authority incomplete. |

## Required next gate

Revise the PRD/implementation plan and paired test specification without weakening the pool double-collect, no-TOFU bundle, provider-plaintext disclosure, no-ciphertext-failover, rejection-only refund, or actual-MLX evidence requirements. The next independent GPT-5.6 Sol review must receive exact new hashes, both repository revisions, this review, and the predecessor review. Implementation remains prohibited until a fresh review reports zero Critical, High, and Medium findings.

## Review method and evidence boundary

This was a code-grounded, read-only review of the exact submitted artifacts and pinned revisions. It independently inspected the current relay-blind reservation/consume/status and refund flow, coordinator URL validation, wallet semantic-route and metadata replay contracts, SQLite replay ceilings, SPEC-041 pin/status rules, and the pinned Malibu retry transport. No implementation, runtime, browser, fixture, MLX, deployed-service, or production test was performed or promoted.
