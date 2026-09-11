# Product Build 2 test specification

**Test revision:** R4
**Paired plan:** `prd-implementation-plan-r4.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`
**Status:** draft; implementation and acceptance are prohibited until the paired plan gate reports zero Critical, High, and Medium findings

## 1. Evidence classes and instrumentation

Every result records exact revision, command, selected test count, duration, exit status, and environment class. Classes are: unit/property test, deterministic Go/Swift fixture, real browser, actual MLX on physical Apple Silicon, deployed service, and production qualification. Skipped, timed-out, zero-selected, fixture-only, or historical results cannot be promoted.

The two-provider harness creates independently signed identities A/B, distinct assigned sessions, encryption keys, and Swift provider processes. It records bounded events for pool epoch/generation, selection phases, reservation/profile state, gateway recovery state, quota/session transitions, public sends, provider frames, and settlement. Payload logs are prohibited. Barriers expose every D/P transition and cross-store crash cut. A fake clock, deterministic random source, SQLite fault hooks, HTTP transport counter, and process-restart harness are mandatory.

Shared fixtures are consumed byte-for-byte by Go, Swift, and JavaScript. Each fixture records raw JSON, accepted/rejected result, exact binary framing hex/base64url, digest, and signature result. Test-only signing keys are labeled local and never accepted by production keyrings.

## 2. Cross-runtime schema, numeric, and framing tests

### T-C01 Closed JSON and numeric grammar

The Slice 0 machine-readable schema manifest enumerates every object in C1. Go, Swift, and JavaScript consume the same vectors and accept only its exact per-object field set, conditional fields, and types. For each field independently test missing, unknown neighbor, duplicate, explicit null, omission, wrong type, trailing bytes, body/record maximum plus one, and noncanonical base64url. Assert JSON null is accepted only for confirmed-profile `pending_mutation`, profile-list `next_cursor`, status-request `envelope_digest`, and the two status-response token fields; each is present as null where specified and omission fails. Assert conditional journal fields are omitted or present only in their named states and `pending_mutation` is present as null or the exact closed object.

For each integer field test raw tokens `0`, `1`, `9007199254740991` where allowed, and reject `-1`, `-0`, `00`, `01`, `1.0`, `1e0`, `1E+0`, quoted numbers, `9007199254740992`, Int64 max, overflow, NaN, and Infinity before state mutation. Go uses raw `json.Number`; JavaScript duplicate/numeric scanning is tested before `JSON.parse`; Swift uses raw lexical fixtures. All three produce identical verdicts.

### T-C02 Profile framing parity

Freeze positive vectors for one pin, 16 pins, 16 models, boundary timestamps, null status digest, and different profile/bundle/invitation IDs. Assert exact domain bytes, `u16str`, big-endian integers, decoded fixed-size base64url fields, pin order, and final SHA-256 in Go/Swift/JavaScript. The three literal C1 provider-binding vectors must produce the listed ASCII-input digests in all runtimes; decoded-byte hashing must produce a different value and fail the fixture. One-byte changes to every field, field reorder, pin/model reorder, alternate JSON serialization, signature text, state, and timestamps prove which bytes do or do not affect the digest. Reject non-ASCII, overlength, normalization variants, duplicate fingerprints/public keys, unsorted models, and counts 0/17.

### T-C02A Request-ID mode compatibility

Across Go, Swift, JavaScript, gateway and coordinator, profile-header mode accepts only canonical lowercase UUIDv4 envelope `request_id` and frames its RFC 4122 bytes into the journal. The supported client rejects uppercase, braces, non-v4 UUID, malformed and generic printable ASCII before journaling/encryption; the gateway rejects them before consume/dispatch. Headerless legacy v1 continues accepting representative non-UUID printable ASCII IDs and never enters the Build 2 journal. Mixed/partial profile headers fail closed.

### T-C03 Signed provider bundle

Verify exact signature/framing/digest vectors, known signer KID, signer validity, bundle ID/revision, issue/expiry, 24-hour bundle lifetime, 60-second skew, 30-day pin lifetime, supported version, and pin scopes. Reject corrupt signature, wrong domain/key/KID/digest, unknown/revoked/not-yet-valid/expired signer, stale/future/cross-release bundle, altered/substituted pin, unknown endpoint, revoked pin, and duplicate/unsorted arrays. Prove SPEC-023 feed, provider identity, wallet, payout, and test keys cannot validate a production bundle.

### T-C04 Invitation binding and trust bootstrap

Account A can fetch invitation I and the exact signed bundle; B, demo, wallet, anonymous, expired credentials, and altered path cannot. I is accepted only with exact bundle ID/revision/digest and selected byte-identical allowed pins. Reject cross-account redemption, different signed bundle, disallowed B substitution, expired/revoked/consumed invitation, reuse by a different operation, and signer revocation. A fresh client with only profile GET cannot enable encryption. A client with invitation but no valid release-baked signer cannot enable it. Test signer evidence is visibly local. After successful activation, ordinary invitation/bundle/signer-window expiry does not revoke the revision; earliest selected-pin expiry and explicit signer/bundle/profile/pin revocation do. Test both sides of that boundary.

Upload a valid public bundle through the operator listener, issue an account-scoped invitation idempotently, fetch it through the buyer gateway, and fetch exact bundle bytes/ETag through the public bundle route. Reject bundle/invitation operator calls on the buyer listener, buyer credentials on operator routes, private-key fields, changed operation replay, wrong account, wrong bundle digest, mutable replacement of an existing bundle revision, and deletion in place. Emergency signer/bundle tombstones survive restart and remain published/retained through the recovery horizon.

### T-C05 Route and wallet canonicalization

For the three reservation headers reject missing, duplicate, comma-joined, whitespace, case-conflict, oversized, invalid ID/digest, and revision numeric variants. Wallet reservation signatures succeed only when the exact header profile `accept,idempotency-key,three trust headers` is bound in sorted SPEC-040 bytes. Mutation of body/header/route/account/session/request ID/timestamp/signature fails before coordinator/quota.

For `POST /v1/relay-blind/request-status`, prove the wallet signature binds the exact raw v2 body, canonical route, UUIDv4 request ID, `accept`, canonical status sequence, and timestamp. Reject queries, body/header re-encoding under an old signature, duplicate covered headers, wrong account/session/locator, stale/future signature, equal/lower sequence with identical or changed request ID/body, and profile mutation/read with wallet bearer. A newly signed higher sequence updates the one status-authority row then polls without dispatch, refund, or budget/profile mutation.

Create the fixed status-authority row before returning each wallet reservation and fault every statement/commit. If it cannot commit, no reservation reaches the client and no encryption begins. At `session/account limit-1`, exact row/byte limits, and over limit, prove new reservation admission fails before return while every existing row remains updateable for higher-sequence polls through the safe-integer ceiling. Restart retains `highest_sequence`; nonterminal and within-8-day evidence cannot prune. Polling never inserts into, consumes, or evicts inference/ordinary metadata replay rows, and their replay rejection remains exact. A client crash/rollback that repeats a lower sequence advances locally and retries only status. Sequence overflow, session expiry/revocation, or authority-store outage keeps economics background-reconciled/held and never authorizes inference retry.

### T-C06 Error inventory and precedence

Generate server fixtures from `wire-errors-v2` and client fixtures from `client-reducer-v2`. Servers reject/never emit `action`; clients ignore no fence supplied by a peer and derive it from their MACed journal. For each origin/code assert exact nonzero server status or local zero status, phase and retryable value, then both local fence actions. Mixed-origin codes have separate local/server vectors. Exercise every pinned SPEC-041 legacy mapping, auth/wallet/quota/cancel/transport adapter, and fail if source inventory has any unmapped emitted constant. Unknown/missing/duplicate/action-injected/status-mismatched wire bodies become unknown. Pairwise reducer precedence proves durable terminal/replay, local fence, evidence, lifecycle, capacity and transport ordering; HTTP/retryable alone never authorizes envelope reuse.

## 3. Invitation/profile storage, bounds, and migration

### T-P01 Account isolation and exact CRUD

Create, get, list, replace, and revoke with account A. Verify exact response fields/digests/no-store headers and absence of provider ID/session/internal IDs/operator config. Account B gets constant-shape not found. Demo/wallet/anonymous cannot read or mutate. Create revision is 1; replacements increment by exactly one; revision rows are immutable; revocation leaves the digest unchanged and writes a tombstone.

### T-P02 Operator intersection

Accept only byte-identical signed pins whose fingerprint maps uniquely to the configured operator provider key. Reject unmapped identity, provider self-assertion, wrong public key/fingerprint, admission/receipt/wallet key, duplicate provider mapping, mapping changed after invitation, and signer/bundle invalidation. No failed operation creates/advances an active profile.

### T-P03 Operation idempotency and CAS

Byte-identical operation-ID replay returns the stored result after restart without revision/audit amplification. Any changed byte conflicts. Two concurrent replacements from the same expected revision produce one winner; wrong digest, revision rollback/gap, consumed invitation mismatch, and concurrent revoke/replace are linearizable. Revocation remains available at normal profile/revision capacity.

### T-P04 Exact caps and pruning

Test exact/over boundaries and the frozen SQLite payload/page/index/WAL accounting for every C9 authority: 8 bundle signers; 4,096 bundle revisions/64 MiB; 32 profiles with 64 revisions; 2,048 reachable successful create/replace operation and audit rows; 2,048 invitations/4 MiB with 128 live; 32 fixed revoke-operation and 32 fixed revoke-audit slots; 24 fixed recovery-quarantine slots; 1,000 normal recovery joins; wallet status session/account caps; confirmed-profile 8 MiB normal, per-active-profile revoke headroom, 40 MiB active/88 MiB physical, and journal active-generation plus old/new/checkpoint physical peak bytes; body/page/rate/safe-integer/lifetime bounds. Boundary construction uses supported APIs and never disables a competing limit.

Through supported APIs create 32 profiles and 63 replacements for each, reaching exactly 2,048 successful create/replace operation and audit rows without disabling another cap. Prove rejected/auth/CAS/rate/capacity requests charge zero retained rows and successful replay reuses its row. Inspect the frozen accounting function against actual SQLite page, index, freelist and WAL growth at limit-1, exact limit and over limit. Startup rejects a model whose B-tree/WAL/page reserve is smaller than observed worst case.

Profile creation must preallocate one fixed revoke-operation and revoke-audit slot. Exhaust all 2,048 normal operations/audits, all 24 recovery-quarantine slots, wallet/status capacity, and client normal capacity; then revoke every one of 32 active profiles without row allocation/blob growth or physical-cap overrun. Repeat revoke reuses its slot. Fault storage I/O separately and assert pending/disabled plus storage-outage reporting, never a capacity classification. Reach 128 live reservations on one profile and 512 across four profiles through normal admission; reject only the precise next limit. Pruning and C8 compaction preserve all reference/horizon rules.

### T-P05 Coordinator migration and rollback

Migrate a pre-Build-2 DB containing every legacy reservation/key state. Crash before/after table creation, copy, index, verification, and schema stamp; reopen and rerun. Prove row counts/bytes/replay fences, status v1, terminal history, and foreign keys survive. Profile-required mode rejects legacy predispatch rows but preserves postdispatch. New `selection_pending`/`dispatch_authorizing` values cannot be exposed to an old binary: rollback checker blocks until drained/fenced. No migration refunds or drops tombstones.

### T-P06 Gateway migration

Migrate API-key and wallet quota rows in active/held/stale-held/quarantined/settled/refunded states. Legacy relay-blind uncertainty imports conservatively held, never refunded. Crash/restart/double migration preserves account/session/request identity and settlement journal links. Verify no relay-blind held token exists without a discoverable recovery join after new admission.

### T-P07 Durable confirmed-profile authority

Go and real Safari/Chromium consume shared exact record/MAC/chain vectors. After signed-bundle confirmation and exact profile creation, restart the CLI and reload/close/reopen the browser after invitation, bundle, and signer activation windows expire; the still-valid pin remains usable only when the authenticated account identity and server profile exactly match the local record. A fresh store plus profile GET never enables private mode.

Test cross-origin/account/profile substitution, changed signed-bundle bytes, selected-pin mismatch, HMAC-key loss, record/MAC/predecessor/generation tamper, partial and whole-record rollback, stale server revision, server rollback, record truncation, local clear, cap/full disk/IndexedDB quota, two processes/tabs, and concurrent replace/revoke. Any mismatch disables sends. For valid local rollback to an older revision, the newer server revision detects it. A record restored to the same immutable active revision may synchronize but cannot recover a prior process/page's request-send ownership.

At every replace/revoke cut prove the complete C3A `mutation_pending` record commits before the call and that `request_disposition` becomes durable `sent_or_unknown` immediately before it. After server success, delete all network responses and activation caches, restart, and prove stable recovery reconstructs and reverifies the target solely from persisted target state, bundle and invitation IDs/revisions/digests, signer KID, exact signed-bundle bytes, selected fingerprints/pinframes, pin expiry, public-authority digest, and revocation generation/root. For client-initiated revoke, prove zero-sentinel pending evidence is durably upgraded with signed nonzero C3B evidence before stable revoke. Mutate each field independently. Active and revoked documents with the same immutable profile digest never compare equal. Cancel restores the prior stable record only from `not_sent`; every later cut remains reconciliation-only. Stable successor append, pending retention, checkpoint compaction, and capacity charges are exact.

Freeze revocation-entry/root and C3B request/response/signature bytes across Go/Swift/JavaScript. Exercise C3B valid, stale, expired, reordered, replayed, lower-generation, same-generation/different-root, clock-skewed, wrong challenge/account/profile/bundle/pin, bad signer, rotated signer, TLS/redirect/outage, and concurrent tombstone cases. New sends require a <=15-second signed result and durable monotonic watermark. A tombstone after preflight is rejected by coordinator lifecycle. At the 8 MiB local normal ceiling and full normal coordinator/recovery capacity, exhaust every non-revoke emergency class and then revoke all 32 active profiles through their preallocated coordinator slots and four-record local revoke headroom. Explicit signer/bundle/pin/profile revocation disables use after restart; ordinary activation-artifact expiry does not. Scan bytes for prohibited material.

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

At 1,000 nonterminal rows and batch 100, instrument exact C6 scan epochs/cutoffs, 20 workers, five two-second waves, one <=3-second claim transaction and one <=3-second aggregate result transaction per pass, 18-second pass work, and <=10-second interpass delay. Assert no per-row persistence transaction occurs. Failures and retry-eligible rows cannot be reclaimed until every row in the frozen epoch has a first call; rows arriving after cutoff wait for the next epoch. With bounded contention that clears within the transaction ceiling, slow/hung/TLS/malformed/cancelled/mixed rows still give every original row a first call by the measured 255-second formula. Fault aggregate commit, restart, and verify the identical claimed batch remains ahead without duplicate economic effect. Persistent DB/network outage is reported unavailable/held and is not claimed as convergence.

Alert at >60 seconds. Coordinator evidence remains through 8 days and across gateway 7-day journal retention plus convergence/skew margin. At 7 days unresolved becomes stale-held/operator-visible without auto-refund; missing evidence never produces a passed acceptance. Startup rejects too-short horizons or any row/batch/concurrency/call/DB/pass/interpass combination whose explicit formula exceeds 300 seconds.

### T-Q06 Settlement/economic boundary

Duplicate and contradictory terminal evidence settles/refunds at most once; contradictions hold/quarantine. Known input and delivered output follow existing caps/rules. Profile/bundle assertions cannot change model identity, rate, cap, provider share, receipt verification, rewards, or payout readiness. Relay-blind positive SPEC-022/verified-work attribution remains excluded.

## 7. Supported Go library and CLI journal

### T-G01 Public package and trust flow

An external module imports `pkg/relayblindbuyer` without gateway internals. With injected transport/clock/random/journal/profile store, test account identity, invitation fetch, bundle verification, explicit fingerprint confirmation callback, profile CRUD, restart continuity, reserve, nonstream, stream, cancel, and status. Local confirmed trust must exactly match origin/account/profile revision/digest before profile GET synchronization or encryption. Fresh-store GET, stale local/server state, pending mutation, malformed/untrusted server data, or local durability failure sends nothing.

### T-G02 File safety and durability

On macOS exercise the single `private.lock` and every C8 descriptor step for both journal and profile authority: relative override rejection; root-to-leaf `openat`/`O_NOFOLLOW` walk; allowed root/sticky and private 0700 ownership; retained-directory edge recapture; symlink/hardlink/FIFO/device/socket/wrong-owner/wrong-mode rejection; `st_nlink == 1`; and exact device/inode equality before load/append/fsync and immediately before rename. After rename assert the old descriptor/path mismatch is expected, the new descriptor equals the captured temporary inode, and old close checks only its captured identity. Race every ancestor/final component replacement at every recapture point. Unsupported platforms fail before reservation/profile confirmation.

Test lock-first ordering, the exact five-second advisory-lock ceiling, same-directory `O_EXCL` temp, write/fsync, pre-rename identity, `renameat`, parent fsync, expected new target identity, reopen, and stable lock identity. Inject short write, disk full, file/directory fsync, rename, reopen, permission, and identity failures. Durable append/readback/MAC failure prevents send. A final partial line truncates only to the last authenticated newline; interior schema/MAC/rollback/generation/predecessor error quarantines and disables new sends. Journal/profile bytes contain none of the prohibited data.

### T-G03 State concurrency and caps

Shared state-machine fixtures assert every C8 record field, conditional presence, request HMAC, record digest/MAC, generation/predecessor, locator, terminal class, transition, and prohibited transition. Two processes race every transition. Exactly one commits `send_fenced`; only that live in-memory owner epoch can make one send. Crash before first record, after reservation record, after envelope build, during fence fsync, after fence/before send, during send, and after response. After reopen, every persisted state has the promised status locator and is recovery-only. A stale lock/process, valid whole-file rollback, or restored earlier owner never takes over or resends.

Test 4,096/16 MiB active/40 MiB physical/4 KiB exact boundaries and the C8 pointer/manifest/immutable-base/append-tail/checkpoint schemas in shared Go/JavaScript vectors. Cover retained and omitted head maps, original logical generations/predecessors, source and compacted roots, pointer CAS, and every crash at base/tail/manifest/pointer write, fsync, reopen, rename, directory sync, and retirement. Reopen selects exactly one valid rooted generation; unreferenced partial generations are inert; pointer-to-invalid content quarantines. Coherent whole-authority rollback remains outside the local-file threat claim and never restores send ownership. At capacity new private work stops before network while status and preallocated revoke work.

### T-G04 Typed errors and CLI black box

Every inventory code preserves phase/retry/action. Run invitation/profile create/show/list/replace/revoke, stream/nonstream, cancel, and status commands. Stdout contains response only on completion; stderr shows bounded fingerprint/profile/boundary/recovery information. Prompts and credentials are read from stdin/private files, never required in argv. Legacy single-pin mode cannot silently upload/TOFU/downgrade.

## 8. Malibu application

### T-W01 Capability and bundle/profile UX

Node plus real Safari/Chromium runs shared framing/signature/crypto/profile-record vectors. Secure context, Web Crypto algorithms, IndexedDB, and Web Locks are all required. Account user fetches identity/invitation, validates baked signer/bundle, confirms fingerprints and plaintext boundary, creates/replaces/revokes a profile, and sees exact freshness/scope. Close/reload/reopen after activation-artifact expiry preserves a matching still-valid confirmed record. Demo/anonymous/wallet cannot mutate/read profiles. Fresh browser profile GET alone, missing local record/key, signer mismatch, stale/cross-release/substituted bundle, cross-origin/account invitation, rollback, or altered server profile leaves private mode disabled and sends nothing.

### T-W02 IndexedDB/Web Locks journal

For both `confirmed_profiles` and request-journal stores, test nonextractable HMAC keys, exact records/MAC/head anchors, atomic pending/transition writes, readback, reload, and cross-account/origin isolation. Double-click and two tabs race profile mutation and request fence creation; exactly one state transition wins and one live page owner sends. Reload/crash at every write/readback/send cut, whole-record rollback versus server state, IndexedDB quota/abort/blocked upgrade, key loss, corrupt/MAC/predecessor record, generation conflict, Web Lock failure, clearing storage, and all profile/journal caps have exact fail-closed outcomes. No lease expiry/takeover sends old ciphertext. Scan storage for prohibited prompt/response/ciphertext/private key/raw binding/provider data. Plaintext chat history and current `malibu.settings`/`malibu.threads` localStorage remain separate and disclosed.

### T-W03 Private transport and recovery

Nonstream and stream through A-only/B-only/A+B. Network inspection proves unchanged reservation JSON plus bounded headers and closed ciphertext envelope. The ordinary `fetchChatCompletions` retry helper receives no encrypted bytes. Abort/loss goes to v2 status with state-specific UI; unknown/postdispatch never offers Retry, and predispatch new transaction appears only after C6A-verified rejection. UI exposes no stable provider ID and states provider plaintext/response relay visibility.

### T-W04 Regression/accessibility

Ordinary chat retry behavior, settings, threads, auth, docs, mobile, keyboard, focus, announcements, reduced motion, and plaintext mode remain usable. Agent/tool mode disables Request encryption. Run targeted Node tests, `npm test`, `npm run docs:validate`, `npm run build`, and `npm run test:private-browser`. The no-dependency harness must report `isSecureContext`, exact Safari/Chrome/OS versions, required/executed case counts, two-tab barriers, target/window close, WebDriver/CDP session termination, spawned-browser PID termination/reopen, IndexedDB/Web Lock fault cuts, and redaction checks. It refuses to kill unrelated Safari state. Missing authorization/binary/runner is a named browser blocker; Node fixtures cannot substitute; zero-selected runs fail.

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
