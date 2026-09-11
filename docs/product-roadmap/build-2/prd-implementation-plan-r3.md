# Product Build 2 PRD and implementation plan

**Plan revision:** R3
**Status:** draft; implementation is prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for these exact bytes and the paired R3 test specification
**Paired test specification:** `test-spec-r3.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu buyer-app base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)
**Predecessor:** `prd-implementation-plan-r2.md`
**Failed predecessor review:** `reviews/plan-r2-sol.md`

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
5. The client verifies that the response revision, digest, and pins exactly equal its locally confirmed selection, durably commits the C3A account/origin-bound confirmed-profile record, and reads it back before enabling encryption. A fresh client with only a profile GET remains disabled; restart/reload uses the stored confirmation and an exact current server match.

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
| Buyer approval | Coordinator immutable profile revisions plus the C3A local confirmed-profile authority containing the verified signed bundle and selected pins. Server reads synchronize; they never bootstrap client trust. |
| Pool liveness | Coordinator in-memory registry process epoch, relay-blind generation, and exact provider/session/model/routability tuple. |
| Profile/key durability | Coordinator relay-blind SQLite. It never calls the pool or network while a transaction is open. |
| Quota and recovery | Gateway SQLite atomically owns quota/session reservation plus the relay-blind recovery join. Only a C6A-signed, challenge/request/account/session/response-bound coordinator rejection permits a refund. |
| Encryption and journal | Supported client/browser. Failure to persist the pre-send fence prevents inference send. |
| Inference | Exact reserved Swift provider session. The provider sees plaintext. |
| Settlement | Existing SPEC-005 path. SPEC-022 positive verification and verified-work rewards remain excluded. |

## 4. Dependency graph and slice order

```text
SPEC-041 / SPEC-006 / SPEC-040 contract amendments
  +-- exact signed-bundle, invitation, local profile authority, status, error, and bounds contracts
  +-- pool generation and cross-store recovery contracts
        |
        +-- coordinator schema, invitation/profile authority, pool snapshots
        |     +-- approved reservation + consume/final-arm lifecycle
        |
        +-- gateway profile/invitation/status proxy + atomic quota recovery row
        |     +-- wallet canonical route/replay partition + signed coordinator evidence
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

### C1. Cross-runtime lexical rules, nullability, and limits

Every Build 2 wire and local object is closed, rejects duplicate keys before object construction, rejects unknown fields and trailing bytes, and uses the exact presence rules below. A field marked required must be present. A field marked conditional must be present only in the named states. JSON `null` is valid only in the three cells that explicitly say `null`; omission and `null` are never interchangeable.

| Object | Exact presence and nullability |
|---|---|
| Bundle, pin, invitation, account-identity response, profile document, profile create/replace/revoke request | Every declared field required and non-null. |
| Profile list response | `version` and `profiles` required/non-null; `next_cursor` required and either a canonical cursor string or JSON `null`. |
| Reservation request/response, coordinator-control outer/result, and coordinator-evidence proof | Every declared field required and non-null. Evidence uses the exact empty-string sentinel only where C6A says so; JSON `null` is invalid except the nested C7 status result's token fields. |
| v2 status request | All three fields required; `envelope_digest` is canonical base64url or JSON `null`. |
| v2 status response | Every field required; `input_tokens` and `completion_tokens` are independently a safe nonnegative integer or JSON `null`. All other fields are non-null. |
| Confirmed-profile record | Every common field required/non-null. `pending_mutation` is required and either JSON `null` or the closed pending object in C3A. No other null is accepted. |
| Client journal record | Every common field required/non-null. `envelope_digest` is omitted only in `reservation_received_unbound` and an unconsumed terminal `predispatch_rejected`; it is required/non-null in every other state. `terminal_class` and `terminal_at_unix_ms` are omitted in nonterminal states and required/non-null in terminal states. No journal field accepts JSON `null`. |
| Error envelope | Every field required/non-null. `http_status` is integer `0` only for client-local errors. |

Wire bodies have a 65,536-byte limit before parsing. Confirmed-profile and journal records use the narrower C3A/C8 limits. Strings used by framing are printable ASCII bytes `0x21..0x7e`; explicitly defined empty sentinels are the only empty strings. Model IDs additionally retain the existing model validator. Base64url is RFC 4648 URL alphabet, unpadded, and must round-trip canonically.

Every wire integer is a JSON number whose raw token matches `0|[1-9][0-9]*` and whose value is at most `9007199254740991` (`2^53-1`). Negative, `-0`, leading-zero, fraction, exponent, quoted-number, NaN, Infinity, and larger tokens fail before mutation. Go must preserve and lexically validate `json.Number`; JavaScript must scan for duplicates and validate numeric tokens before `JSON.parse`; Swift must validate the same raw grammar. Internal pool counters use `uint64` and are never JSON numbers.

All multi-byte integers in digest/signature framing are unsigned big-endian. `u16str(s)` is `uint16(len(ASCII(s))) || ASCII(s)` and rejects length above 128 unless a narrower field bound applies. `u16str_allow_empty` uses the same encoding and is allowed only at named sentinels. `u32bytes(b)` is `uint32(len(b)) || b`. Fixed base64url values are decoded before framing as `b16`, `b32`, or `b64`; UUIDv4 text is decoded to its 16 RFC 4122 bytes. Arrays are `uint16(count)` followed by elements. Tagged optional values use one byte `0x00` absent or `0x01` followed by the value. Booleans are exactly `0x00` or `0x01`. No Unicode normalization occurs because framed strings are ASCII-only.

Slice 0 publishes one machine-readable schema manifest consumed by Go, Swift, JavaScript, and conformance tests. It includes positive, missing, duplicate, unknown, explicit-null, omitted, wrong-type, oversized, unsafe-integer, and trailing-byte vectors for every object above. The status locator is frozen as:

```text
canonical_provider_binding = base64url_unpadded(decoded_32(provider_binding))
provider_binding_digest = base64url_unpadded(
  SHA256(ASCII(canonical_provider_binding))
)
```

It intentionally preserves the gateway's current representation-byte hashing. Three required cross-runtime vectors are:

| Decoded provider-binding bytes | Canonical provider binding | Expected provider-binding digest |
|---|---|---|
| 32 bytes `00` | `AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | `DwBzhbb51LfusnSGBa_hqYSgo7-j8BTQnip4TOnlzRo` |
| bytes `00..1f` | `AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8` | `6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A` |
| 32 bytes `ff` | `__________________________________________8` | `Il9-dTKd1FqjVJddc5hzGTCTk686TGczvBNgGk8bh5Y` |

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

### C3A. Durable locally confirmed profile authority

The coordinator adds account-key-only `GET /v1/account/identity`, returning exactly `version: relay-blind-account-identity-v1` and a stable opaque 16-byte canonical base64url `account_subject`. It is scoped to the authenticated account, contains no email or credential material, and cannot create local profile trust. A client may use a server profile only when `(origin, account_subject, profile_id, revision, profile_digest)` exactly matches a valid local confirmed-profile record.

The canonical confirmed-profile record has exactly these common fields:

```text
version, origin, account_subject, profile_id, revision, profile_digest,
bundle_id, bundle_revision, bundle_digest, signer_kid,
signed_bundle, selected_fingerprints, selected_pinframe_digests,
earliest_pin_expiry_unix, confirmation_generation,
predecessor_record_digest, confirmed_at_unix_ms, state,
pending_mutation, record_digest, record_mac
```

`version` is `relay-blind-confirmed-profile-v1`; `origin` is the canonical HTTPS origin with no path/query/fragment; IDs, digests, signer, bundle bytes, selected fingerprints, and pinframe digests must recompute exactly under C1-C3. `signed_bundle` is canonical base64url of the exact verified public bundle JSON bytes; it contains no private material. Selection order equals bundle order. `state` is `active`, `mutation_pending`, or `revoked`. `confirmation_generation` starts at 1 and increments by one. The genesis predecessor is the literal `genesis`; later predecessors are the prior record digest.

`confirmedprofileframe` follows the displayed common-field order, excluding the final digest/MAC, with `u16str` for version/origin/signer/state, `b16` for account/profile/bundle IDs, `uint64` for revisions/times/generation, `b32` for digests/fingerprints/pinframe digests, `u32bytes(decoded signed_bundle)` for bundle bytes, and counted arrays. Predecessor is tagged `0x00` for genesis or `0x01||b32`. Pending is tagged `0x00` for null or `0x01||pendingframe`; `pendingframe` follows its displayed field order with `u16str(operation)`, `b16(operation_id)`, `uint64` revisions/time, `b32` digests, and the counted target digest array. `record_digest` is SHA-256 over `ASCII("macprovider/relay-blind/confirmed-profile-record/v1\x00") || confirmedprofileframe`; `record_mac` is HMAC-SHA256 over the decoded record digest using the storage key described below. An exact machine-readable fixture freezes these bytes and all state transitions before runtime implementation.

`pending_mutation` is JSON `null` for stable active/revoked records. For `mutation_pending`, it is a closed object containing exactly `operation`, `operation_id`, `expected_revision`, `expected_profile_digest`, `target_revision`, `target_profile_digest`, `target_bundle_digest`, `target_selected_pinframe_digests`, and `started_at_unix_ms`. Replace stores the already locally verified target bundle/pins. Revoke has target state revoked and reuses the current immutable digest. The client durably commits `mutation_pending` before sending replace/revoke and disables encryption for that profile. On restart it may finish only when an authenticated server GET exactly matches the pending target; conflict, unavailable state, or mismatch remains disabled and actionable. Successful server mutation is not usable until the matching stable local record commits. A failed local commit after server success therefore sacrifices availability, never trust.

The Go library stores these records under the C8 descriptor-safe storage root in a separate `confirmed-profiles.jsonl` authority with its own lock and HMAC key. The browser stores them in a distinct `confirmed_profiles` IndexedDB object store and stores a nonextractable HMAC `CryptoKey` in `profile_keys`; ordinary site `localStorage`, thread history, and settings are never profile authority. Both actors use append/generation/predecessor validation, atomic compare-and-swap, exact readback, and the same account/origin key. The threat claim is fail-closed detection of corruption, partial rollback, record substitution, and stale data when compared with the authenticated current server profile; it is not protection from a compromised same-origin script or a malicious local account owner.

The store permits 32 current profile records per `(origin,account_subject)`, one in-place pending object per profile, 96 KiB per record, and 4 MiB total serialized bytes. Stable current and pending records cannot be pruned. A revoked record is retained at least 8 days and until the server no longer exposes/references it. At capacity, new confirmation/replacement stops before mutation. Revoke uses the existing profile record and the coordinator's emergency partitions in C9, so it remains representable without a new local record. Corruption, missing HMAC key, account/origin mismatch, generation gap, chain mismatch, rollback relative to a newer server revision, or server/local pin mismatch disables private mode and never reconstructs trust from GET.

Ordinary invitation, bundle, or signer validity-window expiry after activation does not erase a locally confirmed record; earliest selected-pin expiry and explicit signer/bundle/profile/pin revocation do disable it. Emergency signer/bundle revocation state must be refreshed before a new private transaction. Replacement requires new locally verified activation evidence. Clearing either local authority disables all affected private profiles; it does not revoke the server profile or authorize ciphertext reuse.

### C4. Reservation reference and wallet signing

The existing six-field reservation body and v1 envelope remain unchanged. Supported mode requires exactly one canonical value for:

- `X-MacProvider-Relay-Blind-Trust-Profile` (16-byte base64url ID),
- `X-MacProvider-Relay-Blind-Trust-Revision` (canonical safe JSON-integer text `1..2^53-1`),
- `X-MacProvider-Relay-Blind-Trust-Digest` (32-byte base64url digest).

Gateway rejects missing, duplicate, comma-joined, whitespace-ambiguous, oversized, or conflicting case variants and forwards reconstructed trusted values. Reservation success echoes the exact reference as no-store headers. The selected signed key fingerprint must match an active pin in that revision for model and endpoint; the client checks it locally before encryption. Reservation rows add immutable profile/bundle/invitation/fingerprint and pool-token fields.

For wallet sessions, `/v1/relay-blind/route-reservations` semantic headers are exactly `accept`, `idempotency-key`, and the three lowercase trust-profile headers, sorted by the existing SPEC-040 grammar. The signed raw-body digest covers the unchanged six-field body. Wallet sessions may use an existing profile but cannot call invitation/profile mutation or read routes.

The canonical wallet recovery route is exactly `POST /v1/relay-blind/request-status`, with no query string and semantic headers exactly `accept` and `x-macprovider-status-sequence`. Its raw-body digest covers the exact v2 status body. `X-MacProvider-Status-Sequence` is canonical decimal `1..2^53-1`. The existing SPEC-040 signed object binds method, canonical route, UUIDv4 request ID, raw body SHA-256, both sorted semantic headers, and timestamp. Freshness remains max age 300 seconds and future skew 30 seconds or stricter. Resolved wallet account and session must equal the reservation row. API-key status requires the same account and an empty wallet session.

A successful wallet reservation is returned only after the gateway atomically creates one fixed-size `relay_blind_status_authority` row keyed by `(account_id,wallet_session_id,provider_binding_digest)` with reservation/profile/request binding, `highest_sequence: 0`, state, and retention deadline. A wallet poll serializes on that row, revalidates the session/signature/body/locator, and accepts only `status_sequence > highest_sequence`; it atomically stores the higher sequence and current UUIDv4 correlation ID before coordinator lookup. Equal/lower sequence, whether request ID and body match or differ, returns `relay_blind_wallet_status_replay` without lookup. A newly signed higher sequence is a new read-only status authorization; it cannot dispatch, create/refund budget, or mutate profile trust. This route-specific monotonic authority replaces per-poll `metadata_only` rows and is the required SPEC-040 amendment. Inference and ordinary metadata replay tables and ceilings remain untouched.

The status-authority store has 4,096 rows/2 MiB per wallet session and 16,384 rows/8 MiB per account; each row is at most 512 bytes and remains through reservation terminal plus 8 days. Normal wallet reservation admission checks these ceilings before returning a reservation; at cap it rejects the new reservation before client encryption, so every previously returned reservation retains status capacity. Polling updates an existing row in place and therefore cannot exhaust rows/bytes. Pruning never removes nonterminal or within-horizon rows. Startup requires the status-authority caps to be at least the inherited maximum live wallet reservations and their row-size product; impossible configurations reject wallet private mode.

Supported clients durably advance their journal's `next_status_sequence` before each poll, use 1, 2, 4, 8, 15, then 30-second intervals with at most one outstanding poll per transaction, and stop at session expiry/revocation. A crash or rollback may repeat a lower sequence; the client advances and may retry status with a new signed sequence, never inference. Sequence overflow makes status client-unavailable while gateway background recovery continues. A stale/revoked wallet session receives the exact wallet-auth error and the row remains background-reconciled/held; recovery does not mint or extend wallet authority.

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

Before the coordinator dispatch call, one gateway transaction moves the join to `dispatch_intent`, sets the account quota settlement hold, and, for wallet traffic, arms the wallet-session dispatch. Failure rolls back all three. Every internal dispatch and v2-status call carries a fresh CSPRNG 32-byte canonical base64url `X-MacProvider-Coordinator-Challenge`. The gateway accepts a response for economic mutation only after verifying the C6A proof against the exact request, account/session, response, challenge, and configured coordinator evidence key. Only a verified exact terminal `rejected` response with `dispatch_proven_absent: true` permits the gateway to atomically refund account quota and wallet-session reservation exactly once. Store/network absence, unsigned/untrusted/stale/mixed-up evidence, profile staleness alone, or `reserved`/`consumed_predispatch`/`dispatch_authorizing` never permits refund.

#### C6A. Coordinator economic-evidence authority

An internal v2-status success or predispatch dispatch rejection uses the closed outer object `version, result, coordinator_evidence`, where outer `version` is `relay-blind-coordinator-control-response-v1`. It does not wrap or sign a successful or possibly-dispatched streaming/nonstream inference body; those outcomes can never authorize a refund. `result` is either the exact C7 status object or the exact closed rejection object `version, code, state, envelope_binding, dispatch_proven_absent, retry_action`, with version `relay-blind-predispatch-rejection-v1`. The non-null `coordinator_evidence` object has exactly:

```text
version, evidence_kid, issued_at_unix_ms, expires_at_unix_ms,
operation, challenge, account_id, wallet_session_id, request_id,
provider_binding_digest, envelope_digest, response_digest, signature
```

`version` is `relay-blind-coordinator-evidence-v1`; `operation` is `dispatch_rejection` or `status`; `challenge` is the exact gateway nonce; `account_id` and `request_id` are the exact trusted internal identities. `wallet_session_id` is the exact session ID for wallet traffic and the literal empty string for API-key traffic. `provider_binding_digest` uses C1. `envelope_digest` is the canonical digest for bound rows and the literal empty string for an unbound row. `evidence_kid` is the first 16 bytes of SHA-256 of the evidence public key, canonical base64url. Evidence validity is positive and at most 30 seconds; issuance may be at most 5 seconds in the future.

`statusframe(result)` uses the listed C7 field order, `u16str` for strings, one byte for each boolean, and for each nullable token a one-byte presence tag followed by `uint64` when present. `rejectionframe(result)` uses its listed field order, `u16str` for strings, and one byte for `dispatch_proven_absent`. `response_digest` is exactly:

```text
base64url_unpadded(SHA256(
  ASCII("macprovider/relay-blind/coordinator-control-result/v1\x00") ||
  u16str(operation) ||
  (operation == "status" ? statusframe(result) : rejectionframe(result))
))
```

The Ed25519 signed bytes are exactly:

```text
ASCII("macprovider/relay-blind/coordinator-evidence/v1\x00") ||
u16str(version) || u16str(evidence_kid) ||
uint64(issued_at_unix_ms) || uint64(expires_at_unix_ms) ||
u16str(operation) || decoded_32(challenge) ||
u16str(account_id) || u16str_allow_empty(wallet_session_id) ||
u16str(request_id) || decoded_32(provider_binding_digest) ||
one_byte(envelope_digest == "" ? 0 : 1) ||
(envelope_digest == "" ? empty : decoded_32(envelope_digest)) ||
decoded_32(response_digest)
```

The gateway recomputes every byte, requires outer/result/evidence closed schemas, challenge equality to the one live call, operation/route equality, account/session/request/locator equality to its recovery join, evidence time validity, response digest equality, and a trusted non-revoked evidence key. A challenge is single-attempt in memory and never accepted for another response. A crash before economic commit discards it and recovery issues a new call/challenge. Verified proof bytes or their digest are stored atomically with the settlement/refund transition for audit/idempotency; proof replay cannot authorize a second transition.

The coordinator evidence keyring is independent of bundle/provider/wallet/payout keys, has at most four public keys with explicit activation/retirement intervals, and is pinned in gateway configuration. Rotation requires overlap and capability preflight; unknown/revoked/out-of-window keys make private recovery unavailable/held. The coordinator private key is an operator secret outside repositories and worktrees. Local fixtures use isolated keys and do not qualify production signing.

Production private mode also requires an `https` coordinator URL, verified hostname/service identity, trusted CA chain, redirects disabled, and no TLS-skip option. Plain HTTP is accepted only when the parsed host is loopback (`127.0.0.0/8`, `::1`, or exact `localhost` resolved and dialed as loopback) and an explicit test/development flag is set; it can never enable production qualification. TLS or signer outage leaves economic state held. The signature prevents a validly TLS-terminated but misrouted service from authorizing a refund.

Profile, pin, signer, bundle, operator-map, key, model, and session invalidation applies this table:

| Coordinator state at invalidation | Coordinator result | Gateway result |
|---|---|---|
| `selection_pending`, `reserved` | terminal `rejected`, no dispatch | no quota should exist; if a joined anomaly exists, reconcile and refund only on C6A-verified rejection |
| `consumed_predispatch`, `dispatch_authorizing` | terminal `rejected`, `dispatch_proven_absent: true` | discover join, atomically refund active/held account and wallet quota once |
| `dispatched` | unchanged or later `unknown_postdispatch` | retain hold/reconcile known usage; never refund solely for invalidation |
| `terminal`, `unknown_postdispatch`, `rejected` | immutable terminal fence | idempotently settle/refund according to the recorded terminal class |

Recovery scans all nonterminal relay-blind joins, including `quota_active` and `dispatch_intent`, oldest first by `(next_attempt_at,created_at,row_id)`; it is not limited to existing settlement-hold rows. Duplicate workers claim a bounded batch by compare-and-swap, release SQLite, perform network calls, then apply verified C6A evidence in bounded transactions. A failed/timed-out row receives a bounded next-attempt time and cannot block later rows; the oldest-first cursor wraps only after the claimed batch is accounted for.

The default and maximum convergence contract is: at most 1,000 nonterminal joins; batch exactly 100 for the bound; 20 concurrent coordinator calls; 2-second deadline per call including DNS/connect/TLS/body; at most five waves and therefore 10 seconds network time; at most 2 seconds to acquire the result transaction and 1 second inside it; 2 seconds scheduler/serialization margin; total pass work deadline 15 seconds; and next pass begins within 15 seconds after the previous pass completes. Cancellation at the 15-second deadline releases/ages claims for the next pass. With no new arrivals, ten passes visit 1,000 rows in at most `10*15 + 9*15 = 285` seconds from first pass start; the stated service bound remains 300 seconds. Startup rejects any configured combination whose conservative `ceil(rows/batch) * pass_work + (passes-1) * interpass_delay` exceeds 300 seconds, whose call concurrency cannot cover the batch within `pass_work`, or whose database/call deadlines exceed the pass deadline. Fake-clock arithmetic alone is insufficient; scheduler tests use real bounded slow and timed-out calls.

Coordinator rejection/status evidence is retained for 691,200 seconds (8 days) after terminal state, exceeding the gateway 604,800-second settlement-journal retention plus bounded convergence/skew margin. Oldest age above 60 seconds alerts; unavailable evidence remains held; after 604,800 seconds it becomes `stale_held`/operator-visible and is never auto-refunded.

Coordinator capability publication includes status version, C6A evidence version/key IDs, and exact evidence-retention seconds. Local enabled configuration with nonpositive/impossible bounds fails that service's startup. Gateway enablement preflight requires a common evidence key and the coordinator retention to be at least gateway journal retention plus the 300-second convergence bound plus maximum clock skew; when the coordinator is unavailable or mismatched, the profile feature remains unavailable and fails closed while ordinary plaintext startup continues.

### C7. Versioned status protocol

Legacy internal status v1 remains exact for legacy rows. Build 2 public and internal recovery uses closed v2 request fields `version`, `provider_binding_digest`, and nullable `envelope_digest`; version is `relay-blind-status-request-v2`. The locator is exactly the C1 base64url SHA-256 of the 43 ASCII bytes in the canonical provider-binding representation, is account/session-scoped, and must itself decode to 32 bytes.

- For `reserved`, stored envelope digest is absent. A null or supplied envelope digest does not authenticate/confirm that digest; response is `envelope_binding: unbound`. A wrong supplied digest is intentionally indistinguishable in this state.
- For `consumed_predispatch`, `dispatch_authorizing`, `dispatched`, `terminal`, or `unknown_postdispatch`, a non-null exact digest is mandatory; null/wrong fails constant-shape.
- For `rejected` before any consume, response is `unbound`; for rejection after consume it requires and reports `bound`.

The exact v2 response is `version, state, envelope_binding, internal_request_id, validated, input_tokens, completion_tokens, effective_privacy_outcome, dispatch_proven_absent, retry_action`. `version` is `relay-blind-status-v2`. `input_tokens` and `completion_tokens` are each explicitly present as JSON `null` until authoritative and otherwise use the C1 safe integer grammar; no other response field is nullable. `dispatch_proven_absent` is true only for a terminal `rejected` row whose state transition excluded every network attempt; it is false for fresh `reserved`, even though no dispatch existed at lookup time, because an already in-flight consume can race the read. Fresh predispatch states return `check_status_do_not_resubmit`; status atomically fences expired predispatch state to rejection before returning `new_reservation_and_envelope`. Postdispatch states return `do_not_resubmit`. Status never dispatches, changes profile trust, reconstructs output, or reveals provider/session/profile pins/raw bindings. Internal responses additionally carry C6A evidence; the gateway verifies then strips it from the public response.

### C8. Client and browser journals

The logical state machine is `reservation_received_unbound -> envelope_built -> send_fenced -> response_started -> terminal`, with terminal classes `completed`, `predispatch_rejected`, `unknown_postdispatch`, `cancelled_postfence`, and `quarantined`. Every transition is monotonic compare-and-swap. `send_fenced` is durably committed and read back before `fetch`/HTTP send. No state after `send_fenced` authorizes another owner to send the old envelope.

Every canonical journal record contains these common fields:

```text
version, transaction_id, origin, account_subject, profile_id,
profile_revision, profile_digest, request_id, request_commitment,
provider_binding_digest, state, owner_epoch, generation,
next_status_sequence,
predecessor_record_digest, created_at_unix_ms, updated_at_unix_ms,
record_digest, record_mac
```

`version` is `relay-blind-client-journal-v1`; `transaction_id` is 16 client-CSPRNG bytes; `owner_epoch` is a fresh 16-byte CSPRNG value for one process/page lifetime; and generation starts at 1 and increments exactly by one. `next_status_sequence` starts at 1 and advances monotonically through the same durable transition protocol before each wallet status poll; API-key records retain value 1. `canonical_request_bytes` is the exact closed outbound inference request framing from SPEC-041 before encryption. `request_commitment` is HMAC-SHA256 with the storage key over `ASCII("macprovider/relay-blind/client-request/v1\x00") || b16(transaction_id) || u32bytes(canonical_request_bytes)`; it is not a raw prompt hash. `predecessor_record_digest` is `genesis` for generation 1 and otherwise the decoded prior digest.

`journalrecordframe` follows the displayed common-field order, excluding the final digest/MAC, with `u16str` for version/origin/state, `b16` for transaction/account/profile/owner, RFC-4122 16 bytes for request ID, `uint64` for revisions/generation/status sequence/times, `b32` for digests/commitment, and the tagged predecessor rule from C3A. It then appends, in order, tagged `envelope_digest`, tagged `terminal_class` (`u16str`), and tagged `terminal_at_unix_ms` (`uint64`) under the state table. `record_digest` is SHA-256 over `ASCII("macprovider/relay-blind/client-journal-record/v1\x00") || journalrecordframe`; `record_mac` is HMAC-SHA256 over the decoded record digest. The storage key is a separate 32-byte random 0600 no-follow file in Go and a nonextractable HMAC `CryptoKey` in the browser. Loss/mismatch quarantines records; it never regenerates authority.

| State | Additional fields and only permitted action after reopen |
|---|---|
| `reservation_received_unbound` | `envelope_digest` absent; locator already required; live owner may build once. Any other/reopened owner may send status with JSON-null envelope only. |
| `envelope_built` | `envelope_digest` required; live owner holds ciphertext/key only in memory and may fence. Reopened owner is status-only. |
| `send_fenced` | `envelope_digest` required; only the same live `owner_epoch` that committed/read back this transition may perform one send. Reopened owner is status-only. |
| `response_started` | `envelope_digest` required; status-only after any interruption. |
| terminal states | `envelope_digest` required except an unconsumed `predispatch_rejected` may omit it; `terminal_class` and `terminal_at_unix_ms` required; no send. |

The first journal write occurs immediately after reservation verification and therefore always persists the C1 `provider_binding_digest`. The envelope build transition persists the exact envelope digest before fencing. Status is possible from every recorded state using the state-specific locator above. A crash before the first durable record has no client locator, but it also precedes envelope/consume/quota/send; the coordinator reservation expires without paid admission. All records from a prior process/page epoch are recovery-only even if the entire valid local store was rolled back. Server status/profile synchronization may disable or advance recovery but never restores send ownership.

The Go root defaults to the canonical macOS Application Support directory and any override must be absolute. It is opened by descriptor-relative traversal: start at `/`; for each existing component use `openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, `fstat` it, and compare `(st_dev,st_ino)` with `fstatat(parent,name,AT_SYMLINK_NOFOLLOW)`. System ancestors must be root/effective-user owned and not group/other writable, except a root-owned sticky directory; the private root and descendants must be effective-user owned mode 0700. New directories use `mkdirat` then descriptor open/fchmod/fsync. All directory descriptors are retained and rechecked before file operations. Unsupported primitives/platforms return `relay_blind_client_storage_unsupported` before profile confirmation or private reservation.

Under the retained private-root descriptor, acquire `private.lock` first with `openat(O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600)`, verify regular file, effective-user owner, exact mode 0600, `st_nlink == 1`, capture `(dev,ino)`, and take an exclusive advisory lock by nonblocking retries for at most 5 seconds. Only then open `requests.jsonl`, `confirmed-profiles.jsonl`, and their key files descriptor-relatively with the same owner/mode/type/link rules. Before load, append, fsync, compaction, and close, `fstat(fd)` must equal a fresh `fstatat(parent,name,AT_SYMLINK_NOFOLLOW)` and the captured device/inode; every retained directory edge is also rechecked. Any replacement/link/type/owner/mode mismatch quarantines private writes.

Append holds the lock through canonical encode, write-all, file fsync, record readback/MAC/chain validation, and directory fsync on first creation. Compaction creates a random same-directory file with `openat(O_CREAT|O_EXCL|O_NOFOLLOW,0600)`, verifies identity/link/owner/mode, writes and fsyncs, checks its pathname identity, `renameat`s over the data file, fsyncs the parent, opens the new pathname, and requires its identity to equal the captured temporary identity before closing the old descriptor. The lock-file identity never changes. A final partial line truncates only to the last authenticated newline under the lock; any interior malformed/schema/MAC/generation/predecessor error quarantines the entire authority. This is the required Go ancestry/identity protocol, not an implementation option.

The Go journal permits 4,096 current transactions, 16 MiB, and 4 KiB per record. Terminal records are retained 691,200 seconds. Compaction may remove only expired terminal records; if still at cap, new reservation/encryption fails with `client_journal_capacity` before network, while independently supplied status/profile revocation remains available.

Malibu uses dedicated IndexedDB stores, not the existing thread/settings `localStorage`, and an exclusive Web Lock named from canonical origin plus transaction ID. One readwrite transaction validates the HMAC, predecessor/head generation, old state, and current owner, writes the transition and head anchor, commits, and is read back before `fetch`. No lease expiry permits takeover. Missing Web Locks/IndexedDB/Web Crypto, transaction abort, quota error, blocked version change, corrupt record, generation conflict, key loss, or failed readback prevents send. Records are at most 2 KiB, 128 transactions, and 262,144 total serialized UTF-8 bytes, with the same 8-day terminal retention. Cleanup and state transition occur in one IndexedDB transaction. Two tabs/double-clicks produce one fence owner and at most one send.

Neither journal stores prompt/messages/tools/response text, ciphertext, ephemeral private key, bearer/wallet key, raw provider/buyer binding, provider ID/session, local path, raw server body, or an unsalted/raw request digest. Browser chat history remains separately plaintext and disclosed. Clearing a journal removes recovery convenience and never authorizes resending old material.

### C9. Capacity, retention, and fail-closed configuration

| Item | Bound / retention |
|---|---|
| Bundle keyring/storage | 8 trusted signer keys; 4,096 bundle revisions and 64 MiB public bundle bytes globally |
| Profiles per account | 32 total active or retained profile IDs |
| Revisions per profile | 64 retained immutable revisions |
| Pins/models per revision | 16 pins; 16 models per pin; one endpoint in Build 2 |
| Invitations | 2,048 rows/4 MiB total/account; at most 128 live; 24-hour maximum validity; 8-day consumed/tombstone retention; consumption updates its row in place |
| Mutation operations | 4,096 rows/4 MiB total/account: normal create/replace partition 3,968 rows/3.75 MiB; revoke-only emergency partition 128 rows/256 KiB; 8-day retention |
| Profile/audit rows | 8,192 rows/8 MiB total/account: normal partition 7,936 rows/7.75 MiB; revoke/recovery-quarantine emergency partition 256 rows/256 KiB; 30-day retention |
| Profile request/list | 64 KiB request; page default 20/max 32; 60 mutations and 120 reads/status per account/minute |
| Profile reservations | 512 live/account, 128 live/profile, within existing global 10,000 cap |
| Pool projection/rounds | at most 16 providers and 3 double-collect rounds |
| Pin/bundle lifetime | pin 30 days; bundle/invitation 24 hours; clock skew 60 seconds |
| Signer/bundle revocation tombstones | 38 days (maximum pin lifetime plus 8-day recovery horizon) |
| Coordinator terminal/status evidence | 8 days from terminal state |
| Gateway recovery joins | 1,024 physical rows: at most 1,000 new/nonterminal admissions plus 24 quarantined/emergency rows; existing rows update in place; 8-day evidence dependency; 7-day stale-held threshold |
| Wallet status authority | One fixed row/reservation; 4,096 rows/2 MiB/session and 16,384 rows/8 MiB/account; 512 bytes/row; terminal plus 8-day retention; polls update in place and cannot consume inference replay authority |
| Confirmed-profile stores | 32 records/account-origin, 96 KiB/record, 4 MiB total; pending/revoke updates in place |
| Client journals | Go 4,096/16 MiB/4 KiB; browser 128/256 KiB/2 KiB; terminal retention 8 days |

Pruning is indexed, bounded per pass, oldest eligible first, and never deletes active profiles, live invitations, nonterminal operations, pre/postdispatch fences, unsealed settlement effects, or evidence still referenced by another table. A bundle revision is eligible only after its own expiry, every referencing profile pin expiry, and each referencing reservation terminal plus 8 days. Revisions are eligible only after every pin expiry and the last bound reservation/economic-recovery horizon. Tombstones prevent profile/invitation/operation ID reuse throughout retention.

Normal create/replace admission checks both its row and byte partition before any mutation; it cannot consume emergency rows/bytes. Revoke atomically updates the existing profile head/revision, uses one revoke-operation row and one emergency audit row, and cannot require a new invitation/profile/recovery row. With at most 32 retained profile IDs and terminal revocation per profile, the 128-operation and 256-audit emergency partitions remain reachable under all accepted states. Repeated identical operation IDs reuse the same row. A different revoke of an already revoked profile returns its existing terminal state without a new row. An invariant breach or actual emergency-partition exhaustion fails closed with `relay_blind_emergency_capacity_exhausted`, leaves the profile disabled locally, alerts, and never exceeds the physical cap or authorizes new work. Recovery and status update existing join/reservation rows; if an impossible missing-row repair would require new authority at its 24-row emergency ceiling, it quarantines without refund.

Every table charges UTF-8 canonical bytes plus a frozen per-row SQLite overhead from Slice 0; startup and boundary tests use that same accounting function. An operation that requires multiple rows reserves all row/byte charges in one transaction or writes none. Enabled startup validates every capacity, status-authority, convergence, and retention inequality and fails closed. Disabled mode preserves plaintext startup and safe replay/status defaults.

## 6. Typed errors and precedence

The wire/local error object is exactly `version, code, http_status, phase, retryable, action, message`. Version is `relay-blind-error-v1`; `message` is bounded public text and never changes semantics. `phase` is exactly `bootstrap`, `profile`, `reservation`, `encryption`, `journal`, `admission`, `dispatch`, `status`, `settlement`, or `unknown`. Actions are exactly `provision_profile`, `confirm_profile`, `replace_profile`, `complete_or_revoke_pending_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, `repair_local_state`, or `none`. Local errors use HTTP status 0. `retryable` means the named action may be attempted; it never authorizes reuse of an envelope. Every inherited auth/wallet/quota/transport failure is normalized at the Build 2 boundary to one row below; raw legacy codes never reach a Build 2 client. This table is the complete Build 2 inventory consumed by coordinator, gateway, Go, and Malibu fixtures:

| Code | Origin | HTTP | Phase | Retryable | Action before `send_fenced` | Action at/after `send_fenced` |
|---|---|---:|---|:---:|---|---|
| `relay_blind_feature_disabled` | gateway/coordinator | 503 | bootstrap | false | `none` | `check_status_do_not_resubmit` |
| `relay_blind_mixed_version` | gateway/coordinator | 409 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_auth_invalid` | gateway | 401 | bootstrap | false | `none` | `do_not_resubmit` |
| `relay_blind_request_invalid` | gateway/coordinator | 400 | unknown | false | `none` | `do_not_resubmit` |
| `relay_blind_profile_rate_limited` | gateway/coordinator | 429 | profile | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_reservation_rate_limited` | gateway/coordinator | 429 | reservation | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_admission_rate_limited` | gateway | 429 | admission | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_status_rate_limited` | gateway/coordinator | 429 | status | true | `check_status_do_not_resubmit` | `check_status_do_not_resubmit` |
| `relay_blind_client_capability_unavailable` | client | 0 | bootstrap | false | `none` | `do_not_resubmit` |
| `relay_blind_profile_required` | gateway/coordinator | 428 | profile | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_profile_malformed` | gateway/coordinator | 400 | profile | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_profile_not_found` | gateway/coordinator | 404 | profile | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_profile_revoked` | gateway/coordinator | 410 | profile | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_profile_stale` | gateway/coordinator | 409 | profile | true | `refresh_profile_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_profile_conflict` | gateway/coordinator | 409 | profile | true | `refresh_profile_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_local_profile_missing` | client | 0 | profile | false | `confirm_profile` | `do_not_resubmit` |
| `relay_blind_local_profile_pending` | client | 0 | profile | true | `complete_or_revoke_pending_profile` | `do_not_resubmit` |
| `relay_blind_local_profile_corrupt` | client | 0 | profile | false | `repair_local_state` | `do_not_resubmit` |
| `relay_blind_local_profile_capacity` | client | 0 | profile | false | `repair_local_state` | `do_not_resubmit` |
| `relay_blind_bundle_untrusted` | client/coordinator | 422 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_signer_untrusted` | client/coordinator | 422 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_pin_untrusted` | client/coordinator | 422 | profile | false | `replace_profile` | `check_status_do_not_resubmit` |
| `relay_blind_invitation_not_found` | gateway/coordinator | 404 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_invitation_expired` | gateway/coordinator | 410 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_invitation_mismatch` | gateway/coordinator | 422 | bootstrap | false | `provision_profile` | `check_status_do_not_resubmit` |
| `relay_blind_operation_replay_conflict` | gateway/coordinator | 409 | profile | false | `refresh_profile_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_profile_capacity` | gateway/coordinator | 429 | profile | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_emergency_capacity_exhausted` | coordinator | 507 | profile | false | `none` | `check_status_do_not_resubmit` |
| `relay_blind_no_approved_provider` | coordinator | 503 | reservation | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_model_unsupported` | coordinator | 422 | reservation | false | `replace_profile` | `check_status_do_not_resubmit` |
| `relay_blind_approved_provider_churn` | coordinator | 503 | reservation | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_pool_generation_exhausted` | coordinator | 503 | reservation | false | `none` | `check_status_do_not_resubmit` |
| `relay_blind_reservation_expired` | coordinator | 410 | reservation | false | `new_reservation_and_envelope` | `check_status_do_not_resubmit` |
| `relay_blind_binding_mismatch` | coordinator | 404 | status | false | `none` | `do_not_resubmit` |
| `relay_blind_envelope_mismatch` | coordinator | 409 | dispatch | false | `new_reservation_and_envelope` | `check_status_do_not_resubmit` |
| `relay_blind_envelope_replay` | gateway/coordinator | 409 | dispatch | false | `none` | `check_status_do_not_resubmit` |
| `relay_blind_quota_unavailable` | gateway | 429 | admission | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_wallet_session_invalid` | gateway | 401 | admission | false | `none` | `do_not_resubmit` |
| `relay_blind_wallet_status_replay` | gateway | 409 | status | true | `check_status_do_not_resubmit` | `check_status_do_not_resubmit` |
| `relay_blind_coordinator_evidence_untrusted` | gateway | 503 | settlement | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_recovery_unavailable` | gateway/coordinator | 503 | status | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_recovery_stale_held` | gateway | 409 | status | false | `none` | `do_not_resubmit` |
| `relay_blind_recovery_quarantined` | gateway | 409 | status | false | `none` | `do_not_resubmit` |
| `relay_blind_client_storage_unsupported` | client | 0 | journal | false | `none` | `do_not_resubmit` |
| `relay_blind_client_journal_unavailable` | client | 0 | journal | true | `repair_local_state` | `do_not_resubmit` |
| `relay_blind_client_journal_capacity` | client | 0 | journal | false | `repair_local_state` | `do_not_resubmit` |
| `relay_blind_client_journal_corrupt` | client | 0 | journal | false | `repair_local_state` | `do_not_resubmit` |
| `relay_blind_client_journal_conflict` | client | 0 | journal | false | `check_status_do_not_resubmit` | `check_status_do_not_resubmit` |
| `relay_blind_request_cancelled` | client/gateway | 499 | dispatch | false | `new_reservation_and_envelope` | `check_status_do_not_resubmit` |
| `relay_blind_response_lost` | client/gateway | 502 | dispatch | false | `none` | `do_not_resubmit` |
| `relay_blind_unknown` | any | 500 | unknown | false | `none` | `do_not_resubmit` |

Server origin always uses the listed status. A client receiving a missing/unknown code, wrong schema, status/code mismatch, or unknown phase/action maps it to `relay_blind_unknown`; before fence it sends nothing, and at/after fence it never resubmits. `relay_blind_request_cancelled` before fence permits only a wholly new transaction; after fence it requires status. `relay_blind_envelope_mismatch` before fence applies only to a coordinator-proven unconsumed rejection; otherwise post-fence rules control.

Precedence is fixed: authenticated durable terminal/replay state; local `send_fenced` or later state; C6A evidence validity; binding/envelope/profile lifecycle; quota/capacity/rate; transport error. A lower-precedence error cannot replace a higher one. Durable postdispatch or replay state always yields `do_not_resubmit`/status even when the current profile/provider is unavailable. Clients never infer retry safety from HTTP status or `retryable` alone; they execute only the exact action after applying local state precedence.

## 7. Implementation slices

1. **Governance and vectors:** update SPEC-041, SPEC-006, SPEC-040, AUTHORITY, CONFORMANCE, and shared fixtures with C1-C9/C3A/C6A, exact nullability, local-record schemas, complete errors, evidence/framing vectors, mixed-version rules, and non-claims.
2. **Coordinator authority:** additive/rebuild migration, bundle keyring/config, invitation/profile/operation/audit tables, operator intersection, pool epoch/generation snapshots, double-collect reservation/consume/dispatch, invalidation, status v2, metrics, purge.
3. **Gateway:** authenticated invitation/profile/status proxy, header stripping, wallet route profiles and separate monotonic status authority, C6A evidence verification, atomic quota/session/recovery join, bounded oldest-first reconciliation, bounds/metrics.
4. **Go library/CLI:** exported `pkg/relayblindbuyer`, signed-bundle verification, durable confirmed-profile authority, complete typed errors, exact journal state machine/descriptor protocol, commands for invitation/profile/request/status. Reference CLI becomes a thin adapter.
5. **Two-provider integration:** A-only/B-only/A+B, lifecycle, concurrency, recovery, streaming/nonstreaming, exact settlement.
6. **Malibu dependent repository:** isolated worktree; signed bundle/profile UI, Web Crypto module, IndexedDB/Web Locks journal, no-retry private transport, truthful docs/copy, Node and browser tests.
7. **Physical MLX evidence:** opt-in isolated journey using an already supported cached artifact. Record only safe model/artifact/runtime/hardware context.

Each slice is reviewable and default-off. Material changes to framing, authority, state machines, lock protocol, economic recovery, browser durability, or acceptance strategy reopen the plan gate.

## 8. Migration, compatibility, and rollback

Coordinator migration creates bundle/invitation/profile/revision/operation/audit tables, rebuilds the reservation table transactionally to add `selection_pending` and `dispatch_authorizing` CHECK states plus nullable Build 2 columns, copies all legacy rows byte-for-byte, verifies counts/indexes/foreign keys, and stamps one schema version. Crash/reopen and double migration are mandatory. Legacy terminal/status v1 rows remain readable. With profile-required mode enabled, legacy unbound predispatch rows are terminally rejected; postdispatch rows remain irreversible.

Gateway migration adds the recovery join, separate wallet-status authority, verified-evidence fields, and required quota/session foreign-key/index relationships in one versioned transaction. Existing relay-blind quota rows are conservatively imported as postdispatch-unknown/held when dispatch absence cannot be proven. No migration refunds. Wallet and API-key rows preserve accounting identity.

Mixed-version behavior is fail closed: old gateway cannot request profile mode; new gateway detects old coordinator capability before accepting a profile reservation; old clients receive typed migration action; v1 envelope and six-field reservation body remain valid only on the legacy default-off pilot path. A profile-bound request never downgrades to legacy selection or plaintext.

Rollback disables new profile reservations first, drains/rejects `selection_pending`/`dispatch_authorizing`, keeps v2 status and gateway reconciliation running, then rolls binaries. Schema/tombstones are not dropped. An old binary may start only after a compatibility checker proves no state/value it cannot preserve. Disabling bundle issuance or profile mutation does not delete active recovery evidence.

## 9. Observability and operations

Bounded metrics include invitation/profile create/replace/revoke and local-confirmation outcomes, selected-approved/no-candidate/churn outcomes, double-collect retries, pool generation changes, invalidations by state/reason, recovery join state/oldest age/pass duration/refund/hold/quarantine, coordinator-evidence verification reason, status envelope-binding/replay-partition class, wallet signature failures, journal/descriptor failures, and client recovery actions. Labels use fixed enums and never account/profile/provider/request IDs, fingerprints, model strings, ciphertext digests, prompts, or raw errors.

Sanitized audit records store account-scoped opaque correlation, operation/profile revision/digest, bundle/invitation digest, event/result/reason enums, and timestamps. They exclude provider/session IDs, raw pins/bindings, credentials, prompts, ciphertext, and output. Alerts fire on recovery oldest age over 60 seconds, churn exhaustion, signer/bundle invalidation, pool generation exhaustion, capacity, migration mismatch, stale-held rows, and audit/journal write failures.

Operator runbooks cover bundle signer custody/rotation/revocation, bundle publication, invitation issuance, profile emergency revocation, recovery backlog, stale-held manual handling, feature rollback, and client keyring compatibility. They never place private material in repositories or worktrees.

## 10. Acceptance criteria and roadmap mapping

| Roadmap outcome | Implementation proof |
|---|---|
| Authenticated pin provisioning/replacement/revocation | Signed release-trusted bundle + account invitation vectors; durable account/origin-bound local confirmation across restart; atomic pending mutation, profile CAS/tombstones/invalidation. |
| A-only when B sorts first | Two-provider service test proving only A reservation/frames and exact linearization token. |
| A+B/no candidate/rotation/revocation/expiry/concurrency | Selection and lifecycle matrix with pool generation barriers and race detector. |
| Selection before encryption | Client instrumentation proves no ephemeral key/nonce/envelope before approved reservation/key verification. |
| Never fail over ciphertext | Envelope-hash send/frame instrumentation across all faults; at most one public send and one exact provider/session. |
| Supported client/library and typed recovery | External Go import test, black-box CLI, complete frozen error table, exact journal/ancestry state machine and crash cuts. |
| Wallet status/recovery | Exact SPEC-040 route/body/header/request-ID signature and dedicated replay-partition/exhaustion tests. |
| Malibu product | Real-browser signed-bundle/profile, stream/nonstream, two-tab, reload/storage failure, truthful copy and no ordinary retry. |
| Quota/refund safety | API-key and wallet cross-store crash matrix proves C6A-signed rejection-only exactly-once refund and postdispatch holds/settlement. |
| Actual MLX | One encrypted request and one stream/cancel through real `ModelRuntime`, with safe context recorded. |
| Truth and economics | Provider plaintext and relay-visible-response copy; ordinary settlement exact; no verified-model/reward promotion. |

## 11. Hardware, compatibility, rollback blockers, and non-goals

Planning and deterministic integration require no 64 GB machine. Actual MLX acceptance requires Apple Silicon, compatible macOS/Swift/MLX, sufficient RAM/disk for one already-supported cached catalog artifact, and isolated services. Absence is a named hardware/artifact blocker, never a passed criterion. Browser acceptance requires real supported Safari and Chromium runs.

Non-goals: provider-hidden plaintext; response encryption; confidential compute/anonymity claims; pool-private requests; verified private settlement; SPEC-022 positive receipts/rewards; payout/reward activation; arbitrary endpoints; agent/tool mode in Malibu; automatic model download; deployment/release/production enforcement; signer key creation in a worktree; epoch/payment implementation; Build 4 Trusted Pools.

## 12. Verification and handoff gates

Run targeted contract/storage/selection/recovery/client/browser tests first, then full coordinator/gateway/integration/Swift/Malibu checks from `test-spec-r3.md`. Review each complete repository diff through independent GPT-5.6 Sol code, security, architecture, and applicable browser/product lanes. Critical, High, and Medium findings must all be zero before a slice is complete.

The handoff separately records implementation/PR references, fixture evidence, browser evidence, actual MLX evidence, deployed/production status, hardware/operator/signing blockers, skipped/timed-out/zero-selected runs, and per-repository cumulative versus dependent diffs. It confirms the provider-plaintext boundary, response relay visibility, no ciphertext failover, and verified-model/reward exclusions.
