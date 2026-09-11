# Product Build 2 PRD and implementation plan

**Plan revision:** R2
**Status:** draft; implementation is prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for these exact bytes and the paired R2 test specification
**Paired test specification:** `test-spec-r2.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu buyer-app base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)
**Predecessor:** `prd-implementation-plan-r1.md`
**Failed predecessor review:** `reviews/plan-r1-sol.md`

## 1. Product outcome and evidence boundary

An authenticated buyer can obtain an operator-signed provider bundle without trust on first use, approve one or more identities, reserve only an approved provider before encryption, and send nonstreaming or streaming encrypted requests using a supported Go library/CLI or the Malibu buyer console. The selected provider decrypts and sees plaintext. Gateway and coordinator relays receive ciphertext and routing metadata; they receive the provider response and can see content echoed in it. The product does not claim confidential compute, provider-private execution, anonymity, unlinkability, response encryption, or proof that a provider did not retain plaintext.

Buyer approval is an additional restriction over operator identity authority, authenticated provider sessions, model admission, encryption-key validity, quota, and ordinary settlement. It grants none of those authorities. A ciphertext is permanently bound to one reservation, provider, assigned session, key, model, and trust-profile revision. It is sent at most once and is never failed over.

Fresh local fixture tests, browser tests, actual MLX inference, deployed-service evidence, and production qualification are separate evidence classes. The deterministic Swift fixture cannot satisfy actual-MLX acceptance. Local tests cannot activate production or qualify operator bundle signing.

## 2. User journeys

### J1. Receive and approve provider identities

1. An account-authenticated invitation names one exact signed provider-bundle digest, revision, expiry, and allowed fingerprint set. Invitations are account-scoped, single-purpose, bounded, and cannot be redeemed by another account.
2. The client downloads the public bundle, verifies its Ed25519 signature against a release-baked relay-blind bundle keyring, verifies signer lifecycle, bundle freshness, exact digest, closed schema, and pin bounds, and matches it to the invitation. Coordinator profile reads cannot create this trust state.
3. The client displays every selected fingerprint, model/endpoint scope, expiry, and the provider-plaintext/relay-visible-response boundary. The buyer explicitly confirms a nonempty subset allowed by the invitation.
4. With a normal account API key, the client creates an account-owned profile. Demo and wallet-session credentials cannot mutate profiles. The coordinator independently intersects every pin with its operator provider-identity map and stores the exact signed-bundle and invitation references.
5. The client verifies that the response revision, digest, and pins exactly equal its locally confirmed selection before enabling encryption. A fresh client with only a profile GET remains disabled.

Manual independent fingerprint delivery remains an operator diagnostic path, not the supported Build 2 bootstrap. A production bundle signer/keyring, published bundle, and account invitation are qualification prerequisites; tests may use an isolated test signer and must label that evidence local.

### J2. Reserve A when B sorts first

1. The client sends the unchanged closed six-field reservation JSON and exact profile ID, revision, and digest in three single-value headers.
2. Gateway authenticates the account or signed wallet session, validates the profile reference, strips internal authority headers, and forwards trusted account/session context.
3. Coordinator maps the profile pins to the independent operator map, snapshots only those provider IDs from the in-memory pool, intersects that snapshot with the exact current profile and durable key rows, and commits a reservation using the double-collect protocol in C5. No pool lock overlaps a SQLite transaction or network call.
4. Reservation success is returned only after the profile and the exact provider/session/model tuple were simultaneously valid at the documented linearization point. If B sorts first globally but only A is approved, B is never selected.
5. The client verifies the returned signed key record against the locally confirmed profile before creating an ephemeral key, nonce, request ID, or ciphertext.

### J3. Use A+B and lifecycle changes

Fresh reservations may select either A or B using stable eligible ordering after approved-identity filtering. Replacing A+B with B-only or revoking the profile invalidates old-profile `selection_pending`, `reserved`, `consumed_predispatch`, and `dispatch_authorizing` rows. Rows already marked `dispatched`, `terminal`, or `unknown_postdispatch` remain irreversible. Existing ciphertext never changes target.

### J4. Cancel, disconnect, and recover

Before any inference send, the client durably commits a redacted `send_fenced` journal state. Once fenced, no process or tab may send the same envelope except the in-memory owner that performed that transition; a crash before its send sacrifices availability and requires status fencing, never takeover/resend.

The authenticated v2 status request uses an account-scoped, capability-strength provider-binding digest and a nullable envelope digest. A fresh `reserved` row has no coordinator-authoritative envelope digest; status reports `envelope_binding: unbound` and does not claim the supplied digest is correct. After consume, the exact non-null envelope digest is mandatory. Predispatch expiry or authoritative invalidation produces a terminal rejection that permits a wholly new transaction. `dispatched`, `terminal`, and `unknown_postdispatch` always mean `do_not_resubmit`. Lost output is not reconstructed.

### J5. Malibu browser journey

Malibu exposes **Request encryption** only for account API-key users on a secure origin with Web Crypto, IndexedDB, and Web Locks. It uses a private-request transport separate from `console/api.js::fetchChatCompletions`, whose current ordinary-chat path retries selected 502/503 failures. A committed envelope is sent once. Abort, reload, storage error, or network uncertainty enters status recovery. Unsupported capabilities disable private mode without plaintext fallback.

The UI states that the provider sees plaintext, the response returns through Malibu and may echo the request, and chat history remains plaintext in browser storage. Agent/tool mode stays unsupported in this build.

## 3. Authority and ownership

| Authority | Owner and invariant |
|---|---|
| Bundle trust root | A dedicated relay-blind bundle Ed25519 keyring compiled into compatible CLI/Malibu releases. It is distinct from provider identity, SPEC-023 feed, wallet, payout, and TLS keys. Private signing material never enters a repository/worktree. |
| Invitation | Coordinator SQLite account-scoped invitation rows; gateway exposes authenticated proxy routes. An invitation authorizes a signed bundle/fingerprint subset but does not make an unsigned identity trusted. |
| Provider identity | Existing coordinator operator `provider_id -> Ed25519 public key` map. Profile-required startup rejects duplicate fingerprints mapped to different provider IDs. |
| Buyer approval | Coordinator immutable profile revisions plus the client's locally confirmed signed bundle. Server reads synchronize; they never bootstrap client trust. |
| Pool liveness | Coordinator in-memory registry process epoch, relay-blind generation, and exact provider/session/model/routability tuple. |
| Profile/key durability | Coordinator relay-blind SQLite. It never calls the pool or network while a transaction is open. |
| Quota and recovery | Gateway SQLite atomically owns quota/session reservation plus the relay-blind recovery join. Only authoritative coordinator terminal rejection permits a refund. |
| Encryption and journal | Supported client/browser. Failure to persist the pre-send fence prevents inference send. |
| Inference | Exact reserved Swift provider session. The provider sees plaintext. |
| Settlement | Existing SPEC-005 path. SPEC-022 positive verification and verified-work rewards remain excluded. |

## 4. Dependency graph and slice order

```text
SPEC-041 / SPEC-006 / SPEC-040 contract amendments
  +-- exact signed-bundle, invitation, profile, status, error, and bounds contracts
  +-- pool generation and cross-store recovery contracts
        |
        +-- coordinator schema, invitation/profile authority, pool snapshots
        |     +-- approved reservation + consume/final-arm lifecycle
        |
        +-- gateway profile/invitation/status proxy + atomic quota recovery row
        |     +-- wallet canonical route coverage
        |
        +-- shared Go/Swift/JavaScript vectors
              +-- supported Go library/CLI and durable journal
              +-- two-provider integration
              +-- Malibu dependent repository implementation
                    +-- real-browser evidence

physical Apple Silicon + supported cached MLX artifact
  +-- encrypted actual-MLX acceptance evidence
```

Normative contracts land before runtime code. The Malibu change uses its own fresh worktree/branch and may depend explicitly on an unmerged MacProvider PR. Build 1 is not required when a currently supported cached artifact is used. No model download is introduced.

## 5. Exact normative contracts

### C1. Cross-runtime lexical rules and limits

All new JSON objects are closed, reject duplicate keys before object construction, reject unknown/missing/null fields except the explicitly nullable v2 status `envelope_digest`, reject trailing bytes, and have a 65,536-byte body limit. Strings used by framing are printable ASCII bytes `0x21..0x7e`; model IDs additionally retain the existing model validator. Base64url is RFC 4648 URL alphabet, unpadded, and must round-trip canonically.

Every wire integer is a JSON number whose raw token matches `0|[1-9][0-9]*` and whose value is at most `9007199254740991` (`2^53-1`). Negative, `-0`, leading-zero, fraction, exponent, quoted-number, NaN, Infinity, and larger tokens fail before mutation. Go must preserve and lexically validate `json.Number`; JavaScript must scan for duplicates and validate numeric tokens before `JSON.parse`; Swift must validate the same raw grammar. Internal pool counters use `uint64` and are never JSON numbers.

All multi-byte integers in digest/signature framing are unsigned big-endian. `u16str(s)` is `uint16(len(ASCII(s))) || ASCII(s)` and rejects length above 128 unless a narrower field bound applies. Arrays are `uint16(count)` followed by elements. No Unicode normalization occurs because framed strings are ASCII-only.

### C2. Signed provider bundle and authenticated invitation

The closed bundle is:

```text
version, bundle_id, bundle_revision, issued_at_unix, expires_at_unix,
signer_kid, pins, signature
```

- `version` is exactly `relay-blind-provider-bundle-v1`.
- `bundle_id` decodes to 16 bytes; revision is `1..2^53-1`.
- validity is positive, at most 86,400 seconds, not more than 60 seconds future-skewed, and within the trusted signer's compiled validity interval.
- `signer_kid` is the first 16 bytes of SHA-256 of the signer public key, canonical base64url.
- `pins` contains 1..16 complete `relay-blind-pilot-pin-v1` records, sorted by fingerprint and unique. Each pin has validity at most 2,592,000 seconds (30 days), 1..16 sorted unique models, and exactly the supported sorted endpoint set (Build 2 permits only `chat_completions`). Active bundle pins have `revoked: false`.

`pinframe(pin)` is, in order: `u16str(version)`, decoded 32-byte identity public key, decoded 32-byte fingerprint, model array of `u16str`, endpoint array of `u16str`, `uint64(not_before_unix)`, `uint64(expires_at_unix)`, and one byte `0x00`/`0x01` for revoked. The signed bytes are:

```text
ASCII("macprovider/relay-blind/provider-bundle/v1\x00") ||
decoded_16(bundle_id) || uint64(bundle_revision) ||
uint64(issued_at_unix) || uint64(expires_at_unix) ||
u16str(signer_kid) || uint16(pin_count) || pinframe(pin[0]) ...
```

`signature` is a canonical base64url Ed25519 signature over those exact bytes. `bundle_digest` is canonical base64url SHA-256 of the complete signed bytes followed by the decoded 64-byte signature. Shared fixtures freeze exact positive and negative bytes.

An invitation is a closed authenticated response with `version: relay-blind-trust-invitation-v1`, 16-byte `invitation_id`, exact bundle ID/revision/digest, sorted allowed fingerprints, and expiry. It is stored under the authenticated account, expires within 86,400 seconds, and is consumed idempotently by one successful create/replace operation. Cross-account lookup/redeem is constant-shape not found. Profile pins must be a nonempty subset of both the invitation allowlist and signed bundle, byte-identical by `pinframe`.

Bundle, invitation, and signer time validity are activation checks. Once a revision is created, ordinary bundle/invitation expiry or signer validity-window end does not silently revoke it; the revision remains usable only until its earliest selected pin expiry. Explicit signer/bundle/profile/pin revocation tombstones do invalidate predispatch lifecycle checks. They do not rewrite postdispatch history. This distinction is stored so a consumed invitation can expire without making a valid profile unusable while emergency revocation still fences it.

The supported client obtains the exact invitation through the authenticated gateway and the bundle over HTTPS, then verifies the release-baked signer before presenting approval. A keyring rotation requires an overlapping client release. Unknown/revoked/out-of-window signer, stale bundle, invitation mismatch, cross-release unsupported bundle version, or altered pin fails before profile mutation. Production signer provisioning/publication is a named qualification gate.

The route lifecycle is exact:

- an offline operator tool signs the bundle and uploads only its public bytes through operator-authenticated `PUT /admin/relay-blind/provider-bundles/{bundle_id}/{bundle_revision}`; the coordinator re-verifies the configured public keyring before storing it;
- operator-authenticated `POST /admin/relay-blind/trust-invitations` accepts a closed `version, operation_id, account_id, bundle_id, bundle_revision, bundle_digest, allowed_fingerprints, expires_at_unix` body and writes the account-scoped invitation idempotently;
- account-API-key-only `GET /v1/relay-blind/trust-invitations/{invitation_id}` returns the closed invitation response and constant-shape not-found across accounts;
- public `GET /v1/relay-blind/provider-bundles/{bundle_id}/{bundle_revision}` returns the exact stored signed bytes, `ETag` equal to the quoted bundle digest, and no dynamic pin substitution. It is safe to cache only until bundle expiry; clients still verify every use;
- signer/bundle emergency revocation is an operator-authenticated append-only tombstone operation, not deletion. Revocation is published in coordinator capability state, blocks invitation/profile creation and predispatch lifecycle, and remains retained at least through the 8-day recovery horizon.

Operator routes use the repository's existing operator authentication boundary, are unavailable on the buyer listener, have a 64 KiB body limit and 60 mutations/minute, and never accept or return private signing material. Bundle upload and invitation issuance are implementation scope; producing or activating a production private signing key is not.

### C3. Trust profile framing and CRUD routes

The public profile document has exactly:

```text
version, profile_id, revision, profile_digest, state, bundle_id,
bundle_revision, bundle_digest, invitation_id, pins,
created_at_unix, updated_at_unix
```

`version` is `relay-blind-trust-profile-v1`; `profile_id` decodes to 16 client-CSPRNG bytes; `revision` starts at 1 and increments by one; `state` is `active` or `revoked`. Pins retain bundle order. The digest input is:

```text
ASCII("macprovider/relay-blind/trust-profile/v1\x00") ||
u16str(version) || decoded_16(profile_id) || uint64(revision) ||
decoded_16(bundle_id) || uint64(bundle_revision) || decoded_32(bundle_digest) ||
decoded_16(invitation_id) || uint16(pin_count) || pinframe(pin[0]) ...
```

`profile_digest` is canonical base64url SHA-256 of those exact bytes. State and timestamps are excluded so revocation cannot alter the immutable revision digest. Account ID is not in the public digest; every lookup is account-scoped.

Public account-key-only routes are `POST /v1/relay-blind/trust-profiles`, `PUT /v1/relay-blind/trust-profiles/{profile_id}`, `DELETE /v1/relay-blind/trust-profiles/{profile_id}`, `GET /v1/relay-blind/trust-profiles`, and `GET /v1/relay-blind/trust-profiles/{profile_id}`. Corresponding coordinator buyer-port routes require gateway bearer plus trusted account context. Create body is exactly `version, operation_id, profile_id, invitation_id, bundle, pins`; replace adds exact `expected_revision, expected_profile_digest`; revoke is exactly `version, operation_id, profile_id, expected_revision, expected_profile_digest`. Each operation version is route-specific. Operation IDs decode to 16 CSPRNG bytes. Replays are idempotent only when the stored canonical request digest matches; changed reuse conflicts.

Exact mutation versions are `relay-blind-trust-profile-create-v1`, `relay-blind-trust-profile-replace-v1`, and `relay-blind-trust-profile-revoke-v1`. Create/replace success returns exactly the profile document; revoke success returns the same document with `state: revoked` and unchanged immutable digest. Get returns exactly one profile document. List returns exactly `version: relay-blind-trust-profile-list-v1`, `profiles`, and nullable `next_cursor`; profiles are ordered by `(profile_id,revision)` bytes and contain the same exact public document.

List cursor is a server-authenticated opaque cursor over `(account_id, profile_id, revision)` with default 20 and maximum 32 entries. Reads return public profile fields only. Every route remains mounted while disabled, returns typed no-store errors, and sets `Cache-Control: no-store` and `Pragma: no-cache`.

### C4. Reservation reference and wallet signing

The existing six-field reservation body and v1 envelope remain unchanged. Supported mode requires exactly one canonical value for:

- `X-MacProvider-Relay-Blind-Trust-Profile` (16-byte base64url ID),
- `X-MacProvider-Relay-Blind-Trust-Revision` (canonical safe JSON-integer text `1..2^53-1`),
- `X-MacProvider-Relay-Blind-Trust-Digest` (32-byte base64url digest).

Gateway rejects missing, duplicate, comma-joined, whitespace-ambiguous, oversized, or conflicting case variants and forwards reconstructed trusted values. Reservation success echoes the exact reference as no-store headers. The selected signed key fingerprint must match an active pin in that revision for model and endpoint; the client checks it locally before encryption. Reservation rows add immutable profile/bundle/invitation/fingerprint and pool-token fields.

For wallet sessions, `/v1/relay-blind/route-reservations` semantic headers are exactly `accept`, `idempotency-key`, and the three lowercase trust-profile headers, sorted by the existing SPEC-040 grammar. The signed raw-body digest covers the unchanged six-field body. Wallet sessions may use an existing profile but cannot call invitation/profile mutation or read routes.

The canonical wallet recovery route is exactly `POST /v1/relay-blind/request-status`, with no query string and semantic headers exactly `accept`. Its raw-body digest covers the exact v2 status body. Existing SPEC-040 signed object binds method, canonical route, UUIDv4 request ID, raw body SHA-256, semantic-header SHA-256, and timestamp. Freshness remains max age 300 seconds and future skew 30 seconds or stricter. Each poll uses a new request ID and creates a `metadata_only` replay row before coordinator lookup; identical or mismatched request-ID replay fails and never returns cached status. Resolved wallet account and session must equal the reservation row. API-key status requires the same account and an empty wallet session.

### C5. Pool/SQLite selection protocol

The pool registry adds a CSPRNG 128-bit `relay_blind_pool_epoch` per process and a `uint64 relay_blind_generation` starting at 1. Generation increments, before unlock, on every change to provider presence, assigned session, state, serving predicate, tunnel availability, advertised models/provider model, dispatchable capacity flags, or relay-blind admission flags. Overflow marks relay-blind selection unavailable until restart; it never wraps. Restart changes epoch and rejects orphan `selection_pending` rows.

Operator mapping reduces at most 16 approved fingerprints to at most 16 unique provider IDs. `SnapshotRelayBlindCandidates(ids, model)` briefly holds the pool read lock, copies the epoch/generation and immutable candidate tuples `(provider_id, assigned_session, fingerprint, model, provider_model, tunnel/routability flags)`, sorts by the existing eligible ordering, and releases the lock. It does no DB/network work.

One reservation attempt uses at most three double-collect rounds:

1. **D0:** a SQLite read loads the referenced profile/pins; it closes before pool access.
2. **P1:** take bounded snapshot token `T1=(epoch,generation)` and candidate tuples.
3. **D1:** `BEGIN IMMEDIATE`, with no pool lock: revalidate the exact active profile and immutable bundle/invitation lineage, explicit lineage revocation status, selected-pin time validity, and operator mapping; it does not reapply expired one-time activation windows. Intersect P1 tuples with durable current key rows, choose the first eligible tuple, insert `selection_pending` with T1 and random bindings, commit. Mutation transactions invalidate pending rows.
4. **P2:** exact-tuple recheck returns token `T2`. If tuple is absent or `T2 != T1`, reject the pending row in a new transaction and retry from D0.
5. **D2:** `BEGIN IMMEDIATE`: revalidate the same active profile, selected pin, signed key, unchanged pending row, and token T2; transition to `reserved`; commit. This commit is the candidate/profile authorization linearization candidate.
6. **P3:** exact-tuple recheck. Success requires token `T3 == T2`. Because the generation is monotonic, equality proves no relevant pool mutation across D2. Then a final SQLite read confirms the row remains `reserved`. Only then may the response be emitted. Otherwise reject without response and retry/fail typed.

No pool mutex is held while acquiring/waiting on SQLite, and no SQLite transaction calls pool/network code. No gateway lock spans a coordinator call. SQLite busy timeout is at most 5 seconds; three churn rounds are the maximum. Exhaustion returns `relay_blind_approved_provider_churn` with `wait_then_new_transaction`. `selection_pending` expires after 30 seconds, is never consumable/status-visible, and is rejected by restart sweep, profile/bundle/signer invalidation, or token-epoch mismatch.

Consume uses: close a D0 reservation/profile read; take exact-tuple P1/T1; in D1 `BEGIN IMMEDIATE` validate `reserved`, envelope, profile, bundle/signer, selected pin/key and transition to `consumed_predispatch` while binding the authoritative envelope digest; then take P2/T2 and finally read the row. It returns consume authorization only when T2 equals T1 and the row remains consumed. Mismatch or concurrent invalidation terminally rejects/burns the row with dispatch proven absent; it never restores `reserved`.

Final arm uses: close a D0 read; take P1/T1; in D1 `BEGIN IMMEDIATE` revalidate the consumed row/profile/key and transition to `dispatch_authorizing`; take P2/T2; on mismatch reject authorizing with dispatch proven absent; otherwise in D2 `BEGIN IMMEDIATE` revalidate everything and transition to `dispatched`; then take P3/T3 before any network call. T3 must equal T2. Equality proves the exact tuple was stable across D2; only then does the same handler attempt one send to that assigned session. If P3 mismatches or the process crashes after D2, state is conservatively `unknown_postdispatch`/held even when the live mismatch path knows it had not called the network; it is never auto-refunded. Profile mutation serializes with D1/D2: if mutation wins it rejects `dispatch_authorizing`; if D2 wins, dispatch authorization precedes revocation and the row is irreversible. Pool churn after the successful P3 or after a reservation response is permitted staleness; exact-session send/consume checks fail closed and never select another provider.

### C6. Profile invalidation and gateway quota recovery

Gateway adds a durable `relay_blind_recovery` join keyed by `(account_id, wallet_session_id, request_id)` with profile reference, binding digest, nullable envelope digest, coordinator state class, quota row identity, and state. Coordinator consume succeeds before quota, then the gateway creates quota and this join in the same SQLite transaction. For wallet traffic that transaction also creates the wallet-session reservation. A join exists from the first held token; there is no quota-only relay-blind crash state.

Before the coordinator dispatch call, one gateway transaction moves the join to `dispatch_intent`, sets the account quota settlement hold, and, for wallet traffic, arms the wallet-session dispatch. Failure rolls back all three. The coordinator response is authenticated as either `no_prior_dispatch` with terminal `rejected`, or possible/actual postdispatch. Only exact coordinator terminal `rejected` with `dispatch_proven_absent: true` permits the gateway to atomically refund account quota and wallet-session reservation exactly once. Store/network absence, profile staleness alone, or `reserved`/`consumed_predispatch`/`dispatch_authorizing` never permits refund.

Profile, pin, signer, bundle, operator-map, key, model, and session invalidation applies this table:

| Coordinator state at invalidation | Coordinator result | Gateway result |
|---|---|---|
| `selection_pending`, `reserved` | terminal `rejected`, no dispatch | no quota should exist; if a joined anomaly exists, reconcile and refund only on authenticated rejection |
| `consumed_predispatch`, `dispatch_authorizing` | terminal `rejected`, `dispatch_proven_absent: true` | discover join, atomically refund active/held account and wallet quota once |
| `dispatched` | unchanged or later `unknown_postdispatch` | retain hold/reconcile known usage; never refund solely for invalidation |
| `terminal`, `unknown_postdispatch`, `rejected` | immutable terminal fence | idempotently settle/refund according to the recorded terminal class |

Recovery scans all nonterminal relay-blind joins, including `quota_active` and `dispatch_intent`, oldest first; it is not limited to existing settlement-hold rows. It calls read-only coordinator v2 status and applies the table transactionally. Duplicate workers use compare-and-swap terminal transitions. Coordinator rejection/status evidence is retained for 691,200 seconds (8 days) after terminal state, exceeding the gateway 604,800-second settlement-journal retention plus interval/skew margin. A healthy default configuration uses interval at most 30 seconds, batch 100..500, and at most 1,000 nonterminal relay-blind joins, so a no-new-arrival backlog is visited within 300 seconds at batch 100. Oldest age above 60 seconds alerts; unavailable evidence remains held; after 604,800 seconds it becomes `stale_held`/operator-visible and is never auto-refunded.

Coordinator capability publication includes status version and exact evidence-retention seconds. Local enabled configuration with nonpositive/impossible bounds fails that service's startup. Gateway enablement preflight requires the coordinator value to be at least gateway journal retention plus two recovery intervals plus maximum clock skew; when the coordinator is unavailable or mismatched, the profile feature remains unavailable and fails closed while ordinary plaintext startup continues. Row/batch/interval settings must meet the stated visit bound.

### C7. Versioned status protocol

Legacy internal status v1 remains exact for legacy rows. Build 2 public and internal recovery uses closed v2 request fields `version`, `provider_binding_digest`, and nullable `envelope_digest`; version is `relay-blind-status-request-v2`. The binding digest is SHA-256 of the 32-byte random provider-binding string bytes and is account/session-scoped. It is the reservation locator/capability and must be 32-byte canonical base64url.

- For `reserved`, stored envelope digest is absent. A null or supplied envelope digest does not authenticate/confirm that digest; response is `envelope_binding: unbound`. A wrong supplied digest is intentionally indistinguishable in this state.
- For `consumed_predispatch`, `dispatch_authorizing`, `dispatched`, `terminal`, or `unknown_postdispatch`, a non-null exact digest is mandatory; null/wrong fails constant-shape.
- For `rejected` before any consume, response is `unbound`; for rejection after consume it requires and reports `bound`.

The exact v2 response is `version, state, envelope_binding, internal_request_id, validated, input_tokens, completion_tokens, effective_privacy_outcome, dispatch_proven_absent, retry_action`. `version` is `relay-blind-status-v2`. Nullable usage follows existing rules. `dispatch_proven_absent` is true only for a terminal `rejected` row whose state transition excluded every network attempt; it is false for fresh `reserved`, even though no dispatch existed at lookup time, because an already in-flight consume can race the read. Fresh predispatch states return `check_status_do_not_resubmit`; status atomically fences expired predispatch state to rejection before returning `new_reservation_and_envelope`. Postdispatch states return `do_not_resubmit`. Status never dispatches, changes profile trust, reconstructs output, or reveals provider/session/profile pins/raw bindings.

### C8. Client and browser journals

The logical state machine is `reservation_received_unbound -> envelope_built -> send_fenced -> response_started -> terminal`, with terminal alternatives `predispatch_rejected`, `unknown_postdispatch`, and `quarantined`. Every transition is monotonic compare-and-swap. `send_fenced` stores both digests and is durably committed and read back before `fetch`/HTTP send. No state after `send_fenced` authorizes another owner to send the old envelope.

The Go journal uses a private absolute application-support path, 0700 ancestry, a no-follow regular 0600 lock file, and an append-only canonical JSONL file opened with `O_NOFOLLOW|O_APPEND`. An exclusive advisory lock covers load/validate/transition; append is followed by file fsync, and first creation by directory fsync. Compaction under the lock writes a same-directory `O_EXCL` 0600 temporary snapshot, fsyncs it, atomically renames, fsyncs the directory, and reopens/revalidates identity. A final partial line is truncated only to the last fsynced newline; an interior malformed/schema-invalid/rollback record quarantines the journal and disables new private sends. Status-only recovery of independently supplied valid locators remains allowed. Lock or durable-write failure prevents send.

The Go journal permits 4,096 current transactions, 16 MiB, and 4 KiB per record. Terminal records are retained 691,200 seconds. Compaction may remove only expired terminal records; if still at cap, new reservation/encryption fails with `client_journal_capacity` before network, while status/revocation remain available.

Malibu uses IndexedDB, not the existing thread/settings `localStorage`, and an exclusive Web Lock named from origin plus transaction ID. One readwrite transaction validates the old generation, writes `send_fenced`, commits, and is read back before `fetch`. No lease expiry permits takeover. Missing Web Locks/IndexedDB, transaction abort, quota error, blocked version change, corrupt record, generation conflict, or failed readback prevents send. Records are at most 2 KiB, 128 transactions, and 262,144 total serialized UTF-8 bytes, with the same 8-day terminal retention. Cleanup and state transition occur in one IndexedDB transaction. Two tabs/double-clicks produce one fence owner and at most one send.

Neither journal stores prompt/messages/tools/response text, ciphertext, ephemeral private key, bearer/wallet key, raw provider/buyer binding, provider ID/session, local path, or raw server body. Browser chat history remains separately plaintext and disclosed. Clearing a journal removes recovery convenience and never authorizes resending old material.

### C9. Capacity, retention, and fail-closed configuration

| Item | Bound / retention |
|---|---|
| Bundle keyring/storage | 8 trusted signer keys; 4,096 bundle revisions and 64 MiB public bundle bytes globally |
| Profiles per account | 32 total active or retained profile IDs |
| Revisions per profile | 64 retained immutable revisions |
| Pins/models per revision | 16 pins; 16 models per pin; one endpoint in Build 2 |
| Invitations | 128 live/account; 24-hour maximum validity; 8-day consumed/tombstone retention |
| Mutation operations | 4,096 rows and 4 MiB canonical input/account; 8-day retention |
| Profile/audit rows | 8,192 rows and 8 MiB/account; 30-day retention; mutation fails closed if its required audit cannot commit |
| Profile request/list | 64 KiB request; page default 20/max 32; 60 mutations and 120 reads/status per account/minute |
| Profile reservations | 512 live/account, 2,048 live/profile, within existing global 10,000 cap |
| Pool projection/rounds | at most 16 providers and 3 double-collect rounds |
| Pin/bundle lifetime | pin 30 days; bundle/invitation 24 hours; clock skew 60 seconds |
| Signer/bundle revocation tombstones | 38 days (maximum pin lifetime plus 8-day recovery horizon) |
| Coordinator terminal/status evidence | 8 days from terminal state |
| Gateway nonterminal recovery joins | 1,000; 8-day evidence dependency; 7-day stale-held threshold |
| Client journals | Go 4,096/16 MiB/4 KiB; browser 128/256 KiB/2 KiB; terminal retention 8 days |

Pruning is indexed, bounded per pass, oldest eligible first, and never deletes active profiles, live invitations, nonterminal operations, pre/postdispatch fences, unsealed settlement effects, or evidence still referenced by another table. A bundle revision is eligible only after its own expiry, every referencing profile pin expiry, and each referencing reservation terminal plus 8 days. Revisions are eligible only after every pin expiry and the last bound reservation/economic-recovery horizon. Tombstones prevent profile/invitation/operation ID reuse throughout retention. At a hard cap the affected new operation fails before partial state; revocation/status/recovery remain available through reserved emergency capacity. Enabled startup validates all inequalities and fails closed. Disabled mode preserves plaintext startup and safe replay/status defaults.

## 6. Typed errors and precedence

Freeze the gateway/coordinator/client inventory in SPEC-041 before runtime work. It includes profile required/malformed/not-found/revoked/stale/conflict, untrusted bundle/signer/pin, invitation expired/mismatch, no approved provider, provider churn, journal unavailable/capacity/corrupt, and recovery unavailable. Every error has exact HTTP status, `phase`, `retryable`, and one action: `provision_profile`, `replace_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, or `none`.

Durable replay and postdispatch state outrank rate/capacity/profile/provider errors. Any uncertainty after `send_fenced` is status-only. Unknown/malformed server errors map to unavailable and `do_not_resubmit` when send may have occurred. Clients never infer retry safety from HTTP status alone.

## 7. Implementation slices

1. **Governance and vectors:** update SPEC-041, SPEC-006, SPEC-040, AUTHORITY, CONFORMANCE, and shared fixtures with C1-C9, wire schemas, errors, framing vectors, mixed-version rules, and non-claims.
2. **Coordinator authority:** additive/rebuild migration, bundle keyring/config, invitation/profile/operation/audit tables, operator intersection, pool epoch/generation snapshots, double-collect reservation/consume/dispatch, invalidation, status v2, metrics, purge.
3. **Gateway:** authenticated invitation/profile/status proxy, header stripping, wallet route profiles, atomic quota/session/recovery join, oldest-first reconciliation, bounds/metrics.
4. **Go library/CLI:** exported `pkg/relayblindbuyer`, signed-bundle verification, typed errors, journal state machine, commands for invitation/profile/request/status. Reference CLI becomes a thin adapter.
5. **Two-provider integration:** A-only/B-only/A+B, lifecycle, concurrency, recovery, streaming/nonstreaming, exact settlement.
6. **Malibu dependent repository:** isolated worktree; signed bundle/profile UI, Web Crypto module, IndexedDB/Web Locks journal, no-retry private transport, truthful docs/copy, Node and browser tests.
7. **Physical MLX evidence:** opt-in isolated journey using an already supported cached artifact. Record only safe model/artifact/runtime/hardware context.

Each slice is reviewable and default-off. Material changes to framing, authority, state machines, lock protocol, economic recovery, browser durability, or acceptance strategy reopen the plan gate.

## 8. Migration, compatibility, and rollback

Coordinator migration creates bundle/invitation/profile/revision/operation/audit tables, rebuilds the reservation table transactionally to add `selection_pending` and `dispatch_authorizing` CHECK states plus nullable Build 2 columns, copies all legacy rows byte-for-byte, verifies counts/indexes/foreign keys, and stamps one schema version. Crash/reopen and double migration are mandatory. Legacy terminal/status v1 rows remain readable. With profile-required mode enabled, legacy unbound predispatch rows are terminally rejected; postdispatch rows remain irreversible.

Gateway migration adds the recovery join and required quota/session foreign-key/index relationships in one versioned transaction. Existing relay-blind quota rows are conservatively imported as postdispatch-unknown/held when dispatch absence cannot be proven. No migration refunds. Wallet and API-key rows preserve accounting identity.

Mixed-version behavior is fail closed: old gateway cannot request profile mode; new gateway detects old coordinator capability before accepting a profile reservation; old clients receive typed migration action; v1 envelope and six-field reservation body remain valid only on the legacy default-off pilot path. A profile-bound request never downgrades to legacy selection or plaintext.

Rollback disables new profile reservations first, drains/rejects `selection_pending`/`dispatch_authorizing`, keeps v2 status and gateway reconciliation running, then rolls binaries. Schema/tombstones are not dropped. An old binary may start only after a compatibility checker proves no state/value it cannot preserve. Disabling bundle issuance or profile mutation does not delete active recovery evidence.

## 9. Observability and operations

Bounded metrics include invitation/profile create/replace/revoke outcomes, selected-approved/no-candidate/churn outcomes, double-collect retries, pool generation changes, invalidations by state/reason, recovery join state/oldest age/refund/hold/quarantine, status envelope-binding class, wallet signature failures, journal failures, and client recovery actions. Labels use fixed enums and never account/profile/provider/request IDs, fingerprints, model strings, ciphertext digests, prompts, or raw errors.

Sanitized audit records store account-scoped opaque correlation, operation/profile revision/digest, bundle/invitation digest, event/result/reason enums, and timestamps. They exclude provider/session IDs, raw pins/bindings, credentials, prompts, ciphertext, and output. Alerts fire on recovery oldest age over 60 seconds, churn exhaustion, signer/bundle invalidation, pool generation exhaustion, capacity, migration mismatch, stale-held rows, and audit/journal write failures.

Operator runbooks cover bundle signer custody/rotation/revocation, bundle publication, invitation issuance, profile emergency revocation, recovery backlog, stale-held manual handling, feature rollback, and client keyring compatibility. They never place private material in repositories or worktrees.

## 10. Acceptance criteria and roadmap mapping

| Roadmap outcome | Implementation proof |
|---|---|
| Authenticated pin provisioning/replacement/revocation | Signed release-trusted bundle + account invitation vectors and negative journeys; atomic profile CAS/tombstones/invalidation. |
| A-only when B sorts first | Two-provider service test proving only A reservation/frames and exact linearization token. |
| A+B/no candidate/rotation/revocation/expiry/concurrency | Selection and lifecycle matrix with pool generation barriers and race detector. |
| Selection before encryption | Client instrumentation proves no ephemeral key/nonce/envelope before approved reservation/key verification. |
| Never fail over ciphertext | Envelope-hash send/frame instrumentation across all faults; at most one public send and one exact provider/session. |
| Supported client/library and typed recovery | External Go import test, black-box CLI, exact errors, durable journal crash cuts. |
| Wallet status/recovery | Exact SPEC-040 route/body/header/request-ID signature and replay tests. |
| Malibu product | Real-browser signed-bundle/profile, stream/nonstream, two-tab, reload/storage failure, truthful copy and no ordinary retry. |
| Quota/refund safety | API-key and wallet cross-store crash matrix proves authoritative rejection-only exactly-once refund and postdispatch holds/settlement. |
| Actual MLX | One encrypted request and one stream/cancel through real `ModelRuntime`, with safe context recorded. |
| Truth and economics | Provider plaintext and relay-visible-response copy; ordinary settlement exact; no verified-model/reward promotion. |

## 11. Hardware, compatibility, rollback blockers, and non-goals

Planning and deterministic integration require no 64 GB machine. Actual MLX acceptance requires Apple Silicon, compatible macOS/Swift/MLX, sufficient RAM/disk for one already-supported cached catalog artifact, and isolated services. Absence is a named hardware/artifact blocker, never a passed criterion. Browser acceptance requires real supported Safari and Chromium runs.

Non-goals: provider-hidden plaintext; response encryption; confidential compute/anonymity claims; pool-private requests; verified private settlement; SPEC-022 positive receipts/rewards; payout/reward activation; arbitrary endpoints; agent/tool mode in Malibu; automatic model download; deployment/release/production enforcement; signer key creation in a worktree; epoch/payment implementation; Build 4 Trusted Pools.

## 12. Verification and handoff gates

Run targeted contract/storage/selection/recovery/client/browser tests first, then full coordinator/gateway/integration/Swift/Malibu checks from `test-spec-r2.md`. Review each complete repository diff through independent GPT-5.6 Sol code, security, architecture, and applicable browser/product lanes. Critical, High, and Medium findings must all be zero before a slice is complete.

The handoff separately records implementation/PR references, fixture evidence, browser evidence, actual MLX evidence, deployed/production status, hardware/operator/signing blockers, skipped/timed-out/zero-selected runs, and per-repository cumulative versus dependent diffs. It confirms the provider-plaintext boundary, response relay visibility, no ciphertext failover, and verified-model/reward exclusions.
