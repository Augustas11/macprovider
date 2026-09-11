# Product Build 2 test specification

**Test revision:** R2
**Paired plan:** `prd-implementation-plan-r2.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`
**Status:** draft; implementation and acceptance are prohibited until the paired plan gate reports zero Critical, High, and Medium findings

## 1. Evidence classes and instrumentation

Every result records exact revision, command, selected test count, duration, exit status, and environment class. Classes are: unit/property test, deterministic Go/Swift fixture, real browser, actual MLX on physical Apple Silicon, deployed service, and production qualification. Skipped, timed-out, zero-selected, fixture-only, or historical results cannot be promoted.

The two-provider harness creates independently signed identities A/B, distinct assigned sessions, encryption keys, and Swift provider processes. It records bounded events for pool epoch/generation, selection phases, reservation/profile state, gateway recovery state, quota/session transitions, public sends, provider frames, and settlement. Payload logs are prohibited. Barriers expose every D/P transition and cross-store crash cut. A fake clock, deterministic random source, SQLite fault hooks, HTTP transport counter, and process-restart harness are mandatory.

Shared fixtures are consumed byte-for-byte by Go, Swift, and JavaScript. Each fixture records raw JSON, accepted/rejected result, exact binary framing hex/base64url, digest, and signature result. Test-only signing keys are labeled local and never accepted by production keyrings.

## 2. Cross-runtime schema, numeric, and framing tests

### T-C01 Closed JSON and numeric grammar

For every new request/response/bundle/profile/status/journal schema, accept the exact field set and reject each missing, unknown, duplicated, null, trailing, >65,536-byte, wrong-type, or noncanonical-base64url variation. For each integer field test raw tokens `0`, `1`, `9007199254740991` at fields where allowed, and reject `-1`, `-0`, `00`, `01`, `1.0`, `1e0`, `1E+0`, quoted numbers, `9007199254740992`, Int64 max, overflow, NaN, and Infinity before state mutation. Go uses raw `json.Number`; JavaScript duplicate/numeric scanning is tested before `JSON.parse`; Swift uses raw lexical fixtures. All three produce identical verdicts.

### T-C02 Profile framing parity

Freeze positive vectors for one pin, 16 pins, 16 models, boundary timestamps, empty optional status digest, and different profile/bundle/invitation IDs. Assert exact domain bytes, `u16str`, big-endian integers, decoded fixed-size base64url fields, pin order, and final SHA-256 in Go/Swift/JavaScript. One-byte changes to every field, field reorder, pin/model reorder, alternate JSON serialization, signature text, state, and timestamps prove which bytes do or do not affect the digest. Reject non-ASCII, overlength, normalization variants, duplicate fingerprints/public keys, unsorted models, and counts 0/17.

### T-C03 Signed provider bundle

Verify exact signature/framing/digest vectors, known signer KID, signer validity, bundle ID/revision, issue/expiry, 24-hour bundle lifetime, 60-second skew, 30-day pin lifetime, supported version, and pin scopes. Reject corrupt signature, wrong domain/key/KID/digest, unknown/revoked/not-yet-valid/expired signer, stale/future/cross-release bundle, altered/substituted pin, unknown endpoint, revoked pin, and duplicate/unsorted arrays. Prove SPEC-023 feed, provider identity, wallet, payout, and test keys cannot validate a production bundle.

### T-C04 Invitation binding and trust bootstrap

Account A can fetch invitation I and the exact signed bundle; B, demo, wallet, anonymous, expired credentials, and altered path cannot. I is accepted only with exact bundle ID/revision/digest and selected byte-identical allowed pins. Reject cross-account redemption, different signed bundle, disallowed B substitution, expired/revoked/consumed invitation, reuse by a different operation, and signer revocation. A fresh client with only profile GET cannot enable encryption. A client with invitation but no valid release-baked signer cannot enable it. Test signer evidence is visibly local. After successful activation, ordinary invitation/bundle/signer-window expiry does not revoke the revision; earliest selected-pin expiry and explicit signer/bundle/profile/pin revocation do. Test both sides of that boundary.

Upload a valid public bundle through the operator listener, issue an account-scoped invitation idempotently, fetch it through the buyer gateway, and fetch exact bundle bytes/ETag through the public bundle route. Reject bundle/invitation operator calls on the buyer listener, buyer credentials on operator routes, private-key fields, changed operation replay, wrong account, wrong bundle digest, mutable replacement of an existing bundle revision, and deletion in place. Emergency signer/bundle tombstones survive restart and remain published/retained through the recovery horizon.

### T-C05 Route and wallet canonicalization

For the three reservation headers reject missing, duplicate, comma-joined, whitespace, case-conflict, oversized, invalid ID/digest, and revision numeric variants. Wallet reservation signatures succeed only when the exact header profile `accept,idempotency-key,three trust headers` is bound in sorted SPEC-040 bytes. Mutation of body/header/route/account/session/request ID/timestamp/signature fails before coordinator/quota.

For `POST /v1/relay-blind/request-status`, prove the wallet signature binds the exact raw v2 body, canonical route, UUIDv4 request ID, `accept`, and timestamp. Reject queries, body re-encoding under an old signature, duplicate Accept, wrong account/session, stale/future signature, identical replay, mismatched replay, and profile mutation/read with wallet bearer. A new valid request ID can poll status without dispatch or budget mutation.

### T-C06 Error inventory and precedence

Table/completeness tests prove every coordinator, gateway, Go-client, and Malibu Build 2 code has identical HTTP class, phase, retryable flag, and action. Unknown/malformed errors fail safe. Durable envelope replay/postdispatch state outranks rate, capacity, profile staleness, provider churn, and signer failure. Any error after `send_fenced` maps to status/do-not-resubmit; HTTP 502/503 alone never authorizes resend.

## 3. Invitation/profile storage, bounds, and migration

### T-P01 Account isolation and exact CRUD

Create, get, list, replace, and revoke with account A. Verify exact response fields/digests/no-store headers and absence of provider ID/session/internal IDs/operator config. Account B gets constant-shape not found. Demo/wallet/anonymous cannot read or mutate. Create revision is 1; replacements increment by exactly one; revision rows are immutable; revocation leaves the digest unchanged and writes a tombstone.

### T-P02 Operator intersection

Accept only byte-identical signed pins whose fingerprint maps uniquely to the configured operator provider key. Reject unmapped identity, provider self-assertion, wrong public key/fingerprint, admission/receipt/wallet key, duplicate provider mapping, mapping changed after invitation, and signer/bundle invalidation. No failed operation creates/advances an active profile.

### T-P03 Operation idempotency and CAS

Byte-identical operation-ID replay returns the stored result after restart without revision/audit amplification. Any changed byte conflicts. Two concurrent replacements from the same expected revision produce one winner; wrong digest, revision rollback/gap, consumed invitation mismatch, and concurrent revoke/replace are linearizable. Revocation remains available at normal profile/revision capacity.

### T-P04 Exact caps and pruning

Test exact/over boundaries: 8 bundle signers, 4,096 bundle revisions/64 MiB, 32 profiles/account, 64 revisions/profile, 16 pins, 16 models, 128 invitations, 4,096 operations/4 MiB, 8,192 audit rows/8 MiB, 512 live reservations/account, 2,048/profile, 1,000 recovery joins, body/page/rate bounds, safe integer max, and all lifetimes. At cap, new affected work fails atomically while revoke/status/recovery emergency capacity works. Pruning removes only indexed oldest eligible rows after 8-day/30-day/38-day and reference conditions; active/nonterminal/referenced/unsealed/tombstone evidence survives restart and clock rollback. A bundle referenced by any unexpired pin or reservation recovery row cannot be pruned. Invalid retention inequalities fail enabled startup.

### T-P05 Coordinator migration and rollback

Migrate a pre-Build-2 DB containing every legacy reservation/key state. Crash before/after table creation, copy, index, verification, and schema stamp; reopen and rerun. Prove row counts/bytes/replay fences, status v1, terminal history, and foreign keys survive. Profile-required mode rejects legacy predispatch rows but preserves postdispatch. New `selection_pending`/`dispatch_authorizing` values cannot be exposed to an old binary: rollback checker blocks until drained/fenced. No migration refunds or drops tombstones.

### T-P06 Gateway migration

Migrate API-key and wallet quota rows in active/held/stale-held/quarantined/settled/refunded states. Legacy relay-blind uncertainty imports conservatively held, never refunded. Crash/restart/double migration preserves account/session/request identity and settlement journal links. Verify no relay-blind held token exists without a discoverable recovery join after new admission.

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

With fake clock, fresh reserved/consumed/authorizing remains held and says `check_status_do_not_resubmit`. Status atomically fences expired predispatch to authenticated rejection with `dispatch_proven_absent: true` and permits a wholly new transaction. Dispatched/terminal/unknown always say `do_not_resubmit`. Store unavailable/retention gap never says refund or retry. Legacy v1 behavior remains exact for legacy rows.

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

For profile replace/revoke, signer/bundle/pin/operator/key/model/session invalidation at every coordinator state and gateway state (`no_join`, `quota_active`, `dispatch_intent`, `held`, terminal), assert the C6 table. Only authenticated terminal rejection with `dispatch_proven_absent` refunds, exactly once. Predispatch fresh and unavailable status remain held. Postdispatch never refunds solely due invalidation.

### T-Q04 Crash/restart recovery

Crash gateway after consume, during atomic quota admission, after quota/join, during dispatch-intent arm, before coordinator call, after coordinator rejection/dispatched, after first response, and during settle/refund. Repeat for API key and wallet. Restart one/two concurrent reconcilers. Oldest-first CAS converges without duplicate refund/settlement; coordinator/store/network outage remains held; contradiction quarantines.

### T-Q05 Retention and convergence

At 1,000 nonterminal rows and batch 100, verify a no-new-arrival backlog is visited in <=300 seconds of fake-clock passes. New rows cannot starve oldest. Alert at >60 seconds. Coordinator evidence remains through 8 days and across gateway 7-day journal retention. At 7 days unresolved becomes stale-held/operator-visible without auto-refund; missing evidence never produces a passed acceptance. Startup rejects too-short horizons or impossible row/batch/interval bounds.

### T-Q06 Settlement/economic boundary

Duplicate and contradictory terminal evidence settles/refunds at most once; contradictions hold/quarantine. Known input and delivered output follow existing caps/rules. Profile/bundle assertions cannot change model identity, rate, cap, provider share, receipt verification, rewards, or payout readiness. Relay-blind positive SPEC-022/verified-work attribution remains excluded.

## 7. Supported Go library and CLI journal

### T-G01 Public package and trust flow

An external module imports `pkg/relayblindbuyer` without gateway internals. With injected transport/clock/random/journal, test invitation fetch, bundle verification, explicit fingerprint confirmation callback, profile CRUD, reserve, nonstream, stream, cancel, and status. Local trust must exist before profile GET synchronization or encryption. Malformed/untrusted server data fails before network encryption/send.

### T-G02 File safety and durability

Test absolute-path/0700 ancestry/0600 regular no-follow files, owner, hardlink/symlink/FIFO/device, replacement after open, advisory lock, append, file/directory fsync, temp `O_EXCL`, rename, compaction, and reopen identity. Durable append/readback failure prevents send. A final partial line truncates only to the last newline; interior corruption/rollback/generation error quarantines and disables new sends. Journal bytes contain none of the prohibited data.

### T-G03 State concurrency and caps

Two processes race every transition. Exactly one commits `send_fenced`; only that live in-memory owner can make one send. Crash after envelope build, during fence fsync, after fence/before send, during send, and after response. A stale lock/process never takes over or resends. Test 4,096/16 MiB/4 KiB exact boundaries, 8-day pruning, full-disk/permission/rename/fsync failures. At capacity new private work stops before network while status/revoke works.

### T-G04 Typed errors and CLI black box

Every inventory code preserves phase/retry/action. Run invitation/profile create/show/list/replace/revoke, stream/nonstream, cancel, and status commands. Stdout contains response only on completion; stderr shows bounded fingerprint/profile/boundary/recovery information. Prompts and credentials are read from stdin/private files, never required in argv. Legacy single-pin mode cannot silently upload/TOFU/downgrade.

## 8. Malibu application

### T-W01 Capability and bundle/profile UX

Node plus real Safari/Chromium runs shared framing/signature/crypto vectors. Secure context, Web Crypto algorithms, IndexedDB, and Web Locks are all required. Account user fetches invitation, validates baked signer/bundle, confirms fingerprints and plaintext boundary, creates/replaces/revokes a profile, and sees exact freshness/scope. Demo/anonymous/wallet cannot. Fresh browser profile GET alone, signer mismatch, stale/cross-release/substituted bundle, cross-account invitation, or altered server profile leaves private mode disabled and sends nothing.

### T-W02 IndexedDB/Web Locks journal

Double-click and two tabs race fence creation; exactly one owner sends. Reload/crash at every write/readback/send cut, IndexedDB quota/abort/blocked upgrade, corrupt record, generation conflict, lock failure, clearing storage, and 128/256 KiB/2 KiB caps all have exact safe outcomes. No lease expiry/takeover sends old ciphertext. Scan storage for prohibited prompt/response/ciphertext/key/binding/provider data. Plaintext chat history remains separate and disclosed.

### T-W03 Private transport and recovery

Nonstream and stream through A-only/B-only/A+B. Network inspection proves unchanged reservation JSON plus bounded headers and closed ciphertext envelope. The ordinary `fetchChatCompletions` retry helper receives no encrypted bytes. Abort/loss goes to v2 status with state-specific UI; unknown/postdispatch never offers Retry, and predispatch new transaction appears only after authenticated rejection. UI exposes no stable provider ID and states provider plaintext/response relay visibility.

### T-W04 Regression/accessibility

Ordinary chat retry behavior, settings, threads, auth, docs, mobile, keyboard, focus, announcements, reduced motion, and plaintext mode remain usable. Agent/tool mode disables Request encryption. Run targeted Node tests, full `npm test`, `npm run docs:validate`, `npm run build`, and real browser tests; zero-selected runs fail evidence collection.

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

Run applicable Xcode app tests if shared Swift/provider files change. In the Malibu worktree run `npm test`, `npm run docs:validate`, `npm run build`, plus fresh Safari/Chromium tests. Docker-dependent tests require an available daemon and are blockers when required but unavailable.

Independent GPT-5.6 Sol code, security, architecture, and browser/product lanes inspect the complete landing diff in each repository. Fix and rerun until Critical=0, High=0, Medium=0. Acceptance reports distinguish implementation, local fixture, browser, actual MLX hardware, deployed, and production evidence and list every blocker.
