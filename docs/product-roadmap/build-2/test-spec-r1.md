# Product Build 2 test specification

**Test specification revision:** R1
**Paired plan:** `prd-implementation-plan-r1.md` R1
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu buyer-app base inspected:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`
**Gate status:** draft; no implementation acceptance may be claimed before the paired plan gate passes

## 1. Evidence classes

Every result is labeled as one of:

1. **Unit/fixture:** in-process or deterministic crypto/runtime fixture.
2. **Service integration:** real gateway and coordinator processes with durable SQLite, optionally deterministic Swift provider.
3. **Browser integration:** Malibu application in a real browser against isolated services.
4. **Actual MLX:** encrypted request reaches real MLX tokenization and generation on physical Apple Silicon with recorded model/artifact/runtime/hardware context.
5. **Deployed qualification:** released/deployed service and operator evidence. This task does not authorize it.

Skipped, zero-selected, timed-out, interrupted, historical, fixture-only, and MLX-selftest-only runs never satisfy a higher evidence class. Output must record command, base revisions, start/end time, exit status, selected test count where available, and environment limits.

## 2. Test fixtures and instrumentation

Create independently generated provider A and B Ed25519 relay-blind identities and X25519 keys. Configure both under distinct authenticated provider IDs and assigned sessions. Arrange `AssignedID(B) < AssignedID(A)` for A-only selection tests. Profiles:

- `P-A`: A only.
- `P-B`: B only.
- `P-AB`: A and B.
- `P-X`: structurally valid public pin whose identity is not operator-mapped.
- `P-expired`: pins outside validity.
- `P-revoked`: profile tombstone.

Instrument gateway public requests, coordinator consume/dispatch calls, provider A/B WebSocket frames, quota rows, coordinator reservations/request logs, and client journal transitions. Capture bodies only in process-local test memory; evidence and logs store digests/counters, never prompts, ciphertext, credentials, private keys, raw bindings, or response content.

The deterministic Swift fixture remains the fault-injection authority. The actual MLX journey uses an already-cached supported artifact and a real `ModelRuntime`; it cannot substitute fixture failure coverage.

## 3. Contract and parsing tests

### T-C01 Trust profile closed schema

Accept the exact normative fields and reject missing, unknown, duplicate, null, trailing, wrong-type, noncanonical base64url, non-integer revision/time, overflowed, empty, oversized, unsorted, duplicate, and more-than-16 pin inputs. Prove the 64 KiB body cap is enforced before expensive parsing or database writes.

### T-C02 Profile digest vectors

Go coordinator, exported Go buyer library, CLI, JavaScript browser module, and shared fixture tool compute identical bytes/digest for positive vectors. Negative vectors cover field reorder, pin reorder, Unicode/non-ASCII identifiers, normalized/non-normalized variants, changed revision, changed model scope, changed expiry, changed public key, changed fingerprint, revoked bit, extra field, duplicate JSON key, and JSON numeric alternatives.

### T-C03 Existing pin/key validation

Reject mismatched public key/fingerprint, bad Ed25519 signature, changed signed record, low-order/all-zero X25519 behavior, key outside validity, model/endpoint outside pin scope, noncanonical IDs, and provider identity not in independent operator authority. Buyer profile approval must never make these valid.

### T-C04 Reservation profile headers

For all three headers, reject missing, duplicate, comma-joined, whitespace-ambiguous, case-conflicting, oversized, invalid base64url/profile ID/digest, zero/negative/float/exponent/overflow revision, and mismatch with the authenticated account's current profile. The six-field JSON body remains closed and unchanged.

### T-C05 Wallet semantic binding

Signed wallet requests succeed only when the signature covers the exact profile ID/revision/digest headers. Alter/remove/add conflicting header values after signing fails before reservation/quota. Wallet sessions cannot create, replace, or revoke profiles.

### T-C06 Error inventory parity

Coordinator and gateway compile-time/table tests prove every emitted Build 2 code has identical HTTP status, retryability, phase, and retry action. Unknown codes fail to the safe unavailable/do-not-resubmit outcome. Replay/postdispatch classifications take precedence over rate, capacity, stale profile, or provider unavailability.

## 4. Trust-profile storage and API tests

### T-P01 Create and read isolation

Create a profile using account A's API key. Account A can list/get it; account B, a different key, unauthenticated request, demo token, and wallet session cannot observe or mutate it. Not-found responses do not reveal cross-account existence. No response includes provider ID, assigned session, operator map, internal row ID, or secret.

Treat reads only as synchronization/status. A new client with no previously imported and fingerprint-confirmed local public bundle cannot enable encryption from a successful GET response. Reject a GET response whose revision, digest, or pins differ from the local confirmed bundle; do not rewrite local trust, create TOFU state, or send a reservation.

### T-P02 Operator-authority intersection

Creation accepts only pins whose public identity maps independently to a configured provider. `P-X`, self-asserted provider IDs, admission/receipt/wallet keys, and duplicate mapping of one relay-blind identity across provider IDs fail closed. Failure creates no active revision.

### T-P03 Idempotency and conflicting replay

Repeating one operation ID with byte-identical canonical input returns the original result without a new revision/audit amplification. Reusing it with any changed field returns conflict. The behavior survives coordinator restart.

### T-P04 Atomic replacement CAS

Two concurrent replacements with the same expected revision yield exactly one new active revision; the loser receives typed conflict. Revision increases by one, old revision remains immutable, and the active pointer/digest agree. Wrong expected digest, rollback revision, gap, and reused operation ID fail.

### T-P05 Revocation and retention

Revocation writes an immutable tombstone, removes the active profile, and prevents create/replacement from reusing the revoked revision/profile identity contrary to contract. Tombstones and mutation replay survive restart and are retained through maximum pin/reservation/replay windows. Retention pruning is bounded and cannot revive old material.

### T-P06 Bounds and denial resistance

Exercise maximum profiles/account, revisions/profile, pins/revision, operation replay rows, request size, metadata request rate, concurrent writers, and SQLite busy/fault injection. Capacity returns typed bounded errors; no partial active revision or unbounded log/metric label is created.

### T-P07 Migration

Open a pre-Build-2 relay-blind database containing reserved, consumed, dispatched, terminal, rejected, unknown-postdispatch, active key, and revoked-key rows. Migrate twice. Prove all old replay/settlement fences remain, new indexes/tables/columns exist, legacy rows are classified, profile-required mode cannot consume unbound predispatch rows, and old terminal rows remain inspectable. Crash each migration step and reopen safely.

## 5. Approved-provider selection tests

### T-S01 A-only when B sorts first

With A and B otherwise eligible and B's assigned session sorting first, reserve with `P-A`. Assert the returned signed record fingerprint is A; reservation row binds A/profile revision/digest; B receives zero reservation/consume/dispatch frames. This is mandatory and cannot be replaced by a client rejection test.

### T-S02 A+B selection

Reserve with `P-AB` across stable ordering and controlled availability changes. Every selected record belongs to the exact active profile. When both are eligible the documented stable order wins; when the first becomes ineligible before a fresh reservation, the other may be selected. Existing envelopes never move.

### T-S03 No acceptable candidate

Test approved providers offline, stale session, no WebSocket tunnel, wrong model, no free capacity where required, expired/revoked encryption key, operator pin removed, profile pin expired, and only unapproved B eligible. Expect typed no-approved-provider/trust error before encryption/quota, no reservation row where contract requires none, no provider identifier leak, no plaintext fallback.

### T-S04 Atomic profile/reservation races

Run profile replacement/revocation concurrently with reservation creation at barriers before profile read, candidate filtering, key validation, and insert. Each outcome is linearizable: reservation binds the old revision before the mutation and is atomically rejected by it, or reservation sees the new revision and selects only its pins, or returns stale/conflict. No active reservation survives bound to a non-current profile.

### T-S05 Candidate churn race

Disconnect/reconnect/rotate A between pool snapshot and transaction; rotate/revoke its key between selection and insert; change its model/session after insert and before consume/dispatch. The transaction or lifecycle recheck rejects. It never silently selects B for the existing reservation/envelope.

### T-S06 Concurrent reservations

Create many concurrent A-only and A+B reservations while replacing profiles and reconnecting providers. Assert per-row identity membership, profile binding, uniqueness, max-active bounds, no database corruption, and race-detector cleanliness.

## 6. Lifecycle, replay, and no-failover tests

### T-L01 Profile replacement by state

For each coordinator state (`reserved`, `consumed_predispatch`, `dispatched`, `terminal`, `rejected`, `unknown_postdispatch`), replace/revoke the profile. Predispatch rows burn and refund as applicable. Dispatched/terminal/unknown remain irreversible and never become retryable or redispatchable.

### T-L02 Key/session/provider lifecycle

Repeat T-L01 for provider key revocation/expiry, operator identity remap, assigned-session rotation, provider reconnect, and model change. Rechecks occur at reservation, consume, and final arm.

### T-L03 One ciphertext, one target, one send

Hash each generated envelope and count public inference sends plus A/B provider frames. Across queue-full, NAK, timeout, transport 502/503, cancel, buyer disconnect, coordinator disconnect, provider disconnect, key/profile revocation, process restart, and generic retry middleware, each envelope hash has at most one public inference send and at most one provider/session target. No retry helper receives encrypted bytes.

### T-L04 Replay ordering

Replay exact and semantically equivalent/re-encoded envelopes before/after gateway restart, feature cycling, rate saturation, profile replacement, and provider recovery. Durable replay classification wins. No capacity/rate/profile error hides replay or permits a fresh dispatch.

### T-L05 Cancel boundaries

Cancel before reservation response, after reservation/before encryption, after journal/before send, before consume, after consume/before dispatch, after provider claim, after first output, and after terminal evidence/before client completion. Verify exact burn/refund/unknown/settlement state and safe action. Only a proven predispatch terminal fence permits a fresh transaction; no old envelope is sent again.

### T-L06 Provider reconnect and crash

Restart the selected provider before claim, after claim, after decrypt, after validation, after first token, during terminal persistence, and after terminal-send loss. Reconnect with the same and a new assigned session. Provider journal and coordinator rows prevent reexecution. No dispatch goes to the other approved provider.

### T-L07 Public status safety

Correct authenticated account/profile transaction can query by both digests. Wrong account/session, one wrong digest, missing/duplicate/null/oversized fields, expired auth, demo token, rate limit, and store failure fail closed. Status never dispatches, mutates quota incorrectly, reveals provider/profile pins, or returns response content. Fresh `reserved`/`consumed` remains held; expired predispatch is fenced; postdispatch always says do not resubmit.

### T-L08 Duplicate settlement

Deliver duplicate and contradictory terminal evidence/status recovery results after client disconnect/profile revocation/provider reconnect. Existing settlement journal records at most one authoritative settlement; contradictions quarantine/hold according to current rules. Relay-blind positive verified-model/reward exclusions remain.

## 7. Supported Go library and CLI tests

### T-G01 Public package boundary

An external test module imports `pkg/relayblindbuyer` without importing gateway `internal` packages. The package accepts injected HTTP transport/clock/randomness/journal and provides profile CRUD, request, stream, status, and typed error APIs.

### T-G02 Local profile validation before network

Missing, malformed, expired, revoked, symlinked, writable, wrong-owner, oversized, changed-after-open, profile-digest mismatch, and model-out-of-scope bundles fail before any HTTP call. Valid bounded descriptor reads succeed. Multi-pin bundle selects the returned record by fingerprint.

### T-G03 Typed errors

For every inventory code and malformed/untrusted server response, assert exact phase/retryability/action. Reservation errors preserve body metadata instead of `HTTP <status>` only. A network error after encrypted send becomes status-only and never an automatic retry.

### T-G04 Journal durability and privacy

Test no-follow/private path/lock enforcement, durable append failure, truncation/corruption, concurrent processes, size cap, restart, and recovery. Scan bytes for prompts, completions, ciphertext, raw bindings, keys, bearers, provider IDs, paths, and server error bodies; none appear.

### T-G05 CLI black-box

Run create/show/list/replace/revoke, nonstream, stream, cancel, and status commands against isolated services. Verify exit codes and safe messages. Stdout contains only model response when complete; stderr shows fingerprint/profile state and exact truth boundary without secrets. Shell arguments never require prompt or credentials.

### T-G06 Legacy migration

Import an existing single public pin into a new profile explicitly. Old `--identity-pin` invocation against profile-required capability fails with a clear migration action before encryption; it is not silently uploaded, expanded, or treated as TOFU.

## 8. Gateway and confidentiality tests

### T-R01 Request opacity

Place unique markers in messages, tools, tool schemas, structured-output schemas, and attachments within supported request bounds. Scan gateway/coordinator request bodies, logs, audits, database rows, errors, metrics, and traces. Before provider decryption, no marker appears. The selected provider sees the exact inner plaintext. Responses are intentionally relay-visible and tests must not mislabel echoed markers as a request-path leak.

### T-R02 Header stripping

Buyer-supplied internal account/session/execution authorization, selected fingerprint, provider ID, assigned session, and conflicting trust-profile internal headers are stripped. Gateway reconstructs only authenticated values. Public responses suppress stable provider ID/session headers.

### T-R03 Plaintext regressions

Feature off and ordinary plaintext chat remain byte/semantic compatible, including existing retry behavior. Relay-shaped namespaces never enter plaintext parsing. SPEC-008 provider-leg encryption, wallet, demo, sticky, model selection, rate/quota, receipts, settlement, and Trusted Pool rejection retain existing behavior.

### T-R04 Economic boundaries

Buyer profile assertions do not change model identity, rate-card selection, caps, provider share, settlement arithmetic, receipt verification, rewards, or payout readiness. Relay-blind work remains excluded from positive SPEC-022/verified-work claims. Test forged profile price/model/provider assertions are rejected or ignored.

## 9. Two-provider service journeys

### T-E01 A-only nonstream and stream

Against real gateway/coordinator plus two Swift fixture provider processes, run nonstreaming and streaming through `P-A` while B sorts first. Both succeed through A only, carry truthful privacy/settlement metadata, and settle correct bounded usage.

### T-E02 B-only nonstream and stream

Repeat through `P-B`. A receives no envelope. This proves both independently pinned providers, rather than one provider used twice.

### T-E03 A+B availability and rotation

Run with both online, one offline, key rotation within A identity, identity rotation requiring profile replacement, profile A+B to B-only replacement, expiry, and revocation. Fresh reservations may choose eligible approved identities; existing ciphertext never changes target.

### T-E04 Concurrency

Issue concurrent stream/nonstream requests with A-only, B-only, and A+B profiles while rotating a profile. All completed reservations satisfy membership at their linearization point; no cross-account/profile contamination occurs.

### T-E05 Recovery matrix

Across both providers exercise buyer cancellation, provider reconnect, gateway/coordinator/provider restart, replay, stale/revoked keys, and lost terminal response. Query public status and verify no resubmission or cross-provider failover.

## 10. Malibu buyer application tests

### T-W01 Crypto capability and vectors

Node and real Safari/Chromium tests run shared profile/envelope/AAD/HKDF/AES-GCM vectors. Unsupported X25519/HKDF/AES-GCM or insecure origin disables Request encryption with an actionable message and sends no plaintext/network request.

### T-W02 Profile UX

Authenticated API-key user imports a public bundle, confirms fingerprints/provider-plaintext disclosure, creates a profile, sees active revision/freshness/model scope, replaces it atomically, and revokes it. Demo/anonymous users cannot mutate. Cross-account/not-found responses reveal no profile existence.

On a fresh browser profile, a successful server profile read does not enable Request encryption until the user imports and confirms matching local public trust material. A server response with altered pins, revision, or digest produces a fail-closed synchronization error and no reservation or plaintext fallback.

### T-W03 Private chat transport

Nonstream and stream work through both profiles/providers. Inspect browser network requests: reservation metadata is clear and bounded; chat body is the closed envelope; prompt/tool/schema markers appear only in ciphertext. `fetchChatCompletions` automatic retry is not invoked. Response UI shows request encryption satisfied, provider can read, response relay-visible, and no provider ID.

### T-W04 Cancellation and recovery

Abort before and after dispatch, reload the page, and use status recovery. One envelope is sent once. UI never offers “retry” for unknown/postdispatch; it offers a new transaction only for a proven predispatch terminal state. Lost output is described as unrecoverable.

### T-W05 Local storage truth and safety

Public profiles and redacted recovery records survive/reject corruption according to schema. Chat history remains plaintext locally and UI discloses it. Recovery storage contains no prompt, response, ciphertext, private key, bearer, provider ID, or raw binding. Clearing it cannot trigger resubmission.

### T-W06 UI regression and accessibility

Private mode is unavailable in Agent/tool mode. Keyboard/screen-reader labels, focus, error announcements, cancellation, reduced motion, mobile layout, and ordinary chat/settings remain usable. Run targeted Node tests, `npm test`, `npm run docs:validate`, and `npm run build`; zero-selected tests do not count.

## 11. Actual MLX physical-Mac acceptance

### T-H01 Prerequisite capture

Before running, record source revisions, Apple chip family, RAM bucket, macOS build, Swift version, MLX package/runtime version, model ID, catalog identity/hash/quantization, model cache presence, free disk/RAM bounds, and operator-state isolation. Do not collect secrets, serials, UUIDs, MAC addresses, usernames, raw paths, prompts, or completions. No download occurs automatically.

### T-H02 Encrypted MLX request

Start real provider runtime with the selected cached artifact and relay-blind identity, plus isolated gateway/coordinator/profile. Send a unique but non-sensitive request through the supported client. Prove the provider decrypts, `ModelRuntime` tokenizes and generates with the recorded artifact, response privacy metadata is satisfied, usage is within declared caps, and existing ordinary settlement completes exactly once. A deterministic fixture or separate MLX selftest cannot satisfy this test.

### T-H03 MLX stream/cancel sanity

Run one streaming request and cancel after observed output. Prove actual MLX generation occurred, the old envelope is not resent, status/recovery is truthful, and settlement uses known delivered output/current rules. This is correctness evidence, not throughput or production qualification.

## 12. Broad verification commands

After targeted tests pass, run at minimum:

```bash
cd phase4-coordinator && go test ./... -count=1
cd phase4-coordinator && go test -race ./internal/relayblind ./internal/buyer ./internal/ws -count=1
cd phase4-coordinator && go vet ./...
cd phase5-gateway && go test ./... -count=1
cd phase5-gateway && go test -race ./internal/relayblind ./internal/router ./internal/storage/sqlite ./cmd/relay-blind-client ./pkg/relayblindbuyer -count=1
cd phase5-gateway && go vet ./...
cd test/integration && go test -run '^TestRelayBlind' -race -count=1 -timeout 15m
bash scripts/test-relay-blind-parity.sh
cd phase3-binary && swift test --filter RelayBlindProviderTests
make vet
make test-dist
python3 scripts/check_spec_governance.py --base-ref origin/main
```

Run the full Swift suite and applicable Xcode app tests after provider/shared-fixture changes. In the Malibu worktree run `npm test`, `npm run docs:validate`, and `npm run build`, plus real-browser checks. Docker-specific integration is required only when the changed path/test needs it and a daemon is available; absence is recorded as a blocker.

## 13. Final independent audit gate

Review the complete per-repository diffs as they would land through independent GPT-5.6 Sol code, security, and architecture lanes, plus product-design/browser-privacy review for Malibu. Every finding records severity, evidence, consequence, and required correction. Fix and rerun affected tests/audits until combined Critical=0, High=0, Medium=0. Low/Info may be carried explicitly.

## 14. Acceptance report fields

The Build 2 handoff must state separately:

- implementation status and PR/commit references for MacProvider and Malibu;
- fresh unit/fixture results;
- fresh gateway/coordinator/Swift two-provider integration results;
- fresh browser results;
- actual MLX result and captured safe hardware/model/artifact context;
- deployed/production qualification status;
- skipped, unavailable, timed-out, or blocked evidence;
- remaining operator, release, hardware, credential, or deployment prerequisites;
- confirmation that provider plaintext visibility, response relay visibility, no ciphertext failover, and settlement/reward exclusions remain truthful.
