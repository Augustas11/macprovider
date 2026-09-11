# Product Build 2 adversarial plan review

**Review revision:** 3  
**Reviewer:** independent native GPT-5.6 Sol, high reasoning  
**MacProvider review commit:** `014788013f92e72abb7f9be1b4f2f8120a871140`  
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`  
**Malibu read-only base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`  
**Plan SHA-256:** `452a19c87a3dd0dc62a15ee9e6877dbd7d0fce26de4dd92d728fee210aaa98b7`  
**Test-spec SHA-256:** `2e50ed52a935ee3102182f0400d8aedae1be0503148be7f6dd49b8b67afca6b5`  
**Disposition SHA-256:** `70abf8a8aff4f1168ce6fd3364abfef3080ce5fc048aedb40c6e6f496d3f97db`  
**Failed predecessor review SHA-256:** `c1e327a2ddd0efbe3ed14740cca4111a53cbd3c6c92b279dcab3074ee1e97b4e`

## Verdict

**FAIL — implementation remains prohibited.**

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 6 |
| Medium | 4 |
| Low | 0 |
| Info | 0 |

R3 does close important R2 gaps. The per-object nullability table and three representation-byte locator vectors are implementable. The C6A proof binds the refund result to a fresh challenge, account/session/request, locator, envelope state, signed response digest, and a production HTTPS identity. Wallet status has a fixed row and monotonic sequence rather than consuming inference replay rows. The 128/profile and 512/account limits are independently reachable. The 51-row error inventory is present. The pool double collect, signed-bundle bootstrap, provider-plaintext disclosure, no-ciphertext-failover rule, rejection-only refund rule, and actual-MLX evidence boundary remain intact.

Those improvements do not make the complete plan implementable. The findings below are contract defects, not requests to weaken acceptance.

## Findings

### H1 — The confirmed-profile record cannot durably represent or recover the exact replacement/revocation target

**Severity:** High

**Evidence:** The local authorization predicate matches only `(origin, account_subject, profile_id, revision, profile_digest)` (`prd-implementation-plan-r3.md:204-206`), while the public profile digest deliberately excludes state (`:187-200`). A revoked document therefore has the same tuple as its active predecessor. The closed `pending_mutation` object contains target revision/profile/bundle/pinframe digests but no target state, bundle ID/revision, signer KID, exact signed-bundle bytes, selected fingerprints, or earliest pin expiry (`:208-223`). Those omitted values are mandatory in the stable confirmed record. The prose says replacement stores already verified target bundle/pins and restart may commit a matching server target, but the exact closed record has nowhere to store enough target evidence. T-P07 requires recovery from the pending record after server success (`test-spec-r3.md:81-87`). A profile GET is explicitly forbidden from bootstrapping missing local trust.

**Consequence:** After a crash between server replacement success and the stable local commit, a conforming client cannot construct the new stable authority without either losing availability permanently or trusting server-returned bundle/pin material that was not durably locally confirmed. For revocation, a literal implementation can treat an active and revoked server document as the same pending target because state is neither in the immutable digest nor the pending target. Independent Go and browser clients can therefore converge differently at the most important trust transition.

**Required correction:** Freeze a complete pending target authority. It must include target state and every value needed to construct and reverify the next stable record, or reference a separately MAC-bound immutable candidate record that includes those exact values. Bind the target state into pending framing, make the server synchronization predicate include the exact public state and explicit revocation facts, define safe disposal/retention and capacity accounting, and add crash vectors proving replacement recovery uses only the locally persisted verified target. Revoke recovery must distinguish active from revoked despite the immutable profile digest remaining unchanged.

### H2 — Append-chain compaction has no valid rooted result

**Severity:** High

**Evidence:** Confirmed profiles and request journals are append/generation/predecessor chains (`prd-implementation-plan-r3.md:219-227`, `:351-380`). Compaction may remove expired terminal records and replace the data file (`:380-384`), and T-G03 requires “compaction anchoring” (`test-spec-r3.md:179-183`). The plan defines no checkpoint/snapshot record, retained root digest, per-key head manifest, generation rewrite rule, predecessor rule for the first retained record, or atomic relationship between a compacted file and an external rollback anchor. Removing an old record can leave its successor pointing to a predecessor that no longer exists; re-genesis discards the promised chain history. The same omission applies to current confirmed-profile heads after their historical generations are removed.

**Consequence:** A conforming implementation must either reject its own compacted authority, keep all history until hitting the byte cap, or silently rewrite authenticated history under an invented contract. Tests can exercise rename/fsync mechanics but cannot prove rollback or generation integrity of the resulting logical store.

**Required correction:** Define exact versioned checkpoint/root and compacted-file schemas, canonical frames, MACs, predecessor/head coverage for every retained profile/transaction key, eligibility rules, and an atomic publication/recovery protocol. State which rollback classes are detectable and which are outside the threat claim. Add shared Go/JavaScript compaction fixtures and crash tests at checkpoint creation, data rename, root publication, directory sync, reopen, and old-file retirement.

### H3 — The 51-row error table is not a coherent wire-to-local contract

**Severity:** High

**Evidence:** The closed error object has one `action` field, while every table row has two different actions selected by local `send_fenced` state (`prd-implementation-plan-r3.md:416-476`). Gateway and coordinator do not know the client's durable local fence, so “server origin always uses the listed status” does not tell either server which action to emit. T-C06 nevertheless requires coordinator, gateway, Go, and Malibu to have identical “before/after-fence action” fixtures (`test-spec-r3.md:47-49`). The table also says local errors use HTTP 0 but assigns one HTTP value to mixed client/server origins: `relay_blind_bundle_untrusted`, `relay_blind_signer_untrusted`, and `relay_blind_pin_untrusted` are client/coordinator with HTTP 422; cancellation and response loss are client/gateway with HTTP 499/502; `relay_blind_unknown` is `any` with HTTP 500 (`prd-implementation-plan-r3.md:418-472`). Finally, R3 says every inherited relay-blind error is normalized but provides no exhaustive legacy-code-to-R3 mapping. The pinned SPEC-041 inventory includes `relay_blind_disabled`, `relay_blind_required_unavailable`, `relay_blind_key_expired`, `relay_blind_replay`, `relay_blind_decrypt_failed`, and other codes (`specs/SPEC-041-relay-blind-request-encryption.md:190-212`) that do not appear in the 51 rows.

**Consequence:** Servers cannot emit an exact conforming object without guessing client state, clients cannot distinguish a local error's required HTTP 0 from a server instance of the same code, and implementations can normalize inherited failures to different recovery actions. An incorrect action after the send fence can invite unsafe new work; an overly conservative mismatch can strand recovery.

**Required correction:** Separate the server wire error tuple from the client-derived effective action. Give each code one origin-specific wire tuple, or split codes where local/server HTTP semantics differ. Define the deterministic transformation from wire tuple plus verified journal state to effective local action. Include an exhaustive mapping for every currently emitted legacy relay-blind/auth/wallet/quota/transport code and malformed transport case. Generate server and client fixtures from those distinct tables and test the pinned runtime inventory for completeness.

### H4 — The stated 285-second recovery bound does not account for result persistence or retry ordering

**Severity:** High

**Evidence:** C6 allows duplicate workers to claim a batch, perform calls, and apply evidence in “bounded transactions” (`prd-implementation-plan-r3.md:329`). Its formula budgets five two-second network waves, then only one two-second transaction acquisition plus one second “inside it” for a 100-row batch (`:331`). It never says results are committed in one batch transaction or bounds the total number and serialized duration of per-result transactions. A per-row reading permits up to 300 seconds of database work by itself. Failed rows receive a “bounded next-attempt time,” but there is no minimum deferral or scan-generation rule that prevents early failures from being reclaimed ahead of never-visited rows after the cursor wraps (`:329-331`). T-Q05 repeats the component assertions but does not freeze batch commit shape or a no-reclaim-before-full-visit invariant (`test-spec-r3.md:157-161`).

**Consequence:** All tests could observe 20 bounded calls and individually bounded transactions while the last of 1,000 rows is first visited far later than 300 seconds. Retried failing rows can consume passes and starve untouched rows. The 8-day evidence inequality and alerting are then grounded in an unproved convergence claim.

**Required correction:** Specify the exact claim/scan epoch, cursor and retry eligibility rules that guarantee 100 distinct previously unvisited rows per pass until a full visit completes. Freeze whether results commit in one bounded batch or in bounded chunks, the total SQLite wait/work budget across all chunks, rollback/claim release behavior, and the formula including that total. Tests must measure first-call time for every row under slow calls, DB contention, mixed failures, worker cancellation, and continuously arriving/retry-eligible rows.

### H5 — Shared emergency audit capacity can exhaust before a required revoke

**Severity:** High

**Evidence:** C9 reserves 128 revoke-only operation rows, but its 256-row emergency audit partition is shared by revoke and recovery-quarantine events (`prd-implementation-plan-r3.md:390-412`). It then claims the emergency partitions remain reachable under all accepted states because there are at most 32 profile IDs. That argument ignores accepted recovery-quarantine audits, which can consume all 256 shared audit rows before any profile is revoked. The plan allows actual emergency exhaustion to fail closed, contradicting the earlier product promise that a full normal store still has representable revocation. It also does not enumerate which invitation, profile, reservation, recovery, or operator events consume normal versus emergency audit bytes, despite T-P04 requiring every exact slot and byte boundary (`test-spec-r3.md:65-71`).

**Consequence:** An account can reach a valid accepted database state in which the next profile revoke cannot atomically write its mandatory audit. The coordinator must either exceed the physical cap, omit an audit, or reject revocation. Capacity tests have no authoritative operation-to-charge map and can pass using a favorable implementation-specific allocation.

**Required correction:** Give revoke audits a disjoint reserve sized from the maximum simultaneously revocable profile heads, or define an atomic replacement/aggregation rule that provably preserves required quarantine evidence. Publish a complete event-to-row/byte/partition charging table and prove its inequalities. Test exhausting every other emergency class first and then revoking every still-active profile without exceeding total caps; separately test the truly exhausted terminal behavior.

### H6 — The mandatory Go descriptor protocol contradicts itself at locking and compaction close

**Severity:** High

**Evidence:** C3A says `confirmed-profiles.jsonl` has “its own lock and HMAC key” (`prd-implementation-plan-r3.md:225`), while C8 mandates one `private.lock` acquired before opening both `requests.jsonl` and `confirmed-profiles.jsonl` (`:376-380`). No two-lock order or shared-lock decision is frozen. C8 additionally requires every data descriptor to equal the current pathname before close (`:378`), then requires compaction to rename the temporary inode over that pathname, reopen it, and only afterward close the old descriptor (`:380`). After the rename, the old descriptor cannot equal the current pathname by construction. T-G02 asks implementations to exercise both authorities and every close/rename identity check (`test-spec-r3.md:173-177`).

**Consequence:** No implementation can satisfy all mandatory checks. Choosing separate locks introduces an unspecified lock order and cross-authority race surface; choosing one lock violates C3A. During compaction, either the required old-descriptor close check fails every successful compaction or an implementer silently omits a required identity check.

**Required correction:** Freeze exact lock names, ownership, scope, and total order for both authorities and their key files. Define the old/new descriptor state machine around `renameat`: the final permitted pathname match for the old inode, the expected post-rename mismatch, the new target equality, and close rules for each descriptor. Align fault/race tests to those exact states on macOS.

### M1 — Journal framing narrows `request_id` without defining a supported-mode compatibility rule

**Severity:** Medium

**Evidence:** C8 encodes journal `request_id` as RFC 4122 16 bytes (`prd-implementation-plan-r3.md:351-364`). The plan simultaneously preserves the unchanged v1 envelope (`:231-239`), whose pinned SPEC-041 contract permits any 1..128 printable ASCII request ID (`specs/SPEC-041-relay-blind-request-encryption.md:114-120`). C1 mentions how UUIDv4 text is framed but never requires the supported Build 2 inference-envelope request ID to be UUIDv4. Only wallet signed-request IDs are explicitly UUIDv4.

**Consequence:** A syntactically valid unchanged v1 request can be accepted by the service but cannot be represented by the mandatory supported-client journal frame. Go and Malibu may impose different undocumented request-ID subsets, undermining shared vectors and compatibility claims.

**Required correction:** Either add an explicit supported-profile-mode UUIDv4 request-ID constraint at the envelope boundary while documenting legacy compatibility, or frame the existing bounded ASCII request ID with `u16str`. Add non-UUID valid legacy and UUID Build 2 vectors across Go, Swift, and JavaScript.

### M2 — Client revocation freshness has no versioned, rollback-resistant synchronization object

**Severity:** Medium

**Evidence:** C2 says signer/bundle revocation is published in coordinator capability state (`prd-implementation-plan-r3.md:167-173`), and C3A says emergency signer/bundle revocation “must be refreshed before a new private transaction” (`:229`). No route/schema identifies the revocation generation, signed or authenticated freshness timestamp, maximum acceptable age, ETag/CAS behavior, rollback detection, or atomic relation to the profile GET. C6's capability publication covers status/evidence versions and retention, not a client-consumable revocation watermark (`:333-335`). T-C04/T-P07 assert publication and post-restart disabling but cannot construct a stale/rollback oracle from the normative bytes (`test-spec-r3.md:33-37`, `:81-87`).

**Consequence:** Clients can disagree on whether a cached response is fresh enough and can display or attempt a profile after an emergency revocation without a defined fail-closed synchronization decision. Coordinator lifecycle checks still protect admission, but the supported local trust/UX claim and offline/restart behavior are not testable as written.

**Required correction:** Define a closed authenticated revocation-status object with generation, issued/expiry times, signer/bundle tombstone identifiers or a committed digest, cache rules, and monotonic rollback handling, or explicitly make an authoritative no-cache profile/preflight response carry those facts. Specify outage behavior and add stale, replayed, reordered, clock-skewed, and concurrent-revocation vectors.

### M3 — Exact operation/audit capacity tests still lack reachable state constructions

**Severity:** Medium

**Evidence:** C9 permits at most 32 profile IDs and 64 retained revisions per profile, for 2,048 successful create/replace heads, while assigning 3,968 normal mutation-operation rows per account (`prd-implementation-plan-r3.md:390-414`). It does not state which rejected/failed operations receive retained idempotency rows or how to reach rows 2,049..3,968 without pruning/reusing profile revision capacity. The audit table likewise has no exhaustive event cardinality/charge construction. T-P04 requires filling every normal slot and byte boundary without bypassing other limits (`test-spec-r3.md:65-71`).

**Consequence:** The exact-boundary test either cannot reach the advertised limit or must invent retained failed-operation semantics that affect idempotency and denial resistance. The startup inequalities do not prove the published limits can coexist.

**Required correction:** Supply a reachable worst-case state derivation for every row and byte partition, including which failed requests persist, their canonical charge, and their pruning horizon. If no supported state can reach a boundary, reduce/redefine the limit and test the actual controlling boundary without disabling another cap.

### M4 — Real-browser acceptance has no dependency-compliant harness plan

**Severity:** Medium

**Evidence:** The pinned Malibu `package.json` provides Node tests, docs validation, Vite build, and preview but no browser automation package or command. Malibu governance forbids adding dependencies without explicit approval. R3 requires real Safari and Chromium runs and treats them as mandatory evidence (`prd-implementation-plan-r3.md:478-486`, `:511-519`; `test-spec-r3.md:189-205`, `:241-243`) but does not choose a no-new-dependency harness, identify browser/driver prerequisites, define secure-origin startup/certificate handling, or describe how Web Locks/IndexedDB crash and two-tab cuts are controlled. On the reviewed host Safari and Chrome applications are present and `safaridriver` exists, but no `chromedriver` executable is present; host inventory is evidence, not a portable CI contract.

**Consequence:** The Malibu slice can reach implementation with no approved way to execute its required acceptance suite. Node mocks could be mistaken for browser evidence, or a new dependency/tooling choice could materially change the test strategy after the plan gate.

**Required correction:** Before approval, choose and document the dependency-compliant Safari and Chromium harness, exact commands, secure-origin/certificate setup, browser-version support, process/tab crash controls, artifact/log redaction, CI versus physical-host ownership, and explicit blocker behavior when automation is unavailable. If a dependency is required, obtain that repository's approval before implementation and reopen the gate for the changed strategy.

## R2 finding disposition

| R2 finding | R3 review disposition |
|---|---|
| H1 null and locator rules | Corrected for plan purposes. The per-object table and literal representation-byte vectors are exact. M1 is a separate envelope/journal request-ID compatibility problem. |
| H2 durable local authority | Partially corrected. A real local record/HMAC design now exists, but H1, H2, H6, and M2 leave replacement recovery, compaction, filesystem ownership, and revocation synchronization incomplete. |
| H3 authenticated refund response | Corrected for plan purposes. C6A plus production TLS binds the accepted negative economic evidence. Production key provisioning remains correctly external. |
| H4 exact journal record/state locator | Partially corrected. State-specific fields and locators are present, but H2/H6 and M1 leave durable compaction and exact encoding unimplementable. |
| H5 hard caps/emergency writes | Partially corrected. Numeric partitions now exist, but H5 and M3 leave revoke availability and exact boundary construction unproved. |
| H6 wallet replay capacity | Corrected for plan purposes. The fixed monotonic status-authority row preserves inference replay capacity and fails new reservation before encryption. |
| M1 unreachable profile cap | Corrected. The 128/profile boundary is reachable below 512/account and has an independent test. |
| M2 convergence work bounds | Not corrected. H4 shows the formula still omits total result-persistence work and a unique-visit retry invariant. |
| M3 typed error table | Not corrected. The 51 rows exist, but H3 shows their single wire `action`/HTTP object cannot represent the two client-state-dependent tuples and does not map the pinned legacy inventory. |
| M4 Go pathname ancestry | Partially corrected. Descriptor traversal is much stronger, but H6 contains incompatible lock and post-rename close requirements. |

## Required next gate

Revise the plan and paired test specification without weakening the signed-bundle bootstrap, server-side approved-identity selection, pool/SQLite double collect, provider-plaintext disclosure, no ciphertext failover, signed rejection-only refund authority, wallet replay separation, or actual-MLX acceptance boundary. The next independent GPT-5.6 Sol reviewer must receive the exact new artifact hashes, both repository revisions, this review, and the R2 review. Implementation remains prohibited until a fresh gate reports zero Critical, High, and Medium findings.

## Review method and evidence boundary

This was a code-grounded, read-only review of the exact submitted bytes and pinned revisions. It independently inspected the current coordinator/gateway relay-blind schemas and state flow, gateway representation-byte provider-binding hash, unsigned current refund recovery, coordinator URL validation, SPEC-040 wallet replay rules, SPEC-041 envelope/error/status contracts, and the pinned Malibu storage/retry/test surfaces. No implementation, unit/integration/browser/MLX/deployed-service/production test was run or promoted. No `d-inference` source was inspected.
