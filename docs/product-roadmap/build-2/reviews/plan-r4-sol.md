# Product Build 2 R4 adversarial plan review

**Review model:** native GPT-5.6 Sol, high reasoning
**Verdict:** FAIL — implementation remains prohibited
**Finding counts:** Critical 0, High 5, Medium 4, Low 0, Info 3
**Reviewed MacProvider commit:** `6da243a214eee806b0a0c73c7808bb8e949ebf8f`
**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Reviewed Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Artifact identity

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r4.md` | `e5b4cb2c8e4331592f74584fa786fee03aaa491338c4da6fb2bde14ca6634ea2` |
| `test-spec-r4.md` | `5ea48c45e856501876c0788709a67a7dbcbbbc81c0709265ef4f12cc5e5fd929` |
| `finding-dispositions-r4.md` | `bdd69d39d3df16c5dd364ccffdf5fc79b02b0029fe230e84df7266b09dae2e5d` |
| failed predecessor `reviews/plan-r3-sol.md` | `4a2148bce95b74f8f5ad856edf66637d4fa95811fd4c25439a638fe528a924e7` |

All supplied bytes and revisions matched before review. The MacProvider worktree was clean at the reviewed commit. Malibu was inspected from the pinned git object without modifying its stale canonical checkout.

## High findings

### H1 — The local authority cannot represent a profile create in progress

**Severity:** High

**Evidence:** C3A requires every pending record's common authority fields to equal an expected stable predecessor, requires `expected_state` to equal that predecessor, and permits cancellation by reconstructing that predecessor (`prd-implementation-plan-r4.md:227-244`). A first profile creation has no stable predecessor, but the plan also requires the complete pending record before *every* mutation request (`:244`). The common record has no absent/genesis profile-authority form, and the closed `pending_mutation` object makes `expected_state`, `expected_revision`, and `expected_profile_digest` unconditionally present. T-P07 only applies the crash matrix to replace and revoke (`test-spec-r4.md:91`); the CLI black-box create case does not prove create crash recovery (`:191-193`).

**Consequence:** A conforming client cannot durably fence the first create request. If it sends without a representable pending record, response loss can consume the invitation and create the server profile while leaving no locally trusted material from which to reconcile. Trusting profile GET would violate the explicit no-bootstrap rule.

**Required correction:** Define a closed genesis/create-pending form with a tagged absent predecessor, exact common-field and framing rules, cancellation semantics, target evidence, generation/predecessor behavior, capacity charge, and stable-success transition. Extend T-P07 across every create cut: pending write/readback, disposition fence, request, server commit, response loss, local stable append, restart, invitation consumption, and concurrent same-profile creation. Recovery must use only the locally persisted verified target.

### H2 — Mutable tails and old pointers are not anchored by the compaction root

**Severity:** High

**Evidence:** C8B's manifest authenticates only the immutable base, while normal records append to a tail that is not length-, digest-, or head-bound by `CURRENT` or the manifest (`prd-implementation-plan-r4.md:410-418`). Loading merely validates the records still present. Replacing a tail with any earlier authenticated newline prefix therefore passes record MAC and per-key predecessor validation. Likewise, while an old complete generation remains before retirement, restoring only an older valid `CURRENT` makes recovery trust it and delete the newer generation as unreferenced. These are partial rollbacks, yet C3A claims fail-closed detection of partial rollback (`:246`); the only excluded case is coherent rollback of the pointer, all generation files, and same-user credentials together (`:418`). T-G03 asks the resulting root to prove rollback behavior but has no external expected tail head or pointer generation against which to detect either case (`test-spec-r4.md:185-189`).

**Consequence:** A valid prefix can remove `send_fenced`, pending mutation, terminal, or newer revocation-watermark records without detection by the claimed local authority. The request reopen rule remains conservative, but profile mutation state and the stated corruption/rollback guarantee are false, and tests can pass without proving the advertised root.

**Required correction:** Root every committed append and pointer advance in an independently durable authenticated head whose expected generation cannot be recovered solely from the roll-backable data it protects. Freeze its CAS/publication, fsync, keychain/credential, recovery, and retirement rules and the exact rollback claim. Add tail-prefix, pointer-only, old-generation-retained, head/pointer mismatch, and every publication crash vector for both authorities. Define an equivalent canonical byte/root protocol for IndexedDB rather than referring generically to the file schemas.

### H3 — The revocation log has no valid empty-state contract

**Severity:** High

**Evidence:** C3B says tombstone generation starts at 1 and advances once per committed tombstone, with generation 1 using an all-zero predecessor root (`prd-implementation-plan-r4.md:252-258`). It never defines the signed `revocation_generation` and `revocation_root_digest` returned by a fresh installation with zero tombstones. C3A simultaneously says local generation zero is valid only before the first successful preflight (`:223`), and every private transaction requires a successful preflight (`:250`). If empty state returns zero, the record remains in the state declared to mean no successful preflight; if it returns one, there is no defined empty root and the first tombstone transition is ambiguous. The supposedly canonical per-kind `target_digest` is also described only in prose, without domains or exact frames for signer, bundle, profile/account/revision, and pin targets (`:256`).

**Consequence:** A clean deployment cannot produce an unambiguous first valid preflight, and independent implementations can construct different first roots or target digests. Since fresh reservation is gated on this proof, the supported journey can be unavailable from genesis; a divergent root also strands clients at key rotation or revocation.

**Required correction:** Freeze one exact signed empty-log state, its generation/root bytes, and the first and subsequent tombstone transitions. Define domain-separated frames for every tombstone kind, including the exact account identifier and revision encoding. Add shared genesis, first-entry, each-kind, restart, pruning, and rotation fixtures across all participating runtimes.

### H4 — Wallet profile mode cannot perform its mandatory freshness preflight

**Severity:** High

**Evidence:** Every new private transaction requires C3B (`prd-implementation-plan-r4.md:250`), but the only preflight route is account-API-key-only (`:252-258`). C4 nevertheless supports wallet-session reservations using an existing profile (`:270-278`), and T-C05/T-Q01 through T-Q05 require wallet reservation, status, crash, and recovery behavior (`test-spec-r4.md:43-49`, `:141-167`). The current gateway rejects ambiguous credentials (`phase5-gateway/internal/router/wallet_sessions.go:446-456`), and R4 never requires a wallet client to possess and separately use the account API key. No wallet-signed preflight route or replay domain exists.

**Consequence:** A wallet-only buyer must either bypass the mandatory signed freshness check or cannot start a profile-bound transaction. Quietly requiring the account credential changes the supported wallet authority and sharing model and leaves the wallet tests unable to prove the documented journey.

**Required correction:** Choose and normatively bind one supported authority. Either require the supported wallet client to possess a separately authenticated account credential and specify the cross-credential/account-subject binding and UX, or add a read-only wallet-signed preflight route with exact SPEC-040 canonicalization, replay, sequence, cap, and revocation behavior. Test stale/revoked wallet keys, mismatched accounts, replay, concurrent tombstones, and wallet-only operation end to end.

### H5 — The exact browser command is unsafe and cannot exercise the declared local contract

**Severity:** High

**Evidence:** C10 mandates `npm run preview` on `http://127.0.0.1:4173` (`prd-implementation-plan-r4.md:555-561`), while C3A accepts only a canonical HTTPS origin (`:223`). More seriously, pinned Malibu config routes `/api/mp` to `https://api.streamvc.live` under `server.proxy` (`dc7f425ba7d50c86467f31a82f419df6a0904b13:vite.config.js:80-94`), and pinned Vite 8.0.16 resolves preview proxy as `preview.proxy ?? server.proxy`. The exact test command therefore inherits the production gateway proxy. T-W01 creates/replaces/revokes profiles and T-W03 sends inference (`test-spec-r4.md:197-207`); no isolated local gateway target, reverse proxy, credential fixture, or hard production-host refusal is defined. Safari process-cut ownership is also not executable from the stated command: WebDriver session deletion is not a browser-process crash, and no provisioned disposable macOS user/VM or owned Safari data directory is established.

**Consequence:** With valid credentials the acceptance harness can mutate production trust state or incur real inference charges, actions outside this task's authority. Without them it cannot exercise the journey. Even a mocked fetch would not prove the real gateway/coordinator path, and the HTTP origin is rejected by the planned local-authority schema before the journey begins.

**Required correction:** Specify a test-only same-origin server/reverse proxy that serves the built app and forwards only to explicit loopback coordinator/gateway fixtures, fails startup for non-loopback upstreams, uses isolated test credentials/data, and records its endpoints. Either add an exact test-only loopback-origin rule to the local authority contract or serve trusted local HTTPS. Define Safari crash ownership using a disposable test user/VM that the harness is authorized to terminate, or distinguish the process-crash qualification blocker without treating graceful WebDriver closure as equivalent. Add a guard test proving the harness cannot resolve or connect to production hosts.

## Medium findings

### M1 — The 255-second first-call formula omits four final-batch network waves

**Severity:** Medium

**Evidence:** One 100-row batch uses 20 workers and up to five sequential two-second waves (`prd-implementation-plan-r4.md:358-360`). The formula for the last row counts nine complete pass/interpass intervals and the final claim, but assumes the last row starts immediately after claim: `9 * (18 + 10) + 3 = 255` (`:362`). Rows 81-100 cannot begin until four allowed waves have elapsed, so the stated worst-case first-call start is `9 * 28 + 3 + 4 * 2 = 263` seconds. T-Q05 requires the impossible 255-second assertion under those same maxima (`test-spec-r4.md:163-167`).

**Consequence:** A conforming scheduler can violate the mandatory test while remaining within every configured bound. Startup validation and the 8-day retention inequality are computed from a false value, even though the corrected bound remains below 300 seconds.

**Required correction:** Freeze the general formula including the final row's wave index and verify it for non-divisible row/batch/concurrency shapes. Use the corrected value consistently in startup checks, alerts, retention math, and T-Q05. Separately bound fault/restart cases rather than folding them into the healthy-store claim.

### M2 — Exact auth, wallet, quota, and transport error mappings are deferred past the gate

**Severity:** Medium

**Evidence:** R4 correctly separates server wire errors from client actions, but only enumerates the legacy `relay_blind_*` mapping (`prd-implementation-plan-r4.md:535-553`). It says auth, wallet, quota, cancellation, and transport mappings will later be explicit in a generated `wire-errors-v2` manifest, without supplying those rows now. The pinned relay-blind gateway path currently emits generic codes including `quota_exhausted`, `duplicate_request_id`, `account_concurrency_exceeded`, `settlement_failed`, `internal_error`, `request_too_large`, and `wallet_session_signature_invalid` (`phase5-gateway/internal/router/relay_blind_success.go:221-272`; `phase5-gateway/internal/router/relay_blind.go:73-134,587-592`). T-C06 cannot determine the required tuple/action for these bytes from the reviewed artifacts.

**Consequence:** Slice 0 must make security-sensitive recovery and UX decisions that were not reviewed. Different adapters can collapse a predispatch quota error and a postdispatch settlement/storage error into the same effective action, or conservatively turn all of them into unknown, failing the actionable-error outcome.

**Required correction:** Put the exhaustive pinned emission-site-to-wire-tuple-to-reducer mapping in the next reviewed artifacts, including malformed/non-JSON/empty response and transport-local cases. Generate code/tests from those exact reviewed rows and require source-callsite inventory coverage, not only exported constants or SPEC rows.

### M3 — Physical SQLite capacity remains a future implementation decision

**Severity:** Medium

**Evidence:** C9 states that page size, journal mode, schema indexes, B-tree worst-case pages, WAL headroom, and transaction page-growth reserve will be measured and frozen in Slice 0 (`prd-implementation-plan-r4.md:461`). The reviewed plan contains no schema-derived numeric page/WAL reserve, database file ceiling, filesystem free-space precondition, or measured lower bound. T-P04 already requires exact-limit behavior and startup rejection against that future model (`test-spec-r4.md:69-75`).

**Consequence:** The plan gate would authorize runtime implementation before the physical model that is supposed to prove preallocated revoke reachability has itself been reviewed. A later schema/index choice can invalidate the 1 KiB slot and WAL/page inequalities without formally reopening this gate.

**Required correction:** Produce the concrete Slice 0 schema and measured capacity artifact before runtime work, with exact supported SQLite settings, page/index/WAL/file/free-space formulas and conservative observations. Incorporate its digest and thresholds into the next plan/test revision, or explicitly require a new adversarial plan gate after that artifact and before any storage/runtime slice.

### M4 — The global revocation authority has no row or byte bound

**Severity:** Medium

**Evidence:** C9 says operator tombstones are bounded by “global bundle/tombstone limits,” but the table defines only bundle key/revision/byte limits and a 38-day tombstone retention; it gives no tombstone row count, byte ceiling, operation rate, root/checkpoint space, or reachable worst case (`prd-implementation-plan-r4.md:426-448`). C3B advances one durable global log entry per committed tombstone (`:254-256`). T-P04 covers account partitions but no global tombstone saturation/recovery case (`test-spec-r4.md:69-75`).

**Consequence:** A valid operator workload can grow the revocation database without a reviewed physical limit, exhaust space needed for the next emergency tombstone, or force pruning that makes root/recovery behavior implementation-defined.

**Required correction:** Freeze global tombstone operation/rate, row, byte, checkpoint, retention, and emergency-headroom limits; define pruning/root continuity and the fail-closed behavior at exact capacity. Add a reachable maximum construction followed by one required signer/bundle/profile/pin revocation and restart/recovery tests.

## Informational observations

1. R4 preserves the provider-plaintext disclosure, no ciphertext failover, C6A rejection-only refund authority, ordinary settlement boundary, and actual-MLX evidence separation. No finding above requires weakening those contracts.
2. The wire/effective error object split is directionally sound; M2 concerns completeness of the reviewed mapping, not the split itself.
3. The corrected healthy-store first-call bound is still below the stated 300-second go/no-go ceiling, so M1 is a consistency and proof defect rather than evidence that the chosen scheduler shape is intrinsically infeasible.

## Disposition and next gate

R4 does **not** satisfy the required zero Critical/High/Medium plan gate. No Build 2 runtime, SPEC, schema, fixture, or Malibu implementation is authorized from these bytes. R5 must resolve every finding without weakening signed-bundle bootstrap, server-side approved-provider selection, lifecycle rechecks, provider-plaintext disclosure, no ciphertext retry/failover, signed rejection-only refunds, wallet replay separation, ordinary settlement, real-browser evidence, or actual-MLX acceptance. A fresh independent GPT-5.6 Sol reviewer must receive exact R5 plan/test/disposition hashes, both pinned repository revisions, this review, and the predecessor review.

## Review boundary

This was a code-grounded read-only plan review. It inspected the exact artifacts, pinned MacProvider relay-blind coordinator/gateway contracts and call sites, pinned Malibu console/package/Vite configuration, and the installed pinned Vite 8.0.16 preview proxy resolution. No implementation, unit, integration, browser, MLX, deployed-service, or production test was run. No `d-inference` source was inspected, no secret was read, and no network, deployment, release, or economic action was performed.
