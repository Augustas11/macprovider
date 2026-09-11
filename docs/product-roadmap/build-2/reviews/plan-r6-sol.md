# Product Build 2 R6 adversarial plan review

**Review model:** native GPT-5.6 Sol, high reasoning

**Verdict:** FAIL — implementation remains prohibited

**Finding counts:** Critical 0, High 3, Medium 1, Low 0, Info 4

**Reviewed MacProvider commit:** `314781ce3ca46396b4ddde824236deea8b64c671`

**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`

**Reviewed Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Artifact identity

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r6.md` | `21018218a25cfa1f92a886599bf315bec019a1aad5434c1f8cd02e111bd449e2` |
| `test-spec-r6.md` | `4ec5f42c4c1478f83a864efff206e1b545bc7ee184361acc381a8ed6e6783996` |
| `finding-dispositions-r6.md` | `d28eab029df3658766adf1233b192fce6ff43fbdf6858f03b6e40e5ff33a4da9` |
| `checkpoint-r6.md` | `aefe4bc482776f5f9873a7dea71f771bfecda690da5e980d4d35be67bcb527f3` |
| failed predecessor `reviews/plan-r5-sol.md` | `00b9d3a808e734fbaf60d4c813091ca1b17fd7a5011734bdbb8f71509a02d93f` |

All submitted R6 bytes and revisions matched before review. The MacProvider worktree was clean at the reviewed commit. Malibu was inspected from the pinned git object without modifying its stale canonical checkout.

## High findings

### H1 — Exact profile-response replay cannot fit the fixed operation row

**Severity:** High

**Evidence:** A profile document includes every selected pin and its complete model list (`prd-implementation-plan-r6.md:182-203`). A bundle/profile may contain 16 pins, each with 16 model IDs, and framed strings may contain 128 printable ASCII bytes (`:151`, `:115-119`). The model strings alone can therefore occupy 32,768 response bytes before JSON structure, keys, fingerprints, public keys, endpoints, timestamps, or other profile fields. The terminal operation contract requires the exact success/error `response_body` to be stored and returned byte-for-byte on replay (`:207-211`; `test-spec-r6.md:68-70,96`). C9 nevertheless fixes every normal terminal operation row and each preallocated revoke-operation slot at no more than 1 KiB, with 4 MiB/account and 64 MiB/global operation storage (`prd-implementation-plan-r6.md:490-491`). T-P04 requires both the byte-identical replay and those physical limits (`test-spec-r6.md:74-78`).

**Consequence:** A valid maximum profile cannot produce the sealed terminal result that makes `sent_or_unknown` recovery executable. Truncation or regeneration would violate byte-identical replay; overflow storage would violate the reviewed 1 KiB and physical-cap proof. At the global count, storing permitted responses can also exceed the claimed 64 MiB operation budget by orders of magnitude. The mandatory sizing gate would necessarily fail or force an unreviewed architecture/contract change.

**Required correction:** Freeze a response-storage design that accommodates the actual maximum closed response. Either enlarge and remeasure every normal/fixed operation slot and database ceiling, or atomically retain an immutable exact response blob with a bounded authenticated reference whose lifetime and pruning are tied to the operation/profile evidence. Recompute per-account/global/page/WAL/disk inequalities and test maximum success and maximum v2 error replay through create, replace, and revoke, including normal-capacity emergency revoke. This changes C3/C9 storage and requires a new full plan gate before the sizing slice.

### H2 — Two supported state roots can fork the single Keychain head

**Severity:** High

**Evidence:** C8A permits any absolute state-root override and places `private.lock` inside that root (`prd-implementation-plan-r6.md:433-437`). C8B derives the bootstrap, HMAC, and head Keychain selectors only from authority, origin, and account subject; no canonical root identity participates (`:445`). Head publication is an unconditional Keychain replacement followed by readback (`:451`), not a compare-and-swap against the prior external-head digest. Two valid roots copied from one authenticated generation therefore have different lock files but the same Keychain items. Both can read head H; process A can replace/read back H-A, then process B can replace/read back divergent H-B using H as its recorded predecessor. Each accepted its own readback even though H-A is now orphaned. T-G02/T-G03 test one root's process and object races but contain no two-valid-root clone/fork vector (`test-spec-r6.md:184-198`).

**Consequence:** The external head is not a single-writer rollback anchor under the supported override contract. A locally fenced request or confirmed profile can be accepted, followed by a divergent replacement that makes its files unrecoverable. This can turn an already-sent private transaction into local quarantine with no usable journal lineage and defeats the claimed whole-file rollback/fork protection. The same race can occur without violating either root-local lock.

**Required correction:** Establish one root-independent serialization/CAS authority per `(origin, account_subject, authority)` or bind and enforce one canonical root identity before any authority can load. A later valid root must observe the current head and either have its exact named object set or quarantine; it must never overwrite from a stale predecessor. Define clone/move/override migration semantics and add two-root interleavings around bootstrap, append, profile `sent_or_unknown`, request `send_fenced`, Keychain completion/readback, retirement, restart, and compaction. Prove one accepted successor for a prior head and preserve the no-resend/recovery guarantees.

### H3 — The maximum-live-target normal-saturation proof is unreachable

**Severity:** High

**Evidence:** R6 allocates exactly one unsealed emergency slot to each of the maximum 45,064 live signer, bundle, profile, and pin targets (`prd-implementation-plan-r6.md:496,500-504`). A committed tombstone is a revocation of one of those target kinds and invalidates its target (`:166,270-279`). T-P04 first activates the exact maximum live set and consumes all 45,064 target-bound slots, then requires 65,536 normal tombstones, and only afterward requires every live target to be revoked into its emergency slot (`test-spec-r6.md:80`). Valid normal tombstones against that set would revoke targets, so the set would no longer be live for the emergency phase. No unsealed target slot remains to activate unrelated temporary targets. The plan neither defines revoking nonexistent/already-revoked targets as a valid tombstone nor allows early reuse of sealed target slots; doing either would change authority and denial-of-service semantics (`prd-implementation-plan-r6.md:500-506`).

**Consequence:** The test cannot reach the state from which it claims to prove the R5 H5 correction. The plan therefore has no executable evidence that every maximum reachable live target remains revocable once normal capacity is genuinely full. Implementers would have to admit semantically meaningless tombstones, weaken live-target maxima, reuse protected slots early, or alter retention/capacity after the gate.

**Required correction:** Give an exact supported-event history that reaches normal saturation while preserving the maximum live set and every reference/retention invariant, or redesign the partition/cap inequalities so that the maximum retained normal history and maximum live target set are jointly reachable by construction. Define duplicate, nonexistent, historical, and already-revoked target behavior explicitly. The revised test must enumerate every activation/revocation/prune/clock step, show which target owns every slot at each boundary, and then revoke all still-live targets without allocation or early reuse.

## Medium findings

### M1 — The Keychain anchor is not byte-exact or policy-exact

**Severity:** Medium

**Evidence:** The bootstrap and external-head objects both contain `account_scope_digest`, but R6 never defines its domain or construction; the only nearby formula defines the Keychain account selector string (`prd-implementation-plan-r6.md:445-447`). The same section requires generic-password items with “application-specific access control” and later quarantines a “wrong ACL,” but it does not name the accessibility class, access-control flags/trusted-application policy, access group, authentication-UI behavior, or the exact attributes compared on readback (`:445-451`). T-C02 requires cross-runtime exact bytes and T-G02 requires wrong-ACL rejection without supplying an expected digest/ACL oracle (`test-spec-r6.md:26-28,184-190`).

**Consequence:** The Go implementation and fixtures must invent security-sensitive anchor bytes and Keychain policy after this gate. Different accessibility or interactive policies materially change unattended CLI behavior and which local processes can read/update the rollback anchor; the stated negative test cannot distinguish conforming from nonconforming metadata.

**Required correction:** Define `account_scope_digest` exactly, including domain, input encodings, and base64/binary representation. Freeze the complete Security.framework add/query/update dictionaries and accepted readback attributes for all three item kinds, including accessibility, synchronizability, access-control/trusted-application policy, access group, and authentication UI/context behavior. Add fresh/add/read/update/wrong-policy vectors and state how upgrades from an older accepted policy proceed without treating replacement as freshness.

## R5 correction verification

| R5 finding | R6 result |
|---|---|
| H1 sent-or-unknown recovery | R6 defines exact mutation replay and a sealed terminal operation result, but H1 above makes that result unrepresentable for a valid maximum profile. The correction is not closed as a whole. |
| H2 fresh external-head bootstrap | The original missing-fresh-bootstrap issue is corrected by the creation-only bootstrap state machine and crash matrix (`prd-implementation-plan-r6.md:447-451`; `test-spec-r6.md:188-190`). H2 above is a distinct multi-root fork in that authority. |
| H3 pointer/head contradiction | Corrected: every append publishes a pointer, binds both prior digests, readbacks the new head, and retires the predecessor only after a successful load; the tests cover old/new publication and retirement cuts (`prd-implementation-plan-r6.md:441,451-453`; `test-spec-r6.md:196-198`). |
| H4 browser two-kind ledger | Corrected: paired allocation, per-kind GET/CAS, dual-expectation list/delete, fixed DELETE capacity, and legacy one-kind cleanup are closed and tested (`prd-implementation-plan-r6.md:455-473`; `test-spec-r6.md:210-214`). |
| H5 emergency revocation coverage | R6 allocates one typed slot per maximum target, but H3 above shows the required simultaneous normal-saturation proof is not reachable. The correction is not closed. |
| M1 exact error callsites | Correctly deferred behind a mandatory second zero-C/H/M gate that receives the complete generated inventory bytes/digest before any error-facing implementation (`prd-implementation-plan-r6.md:650-654,670-674`; `test-spec-r6.md:54-56`). |
| M2 checkpoint authentication | Corrected with exact fields, framing, digest/signature domains, dedicated Ed25519 key authority, rollover, suffix, and corruption rules (`prd-implementation-plan-r6.md:281-287`). |
| M3 late Keychain completion | Corrected: five seconds limits acquisition/admission, while the held lock outlives a noncancellable call through exact old/new readback; tests cover completion on both sides of the alert (`prd-implementation-plan-r6.md:435,451`; `test-spec-r6.md:188`). |

## Informational observations

1. The pinned coordinator still chooses the first eligible provider from a globally sorted `pool.Snapshot()` in `internal/buyer/relay_blind.go::selectRelayBlindProvider`; it has no buyer-profile intersection. This independently confirms that acceptable-identity selection remains planned work rather than landed behavior.
2. Subject to the findings above, C5's profile-first double collection, client verification before envelope creation, exact-session final arm, and conservative postdispatch state preserve the intended selection-before-encryption and no-ciphertext-failover boundaries. The barrier suite exercises the relevant profile/key/session/pool races.
3. Pinned Malibu still uses `/api/mp`, and `console/api.js::fetchChatCompletions` retries selected 502/503 and retryable 500 responses. Its package has Vite 8.0.16 and no browser automation dependency. The separate no-retry private transport and isolated HTTPS browser harness remain necessary and are honestly specified.
4. Actual MLX acceptance is kept distinct from deterministic Swift and browser fixtures. T-H01/T-H02 require real `ModelRuntime` tokenization/generation on physical Apple Silicon, record bounded artifact/hardware context, and leave missing hardware/artifact evidence blocked rather than passed.

## Disposition and next gate

R6 does **not** satisfy the required zero Critical/High/Medium plan gate. No Product Build 2 runtime, SPEC, schema, fixture, CLI, or Malibu implementation is authorized from these bytes. R7 must correct all four findings without weakening buyer-approved selection, local authority, exact mutation recovery, capacity bounds, lifecycle rechecks, signed rejection-only refunds, provider-plaintext disclosure, response-relay visibility, no ciphertext retry/failover, browser evidence, or actual-MLX acceptance. The DDL/measurement and exact error-inventory follow-up gate remains mandatory after a future full-plan gate reaches zero.

## Review boundary

This was a code-grounded read-only plan review. It independently inspected the exact submitted artifacts; pinned MacProvider relay-blind selection, pool snapshot, gateway recovery/error, configuration, and SPEC-041 surfaces; and pinned Malibu package, Vite proxy, credential storage, and ordinary chat retry implementation. No implementation, unit, integration, browser, MLX, deployed-service, or production test was run. No `d-inference` source, operator secret, private key, or credential was inspected. No deployment, release, production mutation, or economic activation occurred.
