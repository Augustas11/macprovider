# Product Build 2 R7 adversarial plan review

**Review model:** native GPT-5.6 Sol, high reasoning

**Verdict:** FAIL — implementation remains prohibited

**Finding counts:** Critical 0, High 6, Medium 0, Low 0, Info 4

**Reviewed MacProvider commit:** `9800124990e500d65500043ce98e3e8dd89c9ab8`

**MacProvider implementation base recorded by the plan:** `1d2c930bad81704dd0acc0322226725d8b64aceb`

**Reviewed Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Artifact identity

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r7.md` | `1ef0a654460d24180231933fe6fda442a01ae7673e0ec7d3689e2792f3718eaa` |
| `test-spec-r7.md` | `fe916b0e5eb53c9afa67e946bd3c380193b37715d199f19638eedff0a425b639` |
| `finding-dispositions-r7.md` | `7e3943f06e8661d7879c30aad12e5fed1c6a1a8e98733ebcbad44b4469784e67` |
| `checkpoint-r7.md` | `65d5a3253f784228b8e80430808e4c5f130cfe4eb0c609eb2872f7ad2323964f` |

All four submitted R7 artifacts matched the requested bytes before review. The worktree was clean at the reviewed commit. The branch remained deliberately pinned to the plan's historical base; current `origin/main` was `c123ae2d2d08053612d940b3077994f7c4d709d7` and was not silently incorporated. Malibu was inspected from its exact pinned git object without changing that repository.

## High findings

### H1 — Traditional `F_SETLK` does not provide the claimed process-wide serialization

**Severity:** High

**Evidence:** C8A requires retained-descriptor whole-file `fcntl(F_SETLK)` locks, says the global lock serializes every conforming Go authority, and explicitly says in-process mutexes are not substitutes (`prd-implementation-plan-r7.md:439-447`). On the supported macOS host, `man 2 fcntl` states that traditional `F_SETLK` conflicts are against locks held by another process. A successful request by a process that already owns locks replaces its own lock type over the requested region; it does not block another goroutine or independently opened Store in that same process. The same manual also states that closing any file descriptor for the file removes every traditional record lock that process holds. OFD locks are separately documented as being associated with the open file description. T-G02 and T-G03 race processes and roots but do not require two independent authorities in one process to be excluded, nor do they inject an unrelated same-process descriptor close (`test-spec-r7.md:192-210`).

**Consequence:** Two supported Go authority instances or goroutines in one process can both pass the purported global and root-local locks, read the same Keychain predecessor, and perform divergent file/Keychain work. An unrelated library close of the lock file can also release both traditional locks before the protected Keychain operation completes. This reopens the R6 multi-root fork and can orphan a locally accepted profile mutation or request fence. The plan's statement that every conforming Go authority is serialized is false under its mandated primitive.

**Required correction:** Freeze a same-process and cross-process locking design whose semantics actually cover independently constructed authorities and descriptor lifetime. One viable shape is a process-global keyed mutex held outside an OFD or otherwise descriptor-owned kernel lock, with one canonical descriptor registry preventing unrelated closes; the exact choice must be reviewed. Define acquisition, release, cancellation, fork/exec, duplicate descriptor, close, panic, and late Keychain completion behavior. Add same-process two-Store/two-account/two-root schedules, independent file opens/closes, and process races that prove one accepted successor per external head and at most one send. Rerun the full plan gate.

### H2 — The emergency-slot startup invariant contradicts retained revoked bundles and pins

**Severity:** High

**Evidence:** C9 defines `stored_bundle_revisions` and `unique_pin_fingerprints_referenced_by_stored_bundles` as terms in `allocated_unsealed_emergency_slots`, and says no reachable target exists without exactly one unsealed slot (`prd-implementation-plan-r7.md:517,522-524`). The normative history then revokes every pin and every bundle revision after normal tombstone saturation, sealing their emergency slots while retaining the underlying bundle revisions, references, tombstones, operations, and checkpoints for at least 38 days (`:528-530`). Pin reference counting explicitly includes unrevoked stored bundles and active/reference-retained profiles (`:524`). T-P04 requires restarts at target-kind boundaries during that history (`test-spec-r7.md:84-88`).

**Consequence:** After the first explicitly revoked pin or bundle, the stored revision/reference counters still include the retained record while its emergency slot is sealed. Enabled startup can either enforce the displayed formula and reject the normative state, or exclude revoked targets using a predicate that the plan never defines consistently. The required 129-hour history therefore cannot survive its required restarts, and the capacity proof does not establish a deployable revocation lifecycle.

**Required correction:** Define one exact target-state predicate shared by allocation, reference counting, startup validation, pruning, and the test ledger. It must distinguish active/revocable targets from retained revoked history for signer, bundle, profile, and pin kinds. Rewrite every equation and owner/free/sealed transition using that predicate, then enumerate the expected counts immediately before and after each target-kind revocation and restart. Prove retained revoked bundles/profiles and their pin references do not require unsealed authority while still preserving replay, checkpoint, and recovery evidence.

### H3 — Signed in-database checkpoints cannot detect a self-consistent database rollback

**Severity:** High

**Evidence:** C3B says a rolled-back checkpoint disables preflight, but its startup rule only verifies the checkpoint's signature/digest, reconstructs retained suffix entries, and compares them with the singleton stored in the same coordinator database (`prd-implementation-plan-r7.md:287-293`). No independently monotonic operator, hardware, transparency-log, or second-store head is defined for coordinator revocation state. Client preflight supplies a prior generation/root and a client that has already anchored a higher head fails closed, but a fresh client has no higher watermark. T-P07 asks for `server rollback` and says a valid local rollback is detected by a newer server revision; it does not prove that a complete older coordinator snapshot is rejected for a fresh client/account flow (`test-spec-r7.md:98-106`).

**Consequence:** Restoring a byte-consistent older SQLite snapshot also restores its older singleton, tombstone suffix, and valid signed checkpoint. All displayed startup checks pass. A new client without a later local watermark can accept freshly signed preflight rooted at that stale state, allowing an explicitly revoked signer, bundle, pin, or profile to become usable again. Signatures prove who created a historical state; they do not prove that it is the newest state.

**Required correction:** Add an external monotonic revocation-head authority or explicitly narrow the production claim and make server rollback an operator qualification blocker. A conforming design must bind generation/root to evidence outside the rollback domain, define initialization, update CAS, recovery, backup/restore, key rotation, outage, and disaster-recovery behavior, and prohibit signing a preflight below that external head. Add a complete-database rollback test with both previously anchored and fresh clients, including rollback across explicit signer, bundle, pin, and profile revocations. Do not describe internally consistent signed historical checkpoints as rollback detection.

### H4 — Signer, bundle, and pin revocation lack executable operator contracts

**Severity:** High

**Evidence:** C2 freezes an exact bundle-upload route/body and an exact invitation route/body, but describes signer/bundle emergency revocation only as an operator-authenticated append-only tombstone operation (`prd-implementation-plan-r7.md:172-180`). C3B defines the four tombstone target digests and storage framing (`:276-291`), while C9 and T-P04 require supported APIs to activate and revoke signer, bundle, pin, and profile targets (`:522-532`; `test-spec-r7.md:76-88`). Profile revocation has an exact public method, path, body, CAS, response, and replay contract (`prd-implementation-plan-r7.md:203-217`). There is no corresponding exact method/path/version/body for signer, bundle, or pin revocation, no signer-activation contract, and no defined idempotency, target-CAS, success/error response, request digest, replay, concurrency, or operator authorization result for those mutations.

**Consequence:** Slice 1 cannot generate a complete route/schema/error manifest or execute the normative capacity history without inventing security-sensitive authority after this plan gate. Different implementations can revoke different logical targets, replay differently, or commit a tombstone after the target changed. The plan therefore does not provide the executable revocation and recovery contracts its acceptance tests claim to prove.

**Required correction:** Freeze every operator activation and revocation route, closed request/response schema, version, canonical request digest, authorization boundary, operation ID, target identity/CAS fields, idempotent replay behavior, linearization point, rate/capacity charge, and error precedence for signer, bundle, and pin operations. Define how signer activation and key validity interact with emergency revocation. Add first delivery, exact replay, changed replay, stale target, duplicate, concurrent parent/child revocation, crash at every transaction cut, and response-loss recovery tests through those exact APIs.

### H5 — Buyer-controlled retained-operation caps permit cheap global admission denial

**Severity:** High

**Evidence:** C3 seals every authenticated, schema-valid semantic/CAS/rate/capacity rejection after a normal operation row is reserved, retains rejected create rows for 38 days, permits 4,096 operation rows per account, and caps the global table at only 16,384 rows (`prd-implementation-plan-r7.md:209-217,511,532`). The accepted rate is 60 mutations per account per minute (`:520`). Four authenticated accounts can therefore consume the full coordinator global operation partition in roughly 69 minutes by sending schema-valid semantic failures, preventing every other account from creating or replacing profiles for the retention horizon. C8 similarly permits 4,096 normal browser operations per account but only 65,536 globally (`:487-489,516`), so 16 accounts can consume that shared partition. T-P04/T-W02 test a single account filling its normal slots and eventual eligible drain, but no test reserves global capacity fairly or proves that hostile accounts cannot exhaust service for unrelated accounts (`test-spec-r7.md:78-88,222-224`).

**Consequence:** An authenticated buyer can deny new Build 2 profile provisioning or browser-head advancement network-wide without approaching the advertised 256-account/8,192-pair product capacities. Preallocated revocation remains possible, but the supported buyer journey becomes unavailable for unrelated accounts for up to 38 days or eight days. The global limits therefore fail as an availability and multi-tenant trust-boundary design.

**Required correction:** Partition or reserve retained-operation capacity so one account's maximum cannot consume unrelated accounts' minimum supported service. Define per-account/global fair-share admission, reserved capacity, eviction/pruning eligibility for sealed no-commit failures, rate-cost economics, and behavior when an account loses its share. Recompute physical maxima using the new partitions. Add multi-account saturation tests with hostile semantic/CAS failures and prove an unrelated account can still create, replace, revoke, recover, and advance both browser authority kinds at every boundary.

### H6 — A global pool generation lets an unapproved provider starve all approved reservations

**Severity:** High

**Evidence:** C5 snapshots at most 16 buyer-approved provider IDs, but the token is the registry's single process-wide `(epoch,generation)`. That generation advances for every relevant mutation to every provider in the pool (`prd-implementation-plan-r7.md:315-330`). A round rejects when `T2 != T1` or `T3 != T2`, even when the mutation belonged to a provider absent from the approved snapshot. After three rounds the buyer receives a churn error. T-S01 verifies the global increment behavior, T-S04 treats churn exhaustion as expected, and T-S05 requires no starvation under ordinary concurrent work; none requires continuous relevant mutation by an authenticated provider outside the buyer's acceptable set to leave the approved tuple usable (`test-spec-r7.md:108-132`).

**Consequence:** An unapproved provider can repeatedly rotate session or toggle model/state/capacity/admission fields and invalidate every private reservation round for buyers whose approved providers are unchanged. Selection remains safe but the supported private-request product is globally starvable through an unrelated provider's normal control surface.

**Required correction:** Bind stability to only the approved candidate set and facts used by the decision, for example per-provider monotonic generations plus a mapping/configuration generation, or prove an equivalent scoped token. Define provider removal/reinsertion and operator-map generation semantics. Test sustained churn by unapproved providers while A-only and A+B reservations continue; separately prove any mutation to an approved candidate or its authority invalidates the affected round. Preserve the no-pool-lock-over-SQLite rule and exact-session final arm.

## R6 correction verification

| R6 finding | R7 result |
|---|---|
| H1 maximum response storage | The exact 16,384-byte response ceiling, future-revoke projection, fixed response extents, byte oracle, and mandatory DDL/physical-measurement gate correct the plan-level size contradiction. The correction remains conditional on the second gate receiving exact oracle/DDL/report bytes. |
| H2 two state roots fork one Keychain head | Root-independent locking and predecessor/object reread address cross-process roots in concept, but H1 shows the mandated primitive does not serialize independent authorities inside one process and can be released by an unrelated close. The correction is not closed. |
| H3 unreachable normal-saturation history | R7 gives a concrete supported history that reaches full normal tombstones and a maximum unrevoked target set. H2 above finds a later startup contradiction in the required emergency revocation phase; the full lifecycle proof is not closed. |
| M1 Keychain byte/policy exactness | Corrected at plan level with exact account/root/policy/access-group digests, complete add/read/update dictionaries, normalization, migration constraints, shared vectors, and a native Security.framework oracle (`prd-implementation-plan-r7.md:457-469`; `test-spec-r7.md:192-200`). Runtime bytes remain subject to the mandatory oracle gate. |

## Informational observations

1. The pinned coordinator still sorts a global `pool.Snapshot()` and selects the first serving/tunneled/model-matching provider in `phase4-coordinator/internal/buyer/relay_blind.go::selectRelayBlindProvider` (`relay_blind.go:243-259`). Its current SQLite store has keys and reservations but no Build 2 profile, invitation, external revocation-head, or acceptable-identity authority (`phase4-coordinator/internal/relayblind/store.go:41-217`). Buyer-approved selection remains planned rather than landed.
2. Subject to the findings above, R7 preserves selection before encryption, exact profile/key/session final checks, provider-plaintext disclosure, relay-visible response disclosure, and the prohibition on ciphertext retry/failover. The client verifies the returned fingerprint before creating an ephemeral key, nonce, or ciphertext, and post-fence recovery remains status-only.
3. Pinned Malibu still uses `BASE = '/api/mp'`; `console/api.js::fetchChatCompletions` retries selected 502/503 and retryable 500 ordinary-chat responses. `vite.config.js` proxies `/api/mp` to a public upstream, and `package.json` has Vite 8.0.16 with no browser automation package. R7 correctly requires a separate no-retry encrypted transport and an isolated TLS loopback browser harness rather than treating the ordinary path or Vite preview as evidence.
4. T-H01/T-H02 correctly distinguish physical Apple Silicon `ModelRuntime` inference from deterministic Swift fixtures and require recorded artifact/hardware context. This review supplies no hardware evidence; actual MLX, browser, deployed-service, and production qualification remain unproven rather than passed. The branch is also one commit behind current `origin/main`; reconciliation with that later change is required after a future plan gate and must not be represented as part of this pinned review.

## Disposition and next gate

R7 does **not** satisfy the required zero Critical/High/Medium plan gate. No Product Build 2 SPEC, schema, vector, coordinator, gateway, Go client/CLI, Swift provider, or Malibu implementation is authorized from these bytes. R8 must correct all six High findings without weakening buyer-approved selection, explicit local confirmation, rollback resistance, exact mutation recovery, revocation availability, tenant isolation, lifecycle checks, no ciphertext retry/failover, provider-plaintext and response-relay disclosure, signed rejection-only refunds, ordinary settlement, browser evidence, or actual-MLX acceptance. The exact DDL/response-oracle/physical-measurement/error-inventory second gate remains mandatory after a future full-plan revision reaches zero Critical, High, and Medium findings.

## Review boundary

This was a code-grounded read-only plan review. It independently inspected the exact submitted R7 artifacts; pinned MacProvider coordinator selection, relay-blind store, pool and gateway surfaces; local supported-macOS `fcntl` and Security.framework interfaces; and pinned Malibu API, proxy, package, credential, and retry behavior. No implementation, unit, integration, browser, MLX, deployed-service, or production test was run. No `d-inference` source, operator secret, private key, or credential was inspected. No deployment, release, production mutation, or economic activation occurred.
