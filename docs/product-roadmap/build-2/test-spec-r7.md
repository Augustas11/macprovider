# Product Build 2 test specification

**Test revision:** R7
**Paired plan:** `prd-implementation-plan-r7.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`
**Status:** draft; implementation and acceptance are prohibited until the paired plan gate reports zero Critical, High, and Medium findings
**Failed predecessor review:** `reviews/plan-r6-sol.md`

## 1. Evidence classes and instrumentation

Every result records exact revision, command, selected test count, duration, exit status, and environment class. Classes are: unit/property test, deterministic Go/Swift fixture, real browser, actual MLX on physical Apple Silicon, deployed service, and production qualification. Skipped, timed-out, zero-selected, fixture-only, or historical results cannot be promoted.

The two-provider harness creates independently signed identities A/B, distinct assigned sessions, encryption keys, and Swift provider processes. It records bounded events for pool epoch/generation, selection phases, reservation/profile state, gateway recovery state, quota/session transitions, public sends, provider frames, and settlement. Payload logs are prohibited. Barriers expose every D/P transition and cross-store crash cut. A fake clock, deterministic random source, SQLite fault hooks, HTTP transport counter, and process-restart harness are mandatory.

Shared fixtures are consumed byte-for-byte by Go, Swift, and JavaScript. Each fixture records raw JSON, accepted/rejected result, exact binary framing hex/base64url, digest, and signature result. Test-only signing keys are labeled local and never accepted by production keyrings.

## 2. Cross-runtime schema, numeric, and framing tests

### T-C01 Closed JSON and numeric grammar

The Slice 1 machine-readable schema manifest enumerates every object in C1. Go, Swift, and JavaScript consume the same vectors and accept only its exact per-object field set, conditional fields, and types. For each field independently test missing, unknown neighbor, duplicate, explicit null, omission, wrong type, trailing bytes, body/record maximum plus one, and noncanonical base64url. Assert JSON null is accepted only for profile-list `next_cursor`, status-request `envelope_digest`, and the two status-response token fields; each is present as null where specified and omission fails. Confirmed-profile records accept no null: `record_kind` selects exactly one closed payload, absent expected authority carries only its exact absence fields, and present expected authority carries only its exact authority object. Assert journal conditional fields occur only in named states.

Consume `profile-response-capacity-v1.json` byte-for-byte. The accepted profile's exact active and maximum-timestamp revoked projections both fit, with one exactly 16,384 bytes; the smallest active-or-projected-revoke response requiring 16,385 bytes fails before invitation/profile/audit/slot mutation. Revoke the boundary profile at minimum and maximum safe timestamps and require the actual response to fit its reserved extent. Vary quotes, backslashes, `<>&`, pin/model counts, model lengths, timestamps, and every displayed field to prove the serializer and oracle use identical field order/escaping with no whitespace, newline, or HTML escaping. For every wire-error tuple, verify its maximum encoded response bytes/length/digest and the 2,048-byte ceiling. Zero selected tuples or a regenerated nonmatching oracle fails.

List 32 maximum profiles from a fixed dataset. The byte-aware paginator returns the largest ordered nonempty prefix whose exact response plus next cursor is <=65,536 bytes, then resumes without skip/duplicate until all rows are returned. Test a boundary where adding the next profile or cursor changes the fit, requested limits 1/20/32, empty list, a single maximum profile, and every response at most 65,536 bytes.

For each integer field test raw tokens `0`, `1`, `9007199254740991` where allowed, and reject `-1`, `-0`, `00`, `01`, `1.0`, `1e0`, `1E+0`, quoted numbers, `9007199254740992`, Int64 max, overflow, NaN, and Infinity before state mutation. Go uses raw `json.Number`; JavaScript duplicate/numeric scanning is tested before `JSON.parse`; Swift uses raw lexical fixtures. All three produce identical verdicts.

### T-C02 Profile framing parity

Freeze positive vectors for one pin, 16 pins, 16 models, boundary timestamps, null status digest, different profile/bundle/invitation IDs, the three confirmed-profile payload variants, both expected-authority tags, mutation request/response/response-slot digests, the revocation empty root/first entry/all four target kinds/exact Ed25519 checkpoint, root marker/account-scope/policy/access-group digests, exact Keychain add/read/update dictionaries and normalized attributes, bootstrap initializing/committed values, accepted genesis/first-append/second-append-after-retirement/compaction tail-pointer-external-head sets, and all browser paired-ledger request/response objects. Assert exact domains, tags, `u16str`, big-endian integers, decoded fixed-size fields, ordering, root/policy/prior-pointer/head bindings, and final digests/MACs/signatures in Go/Swift/JavaScript. The three C1 provider-binding vectors produce the listed ASCII-input digests; decoded-byte hashing differs and fails. One-byte mutation and alternate serialization fail wherever bytes are authoritative. Reject non-ASCII, overlength, normalization variants, duplicate/unsorted arrays, counts 0/17, wrong checkpoint key/domain, wrong Keychain policy/attribute/type, cross-root substitution, and rolled-back/gapped checkpoint ranges.

### T-C02A Request-ID mode compatibility

Across Go, Swift, JavaScript, gateway and coordinator, profile-header mode accepts only canonical lowercase UUIDv4 envelope `request_id` and frames its RFC 4122 bytes into the journal. The supported client rejects uppercase, braces, non-v4 UUID, malformed and generic printable ASCII before journaling/encryption; the gateway rejects them before consume/dispatch. Headerless legacy v1 continues accepting representative non-UUID printable ASCII IDs and never enters the Build 2 journal. Mixed/partial profile headers fail closed.

### T-C03 Signed provider bundle

Verify exact signature/framing/digest vectors, known signer KID, signer validity, bundle ID/revision, issue/expiry, 24-hour bundle lifetime, 60-second skew, 30-day pin lifetime, supported version, and pin scopes. Reject corrupt signature, wrong domain/key/KID/digest, unknown/revoked/not-yet-valid/expired signer, stale/future/cross-release bundle, altered/substituted pin, unknown endpoint, revoked pin, and duplicate/unsorted arrays. Prove SPEC-023 feed, provider identity, wallet, payout, and test keys cannot validate a production bundle.

### T-C04 Invitation binding and trust bootstrap

Account A can fetch invitation I and the exact signed bundle; B, demo, wallet, anonymous, expired credentials, and altered path cannot. I is accepted only with exact bundle ID/revision/digest and selected byte-identical allowed pins. Reject cross-account redemption, different signed bundle, disallowed B substitution, expired/revoked/consumed invitation, reuse by a different operation, and signer revocation. A fresh client with only profile GET cannot enable encryption. A client with invitation but no valid release-baked signer cannot enable it. Test signer evidence is visibly local. After successful activation, ordinary invitation/bundle/signer-window expiry does not revoke the revision; earliest selected-pin expiry and explicit signer/bundle/profile/pin revocation do. Test both sides of that boundary.

Upload a valid public bundle through the operator listener, issue an account-scoped invitation idempotently, fetch it through the buyer gateway, and fetch exact bundle bytes/ETag through the public bundle route. Reject bundle/invitation operator calls on the buyer listener, buyer credentials on operator routes, private-key fields, changed operation replay, wrong account, wrong bundle digest, mutable replacement of an existing bundle revision, and deletion in place. Emergency signer/bundle tombstones survive restart and remain published/retained through the recovery horizon.

### T-C05 Route and wallet canonicalization

For the three reservation headers reject missing, duplicate, comma-joined, whitespace, case-conflict, oversized, invalid ID/digest, and revision numeric variants. Wallet reservation signatures succeed only when the exact header profile `accept,idempotency-key,three trust headers` is bound in sorted SPEC-040 bytes. Mutation of body/header/route/account/session/request ID/timestamp/signature fails before coordinator/quota.

Exercise wallet profile mode with two credentials held separately. The account API key alone calls identity/profile GET and C3B v2 with `reservation_auth_mode: wallet_session` plus the exact wallet session ID; the later reservation/status requests contain only wallet bearer/signature material. Reject both credential types on one request, missing account key, wallet-only preflight, account/profile subject mismatch, wallet session owned by another account, inactive/expired/revoked session, changed session after preflight, wrong signed response binding, and stale/replayed preflight. A valid split flow reaches wallet reservation without granting wallet profile read/mutation authority. Malibu exposes account-key private mode only.

For `POST /v1/relay-blind/request-status`, prove the wallet signature binds the exact raw v2 body, canonical route, UUIDv4 request ID, `accept`, canonical status sequence, and timestamp. Reject queries, body/header re-encoding under an old signature, duplicate covered headers, wrong account/session/locator, stale/future signature, equal/lower sequence with identical or changed request ID/body, and profile mutation/read with wallet bearer. A newly signed higher sequence updates the one status-authority row then polls without dispatch, refund, or budget/profile mutation.

Create the fixed status-authority row before returning each wallet reservation and fault every statement/commit. If it cannot commit, no reservation reaches the client and no encryption begins. At `session/account limit-1`, exact row/byte limits, and over limit, prove new reservation admission fails before return while every existing row remains updateable for higher-sequence polls through the safe-integer ceiling. Restart retains `highest_sequence`; nonterminal and within-8-day evidence cannot prune. Polling never inserts into, consumes, or evicts inference/ordinary metadata replay rows, and their replay rejection remains exact. A client crash/rollback that repeats a lower sequence advances locally and retries only status. Sequence overflow, session expiry/revocation, or authority-store outage keeps economics background-reconciled/held and never authorizes inference retry.

### T-C06 Error inventory and precedence

Generate server fixtures from `wire-errors-v2` and client fixtures from `client-reducer-v2`. Servers reject/never emit `action`; clients derive the fence only from authenticated local state. The mandatory sizing/error gate receives the complete `error-emission-inventory-v2.json` and its digest before any error implementation. Assert each exact field and recompute every `emission_key`; each route helper expands to one row per exact `METHOD SP PATH`, each dynamic branch expands to every finite code, and every row repeats the complete replacement tuple and both actions. At the pinned gateway base the source scan must select exactly 40 direct emitters in `relay_blind.go`, 22 in `relay_blind_success.go`, and 25 in the three named wallet helpers, with three dynamic branches expanded. Separately require every reachable coordinator and planned new route/client emitter exactly once. Fail the second gate and CI on a missing, stale, duplicate, ambiguous, line-number/message-derived, unexpanded, newly reachable, or unreviewed-default mapping. Explicitly execute quota, duplicate ID, concurrency, settlement arm, internal audit/store, wallet auth/signature/lifecycle/cap/replay/rate, AbortError, DNS/TLS/timeout/EOF, and malformed/non-JSON/empty response cases before and after `send_fenced`. Unknown/missing/duplicate/action-injected/status-mismatched bodies become unknown. Pairwise precedence proves terminal/replay, fence, C6A evidence, lifecycle, capacity, and transport ordering; HTTP/retryable alone never authorizes envelope reuse.

## 3. Invitation/profile storage, bounds, and migration

### T-P01 Account isolation and exact CRUD

Create, get, list, replace, and revoke with account A. Verify exact response fields/digests/no-store headers and absence of provider ID/session/internal IDs/operator config. Account B gets constant-shape not found. Demo/wallet/anonymous cannot read or mutate. Create revision is 1; replacements increment by exactly one; revision rows are immutable; revocation leaves the digest unchanged and writes a tombstone.

### T-P02 Operator intersection

Accept only byte-identical signed pins whose fingerprint maps uniquely to the configured operator provider key. Reject unmapped identity, provider self-assertion, wrong public key/fingerprint, admission/receipt/wallet key, duplicate provider mapping, mapping changed after invitation, and signer/bundle invalidation. No failed operation creates/advances an active profile.

### T-P03 Operation idempotency and CAS

For create, replace, and revoke independently, persist the exact method/route/content type/body/digest, then cut before server receipt, after auth, after operation-row/response-slot reservation, during incremental-BLOB write, after semantic validation, after mutation/invitation/tombstone writes, after transaction commit, and during/after response. Run minimum, typical, exactly 16,384-byte maximum success, smallest 16,385-byte rejected prospective success, and every maximum 2,048-byte-or-smaller v2 error oracle. From every `sent_or_unknown` cut and restart, replay only those exact bytes with the same operation ID. Before-receipt replay may perform the operation once; committed replay returns the stored slot bytes byte-for-byte without regeneration; sealed no-commit replay returns the inline stored v2 error byte-for-byte; a transient inability to allocate an operation/response slot leaves the client pending and replayable without mutation. Reject wrong length/digest/kind/profile/revision, nonzero padding, unequal digest collision, truncated extent, and response-byte regeneration drift as corruption. Delete all GET/list/invitation evidence and prove none is interpreted as absence. Changed method, route, content type, or one body byte conflicts; rotated authorization is allowed only for the same account subject. Two initial deliveries and concurrent recovery serialize to one terminal row with no revision, invitation, tombstone, audit, response extent, or economic amplification. After eligible operation-row pruning, activation requests fail their expired evidence, while exact revoke of an already revoked matching target returns the stored current revoked response without another tombstone. Wrong digest, revision rollback/gap, consumed invitation mismatch, and concurrent revoke/replace remain linearizable. At normal operation/page/response capacity, revoke overwrites its fixed 16 KiB extent and fixed operation/audit rows with no page, row, index-key, or BLOB-length growth.

### T-P04 Exact caps and pruning

Test exact/over boundaries and C9 accounting for every per-account and global cap: 8 signers; 1,024 bundle revisions/32 MiB; 2,048 unique stored-bundle pin fingerprints; 256 profile accounts; 16 live and 32 retained profile IDs/account; 4,096 live IDs; 8,192 immutable revisions/64 MiB metadata; 8,192 success and 8,192 revoke response extents as conservative independent maxima within exactly 16,384 preallocated 16 KiB extents/256 MiB payload; 16,384 fixed 4 KiB normal operation rows/64 MiB; 8,192 fixed 2 KiB normal audit rows/16 MiB; 8,192 fixed profile revoke operation/audit/response sets; fixed 4 KiB signer/bundle/pin emergency operation/audit units; 16,384 invitations; 8,192 reservations; 1,000 joins; 262,144 wallet-status rows; 8 paired browser IDs/account and 8,192 globally; 65,536/128 MiB browser operations plus fixed DELETE slots; local-store peaks; 1,024 normal tombstones; 7,176 target-bound emergency slots; 8,200 total tombstones; and 16 checkpoint slots. Boundary construction uses supported APIs and never assumes incompatible per-account maxima coexist beyond a global cap.

Run the exact response oracle through the proposed DDL. Migration must instantiate all 16,384 profile response extents at their fixed 16,384-byte physical length, for exactly 256 MiB payload independent of logical occupancy. In separate supported-API boundary scenarios, write maximum oracle bytes into every semantically reachable sealed success/revoke slot; verify exact sealed lengths/digests/zero padding, and verify every free or reserved extent remains in its required zero form. Reach 1 GiB/512 MiB live-page ceilings, 16 MiB/8 MiB transaction reserves, WAL ceilings, and free-disk reserves at limit-1/exact/over. Inspect `dbstat`, every table/index/overflow page, incremental-BLOB page identity, page/freelist/max-page counts, WAL frames, FULL checkpoint, restart, and competing nonfeature growth. From the exact jointly reachable full-tombstone/live-target state, revoke a maximum-response live profile and prove the fixed response/operation/audit/tombstone writes allocate no page, row, index key, or longer BLOB. Any smaller physical fixture, regenerated body, overflow, compression assumption, invented co-reachability, or observed threshold increase fails and reopens the gate. Runtime storage remains prohibited until the exact DDL, byte-oracle, measurement, and error-inventory digests pass the second independent review.

Separately exercise 64 revisions on one profile and 1,024 successful heads/account while global capacity remains, fill normal operation-only slots with sealed semantic rejections, and prove replay reuses its row. Auth/body rejection and transient inability to reserve an operation/response slot charge zero and cannot restore authority. Exhaust normal operation rows, all 24 recovery-quarantine slots, wallet/status capacity, and client normal capacity; every live profile still owns fixed revoke operation/audit/response and emergency slots. Fault storage I/O separately and assert pending/disabled plus storage-outage reporting, never capacity classification. Reach 128 live reservations/profile and 512/account through normal admission; reject only the precise next limit.

Execute the normative joint history without test-only insertion. Activate exactly 8 signers and 1,024 bundle revisions containing exactly 2,048 unique pins. Across 256 accounts, issue 1,024 invitations and create 4 temporary one-revision profiles/account. Enumerate all 7,176 typed emergency slots and assert 4,104 exact live owners plus 3,072 free profile slots. At 64 normal tombstones per fake-clock hour, revoke every temporary profile into one distinct normal slot; after each atomic commit verify the normal tombstone and fixed response evidence are sealed, the target is nonlive, only its still-unsealed profile emergency slot was zeroed/released, and the complete owner/free map remains a bijection. After 16 hours, normal tombstones are exactly 1,024/full, all 1,024 temporary profile revisions/responses remain retained, and exactly 4,096 profile slots are free.

Before the 24-hour bundle/invitation activation boundary, issue 4,096 new invitations and create 16 final profiles/account using the free profile slots. Assert the simultaneous maximum: 1,024 historical normal tombstones; 5,120 retained revisions; exactly 10,240 bound response extents comprising 1,024 temporary successes, 1,024 sealed temporary revokes, 4,096 final successes, and 4,096 final revoke reserves; 6,144 zero-filled free response extents; and exactly 7,176 unrevoked live targets with a typed slot bijection whose complete map has no free slot or duplicate owner. Reject the next signer/bundle/pin/account/live-profile activation before visibility, and exercise retained-profile/revision/response maxima separately where the caps are not jointly reachable. Fill remaining normal operation rows with sealed no-commit errors. Advance the fake clock through the same 64/hour limit and revoke, in exact leaf-to-root order, all 4,096 profiles, 2,048 pins, 1,024 bundle revisions, and 8 signers over 113 additional rolling-hour windows. Assert that ordinary bundle expiry after activation does not silently revoke active profiles and that the 129-hour construction remains inside the 30-day pin-validity and 38-day evidence-retention horizons. Immediately before each operation assert that target is unrevoked; afterward assert its emergency slot sealed at the next generation without allocation/growth and update the complete slot-owner/sealed-state ledger. Restart at every target-kind boundary and sampled BLOB/tombstone commits. Verify 8,200 consecutive generations, at most 9 used of 16 checkpoint rows, singleton/root continuity, prunable checkpointed prefix, first-suffix predecessor, empty-suffix equality, and reference-delayed retention.

For each kind while normal operation capacity is available, nonexistent, pruned, already-revoked, wrong-kind, mismatched-digest, and duplicate new-operation revocations return the exact sealed no-commit error and create no tombstone. Repeat after normal operation saturation: they return transient unsealed unavailable and cannot bind or alter the target's fixed emergency unit. Exact replay of a previously sealed result returns it in either state. A normal-slot target's emergency slot may be reused only after the same transaction made it nonlive and committed its normal tombstone. A sealed emergency slot is never reused before every 38-day/reference/checkpoint horizon drains. Exercise time just before/at each release boundary and prove no prune crosses a client watermark, signer overlap, profile/invitation, reservation, recovery, or operation-response reference.

### T-P05 Coordinator migration and rollback

Migrate a pre-Build-2 DB containing every legacy reservation/key state. Crash before/after table creation, copy, index, verification, and schema stamp; reopen and rerun. Prove row counts/bytes/replay fences, status v1, terminal history, and foreign keys survive. Profile-required mode rejects legacy predispatch rows but preserves postdispatch. New `selection_pending`/`dispatch_authorizing` values cannot be exposed to an old binary: rollback checker blocks until drained/fenced. No migration refunds or drops tombstones.

### T-P06 Gateway migration

Migrate API-key and wallet quota rows in active/held/stale-held/quarantined/settled/refunded states. Legacy relay-blind uncertainty imports conservatively held, never refunded. Crash/restart/double migration preserves account/session/request identity and settlement journal links. Verify no relay-blind held token exists without a discoverable recovery join after new admission.

### T-P07 Durable confirmed-profile authority

Go and real Safari/Chromium consume shared exact record/MAC/chain vectors. After signed-bundle confirmation and exact profile creation, restart the CLI and reload/close/reopen the browser after invitation, bundle, and signer activation windows expire; the still-valid pin remains usable only when the authenticated account identity and server profile exactly match the local record. A fresh store plus profile GET never enables private mode.

Test cross-origin/account/profile substitution, changed signed-bundle bytes, selected-pin mismatch, HMAC-key loss, record/MAC/predecessor/generation tamper, partial and whole-record rollback, stale server revision, server rollback, record truncation, local clear, cap/full disk/IndexedDB quota, two processes/tabs, and concurrent replace/revoke. Any mismatch disables sends. For valid local rollback to an older revision, the newer server revision detects it. A record restored to the same immutable active revision may synchronize but cannot recover a prior process/page's request-send ownership.

For create, replace, and revoke, prove the complete v3 discriminated pending record, exact replay tuple/digest, and external C8 head commit before the call and `sent_or_unknown` commits immediately before it. For each mutation cover candidate/pending write and readback, external-head publication/readback, disposition write/head, every T-P03 server cut, terminal response loss, local stable/expected/absent append/head, restart, and concurrent send/recovery. Create starts from exact tagged absent/genesis authority; cancellation from `not_sent` appends an anchored absent marker, while every later cut is exact-replay reconciliation only. A sealed no-commit result restores the exact expected authority/absent marker; a transient response cannot. Delete responses, GET/list results, invitation state, and caches and prove recovery uses only the persisted target plus exact replay. Replace/revoke use present expected authority; revoke advances from the C3B empty/current root to signed tombstone evidence before stable revoke. Mutate every envelope/payload/tag/target/replay field. Stable active, stable revoked, pending, and absent never compare equal. Verify exact charges and byte-identical response replay at every terminal path.

Freeze empty-root, first-entry, each target-domain frame, subsequent roots, checkpoint/pruning, and C3B v2 request/response/signature bytes across Go/Swift/JavaScript. Fresh deployment returns signed generation 0 with only the defined empty root; first entry uses it as predecessor. Exercise stale/expired/reordered/replayed/lower/same-different-root, clock, every binding, bad/rotated signer, TLS/redirect/outage, concurrent tombstones, and wallet/account/session split. New sends require a <=15-second signed result anchored locally. A tombstone after preflight is rejected by lifecycle. At every local/coordinator capacity, all active profiles remain revocable through reserved paths. Explicit revocation disables use after restart; activation-artifact expiry alone does not. Scan bytes for prohibited material.

## 4. Pool/SQLite selection and lifecycle

### T-S01 Generation coverage

Assert epoch changes on process restart and generation increments exactly once before unlock for register/remove, session rotation, state, serving predicate, tunnel, model/provider-model, capacity/admission flag changes. Unrelated metadata does not change it. Counter overflow disables relay-blind selection without wrap. Snapshots contain at most the 16 operator-mapped approved provider IDs and no caller mutation can alter returned tuples.

### T-S02 A-only when B sorts first

With B globally first and both otherwise eligible, reserve using A-only. Assert selected signed key fingerprint A, exact profile/bundle/invitation and pool token persisted, zero B reservation/consume/dispatch frames, and no ephemeral key/nonce/envelope before the client verifies A. This cannot be replaced by client-side rejection.

### T-S03 A+B, no candidate, and scopes

With A+B verify stable filtered ordering, A/B availability changes for fresh reservations, and exact pin membership. Reject approved providers offline/stale/no tunnel/wrong model/full capacity, expired/revoked key/pin/bundle/signer, removed operator mapping, and only unapproved B. No candidate returns typed error before encryption/quota, leaks no provider ID, and has no plaintext/legacy fallback.

### T-S04 Double-collect barriers

At D0/P1/D1/P2/D2/P3/final-read barriers race profile replace/revoke, invitation/bundle/signer invalidation, key rotation/revoke, provider disconnect/reconnect/session/model/state/tunnel/capacity changes, epoch restart, SQLite busy, and cancellation. A successful response proves equal epoch/generation around D2 and an exact `reserved` final read. Every mismatch rejects/fences the pending row and retries at most three times. Churn exhaustion is typed. No response references a pre-transaction or stale tuple.

### T-S05 Lock order and liveness

Instrument pool and DB locks. Fail the test if a pool lock overlaps SQLite begin/wait/transaction or network, or if a SQLite transaction calls pool/network. Run heartbeats, 100 concurrent reservations, profile mutations, status, key updates, and busy writers under the race detector. Heartbeats make progress, waits stay <=5 seconds, no deadlock/starvation occurs, and orphan pending rows expire/restart-fence within 30 seconds.

### T-S06 Consume and final arm

Repeat generation/profile/key/session barriers at consume D0/P1/D1/P2/final-read and final-arm D0/P1/D1/P2/D2/P3. A failed consume postcheck burns the envelope. `dispatch_authorizing` is non-dispatchable and invalidated by a profile mutation that linearizes before D2. A stable P2/D2/P3 permits one exact-session send; a P3 mismatch or crash after D2 produces conservative unknown/held state without a network retry or automatic refund. A mutation after D2 observes irreversible dispatch authorization. Churn after successful P3 is allowed to make the exact-session send fail, but never chooses B or refunds as proven predispatch. B never receives A-bound ciphertext.

## 5. Status and client recovery

### T-L01 State-specific v2 status

For a fresh `reserved` row, null, correct-looking, and wrong envelope digests all return the same authenticated `unbound` status and never claim digest validation. Wrong binding/account/session fails constant-shape. Once consumed, null/wrong digest fails and exact digest returns `bound`. Test rejected-before-consume (`unbound`) and rejected-after-consume (`bound`), plus `dispatch_authorizing`, dispatched, terminal, and unknown. Missing/duplicate/unknown/oversized fields fail. Status never dispatches, changes trust, exposes provider/profile pins/raw binding/output, or creates quota.

### T-L02 Expiry and safe actions

With fake clock, fresh reserved/consumed/authorizing remains held and says `check_status_do_not_resubmit`. Status atomically fences expired predispatch to C6A-verified rejection with `dispatch_proven_absent: true` and permits a wholly new transaction. Dispatched/terminal/unknown always say `do_not_resubmit`. Store unavailable/retention gap never says refund or retry. Legacy v1 behavior remains exact for legacy rows.

### T-L03 No ciphertext retry/failover

Hash envelopes and count public sends/provider frames across queue-full, NAK, 502/503, timeout, cancel, buyer/gateway/coordinator/provider disconnect, restart, key/profile/session change, and generic retry middleware. Each hash has <=1 public inference send and <=1 exact provider/session. Fresh work uses a new reservation, request ID, ephemeral key, nonce, and envelope. Relay-shaped data never reaches plaintext transport.

### T-L04 Replay, cancel, reconnect

Replay exact and semantically re-encoded envelopes before/after gateway restart, feature cycling, rate saturation, profile replacement, and provider recovery. Durable replay wins. Cancel before reservation, after reservation, after `send_fenced`, before/after consume, during authorizing, after dispatched, after first output, and during terminal persistence. Restart provider at claim/decrypt/validate/output/terminal cuts with same/new session. Prove exact state/action/accounting and no reexecution/failover.

## 6. Cross-store quota, refund, and settlement

### T-Q01 Atomic quota/recovery join

For API-key and wallet requests, fault every statement/commit in quota admission. Either quota/session reservation and recovery join all commit, or none do. The first held token is always discoverable. Capacity/account/wallet admission failure leaves coordinator consumed material burned and no quota leak; status eventually permits only a new transaction after predispatch rejection/expiry.

### T-Q02 Atomic dispatch intent

Fault account hold, wallet arm, recovery-state transition, and commit. All roll back together. No coordinator dispatch call occurs unless the join is `dispatch_intent` and required holds/arms exist. Duplicate arm is idempotent or conflicts safely.

### T-Q03 Invalidation matrix

For profile replace/revoke, signer/bundle/pin/operator/key/model/session invalidation at every coordinator state and gateway state (`no_join`, `quota_active`, `dispatch_intent`, `held`, terminal), assert the C6 table. Only a C6A-verified terminal rejection with `dispatch_proven_absent` refunds, exactly once. Predispatch fresh and unavailable status remain held. Postdispatch never refunds solely due invalidation.

### T-Q03A Coordinator evidence authentication

Go fixtures freeze the exact C6A signed bytes and positive/negative signatures. For dispatch and status, mutate each response/proof field and reject wrong domain/key/KID, signature, challenge, operation/route, account, wallet-session empty sentinel/session, request ID, provider-binding digest, envelope tag/digest, response digest, issue/expiry, and replayed proof. Test a valid proof applied once, duplicate workers, proof stored then crash, and a new challenge after restart; refund/settlement changes at most once.

Integration uses TLS with a local CA and distinct coordinator/misroute identities. Reject wrong hostname/CA, redirects, remote plaintext HTTP, TLS skip, a correctly TLS-authenticated service without the pinned evidence signer, a valid signer from the wrong response/request/account/session, stale/replayed proof, and signer rotation without overlap. Allow plaintext only for the explicit loopback development flag and still require the test evidence signature. Signer/TLS/coordinator outage holds economics and never refunds. Production-key provisioning remains an external qualification blocker.

### T-Q04 Crash/restart recovery

Crash gateway after consume, during atomic quota admission, after quota/join, during dispatch-intent arm, before coordinator call, after coordinator rejection/dispatched, after first response, and during settle/refund. Repeat for API key and wallet. Restart one/two concurrent reconcilers. Oldest-first CAS converges without duplicate refund/settlement; coordinator/store/network outage remains held; contradiction quarantines.

### T-Q05 Retention and convergence

At 1,000 nonterminal rows and batch 100, instrument exact C6 scan epochs/cutoffs, 20 workers, five two-second waves, one <=3-second claim and one <=3-second aggregate transaction per pass, 18-second pass work, and <=10-second interpass delay. Assert no per-row persistence transaction. Failures/retries cannot be reclaimed until every frozen-epoch row has a first call; later arrivals wait. With bounded contention, every original row receives its first call by `floor((N-1)/B)*(P+I)+C+floor(((N-1) mod B)/W)*L`; the last row must start by 263 seconds, including four final-batch waves. Test non-divisible `(N,B,W)` shapes and safe-integer/zero/impossible configurations. Fault aggregate commit/restart and prove the same claimed batch remains ahead without duplicate economics. Persistent DB/network outage is unavailable/held and is outside healthy convergence.

Alert at >60 seconds. Coordinator evidence remains through 8 days and across gateway 7-day journal retention plus the 263-second convergence/skew margin. At 7 days unresolved becomes stale-held/operator-visible without auto-refund. Startup rejects too-short horizons or any formula above 300 seconds. Separately inject process crashes/restarts and report their measured recovery without claiming the 263-second healthy bound.

### T-Q06 Settlement/economic boundary

Duplicate and contradictory terminal evidence settles/refunds at most once; contradictions hold/quarantine. Known input and delivered output follow existing caps/rules. Profile/bundle assertions cannot change model identity, rate, cap, provider share, receipt verification, rewards, or payout readiness. Relay-blind positive SPEC-022/verified-work attribution remains excluded.

## 7. Supported Go library and CLI journal

### T-G01 Public package and trust flow

An external module imports `pkg/relayblindbuyer` without gateway internals. With injected transport/clock/random/journal/profile store, test account identity, invitation fetch, bundle verification, explicit fingerprint confirmation callback, profile CRUD, restart continuity, reserve, nonstream, stream, cancel, and status. Local confirmed trust must exactly match origin/account/profile revision/digest before profile GET synchronization or encryption. Fresh-store GET, stale local/server state, pending mutation, malformed/untrusted server data, or local durability failure sends nothing.

### T-G02 File safety and durability

On macOS exercise the non-overridable `getpwuid_r` coordination path, 0700 directory, 0600 `authority.lock`, root-local `private.lock`, immutable root marker, and every C8 descriptor step for both journal and profile authority. Reject environment-HOME/redirection, relative override, symlink/hardlink/FIFO/device/socket/wrong-owner/wrong-mode, wrong link count, root marker replacement, and every ancestor/final-component race. Require exact descriptor/path `(dev,ino)` equality before load/append/fsync and around `CURRENT` rename. After rename assert the old mismatch is expected, the new descriptor equals the captured temporary inode, and old close checks only its captured identity. Unsupported platforms fail before reservation/profile confirmation.

Test exact global-then-local lock ordering and the combined five-second **acquisition** deadline separately from post-acquisition work. Race two accounts, both authorities, and two different state-root overrides; no process reaches a Keychain read before both locks. Inject a noncancellable Keychain call completing before and long after the alert: both locks remain held, other roots/processes cannot enter, admission stays blocked, and exact readback selects old/new before release. Exercise immutable `O_EXCL` generation/tail/pointer objects, write/fsync/reopen, cache identity, parent fsync, and stable identity of both locks.

For both authorities, begin with no directory/items and prove freshness only through creation-only bootstrap add under both locks. Fault/crash before/after root-marker add/readback, bootstrap add/attribute readback, access-group derivation, HMAC add/readback, every genesis object boundary, external-head add/readback, bootstrap committed update/readback, `CURRENT`, and directory fsync. Exercise `initializing` resume with every prefix; require the same root/bootstrap IDs and deterministic genesis. Run `keychain-policy-v1.json` against an in-memory dictionary spy and real Security.framework: exact account-scope/root/policy/access-group digests, service/account/generic selectors, accessibility, Data Protection, synchronizable false, noninteractive UI, process-default group consistency, add/read/update values, returned-attribute normalization, and the nonsecurity metadata allowlist must match. Inject named group, custom access control/legacy ACL, authentication context/prompt, wrong accessibility/generic/group/class/service/account, synchronizable true, missing entitlement, interaction-required, and altered/extra security attributes; each blocks or quarantines without a prompt. Unversioned/pre-v1 items quarantine. A future-policy migration fixture uses distinct selectors and authenticated `migrating` state bound to the prior head; delete/re-add and absence-as-fresh fail.

Directory emptiness without successful bootstrap add, files/HMAC/head without bootstrap, committed bootstrap with missing state, and mismatched partials quarantine. A second empty root while selectors exist cannot initialize. No path infers genesis from an empty directory. Journal/profile bytes and Keychain metadata contain none of the prohibited data.

### T-G03 State concurrency and caps

Shared state-machine fixtures assert every C8 record field, conditional presence, request HMAC, record digest/MAC, generation/predecessor, locator, terminal class, transition, and prohibited transition. Two processes race every transition. Exactly one commits `send_fenced`; only that live in-memory owner epoch can make one send. Crash before first record, after reservation record, after envelope build, during fence fsync, after fence/before send, during send, and after response. After reopen, every persisted state has the promised status locator and is recovery-only. A stale lock/process, valid whole-file rollback, or restored earlier owner never takes over or resends.

Test 4,096/16 MiB active/40 MiB physical/4 KiB boundaries and every C8 frame. Byte fixtures cover genesis, first append, second append after retirement, and compaction. Every append must publish a new pointer whose prospective external generation and live tail tuple equal the new external head and whose prior pointer/head digests equal the previously authenticated objects. Fault before/after new tail and pointer write/fsync/reopen, Keychain replacement completion/readback, `CURRENT`, successful new-set load, old-tail unlink, old-pointer unlink, and directory fsync. Old-head recovery deletes candidates; new-head recovery requires the new pair and finishes retirement. Before another append there are at most current+candidate full-copy tails and two small pointers; a retirement failure blocks the next append/compaction. Measure exact peak against 40/88 MiB bounds.

Cover retained/omitted heads and every compaction crash. Restore a tail prefix, old `CURRENT`, old pointer, retained old complete generation, mismatched head/pointer/live-tail tuple, bad prior digest, missing new object, and mixed generations; each disagrees with Keychain and quarantines. Same-user rollback or authorized replacement of all Keychain discriminators is labeled outside scope and never restores send ownership. For the browser, use the exact paired API and fault prepared IndexedDB commit, server CAS, lost CAS response, GET reconciliation, local committed mark, compaction, two tabs, and local/server rollback combinations. Server head cannot reconstruct cleared local trust. At capacity new work stops before network while status/revocation remain.

Clone a complete root at authenticated head H to two absolute override paths with the same marker. Enumerate both-root schedules around bootstrap, append candidate creation, immediate predecessor reread, noncancellable Keychain completion/readback, `CURRENT`, retirement, restart, and compaction. Include confirmed-profile `not_sent`/`sent_or_unknown` and request `envelope_built`/`send_fenced` transitions. The root-independent lock permits one writer; after H-A commits, the H clone must quarantine before update because it lacks H-A's exact object set. A byte-complete offline move at current H loads; the old source becomes stale after the destination advances. Partial copy, changed marker, empty destination, divergent candidate, stale process, and attempts to alternate roots never publish H-B from H or regain send ownership. Across every schedule there is one accepted successor per prior external head, no orphan accepted fence, and at most one send.

### T-G04 Typed errors and CLI black box

Every inventory code preserves phase/retry/action. Run invitation/profile create/show/list/replace/revoke, stream/nonstream, cancel, and status commands. Stdout contains response only on completion; stderr shows bounded fingerprint/profile/boundary/recovery information. Prompts and credentials are read from stdin/private files, never required in argv. Legacy single-pin mode cannot silently upload/TOFU/downgrade.

## 8. Malibu application

### T-W01 Capability and bundle/profile UX

Node plus real Safari/Chromium runs shared framing/signature/crypto/profile-record vectors. Secure context, Web Crypto algorithms, IndexedDB, and Web Locks are all required. Account user fetches identity/invitation, validates baked signer/bundle, confirms fingerprints and plaintext boundary, creates/replaces/revokes a profile, and sees exact freshness/scope. Close/reload/reopen after activation-artifact expiry preserves a matching still-valid confirmed record. Demo/anonymous/wallet cannot mutate/read profiles. Fresh browser profile GET alone, missing local record/key, signer mismatch, stale/cross-release/substituted bundle, cross-origin/account invitation, rollback, or altered server profile leaves private mode disabled and sends nothing.

### T-W02 IndexedDB/Web Locks journal

For both stores, test nonextractable keys, exact v3/v2 records, prepared/committed generations, and the literal paired-ledger HTTP bytes for `POST /v1/relay-blind/client-authority-heads`, `GET /v1/relay-blind/client-authority-heads/{authority_id}/{authority_kind}`, `PUT /v1/relay-blind/client-authority-heads/{authority_id}/{authority_kind}`, `GET /v1/relay-blind/client-authority-heads?cursor={cursor}&limit={limit}`, and `DELETE /v1/relay-blind/client-authority-heads/{authority_id}`. Paired allocation atomically returns sorted generation-zero `confirmed_profiles` and `request_journal` rows; per-kind GET/CAS selects only the path kind; list returns two tagged expectations; DELETE validates both and returns empty 204. Exercise byte-identical operation replay, changed-operation conflict, generation-zero first CAS, later-zero rejection, lost allocation/CAS/DELETE responses, and GET/list reconciliation. Fill all 4,096 normal operation slots: the next allocation/CAS is transient and mutation-free, then succeeds only after eligible drain; all eight preallocated DELETE slots still revoke/clean their pairs without row/index/blob growth. Cross-account/unknown ID responses have the same fixed 404 tuple/timing bucket. Double-click/two tabs race profile mutation and fence creation; one server head wins and one live page owner sends.

Fault every IndexedDB write, allocation/CAS/GET/list/DELETE transaction, local committed mark, send cut, quota/abort/blocked upgrade, key loss, corrupt/predecessor/head rollback, Web Lock failure, clearing storage, and all caps. Inject a legacy one-kind pair: it is `incomplete`, cannot GET/CAS/authorize private mode, list exposes one present and one absent expectation, and exact DELETE materializes the absent revoked sentinel while revoking the present row atomically. Both-absent cleanup stays 404. Server GET/list alone never bootstraps content. Clear local storage, list the stranded opaque authority, revoke it, retain both rows/operations through references/eight days, and create no ninth pair before eligible drain. No lease takeover sends ciphertext. Scan all local/server head bytes for prohibited material. Plaintext history/settings remain separate and disclosed.

### T-W03 Private transport and recovery

Nonstream and stream through A-only/B-only/A+B. Network inspection proves unchanged reservation JSON plus bounded headers and closed ciphertext envelope. The ordinary `fetchChatCompletions` retry helper receives no encrypted bytes. Abort/loss goes to v2 status with state-specific UI; unknown/postdispatch never offers Retry, and predispatch new transaction appears only after C6A-verified rejection. UI exposes no stable provider ID and states provider plaintext/response relay visibility.

### T-W04 Regression/accessibility

Ordinary chat retry behavior, settings, threads, auth, docs, mobile, keyboard, focus, announcements, reduced motion, and plaintext mode remain usable. Agent/tool mode disables Request encryption. Run targeted Node tests, `npm test`, `npm run docs:validate`, `npm run build`, and `npm run test:private-browser`. The harness must never invoke Vite preview: its isolated HTTPS server serves `dist`, proxies production-shaped `/api/mp` only to explicit TLS loopback gateway, and fails before credentials/socket creation for every production/public/plaintext/redirect target. Assert trusted canonical HTTPS origin, local CA/SPKI scope, exact proxy rewrite, connected peer loopback, zero production sockets, versions/counts/cuts, and redaction. Chrome uses only its owned profile/process. Safari process-crash evidence requires a disposable test user/VM owning all Safari processes; otherwise that exact case is BLOCKED and session deletion is not relabeled. Missing browser/authorization/runner cannot fall back to Node; zero-selected fails.

## 9. Two-provider services and actual MLX

### T-E01 Deterministic services

Against real gateway/coordinator and two independent Swift fixture processes, run A-only with B first, B-only, A+B, no candidate, rotation, revocation, expiry, 100-request concurrency, stream/nonstream, cancellation, reconnect, replay, restart, and recovery. Assert approved membership at D2, one send/target, correct ordinary settlement, and truthful privacy metadata. Fixture evidence is labeled protocol integration.

### T-H01 Physical actual-MLX journey

Record safe revisions, chip family, RAM bucket, macOS/Swift/MLX versions, catalog model identity/hash/quantization, cache presence, and resource bounds without secrets/device IDs/usernames/raw paths/prompts/output. With a supported cached artifact, send one non-sensitive encrypted nonstream request through the supported client and prove provider decrypt, real `ModelRuntime` tokenize/generate, exact artifact context, bounded usage, and one ordinary settlement. A separate MLX selftest or deterministic fixture does not pass.

### T-H02 MLX stream/cancel

Run actual MLX streaming, observe output, cancel, then prove no envelope resend/failover, truthful v2 status, and settlement using current known-input/delivered-output rules. This is hardware correctness evidence, not throughput or production qualification. Missing artifact/hardware remains a blocker.

## 10. Broad checks and final audit

After targeted tests:

```bash
cd phase4-coordinator && go test ./... -count=1
cd phase4-coordinator && go test -race ./internal/relayblind ./internal/buyer ./internal/pool ./internal/ws -count=1
cd phase4-coordinator && go vet ./...
cd phase5-gateway && go test ./... -count=1
cd phase5-gateway && go test -race ./internal/relayblind ./internal/router ./internal/storage/sqlite ./internal/auth ./cmd/relay-blind-client ./pkg/relayblindbuyer -count=1
cd phase5-gateway && go vet ./...
cd test/integration && go test -run '^TestRelayBlind' -race -count=1 -timeout 20m
bash scripts/test-relay-blind-parity.sh
cd phase3-binary && swift test --filter RelayBlindProviderTests
cd phase3-binary && swift test
make vet
make test-dist
python3 scripts/check_spec_governance.py --base-ref origin/main
```

Run applicable Xcode app tests if shared Swift/provider files change. In the Malibu worktree run `npm test`, `npm run docs:validate`, `npm run build`, plus `npm run test:private-browser`, with Safari and Chrome results recorded separately. Docker-dependent tests require an available daemon and are blockers when required but unavailable.

Independent GPT-5.6 Sol code, security, architecture, and browser/product lanes inspect the complete landing diff in each repository. Fix and rerun until Critical=0, High=0, Medium=0. Acceptance reports distinguish implementation, local fixture, browser, actual MLX hardware, deployed, and production evidence and list every blocker.
