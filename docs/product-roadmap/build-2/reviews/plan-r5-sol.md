# Product Build 2 R5 adversarial plan review

**Review model:** native GPT-5.6 Sol, high reasoning
**Verdict:** FAIL — implementation remains prohibited
**Finding counts:** Critical 0, High 5, Medium 3, Low 0, Info 4
**Reviewed MacProvider commit:** `80c8bcf162277879919bcc098ac9f5e5d7ac85cc`
**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Reviewed Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Artifact identity

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r5.md` | `2a85bc59e8e6c093b71b73506b91d10f52d0fcb649be620ccdb6ea8051399b29` |
| `test-spec-r5.md` | `38f20aa5d785d51464fd0888365fc41b22b1a60baa12a8c0175a44c3b173c98b` |
| `finding-dispositions-r5.md` | `0841782d749adabcf4a596cdfc65975afd39cc6974d7a216c15834f53a1c0fd3` |
| failed predecessor `reviews/plan-r4-sol.md` | `3a2ce35dce0fe1fc4f16168fe19fd06790ed4d07297cc3b0662d29032c3d4f9c` |

All supplied bytes and revisions matched before review. The MacProvider worktree was clean at the reviewed commit. Malibu was inspected from the pinned git object without modifying its stale canonical checkout.

## High findings

### H1 — A sent-or-unknown profile mutation has no executable recovery operation

**Severity:** High

**Evidence:** C3A says a create, replace, or revoke at `sent_or_unknown` can only reconcile, and says a lost create remains pending until an authenticated terminal disposition proves absence (`prd-implementation-plan-r5.md:244-246`). The complete route inventory exposes profile create/replace/revoke/get/list but no mutation-status or operation-disposition route (`:201-205`). The plan also does not authorize or define replay of the exact mutation request as the reconciliation operation. T-P07 names request-loss cuts but does not identify which request proves committed, definitely absent, or safe exact replay (`test-spec-r5.md:95`).

**Consequence:** If the request is lost before the server receives it, local state can remain pending forever. An implementer must either invent a mutation replay policy after the gate or infer absence from profile/invitation reads, which the plan explicitly says is unsafe. The same ambiguity affects replace and revoke and prevents the promised supported recovery journey.

**Required correction:** Freeze one authenticated recovery mechanism before implementation: either an exact operation-disposition route with closed request/response schemas and retained terminal/no-commit evidence, or exact byte-identical idempotent mutation replay with explicit eligibility from `sent_or_unknown`, request-digest binding, invitation-consumption behavior, concurrency, expiry, and terminal transitions. Add every before-receive/after-receive/commit/response-loss/restart cut for all three mutations and prove that no read-only profile response is treated as absence authority.

### H2 — The Go external-head authority cannot be initialized from a fresh installation

**Severity:** High

**Evidence:** The external Keychain head starts at generation 1, while a missing HMAC or head item quarantines the authority (`prd-implementation-plan-r5.md:433`). Every append begins by reading and authenticating an existing head (`:435`). No contract creates the HMAC key, generation-1 checkpoint/base/manifest/tail/pointer, and first external head, or distinguishes an expected fresh store from deletion/rollback. T-G02 asks for missing-item failure and append crash cuts but has no bootstrap crash matrix (`test-spec-r5.md:185-187`). C3A's valid first-create record therefore has no reachable C8 publication path.

**Consequence:** A conforming fresh CLI either rejects its first profile/request forever or treats missing rollback-sensitive state as genesis without a reviewed discriminator. Partial crashes can leave a key without a head, files without an anchor, or an anchor without required files, and the plan gives recovery no authoritative old/new outcome.

**Required correction:** Define a closed bootstrap state machine under `private.lock`, including exact fresh-store evidence, creation-only Keychain selectors, HMAC generation, genesis checkpoint/base/manifest/tail/pointer bytes, head generation 1, fsync/readback order, collision behavior, and every file/Keychain crash cut. Missing state after any previously committed authority must remain quarantine; fresh initialization must not be inferred from directory emptiness alone.

### H3 — Pointer and external-head invariants contradict the append protocol

**Severity:** High

**Evidence:** An immutable pointer contains `tail_sequence`, committed tail size/digest, committed head digest, and `external_head_generation` (`prd-implementation-plan-r5.md:429`). A normal append writes a new immutable tail and advances only the Keychain head; it does not publish a new pointer (`:435`). The plan nevertheless says pointer/head mismatch quarantines (`:445`) without defining which duplicated fields must remain equal or which pointer values intentionally describe an older generation boundary. It also does not define retirement of the superseded full-copy tail, even though every next tail contains all prior tail bytes and the physical caps are 40 MiB/88 MiB (`:429,447`). T-G03 names pointer/head mismatch and physical limits but supplies no accepted post-append vector or retirement crash outcomes (`test-spec-r5.md:193`).

**Consequence:** After the first append, implementations can either reject the valid new head because the pointer is stale, ignore authenticated pointer fields, or silently publish a new pointer using an unreviewed protocol. Retaining every full-copy tail exceeds the physical cap; deleting one without an exact authenticated-retirement rule can destroy the old outcome needed after an ambiguous publication.

**Required correction:** Freeze one consistent model. Either publish a new immutable pointer on every append and bind its digest in the external-head CAS, or define the pointer as a generation-base descriptor without duplicated live-tail claims and make the external head the exact live suffix authority. Specify current/prior tail retention, how the immediately prior head is authenticated, deletion/fsync order, physical peak accounting, and crash vectors for append, head readback, cache update, and retirement. Add exact accepted genesis/append/compaction vectors plus mismatch negatives.

### H4 — The browser head-ledger API is not a closed, implementable two-authority protocol

**Severity:** High

**Evidence:** C8B declares one path `/v1/relay-blind/client-authority-heads/{authority_id}` but stores two rows per ID distinguished by `authority_kind` (`prd-implementation-plan-r5.md:439`). It gives no exact HTTP methods or closed create/GET/CAS bodies and responses that select one kind or return both. DELETE requires exact expected generations/digests for both kind rows (`:441`), but neither paired row creation nor an absent-kind sentinel is defined; a profile-only authority can therefore have no request-journal row to name. The recovery list returns only ID, state, and time, not the expected dual-head tuple. T-W02 assumes create/GET/CAS and exact dual-head revocation without testing a one-kind authority or freezing route bytes (`test-spec-r5.md:207`).

**Consequence:** Independent gateway and Malibu implementations cannot agree on which row a GET/CAS addresses, how a first kind is created, or how cleared-storage recovery revokes an ID that has only one kind. That breaks the rollback anchor and can strand one of eight authority IDs permanently, making the promised cap-drain recovery unavailable.

**Required correction:** Specify exact versioned method/path/body/response schemas for paired allocation, per-kind GET/CAS, list, and atomic revoke. Define whether both kind rows are preallocated together; otherwise define authenticated absent-kind expectations. Freeze generation-zero semantics, operation idempotency, constant-shape cross-account behavior, lost-response reconciliation, and one-kind/two-kind/revoked/pruned fixtures before browser implementation.

### H5 — Emergency tombstone reserves cannot keep all reachable live authority revocable

**Severity:** High

**Evidence:** The normal global partition can fill at 65,280 tombstones, after which each kind has only 64 emergency rows (`prd-implementation-plan-r5.md:469-471`). Reachable live targets are not capped by those reserves: bundles alone allow 4,096 stored revisions, profiles allow 32 active IDs per account with no reviewed global account/profile ceiling, and pins can greatly exceed 64 (`:457-467`). Profile create preallocates only account-local operation/audit slots, not a global profile-tombstone slot (`:461,473`). T-P04 simultaneously claims all active profiles remain revocable at every coordinator capacity (`test-spec-r5.md:97`) but tests only one tombstone of each kind after normal saturation and then accepts blocking when 64 entries of one reserve are exhausted (`:79`).

**Consequence:** A valid workload can fill the normal partition while more than 64 live profiles, bundles, or pins still require independent emergency revocation. The 65th target cannot be revoked, contradicting the safety and acceptance claims. Blocking new related admission after reserve exhaustion does not revoke already active authority or satisfy emergency response.

**Required correction:** Make emergency capacity reachable-proof complete. Preallocate or charge one global revocation slot for every independently revocable live target, cap live targets per kind to the available reserve, or define a reviewed coarser tombstone that safely revokes the remaining set without over-revocation claims. Include global inequalities across all accounts/bundles/pins, normal saturation with the maximum live target set, revocation of every live target, restart/pruning, and exact physical accounting.

## Medium findings

### M1 — The reviewed error table still does not contain exact source callsite keys

**Severity:** Medium

**Evidence:** The plan claims the compatibility adapter is frozen by emission site and requires repository, path, enclosing function, stable label, legacy code, route/method, and v2 code (`prd-implementation-plan-r5.md:579,615`). The actual table uses grouped prose such as ``relay_blind.go` route method/body/schema`, ``relay_blind_success.go` recovery arm/settle/refund persistence`, `wallet lookup/signature/session lifecycle`, and `existing auth middleware 401/403 code` (`:581-608`). Current code has many distinct writers even inside one group, for example `dispatchRelayBlindChat` emits separate `relay_blind_required_unavailable` and `relay_blind_committed_failed` outcomes at `phase5-gateway/internal/router/relay_blind_success.go:175-193,250-344`, while `requireWalletSessionBearer` emits distinct lookup and lifecycle outcomes at `wallet_sessions.go:480-522`. The exact callsite constants do not exist in the reviewed artifacts.

**Consequence:** Slice 0 must invent security-sensitive callsite partitions and reducer mappings after this gate. The required source scanner cannot compare code to an exact reviewed manifest, and a broad condition can map the same raw code differently depending on an unreviewed phase/fence assumption.

**Required correction:** Include the generated exact emission inventory, with every required key and complete replacement tuple/action, in the next reviewed artifact. Source-scan the pinned bases and show zero missing, duplicate, ambiguous, or stale callsites. If generation occurs in the sizing slice, its digest and all rows must be included in the mandatory second plan gate before any server/client error implementation.

### M2 — Revocation checkpoint authentication is still underspecified

**Severity:** Medium

**Evidence:** C9 calls the every-1,024-entry object a signed checkpoint and lists semantic fields plus `checkpoint_digest/MAC` (`prd-implementation-plan-r5.md:471`), but C3B defines neither its version, canonical frame/domain, MAC key/key ID, nor signature algorithm and rollover. C3B merely delegates checkpoint/pruning to C9 (`:271`). T-C02 and T-P07 require cross-runtime checkpoint/pruning vectors without bytes from which independent runtimes can produce the same result (`test-spec-r5.md:27,97`).

**Consequence:** Pruning can remove the entry prefix before the checkpoint authority that replaces it has been normatively bound. Implementations can generate incompatible roots or accept a checkpoint under the wrong key/domain, and the restart test can only ratify one implementation's invented format.

**Required correction:** Freeze the exact checkpoint object, field presence/order, binary framing, digest domain, MAC/signature key authority and rotation, first-suffix predecessor rules, empty-suffix behavior, and corrupted/rolled-back checkpoint handling. Add independently computed positive and negative vectors before the governance slice lands.

### M3 — The five-second Keychain ceiling has no safe late-completion contract

**Severity:** Medium

**Evidence:** C8A gives the entire nonblocking lock acquisition a five-second ceiling, while C8B performs Keychain replacement/readback under that same lock and says timeout fails closed (`prd-implementation-plan-r5.md:423,435`). It does not say whether a timed-out Keychain mutation is synchronously complete, cancelled, or may complete after the lock is released. T-G02 injects a timeout but asserts no observable rule for a late successful replacement (`test-spec-r5.md:187`).

**Consequence:** Waiting synchronously can violate the mandatory total ceiling. Returning at five seconds while a mutation can still complete later can advance the external head after another process acquires the lock, invalidating the single-writer proof. A simple timeout test will miss that delayed side effect.

**Required correction:** Define a concrete execution mechanism and old/new reconciliation for deadline overrun. No process may release `private.lock` while an external-head mutation can still complete unobserved. If the platform operation is not safely cancellable, make the five seconds an alert/admission deadline rather than a hard lock-hold ceiling, or isolate the authority in a helper with a durable, fenced completion protocol. Test delayed completion both before and after the reported timeout.

## Informational observations

1. R5 correctly defines the generation-zero revocation root and first tombstone predecessor, and the domain-separated signer/bundle/profile/pin target frames close R4 H3 apart from checkpoint authentication covered by M2.
2. The split wallet journey is internally coherent: the account API key performs identity/profile/preflight, the signed result binds the same active wallet session, and later reservation/status requests use only wallet authority. Malibu accurately remains account-key-only.
3. The corrected healthy-store first-call formula includes the four final-batch waves and yields 263 seconds. The plan also correctly keeps crash/restart measurements separate and reopens the gate after exact SQLite DDL/physical measurement rather than treating arithmetic as capacity proof.
4. The isolated browser harness removes the inherited Vite production proxy, uses a trusted HTTPS origin, refuses non-loopback upstreams before credential loading/socket creation, and preserves Safari process-crash evidence as a qualification blocker without relabeling WebDriver session deletion.

## Disposition and next gate

R5 does **not** satisfy the required zero Critical/High/Medium plan gate. No Build 2 runtime, SPEC, schema, fixture, CLI, or Malibu implementation is authorized from these bytes. R6 must resolve every finding without weakening server-side approved-provider selection, double collection, signed bundle/invitation bootstrap, provider-plaintext disclosure, response-relay visibility, no ciphertext retry/failover, signed rejection-only refunds, ordinary settlement, real-browser evidence, or actual-MLX acceptance. The SQLite DDL/measurement follow-up gate remains mandatory even after the full plan reaches zero.

## Review boundary

This was a code-grounded read-only plan review. It independently inspected the exact submitted artifacts, pinned MacProvider relay-blind coordinator/gateway selection, dispatch, auth, wallet, and error-emission code, and the pinned Malibu package, Vite proxy, and ordinary chat retry implementation. No implementation, unit, integration, browser, MLX, deployed-service, or production test was run. No `d-inference` source, operator secret, private key, or credential was inspected. No deployment, release, production mutation, or economic activation occurred.
