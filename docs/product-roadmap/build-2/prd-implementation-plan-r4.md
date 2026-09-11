# Product Build 2 PRD and implementation plan

**Plan revision:** R4
**Status:** draft; implementation is prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for these exact bytes and the paired R4 test specification
**Paired test specification:** `test-spec-r4.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu buyer-app base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)
**Predecessor:** `prd-implementation-plan-r3.md`
**Failed predecessor review:** `reviews/plan-r3-sol.md`

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

Every Build 2 wire and local object is closed, rejects duplicate keys before object construction, rejects unknown fields and trailing bytes, and uses the exact presence rules below. A field marked required must be present. A field marked conditional must be present only in the named states. JSON `null` is valid only in the cells that explicitly say `null`; omission and `null` are never interchangeable.

| Object | Exact presence and nullability |
|---|---|
| Bundle, pin, invitation, account-identity response, profile document, profile create/replace/revoke request | Every declared field required and non-null. |
| Profile list response | `version` and `profiles` required/non-null; `next_cursor` required and either a canonical cursor string or JSON `null`. |
| Reservation request/response, coordinator-control outer/result, and coordinator-evidence proof | Every declared field required and non-null. Evidence uses the exact empty-string sentinel only where C6A says so; JSON `null` is invalid except the nested C7 status result's token fields. |
| v2 status request | All three fields required; `envelope_digest` is canonical base64url or JSON `null`. |
| Revocation-preflight request/response | Every displayed C3B field required/non-null; arrays may be empty only where C3B permits. |
| Compaction pointer/manifest/checkpoint/head entries | Every displayed C8B field required/non-null; genesis uses only the named all-zero sentinels. |
| v2 status response | Every field required; `input_tokens` and `completion_tokens` are independently a safe nonnegative integer or JSON `null`. All other fields are non-null. |
| Confirmed-profile record | Every common field required/non-null. `pending_mutation` is required and either JSON `null` or the closed pending object in C3A. No other null is accepted. |
| Client journal record | Every common field required/non-null. `envelope_digest` is omitted only in `reservation_received_unbound` and an unconsumed terminal `predispatch_rejected`; it is required/non-null in every other state. `terminal_class` and `terminal_at_unix_ms` are omitted in nonterminal states and required/non-null in terminal states. No journal field accepts JSON `null`. |
| Server wire error | Every field required/non-null. `http_status` is the origin-specific server status and is never `0`. The object has no client action field. |
| Client effective error | Every field required/non-null. `http_status` is `0` for a locally originated error and the verified server status otherwise; `action` is derived locally from the journal fence and is never accepted from a server. |

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

### C3A. Durable locally confirmed profile authority and revocation freshness

The coordinator adds account-key-only `GET /v1/account/identity`, returning exactly `version: relay-blind-account-identity-v1` and a stable opaque 16-byte canonical base64url `account_subject`. It is scoped to the authenticated account, contains no email or credential material, and cannot create local profile trust. A client may use a server profile only when `(origin, account_subject, profile_id, revision, profile_digest, state)` exactly matches a valid local confirmed-profile record and the C3B revocation preflight is fresh.

The canonical confirmed-profile record has exactly these common fields:

```text
version, origin, account_subject, profile_id, revision, profile_digest,
bundle_id, bundle_revision, bundle_digest, invitation_id, signer_kid,
signed_bundle, selected_fingerprints, selected_pinframe_digests,
earliest_pin_expiry_unix, confirmation_generation,
predecessor_record_digest, confirmed_at_unix_ms, state,
last_revocation_generation, last_revocation_root_digest,
pending_mutation, record_digest, record_mac
```

`version` is `relay-blind-confirmed-profile-v2`; `origin` is the canonical HTTPS origin with no path/query/fragment; IDs, digests, signer, bundle bytes, selected fingerprints, and pinframe digests must recompute exactly under C1-C3. `signed_bundle` is canonical base64url of the exact verified public bundle JSON bytes and contains no private material. Selection order equals bundle order. `state` is `active`, `mutation_pending`, or `revoked`. `confirmation_generation` starts at 1 and increments by one. The genesis predecessor is the literal `genesis`; later predecessors are the prior record digest. `last_revocation_generation` is zero only before the first successful C3B preflight, with a 32-byte all-zero root sentinel; it never decreases and a repeated generation must carry the same root.

`confirmedprofileframe` follows the displayed common-field order, excluding the final digest/MAC, with `u16str` for version/origin/signer/state, `b16` for account/profile/bundle/invitation IDs, `uint64` for revisions/times/generations, `b32` for digests/fingerprints/pinframe digests, `u32bytes(decoded signed_bundle)` for bundle bytes, and counted arrays. Predecessor is tagged `0x00` for genesis or `0x01||b32`. Pending is tagged `0x00` for null or `0x01||pendingframe`. `record_digest` is SHA-256 over `ASCII("macprovider/relay-blind/confirmed-profile-record/v2\x00") || confirmedprofileframe`; `record_mac` is HMAC-SHA256 over the decoded record digest. Shared fixtures freeze every byte and transition before runtime implementation.

`pending_mutation` is JSON `null` for stable active/revoked records. For `mutation_pending`, it is one closed, MAC-covered object containing exactly:

```text
operation, operation_id, request_disposition,
expected_state, expected_revision, expected_profile_digest,
target_state, target_revision, target_profile_digest,
target_bundle_id, target_bundle_revision, target_bundle_digest,
target_invitation_id,
target_signer_kid, target_signed_bundle,
target_selected_fingerprints, target_selected_pinframe_digests,
target_earliest_pin_expiry_unix, target_public_authority_digest,
target_revocation_generation, target_revocation_root_digest,
started_at_unix_ms
```

`request_disposition` is `not_sent` or `sent_or_unknown`. In a pending record, every common authority field equals the expected stable predecessor, `expected_state` equals its state, and the expected revision/digest equal its public tuple; cancel reconstructs only from these MAC-covered expected fields. `target_public_authority_digest = SHA256(ASCII("macprovider/relay-blind/trust-profile-authority/v1\x00") || profile_digest_input_bytes_from_C3 || u16str(target_state))`; it covers profile/bundle/invitation/pins and excludes server-assigned timestamps, so it is knowable before mutation. The pending frame follows the displayed order and uses the same fixed-width/string/array rules as the common record. Replace embeds the complete independently verified next bundle and selected pins. Revoke embeds the complete current evidence, `target_state: revoked`, and unchanged revision/profile digest. Before the DELETE call its target revocation generation/root use the defined zero sentinels because the tombstone does not yet exist. After server success, the client obtains signed C3B evidence, appends a new still-pending generation with the actual nonzero generation/root, and only then may commit stable revoked state. Replace embeds the latest already verified C3B generation/root. Thus active and revoked targets cannot collide even though the immutable profile digest excludes state.

Before any mutation request, the client appends and reads back the complete pending record. It may cancel and append the prior stable authority only while `request_disposition: not_sent`; immediately before the HTTP call it durably changes the disposition to `sent_or_unknown`. After that transition, cancellation, response loss, or restart can only reconcile. A successful authenticated server response is compared to every authority-bearing target field and its exact `target_public_authority_digest`; server timestamps must be well formed and monotonic but are not local trust input; no bundle, pin, signer, expiry, or target-state byte is copied from GET. On restart the client reconstructs the candidate solely from the locally persisted target, reverifies its signature/digests/pins, runs C3B, and commits stable state only when the authenticated server document and fresh revocation result exactly match. Conflict/unavailability/mismatch remains disabled and retains the pending record. Revoke convergence requires both server `state: revoked` and a signed C3B tombstone result. Safe disposal is an authenticated append of the stable successor; the pending predecessor remains until compaction checkpointing under C8. A failed local commit after server success sacrifices availability, never trust.

The Go library and browser each use the single authority lock/transaction rules in C8. The Go confirmed-profile and journal authorities have distinct HMAC keys but one `private.lock`; there is no second advisory lock. The browser uses distinct nonextractable keys and stores but one account/origin-scoped Web Lock per mutation. Both use append/generation/predecessor validation, atomic compare-and-swap, exact readback, and C8 versioned compaction. The threat claim is fail-closed detection of corruption, partial rollback, record substitution, and server-visible revision/revocation rollback. A coherent rollback of all same-user local files and OS credentials is outside the claim; restored request records are still recovery-only because owner epochs never persist as current authority.

The store permits 32 current profiles per `(origin,account_subject)` and one complete pending object per profile at 192 KiB/record. Normal confirmation/replacement content stops at 8 MiB. In addition, each active profile reserves 768 KiB of logical active-generation headroom for four worst-case revoke records: pending-not-sent, pending-sent-or-unknown, pending-with-signed-tombstone, and stable-revoked; this reserve cannot be consumed by confirmation, replacement, revocation-preflight watermark updates, or compaction metadata. The active generation therefore has a hard 40 MiB ceiling and an 88 MiB physical old+new/checkpoint reserve. Stable current and pending records cannot be pruned. A revoked record is retained at least 8 days and until the server no longer exposes/references it. Admission reserves worst-case pending, watermark, compaction/checkpoint, and per-active-profile revoke bytes before create/replace. At normal capacity, every active profile can still append the four bounded revoke records; new confirmation/replacement stops before server mutation. Coordinator revoke uses its preallocated C9 slots. Corruption, missing HMAC key, account/origin mismatch, generation/chain/checkpoint error, rollback relative to the server or C3B watermark, or pin mismatch disables private mode and never reconstructs trust from GET.

Ordinary invitation, bundle, or signer validity-window expiry after activation does not erase a locally confirmed record; earliest selected-pin expiry and explicit signer/bundle/profile/pin revocation do disable it. Every new private transaction requires a successful C3B preflight; cached or offline state is displayed as stale and cannot authorize a reservation. Replacement requires new locally verified activation evidence. Clearing either local authority disables all affected private profiles; it does not revoke the server profile or authorize ciphertext reuse.

### C3B. Authenticated revocation synchronization

The client sends account-key-only `POST /v1/relay-blind/revocation-preflight` with exactly `version, challenge, profile_id, revision, profile_digest, state, signer_kid, bundle_id, bundle_revision, bundle_digest, selected_fingerprints, prior_generation, prior_root_digest`; request version is `relay-blind-revocation-preflight-request-v1` and `challenge` is 32 client-CSPRNG bytes. The response contains exactly `version, challenge, profile_id, revision, profile_digest, state, signer_kid, bundle_id, bundle_revision, bundle_digest, selected_fingerprints, prior_generation, prior_root_digest, revocation_generation, revocation_root_digest, profile_revoked, signer_revoked, bundle_revoked, revoked_fingerprints, issued_at_unix, expires_at_unix, evidence_kid, signature`; response version is `relay-blind-revocation-preflight-v1`. Booleans and the sorted unique fingerprint subset report authoritative state in one SQLite read transaction. The root commits the ordered append-only tombstone log and generation; generation starts at 1, advances once per committed tombstone, never wraps, and one generation has one root.

The revocation log record is exactly `version, generation, operation_id, kind, target_digest, created_at_unix, predecessor_root_digest, entry_digest`. Version is `relay-blind-revocation-tombstone-v1`; kind is `signer`, `bundle`, `profile`, or `pin`; operation ID is 16 bytes; and target digest is SHA-256 of the kind-specific canonical signer KID, bundle ID/revision/digest, account/profile ID/revision, or pin fingerprint frame. `entry_digest = SHA256(ASCII("macprovider/relay-blind/revocation-entry/v1\x00") || uint64(generation) || b16(operation_id) || u16str(kind) || b32(target_digest) || uint64(created_at_unix) || b32(predecessor_root_digest))`. The committed root is `SHA256(ASCII("macprovider/relay-blind/revocation-root/v1\x00") || uint64(generation) || b32(predecessor_root_digest) || b32(entry_digest))`; generation 1 uses an all-zero predecessor root. Commit of tombstone row and new generation/root is one SQLite transaction.

`revocationrequestframe` follows request field order with `u16str` for version/state, `b32` challenge, profile/bundle/root digests and fingerprints, `b16` profile/bundle IDs and signer KID, `uint64` revisions/generation, and counted fingerprint arrays. `revocationresponseframe` follows response order except signature with the same types, one byte per boolean, `b16(evidence_kid)`, and `uint64` times. `evidence_kid` is the first 16 bytes of SHA-256 of the revocation-evidence public key. Signed bytes are `ASCII("macprovider/relay-blind/revocation-preflight/v1\x00") || b16(account_subject) || revocationrequestframe || revocationresponseframe`; signature is canonical base64url Ed25519. Shared fixtures freeze exact bytes. A dedicated online revocation-evidence keyring of at most four release-baked public keys is separate from bundle/provider/wallet/payout/C6A keys. Production private keys remain operator secrets. Evidence validity is positive and at most 30 seconds, issuance may be at most 5 seconds in the future, and the client starts reservation within 15 seconds of issuance. The route is `Cache-Control: no-store`, rejects redirects, and production requires verified HTTPS. Unknown/revoked/out-of-window key, bad signature/binding, lower generation, same-generation different root, clock failure outside allowed skew, timeout, or HTTP/TLS failure disables new private transactions. Higher generations are appended to the confirmed-profile authority before reservation. A revocation committed after preflight is still caught by C5 lifecycle revalidation; preflight is a client trust/UX freshness guard, not the coordinator admission authority.

### C4. Reservation reference and wallet signing

The existing six-field reservation body and v1 envelope remain unchanged for legacy mode. When any Build 2 trust-profile header is present, the gateway requires all three headers and requires the envelope `request_id` to be canonical lowercase RFC 4122 UUIDv4 text; supported clients generate that value before journaling. Headerless legacy v1 continues accepting the pinned 1..128 printable-ASCII request ID and never enters the Build 2 client-journal path. Supported mode also requires exactly one canonical value for:

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

The reconciler freezes a scan epoch as `(epoch_id, cutoff_created_at, cutoff_row_id)` over all eligible nonterminal rows present at epoch start, ordered by `(created_at,row_id)`. Rows inserted after the cutoff belong to the next epoch. Within an epoch, `first_attempt_epoch < epoch_id` rows always sort ahead of retry rows; one claim transaction selects up to 100 distinct never-visited rows and durably marks the epoch/claim. A failed row cannot become retry-eligible until every row at the epoch cutoff has either started one call or reached a durable terminal state. This forbids retry churn and new arrivals from overtaking untouched rows.

One pass has exactly one claim transaction with total wait at most two seconds and work at most one second, at most five two-second network waves through exactly 20 workers, and exactly one aggregate result transaction for the whole batch with total wait at most two seconds and work at most one second. No per-result transaction is permitted. A cancelled worker records an explicit retryable outcome in that aggregate transaction; if the aggregate transaction fails, the claim expires after 20 seconds and the identical batch remains ahead of later work. With an available store/endpoint, each required transaction succeeds within its stated budget; persistent store or endpoint outage is an availability blocker and is never counted as convergence. Claim plus network plus aggregate persistence totals 16 seconds; two seconds of scheduler/serialization margin makes pass work at most 18 seconds. Pass-completion to next start is at most 10 seconds.

For 1,000 rows, ten 100-row passes are required. The last row's first call begins no later than `9 * (18 pass + 10 interpass) + 3 claim = 255 seconds`; aggregate persistence is not on the first-call critical path, while total per-pass work still includes its three-second budget. Startup evaluates this formula plus the 18-second pass inequality from configured row/batch/concurrency/call/claim/result/interpass values and rejects enabled recovery if either fails. Alert at 60 seconds. Tests also measure total aggregate persistence, retry ordering, continuously arriving rows, and cancellation rather than inferring them from worker count.

Coordinator rejection/status evidence is retained for 691,200 seconds (8 days) after terminal state, exceeding the gateway 604,800-second settlement-journal retention plus bounded convergence/skew margin. Oldest age above 60 seconds alerts; unavailable evidence remains held; after 604,800 seconds it becomes `stale_held`/operator-visible and is never auto-refunded.

Coordinator capability publication includes status version, C6A evidence version/key IDs, and exact evidence-retention seconds. Local enabled configuration with nonpositive/impossible bounds fails that service's startup. Gateway enablement preflight requires a common evidence key and the coordinator retention to be at least gateway journal retention plus the 300-second convergence bound plus maximum clock skew; when the coordinator is unavailable or mismatched, the profile feature remains unavailable and fails closed while ordinary plaintext startup continues.

### C7. Versioned status protocol

Legacy internal status v1 remains exact for legacy rows. Build 2 public and internal recovery uses closed v2 request fields `version`, `provider_binding_digest`, and nullable `envelope_digest`; version is `relay-blind-status-request-v2`. The locator is exactly the C1 base64url SHA-256 of the 43 ASCII bytes in the canonical provider-binding representation, is account/session-scoped, and must itself decode to 32 bytes.

- For `reserved`, stored envelope digest is absent. A null or supplied envelope digest does not authenticate/confirm that digest; response is `envelope_binding: unbound`. A wrong supplied digest is intentionally indistinguishable in this state.
- For `consumed_predispatch`, `dispatch_authorizing`, `dispatched`, `terminal`, or `unknown_postdispatch`, a non-null exact digest is mandatory; null/wrong fails constant-shape.
- For `rejected` before any consume, response is `unbound`; for rejection after consume it requires and reports `bound`.

The exact v2 response is `version, state, envelope_binding, internal_request_id, validated, input_tokens, completion_tokens, effective_privacy_outcome, dispatch_proven_absent, retry_action`. `version` is `relay-blind-status-v2`. `input_tokens` and `completion_tokens` are each explicitly present as JSON `null` until authoritative and otherwise use the C1 safe integer grammar; no other response field is nullable. `dispatch_proven_absent` is true only for a terminal `rejected` row whose state transition excluded every network attempt; it is false for fresh `reserved`, even though no dispatch existed at lookup time, because an already in-flight consume can race the read. Fresh predispatch states return `check_status_do_not_resubmit`; status atomically fences expired predispatch state to rejection before returning `new_reservation_and_envelope`. Postdispatch states return `do_not_resubmit`. Status never dispatches, changes profile trust, reconstructs output, or reveals provider/session/profile pins/raw bindings. Internal responses additionally carry C6A evidence; the gateway verifies then strips it from the public response.

### C8. Client/browser journals, lock ownership, and rooted compaction

The request journal's logical state machine remains `reservation_received_unbound -> envelope_built -> send_fenced -> response_started -> terminal`, plus terminal `predispatch_rejected`, `cancelled`, `response_lost`, and `unknown`. Its common record fields are:

```text
version, origin, transaction_id, account_subject, wallet_session_digest,
profile_id, profile_revision, profile_digest, request_id, request_commitment,
provider_binding_digest, state, owner_epoch, next_status_sequence,
generation, predecessor_record_digest, created_at_unix_ms, updated_at_unix_ms,
[envelope_digest], [terminal_class], [terminal_at_unix_ms], record_digest, record_mac
```

`version` is `relay-blind-client-journal-v2`; `transaction_id` and `owner_epoch` are fresh 16-byte CSPRNG values, and logical generation starts at 1 and increments exactly once. `next_status_sequence` starts at 1 and is durably advanced before each wallet poll; API-key rows retain 1. `canonical_request_bytes` is the exact closed SPEC-041 inference request framing before encryption. `request_commitment` is HMAC-SHA256 with the journal key over `ASCII("macprovider/relay-blind/client-request/v2\x00") || b16(transaction_id) || u32bytes(canonical_request_bytes)`; it is not a raw prompt hash. Genesis predecessor is tagged `0x00`; later record predecessors are `0x01||b32(prior digest)`; compacted snapshots use `0x02||b32(checkpoint digest)`.

`journalrecordframe` follows the displayed order excluding digest/MAC: `u16str` for version/origin/state; `b16` for transaction/account/profile/owner and the C4 UUIDv4 request ID; `uint64` for revisions/generation/status sequence/times; `b32` for digests/commitment; tagged predecessor; then tagged `envelope_digest`, tagged `terminal_class` as `u16str`, and tagged terminal time. `record_digest` is SHA-256 over `ASCII("macprovider/relay-blind/client-journal-record/v2\x00") || journalrecordframe`; `record_mac` is HMAC-SHA256 over the decoded digest. Legacy printable-ASCII request IDs remain outside profile mode and this journal.

| State | Additional fields and only permitted action after reopen |
|---|---|
| `reservation_received_unbound` | Envelope absent; locator present; only live owner may build. Reopen may poll with null envelope. |
| `envelope_built` | Envelope digest required; only live owner may durably fence. Reopen is status-only. |
| `send_fenced` | Envelope digest required; only the same live owner that committed/read back the fence may perform one send. Reopen is status-only. |
| `response_started` | Envelope digest required; interruption is status-only. |
| terminal | Envelope required except unconsumed `predispatch_rejected`; terminal class/time required; no send. |

The first durable record follows reservation verification and includes the provider-binding locator. Envelope digest is durable before `send_fenced`; only the live in-memory owner that committed the fence can send once. A crash before the first record precedes envelope/consume/quota/send and leaves reservation expiry to the coordinator. Reopen makes every persisted owner epoch recovery-only, including a coherently rolled-back local store. Status remains possible from each persisted state-specific locator. No local record, checkpoint, lease or server response restores send ownership.

#### C8A. Go root, single lock, and descriptor state machine

The Go root defaults to canonical macOS Application Support; overrides are absolute. Root-to-leaf `openat`/`O_NOFOLLOW` traversal, owner/mode/sticky checks, retained directory descriptors, link-count checks, and edge recapture remain mandatory. Under the retained private-root descriptor there is exactly one advisory lock pathname, `private.lock`, for both `requests` and `confirmed-profiles` authorities and both key files. Acquire and verify it before opening an authority/key descriptor. The lock order is therefore `directory descriptors -> private.lock -> authority/key descriptors`; code holding it may do file I/O but no HTTP, SQLite, callback, or browser work. HMAC keys are distinct and their paths never change. Nonblocking acquisition has a five-second ceiling.

Before load/append/fsync and immediately before replacement, each live data descriptor must equal its current pathname and captured `(dev,ino)`. Compaction creates and validates a same-directory `O_EXCL|O_NOFOLLOW` temporary generation, fsyncs it, and performs the last old-descriptor/path equality check before `renameat`. After rename the old descriptor is expected not to equal the current pathname; close verifies only that `fstat(old_fd)` still equals the captured old identity. The new pathname is opened and must equal the captured temporary identity before the old descriptor closes. The parent is fsynced after rename and after retirement. The lock descriptor must equal `private.lock` at every boundary. Any other equality/mismatch quarantines writes. This exact pre-rename equality, expected post-rename mismatch, new-target equality, then old-close sequence replaces the contradictory universal close check.

#### C8B. Versioned compaction generations

Each authority subdirectory has `CURRENT`, immutable compacted base `base.<16-byte-generation-id>.jsonl`, append-only `tail.<generation-id>.jsonl`, and `manifest.<generation-id>.json`; names use lowercase hex. `CURRENT` is `version, authority, generation_id, prior_generation_id, manifest_digest, pointer_generation, pointer_mac`. A manifest is `version, authority, generation_id, source_generation_id, source_manifest_digest, base_data_digest, base_size, base_record_count, checkpoint_digest, created_at_unix_ms, manifest_mac`. Genesis source ID/digest is all-zero. The manifest authenticates only the immutable base. Normal appends go to the tail under `private.lock`, use the current record digest for that logical key as predecessor, and do not rewrite `CURRENT` or the manifest. Load validates every tail record against the per-key heads established by the base, so unrelated keys never share a predecessor chain.

The first base line is a checkpoint `version, authority, generation_id, source_generation_id, source_manifest_digest, source_base_digest, source_tail_digest, source_tail_size, source_tail_record_count, cutoff_record_digest, retained_heads, omitted_heads, created_at_unix_ms, checkpoint_digest, checkpoint_mac`. At compaction time the source base is verified against its manifest and the exact source tail bytes are digested and length-bound after full record validation. `retained_heads` is sorted by 16-byte profile/transaction key and each entry is `key, logical_generation, original_head_digest, original_predecessor_digest, state_or_terminal_class, snapshot_authority_digest`. `omitted_heads` is sorted and contains `key, original_head_digest, terminal_at_unix_ms, removal_reason`, only for retention-eligible terminal keys. `snapshot_authority_digest` hashes the canonical logical snapshot fields excluding predecessor, record digest and MAC, so it is knowable before the checkpoint and avoids a digest cycle. Retained snapshot records preserve logical generations and use checkpoint tag `0x02`; their ordinary record digests are computed only after the checkpoint digest. The resulting snapshot digest becomes that key's head for subsequent tail appends, while the checkpoint preserves the original head/predecessor evidence. No successor points across removed bytes without the checkpoint witness.

Binary framing is exact displayed order. Versions/authority/state/reason use `u16str`; IDs and head keys use `b16`; digests use `b32`; sizes/counts/generations/times use `uint64`; head arrays use `uint32(count)` then their frames. `base_data_digest`/source data digests are SHA-256 over exact file bytes including newlines. `checkpoint_digest = SHA256(ASCII("macprovider/relay-blind/compaction-checkpoint/v1\x00") || checkpointframe_without_digest_mac)` and its MAC is over the decoded digest. `manifest_digest` uses domain `macprovider/relay-blind/compaction-manifest/v1\x00` and its MAC is over that digest. `pointer_mac` is HMAC over `ASCII("macprovider/relay-blind/compaction-pointer/v1\x00") || pointerframe_without_mac`. Unknown fields, unsorted/duplicate heads, count/length mismatch, or a source/root disagreement quarantines.

Publication under `private.lock` is: validate source pointer, manifest, base and tail; write+fsync new base; write+fsync new manifest; create+fsync an empty new tail; reopen/validate all three; write+fsync `CURRENT.tmp` whose prior ID/pointer generation match the observed source; last-check old pointer identity; rename over `CURRENT`; fsync directory; reopen/validate the pointer and referenced generation; then retire unreferenced old base/tail/manifest files and fsync again. Recovery trusts only the valid generation named by `CURRENT`. Unreferenced complete or partial generations are deleted; pointer-to-missing/invalid content quarantines. A final partial tail line truncates only to the last authenticated newline; any interior error quarantines. Crash outcomes are fixed at every write/fsync/reopen/rename/directory-sync/retirement cut. This detects torn publication and authenticated substitution. Coherent rollback of the pointer, all generation files and same-user HMAC credentials is outside the claim; profile rollback is checked against server/C3B, and request rollback never restores send authority.

IndexedDB `authority_roots` stores the same logical pointer/manifest/checkpoint objects. One readwrite transaction writes checkpoint/snapshots, validates counts/digests, switches the root, and deletes old generation rows; abort leaves the old root authoritative. Shared Go/JavaScript vectors cover identical frames, heads and rollback limits even though publication mechanisms differ.

Go request records are at most 4 KiB, 4,096 current transactions, 16 MiB per active generation and 40 MiB total authority space reserved so old+new generations can coexist. Confirmed profiles use an 8 MiB normal ceiling plus 768 KiB revoke headroom per active profile, bounded by 40 MiB active and 88 MiB physical reserve. Browser request records are at most 2 KiB, 128 transactions, 262,144 active-generation bytes and 768 KiB physical IndexedDB reserve. Terminal retention is 691,200 seconds. Compaction removes only eligible expired terminal keys and reserves space for the complete checkpoint/manifest/pointer before starting. At capacity new reservation/encryption fails before network; independently supplied status and preallocated profile revocation remain available.

The browser uses dedicated IndexedDB stores and a Web Lock named from canonical origin plus account subject for profile mutations, or origin plus transaction ID for request transitions. One readwrite transaction validates record MAC/head/root, old state and owner, commits transition, and readbacks before fetch. No lease takeover exists. Missing APIs, abort/quota/blocked upgrade, key loss, corruption, generation/root conflict, or failed readback prevents sends. Two tabs/double clicks produce one live fence owner and at most one send. Neither implementation stores prompt/messages/tools/response, ciphertext, ephemeral private key, bearer/wallet key, raw provider/buyer binding, provider/session identity, local path, raw server body, or raw/unsalted request digest. Plaintext browser history remains separately stored and disclosed.

### C9. Capacity, retention, and fail-closed configuration

| Item | Bound / retention and reachable construction |
|---|---|
| Bundle keyring/storage | 8 trusted signer keys; 4,096 bundle revisions and 64 MiB public bytes globally |
| Profiles | 32 active/retained IDs/account; 64 immutable revisions/profile; exactly 2,048 successful create/replace heads are reachable as 32 creates plus 32*63 replacements |
| Invitations | 2,048 rows/4 MiB/account; 128 live; successful consumption updates in place; rejected requests do not retain operation rows |
| Normal mutation operations | Exactly 2,048 rows/2 MiB/account, one for every reachable successful create/replace head; canonical charge at most 1 KiB; 8-day retention after its referenced revision becomes pruneable |
| Normal profile audits | Exactly 2,048 rows/2 MiB/account, one for every successful create/replace; canonical charge at most 1 KiB; 30-day retention subject to references |
| Preallocated revoke authority | On profile create, the same transaction allocates one fixed 1 KiB revoke-operation slot and one fixed 1 KiB revoke-audit slot keyed by profile ID. At most 32 each/account; charged to create before success and never consumable by another event |
| Recovery quarantine authority | At account authority initialization, 24 fixed 1 KiB slots are allocated and reused by quarantined recovery key; they are disjoint from revoke slots and normal audits |
| Profile reservations | 512 live/account and 128 live/profile, independently reachable as four profiles with 128 each |
| Gateway recovery joins | 1,024 physical rows: 1,000 admission rows plus 24 preallocated quarantine slots; existing rows update in place |
| Wallet status authority | One fixed row/reservation; 4,096 rows/2 MiB/session and 16,384 rows/8 MiB/account; 512 bytes/row |
| Confirmed-profile stores | 32 current profiles; 192 KiB/record; 8 MiB normal plus 768 KiB revoke reserve/active profile; 40 MiB active and 88 MiB physical ceiling |
| Client journals | Go 4,096/16 MiB active/40 MiB physical/4 KiB record; browser 128/256 KiB active/768 KiB physical/2 KiB record; terminal retention 8 days |
| Other bounds | 16 pins and models/revision; one endpoint; 64 KiB requests; 60 mutations and 120 reads/status per account/minute; 16 providers/3 pool rounds; pin 30 days; bundle/invitation 24 hours; tombstones 38 days; coordinator evidence 8 days |

The Slice 0 charging manifest is exhaustive:

| Accepted event | Retained authority and maximum new charge |
|---|---|
| Operator bundle upload or signer/bundle/pin tombstone | Global bundle/tombstone row plus global operator audit; outside account partitions and bounded by the global bundle/tombstone limits |
| Invitation issue | One invitation row, <=2 KiB; issuance audit fields are embedded in that row |
| Invitation consume/expire | In-place invitation state/timestamp update; zero new rows |
| Profile create | One revision row, one <=1 KiB normal operation, one <=1 KiB normal audit, and one preallocated <=1 KiB revoke-operation plus <=1 KiB revoke-audit blob; consumes invitation in place |
| Profile replace | One revision row, one <=1 KiB normal operation and one <=1 KiB normal audit; consumes invitation in place |
| Profile revoke | In-place profile state plus overwrite of that profile's fixed revoke operation/audit blobs; zero new rows and no blob growth |
| Profile read/list or revocation preflight | Zero retained rows; a higher client watermark is local authority only |
| Recovery quarantine | Overwrite one of 24 preallocated <=1 KiB slots by recovery key; zero new rows |
| Reservation/status/recovery transition | Update the existing reservation, status-authority or recovery row; normal admission creates only the already budgeted join/status rows |
| Rejected auth/validation/CAS/rate/capacity request | Zero retained rows; successful operation replay reuses its row; changed operation-ID reuse conflicts without a row |

Profile/reservation/request-log audits outside this table retain their existing bounded authorities and cannot charge a profile mutation partition. No implementation may introduce a new retained event class without reopening the plan gate.

Every charge is canonical UTF-8 bytes plus the frozen SQLite page/row/WAL reserve from a Slice 0 database-size model measured at supported `page_size`, journal mode, and schema indexes. Enabled startup checks row counts, per-row maximums, B-tree worst-case pages, WAL headroom, and the full transaction's page-growth reserve; row payload alone is never used as the physical-cap proof. Tests construct the 2,048 successful heads, 32 preallocated revoke slots, every audit category, 1,000+24 recovery rows, and exact wallet/profile reservation limits through supported APIs. Limits that cannot be reached under those prerequisites are rejected at Slice 0 rather than advertised.

Logical normal/emergency capacity can never block revoke because its two slots were durably reserved before profile creation returned. Even after exhausting normal operations, normal audits, every recovery-quarantine slot, wallet/status rows, and client journal bytes, all 32 active profiles can each commit one revoke without allocating a row or growing a fixed blob. Disk/I/O corruption can still prevent durable server mutation; that fails closed, leaves the client locally disabled/pending, alerts, and is reported as a storage outage rather than `emergency_capacity_exhausted`. There is no shared revoke/recovery emergency partition and no accepted logical state in which a new capacity charge is needed for revoke.

Pruning is indexed, bounded, oldest eligible first, and never deletes active profiles, live invitations, nonterminal operations, request fences, unsealed economic effects, referenced evidence, or a bundle/revision before all pin and reservation recovery horizons expire. Compaction follows C8 and includes its peak-space reserve. Enabled startup validates capacity, status-authority, scheduler and retention inequalities; invalid configuration disables private mode while plaintext startup and safe status defaults remain.

## 6. Typed wire errors and client recovery reducer

Servers emit only the closed wire object `version, code, http_status, phase, retryable, message`, version `relay-blind-wire-error-v2`. A server never emits `action` and never claims knowledge of the client's journal fence. `http_status` is the actual nonzero response status. Coordinator/gateway fixtures own this tuple.

Clients produce a separate closed effective object `version, code, origin, http_status, phase, retryable, fence_class, action, message`, version `relay-blind-effective-error-v2`. `origin` is `client`, `gateway`, or `coordinator`; a local client error has status `0`, while a verified wire error retains its server status. `fence_class` is `before_send_fence` or `at_or_after_send_fence` and comes only from the authenticated local journal. The client reducer looks up the verified `(origin,code,http_status,phase,retryable)` row, applies the corresponding before/after column below, and emits `action`. A server-supplied action field is an unknown-field error. Missing/unknown/malformed/status-mismatched wire errors reduce to `relay_blind_unknown`; at/after fence they cannot authorize new work.

`phase` is exactly `bootstrap`, `profile`, `reservation`, `encryption`, `journal`, `admission`, `dispatch`, `status`, `settlement`, or `unknown`. Effective `action` is exactly `provision_profile`, `confirm_profile`, `replace_profile`, `complete_or_revoke_pending_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, `repair_local_state`, or `none`. `message` is printable public text of at most 512 bytes and never changes semantics.

In the table, HTTP is the server value for gateway/coordinator origins. For mixed client/server rows, a locally synthesized instance uses status `0`; the named server origins use the listed status. `any` means client `0` or server `500`. Slice 0 emits distinct machine-readable `wire-errors-v2` and `client-reducer-v2` manifests; server packages consume only the first and Go/Malibu consume both. The 53 rows remain the complete Build 2 inventory:

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
| `relay_blind_revocation_state_untrusted` | client | 0 | profile | false | `none` | `do_not_resubmit` |
| `relay_blind_revocation_preflight_unavailable` | client/gateway/coordinator | 503 | profile | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
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

The reducer precedence is: authenticated durable terminal/replay state; local fence class; C6A evidence validity; binding/envelope/profile lifecycle; quota/capacity/rate; transport. A lower-precedence error cannot replace a higher one. `retryable` and HTTP status never authorize reuse. `relay_blind_request_cancelled` before fence permits only a wholly new transaction; at/after fence requires status. `relay_blind_envelope_mismatch` permits new work only before fence and only with C6A-authenticated `dispatch_proven_absent`; otherwise the reducer selects status/no-resubmit.

The pinned SPEC-041 v1 runtime inventory has this exhaustive compatibility mapping at the Build 2 boundary:

| Legacy code | V2 code | Required context |
|---|---|---|
| `relay_blind_disabled` | `relay_blind_feature_disabled` | bootstrap |
| `relay_blind_required_unavailable` | `relay_blind_feature_disabled` | preserve original message only |
| `relay_blind_key_expired` | `relay_blind_pin_untrusted` | profile lifecycle |
| `relay_blind_envelope_invalid` | `relay_blind_request_invalid` | before consume; after fence reducer controls |
| `relay_blind_route_reservation_invalid` | `relay_blind_request_invalid` | reservation |
| `relay_blind_endpoint_unsupported` | `relay_blind_model_unsupported` | reservation/model scope |
| `relay_blind_replay` | `relay_blind_envelope_replay` | durable replay precedence |
| `relay_blind_metadata_rate_limited` | `relay_blind_admission_rate_limited` | inference path; status path maps to status-rate-limited |
| `relay_blind_downgrade_rejected` | `relay_blind_mixed_version` | bootstrap/version boundary |
| `relay_blind_decrypt_failed` | `relay_blind_response_lost` | post-consume; never new envelope from wire alone |
| `relay_blind_ciphertext_invalid` | `relay_blind_envelope_mismatch` | requires rejection proof for before-fence new work |
| `relay_blind_committed_failed` | `relay_blind_response_lost` | committed/postdispatch |
| `relay_blind_provider_unsupported` | `relay_blind_no_approved_provider` | reservation |

`relay_blind_emergency_capacity_exhausted` is retained only for imported pre-R4 schema/invariant-breach compatibility; an R4 revoke path cannot emit it for logical capacity. The inventory generator scans pinned coordinator/gateway exported error constants and SPEC-041 rows and fails on an unmapped emitted code. Auth, wallet, quota, cancellation and transport adapters likewise have explicit source-code mappings in `wire-errors-v2`; no regex/default mapping except malformed-to-unknown is permitted. Pairwise precedence fixtures run against the reducer, not server packages.

### C10. Dependency-compliant real-browser harness

Malibu `origin/main` at the inspected revision has no browser automation dependency, while Safari 26.5, `/usr/bin/safaridriver`, Google Chrome 152.0.7977.85, and Node 22.23.2 are installed on the reviewed Mac and no `chromedriver` is installed. R4 therefore uses only Node built-ins and browser-provided protocols. `scripts/private-request-browser-tests.mjs` starts `npm run preview -- --host 127.0.0.1 --port 4173`, then requires the page to report `isSecureContext === true`; loopback HTTP is the browser-defined potentially trustworthy test origin and requires no certificate. Production-origin smoke evidence separately uses HTTPS. Any non-loopback or insecure context fails.

Safari uses W3C WebDriver over a child `safaridriver -p <ephemeral-port>` process. Chrome uses a child `Google Chrome --remote-debugging-port=<ephemeral> --user-data-dir=<private-temp> --no-first-run` and the Chrome DevTools Protocol through Node's built-in `fetch` and `WebSocket`; no chromedriver or npm package is added. The checked-in command is `node scripts/private-request-browser-tests.mjs --browser safari|chrome --base-url http://127.0.0.1:4173`, with `npm run test:private-browser` invoking both. Supported evidence records exact browser/OS versions; CI requires a physical macOS runner with both browsers. Missing Safari automation authorization, browser binary, WebSocket support, or runner marks browser acceptance blocked and cannot fall back to Node mocks.

The harness owns isolated Chrome profiles and a dedicated Safari test user/session. It refuses destructive Safari crash cuts when an unrelated Safari process/window exists. Chrome tab cuts use `Target.closeTarget`; Chrome process cuts terminate only the spawned PID and reopen the same isolated profile. Safari tab cuts close only its WebDriver window; process cuts end only the WebDriver-owned session/process and reopen the same dedicated-user data. Two-tab barriers, reload, window close, driver/session termination, browser termination, IndexedDB abort/quota/blocked-upgrade hooks, and Web Lock races are coordinated through test-only same-origin hooks compiled out of production builds. Artifacts contain test IDs, state names, counts, timings and redacted console/network metadata; headers, keys, prompts, ciphertext and response bodies are filtered before write. Each run fails on zero selected cases and emits a manifest of required versus executed crash cuts.

## 7. Implementation slices

1. **Governance and vectors:** update SPEC-041, SPEC-006, SPEC-040, AUTHORITY, CONFORMANCE, and shared fixtures with C1-C10/C3A-C3B/C6A, exact nullability, local-record schemas, separate wire/reducer errors, revocation evidence, compaction roots, evidence/framing vectors, mixed-version rules, and non-claims.
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

Bounded metrics include invitation/profile create/replace/revoke and local-confirmation outcomes, selected-approved/no-candidate/churn outcomes, double-collect retries, pool generation changes, invalidations by state/reason, recovery join state/oldest age/pass duration/refund/hold/quarantine, coordinator-evidence and revocation-preflight verification reason/generation-age, status envelope-binding/replay-partition class, wallet signature failures, journal/descriptor failures, and client recovery actions. Labels use fixed enums and never account/profile/provider/request IDs, fingerprints, model strings, ciphertext digests, prompts, or raw errors.

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

Run targeted contract/storage/selection/recovery/client/browser tests first, then full coordinator/gateway/integration/Swift/Malibu checks from `test-spec-r4.md`. Review each complete repository diff through independent GPT-5.6 Sol code, security, architecture, and applicable browser/product lanes. Critical, High, and Medium findings must all be zero before a slice is complete.

The handoff separately records implementation/PR references, fixture evidence, browser evidence, actual MLX evidence, deployed/production status, hardware/operator/signing blockers, skipped/timed-out/zero-selected runs, and per-repository cumulative versus dependent diffs. It confirms the provider-plaintext boundary, response relay visibility, no ciphertext failover, and verified-model/reward exclusions.
