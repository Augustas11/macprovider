# Product Build 2 PRD and implementation plan

**Plan revision:** R5
**Status:** draft; implementation is prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for these exact bytes and the paired R5 test specification
**Paired test specification:** `test-spec-r5.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu buyer-app base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)
**Predecessor:** `prd-implementation-plan-r4.md`
**Failed predecessor review:** `reviews/plan-r4-sol.md`

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
| Revocation-preflight request/response | Every displayed C3B field required/non-null. `wallet_session_id` is the named empty string only for API-key mode; arrays may be empty only where C3B permits. |
| Compaction pointer/manifest/checkpoint/external-head/head-ledger objects | Every displayed C8B field required/non-null; genesis uses only the named tagged or all-zero expected-digest values. |
| v2 status response | Every field required; `input_tokens` and `completion_tokens` are independently a safe nonnegative integer or JSON `null`. All other fields are non-null. |
| Confirmed-profile record | Every envelope field is required/non-null. `record_kind` selects exactly one closed `stable_authority`, `mutation_pending`, or `absent_marker` payload; fields from another payload are forbidden. No field accepts JSON `null`. |
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

The coordinator adds account-key-only `GET /v1/account/identity`, returning exactly `version: relay-blind-account-identity-v1` and a stable opaque 16-byte canonical base64url `account_subject`. It is scoped to the authenticated account, contains no email or credential material, and cannot create local profile trust. A client may use a server profile only when the committed local `stable_authority` payload matches `(origin, account_subject, profile_id, revision, profile_digest, state)` exactly, its externally anchored C8 head is current, and C3B preflight is fresh.

R5 replaces the R4 common-record/pending-object shape with one closed discriminated union so a first create has a representable predecessor. Every record has exactly this envelope:

```text
version, origin, account_subject, profile_id, confirmation_generation,
predecessor_record_digest, record_kind, payload, record_digest, record_mac
```

`version` is `relay-blind-confirmed-profile-v3`; `record_kind` is `stable_authority`, `mutation_pending`, or `absent_marker`. `origin` is a canonical HTTPS origin with no path/query/fragment. `confirmation_generation` starts at 1 and increments exactly once. The predecessor is literal `genesis` only at generation 1 and otherwise the preceding record digest. `payload` is exactly one of the closed variants below; fields from another variant are forbidden.

A `stable_authority` payload contains exactly:

```text
state, revision, profile_digest, bundle_id, bundle_revision, bundle_digest,
invitation_id, signer_kid, signed_bundle, selected_fingerprints,
selected_pinframe_digests, earliest_pin_expiry_unix,
last_revocation_generation, last_revocation_root_digest, confirmed_at_unix_ms
```

`state` is `active` or `revoked`. All public authority bytes recompute under C1-C3. `signed_bundle` is canonical base64url of the exact verified bundle JSON bytes. Selection order is bundle order. `confirmed_at_unix_ms` is a client-local audit timestamp fixed when the target is first prepared; it is not compared to a server timestamp and cannot alter the public profile digest. Revocation generation/root obey C3B; generation zero always carries the C3B empty-log root, never an all-zero sentinel.

A `mutation_pending` payload contains exactly:

```text
operation, operation_id, request_disposition, expected_authority,
target_authority, target_public_authority_digest, started_at_unix_ms
```

`operation` is `create`, `replace`, or `revoke`; `request_disposition` is `not_sent` or `sent_or_unknown`. `expected_authority` is a tagged closed union: an absent expectation is exactly `presence, absence_predecessor`, where `presence` is `absent` and `absence_predecessor` is literal `genesis` for the first local record or the digest of the current `absent_marker`; a present expectation is exactly `presence, authority`, where `presence` is `present` and `authority` is a byte-identical `stable_authority` payload. `target_authority` is a complete `stable_authority` payload. Create requires absent expected authority and target `active`, revision 1. Replace requires present active expected authority and a complete independently verified active successor at revision +1. Revoke requires present active expected authority and a revoked target with unchanged immutable revision/profile digest; before the server call its revocation generation/root remain the prior valid watermark, and after success the still-pending successor is advanced to the signed tombstone-bearing watermark before stable revoke.

An `absent_marker` payload contains exactly `abandoned_operation_id, abandoned_target_public_authority_digest, abandoned_at_unix_ms`. It is local negative authority, never a server profile and never usable for encryption. Only cancellation of a create whose disposition is still `not_sent` may append it. A later create names its digest as `absence_predecessor`; a server GET can never replace it or bootstrap trust.

`authorityframe`, `expectedauthorityframe`, and each payload frame follow the displayed field order. Strings use `u16str`; account/profile/bundle/invitation/operation IDs use decoded `b16`; digests/fingerprints/roots use decoded `b32`; revisions/times/generations use `uint64`; signed bundle uses `u32bytes`; arrays are counted. `expectedauthorityframe` begins `0x00 || (0x00 for genesis, else 0x01||b32(absence_predecessor))` for absent and `0x01 || authorityframe` for present. `payloadframe` begins `0x00`, `0x01`, or `0x02` for stable, pending, or absent. `record_digest = SHA256(ASCII("macprovider/relay-blind/confirmed-profile-record/v3\x00") || envelope_without_digest_mac_frame)` and `record_mac = HMAC-SHA256(profile_authority_key, decoded_record_digest)`. `target_public_authority_digest = SHA256(ASCII("macprovider/relay-blind/trust-profile-authority/v1\x00") || profile_digest_input_bytes_from_C3 || u16str(target_state))`. Shared Go/JavaScript vectors freeze every byte before runtime work.

Before every create, replace, or revoke HTTP request, the client appends and reads back the complete pending record and commits its C8 external head. Immediately before the request it appends/anchors `sent_or_unknown`. Create generation 1 therefore durably contains the complete locally verified target before invitation consumption or server mutation. A first-create cancellation is permitted only from `not_sent` and appends/anchors `absent_marker`; replace/revoke cancellation from `not_sent` appends/anchors the exact expected stable authority. At `sent_or_unknown`, cancellation, response loss, restart, or a concurrent process can only reconcile.

Recovery uses only the locally persisted verified target. A successful authenticated response must equal every public authority-bearing target field and target digest; client-local confirmation time is retained unchanged, while server timestamps are syntax/monotonicity checks but not trust input. On restart the client reverifies the stored bundle/signature/pins, performs C3B, and commits stable state only when server state and fresh revocation evidence agree. For create, an consumed invitation plus lost response is recoverable because the target preceded the call. If the server has no profile after a `sent_or_unknown` create, the client retains pending state until the operation's authenticated terminal disposition proves absence; it never guesses from invitation consumption. Conflicts and mismatches remain disabled. Concurrent same-profile create attempts serialize on C8 and coordinator operation/profile CAS; only one pending lineage may reach the network.

The Go library uses the single authority lock and external Keychain head in C8. Malibu uses one account/origin Web Lock plus the authenticated browser-head service in C8. The threat claim covers corruption, file/record/tail prefix rollback, pointer-only rollback, retained-old-generation rollback, record substitution, and server-visible profile/revocation rollback. Rollback or authorized replacement of either non-synchronizable Keychain item by the same logged-in user is outside the Go claim. Browser rollback is checked against the server head. Request records still never restore send ownership.

Each variant is at most 192 KiB. A create admission reserves bytes for pending-not-sent, pending-sent-or-unknown, stable-success, and absent cancellation before the first append. Existing per-active-profile 768 KiB revoke headroom reserves four worst-case revoke records and cannot be consumed by normal work. Normal content stops at 8 MiB; active generation remains capped at 40 MiB and physical old/new/checkpoint peak at 88 MiB. Stable current, pending, absent marker, and every externally anchored head remain until a checkpoint proves their successor. Revoked authority remains at least 8 days and until no server/recovery reference exists. Capacity, durability, or external-head failure occurs before server mutation and disables private mode.

Ordinary invitation, bundle, or signer validity-window expiry after activation does not erase confirmed authority; selected-pin expiry and explicit signer/bundle/profile/pin revocation disable it. Every new private transaction, including wallet-authenticated reservation, requires C3B under the credential split below. Cached/offline evidence is stale and cannot authorize reservation. Clearing either local authority disables affected profiles and does not revoke server state or authorize ciphertext reuse.

### C3B. Authenticated revocation synchronization

The signed empty revocation-log state is exact: `revocation_generation = 0` and `revocation_root_digest = base64url(SHA256(ASCII("macprovider/relay-blind/revocation-empty/v1\x00")))`. It is stored in the database singleton at migration, returned in a normally signed preflight on a fresh deployment, and is the only valid generation-zero root. The first tombstone is generation 1 with that empty root as predecessor; every later tombstone uses the immediately preceding committed root. There is no all-zero root sentinel.

The account-key-only public preflight is `POST /v1/relay-blind/revocation-preflight`. Its request contains exactly `version, challenge, reservation_auth_mode, wallet_session_id, profile_id, revision, profile_digest, state, signer_kid, bundle_id, bundle_revision, bundle_digest, selected_fingerprints, prior_generation, prior_root_digest`. `reservation_auth_mode` is `api_key` or `wallet_session`; `wallet_session_id` is the literal empty string only for API-key reservation and is the exact active wallet-session ID otherwise. The response echoes all request fields and then exactly `revocation_generation, revocation_root_digest, profile_revoked, signer_revoked, bundle_revoked, revoked_fingerprints, issued_at_unix, expires_at_unix, evidence_kid, signature`. Versions are `relay-blind-revocation-preflight-request-v2` and `relay-blind-revocation-preflight-v2`.

For wallet reservation, the supported client holds two separate credentials: an account API key used only for account identity/profile reads and this preflight, and the wallet bearer/signing key used only for the later wallet reservation/status routes. They are never placed together on one HTTP request. Preflight resolves the account API key, loads the named active wallet session, and requires its account to equal the API-key account and local `account_subject`; the signed response binds the exact wallet session. A missing account key, mismatched/revoked/expired wallet session, or changed wallet session after preflight disables new private work. Gateway reservation independently reauthenticates the wallet, and coordinator lifecycle rechecks profile/revocations. Malibu R5 supports account-key private mode only; wallet private mode is a Go library/CLI journey and its account-key prerequisite is stated before enablement.

The closed tombstone record is `version, generation, operation_id, kind, target_digest, created_at_unix, predecessor_root_digest, entry_digest`, version `relay-blind-revocation-tombstone-v1`. Target digests are domain-separated exact frames:

```text
signer:  SHA256(ASCII("macprovider/relay-blind/revocation-target/signer/v1\x00")  || b16(signer_kid))
bundle:  SHA256(ASCII("macprovider/relay-blind/revocation-target/bundle/v1\x00")  || b16(bundle_id) || uint64(bundle_revision) || b32(bundle_digest))
profile: SHA256(ASCII("macprovider/relay-blind/revocation-target/profile/v1\x00") || b16(account_subject) || b16(profile_id) || uint64(revision) || b32(profile_digest))
pin:     SHA256(ASCII("macprovider/relay-blind/revocation-target/pin/v1\x00")     || b32(fingerprint))
```

`entry_digest = SHA256(ASCII("macprovider/relay-blind/revocation-entry/v1\x00") || uint64(generation) || b16(operation_id) || u16str(kind) || b32(target_digest) || uint64(created_at_unix) || b32(predecessor_root_digest))`. The root is `SHA256(ASCII("macprovider/relay-blind/revocation-root/v1\x00") || uint64(generation) || b32(predecessor_root_digest) || b32(entry_digest))`. Tombstone row, singleton generation/root, kind reserve charge, and audit commit in one SQLite transaction. Checkpoint/pruning follows C9 and never changes the current generation/root.

Request/response frames follow displayed order. Strings use `u16str`, except the named wallet empty sentinel uses `u16str_allow_empty`; fixed values use decoded `b16`/`b32`; arrays are counted; numbers are `uint64`; booleans are one byte. Signed bytes are `ASCII("macprovider/relay-blind/revocation-preflight/v2\x00") || b16(account_subject) || revocationrequestframe || revocationresponseframe_without_signature`. `evidence_kid` is the first 16 bytes of SHA-256 of the revocation-evidence public key. Signature is Ed25519 canonical base64url. Shared Go/Swift/JavaScript vectors include empty state, first entry, all four kinds, and wallet/account binding.

A dedicated online keyring of at most four release-baked public keys is separate from bundle/provider/wallet/payout/C6A keys. Evidence validity is positive and at most 30 seconds, issuance future skew at most 5 seconds, and reservation begins within 15 seconds. The route is no-store, rejects redirects, and production requires verified HTTPS. Unknown/revoked/out-of-window evidence key, invalid signature/binding, lower generation, same generation with another root, clock failure, timeout, TLS/HTTP failure, wallet/account mismatch, or a locally anchored head that cannot advance disables new private work. A higher root must be committed to the C8 local authority before reservation. Lifecycle revalidation still catches revocation after preflight.

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

For 1,000 rows, ten 100-row passes are required. C9 freezes the general first-call formula and the 263-second last-row result, including four final-batch waves before rows 81-100 start. Aggregate persistence remains outside that row's first-call instant but inside the 18-second pass bound. Startup evaluates both formulas with checked arithmetic and rejects enabled recovery if either exceeds its bound. Alert at 60 seconds. Tests measure persistence, retry order, continuously arriving rows, cancellation, and non-divisible shapes rather than inferring progress from worker count.

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

The Go root defaults to canonical macOS Application Support; overrides are absolute. Root-to-leaf `openat`/`O_NOFOLLOW` traversal, owner/mode/sticky checks, retained directory descriptors, link-count checks, and edge recapture remain mandatory. Under the retained private-root descriptor there is exactly one advisory lock pathname, `private.lock`, shared by the `requests` and `confirmed-profiles` authorities. Acquire and verify it before opening an authority descriptor or reading the corresponding Keychain items. The lock order is `directory descriptors -> private.lock -> authority descriptors/Keychain`; code holding it may do file and Keychain I/O but no HTTP, SQLite, callback, or browser work. HMAC keys are distinct non-synchronizable Keychain items with fixed service/account selectors; no HMAC key file exists in the private root. Nonblocking acquisition has a five-second total ceiling.

Before load/append/fsync, every live immutable-object descriptor must equal its pathname and captured `(dev,ino)`; immutable objects use their final unique `O_EXCL|O_NOFOLLOW` name and are never renamed over another object. Only non-authoritative `CURRENT.tmp` is renamed over the `CURRENT` cache. Immediately before that cache rename, the old descriptor must equal `CURRENT`; afterward the old descriptor/path mismatch is expected, the reopened path must equal the captured temporary identity, and old close checks only its captured identity. Parent fsync follows cache rename and retirement. The lock descriptor equals `private.lock` at every boundary. Any other equality, replacement, link-count, or ownership result quarantines writes.

#### C8B. Externally anchored generations and compaction

File-backed authorities use immutable objects under each authority directory: `base.<generation-id>.jsonl`, `tail.<generation-id>.<tail-sequence>.jsonl`, `manifest.<generation-id>.json`, and `pointer.<pointer-generation>.json`. `CURRENT` is only a replaceable cache of the externally anchored pointer bytes; it is never authority. Names use lowercase hex generation IDs and canonical decimal sequences. A pointer contains exactly `version, authority, generation_id, prior_generation_id, manifest_digest, pointer_generation, tail_sequence, committed_tail_size, committed_tail_digest, committed_head_digest, external_head_generation, pointer_mac`, version `relay-blind-compaction-pointer-v2`. A manifest contains exactly `version, authority, generation_id, source_generation_id, source_manifest_digest, base_data_digest, base_size, base_record_count, checkpoint_digest, created_at_unix_ms, manifest_mac`, version `relay-blind-compaction-manifest-v1`. A tail object is never mutated after committed external-head publication; the next append writes a fresh tail object containing the prior exact bytes plus one record. This bounds recovery to whole immutable objects rather than trusting a mutable prefix.

The first base line is a checkpoint containing exactly `version, authority, generation_id, source_generation_id, source_pointer_digest, source_manifest_digest, source_base_digest, source_tails, cutoff_record_digest, retained_heads, omitted_heads, created_at_unix_ms, checkpoint_digest, checkpoint_mac`, version `relay-blind-compaction-checkpoint-v2`. Each sorted `source_tails` entry is exactly `tail_sequence, tail_size, tail_digest, tail_record_count`. Each sorted retained head is exactly `key, logical_generation, original_head_digest, original_predecessor_digest, state_or_terminal_class, snapshot_authority_digest`; each sorted omitted head is exactly `key, original_head_digest, terminal_at_unix_ms, removal_reason`. Genesis source ID/digests use 16/32 all-zero bytes only in a generation-1 checkpoint. Snapshot records preserve logical generation, use predecessor tag `0x02||checkpoint_digest`, and become the subsequent per-key heads. Omission is allowed only for terminal keys past every retention/reference horizon.

Each Go authority has two non-synchronizable, this-device-only macOS Keychain generic-password items with application-specific access control: an HMAC key item and an external-head item. Their services are `macprovider.relay-blind.<authority>.hmac.v1` and `macprovider.relay-blind.<authority>.head.v1`; account is `base64url(SHA256(ASCII("macprovider/relay-blind/keychain-account/v1\x00") || u16str(origin) || b16(account_subject)))`. The external-head value is exactly `version, authority, account_scope_digest, external_head_generation, pointer_generation, pointer_digest, generation_id, tail_sequence, committed_tail_size, committed_tail_digest, committed_head_digest, head_mac`. `external_head_generation` starts at 1 and advances once per committed append or pointer publication. `head_mac = HMAC-SHA256(authority_key, ASCII("macprovider/relay-blind/external-head/v1\x00") || externalheadframe_without_mac)`. Synchronizable/iCloud Keychain items are forbidden. A missing, duplicate, ACL-mismatched, malformed, or MAC-invalid item quarantines the authority. Rollback or authorized replacement of either Keychain item by the same logged-in user is outside the claim; with the Keychain items intact, file-only rollback, tail-prefix rollback, and pointer rollback are detected.

Under `private.lock`, append is: read and authenticate the Keychain head; validate the named immutable pointer/base/manifest/tail and exact committed size/digests; write+fsync the next immutable tail object; reopen and validate it; atomically replace the Keychain head with generation +1 naming its size/tail/head digests; read back the exact Keychain value; then update/fsync the non-authoritative `CURRENT` cache. A crash before Keychain replacement leaves an unreferenced candidate that recovery deletes. A crash after replacement requires the new object and never accepts the old head. A failed/unknown Keychain replacement is reconciled by exact readback; no append continues until one head is proven. The Keychain call happens under the file lock but performs no network/SQLite/callback work and has the existing five-second total lock ceiling; timeout fails closed.

Compaction fully validates the source named by the external head, including every committed tail record. It writes/fsyncs/reopens the new base, checkpoint, manifest, empty tail sequence zero, and immutable next pointer. The checkpoint binds exact source pointer digest, base digest, all committed tail object digests/sizes/sequences through the anchored head, cutoff head, and retained/omitted per-key heads. It then replaces/readbacks the Keychain head naming the new pointer and tail zero before updating `CURRENT`. Old objects remain until that readback and one subsequent successful load; retirement never removes an object named by the current or immediately prior externally authenticated head. Restoring an older `CURRENT`, pointer, retained complete generation, or tail prefix disagrees with Keychain and quarantines. Publication crash vectors have only old-head/new-head outcomes; there is no authority recovered from directory contents alone.

The browser uses the same logical record/checkpoint/pointer frames in IndexedDB and an API-key-authenticated opaque head ledger at `/v1/relay-blind/client-authority-heads/{authority_id}` through Malibu's `/api/mp` same-origin path. `authority_id` is 16 browser-CSPRNG bytes stored only in the nonextractable local authority; the server row is account-scoped and contains exactly `version, authority_id, authority_kind, origin_digest, head_generation, pointer_digest, committed_head_digest, state, updated_at_unix_ms`. `origin_digest = SHA256(ASCII("macprovider/relay-blind/browser-origin/v1\x00") || u16str(origin) || b16(account_subject))`. It stores no profile, provider, request, prompt, ciphertext, or key material. Create uses expected generation 0 and all-zero expected digests; update is a single SQLite CAS over exact prior generation/pointer/head and increments once. GET is account-key-only, no-store, constant-shape across accounts, and can confirm an already known authority ID but cannot reconstruct local trust. There are at most 8 browser authority IDs per account and two authority kinds per ID; a row is 512 bytes and is preflighted before local profile creation/private request.

An account-key-only `DELETE` of a known authority ID uses an operation ID plus exact expected head generations/digests for both kind rows, atomically changes both to `revoked`, and never returns content. A no-store account page may list only authority ID, state, and last-update time so a buyer who cleared local storage can revoke stranded heads; list cannot enable private mode. Revoked heads reject CAS immediately, remain eight days plus every request/profile recovery reference, then prune. At the eight-ID cap a new browser authority stays disabled until the buyer explicitly revokes a stranded head and its references drain; the service never evicts a live head to make room.

A browser transition under the account/origin Web Lock first commits a `prepared` IndexedDB generation containing the complete successor and prior server-head tuple, then performs the server CAS, then reads GET if the CAS response is lost, and finally marks the matching local generation committed. Before any profile mutation or inference fetch, local committed bytes and fresh server head must match. If CAS did not commit, the prepared generation is discarded. If CAS committed but local bytes are missing/corrupt after restart, private mode remains disabled; server head never supplies content. Concurrent tabs/devices cannot advance one authority ID from the same predecessor twice. Clearing IndexedDB loses the authority ID/key and cannot reacquire trust from the ledger. Browser offline/head-ledger outage blocks private transitions.

Checkpoint/manifest/head framing is binary exact displayed order: strings use `u16str`, IDs/keys use `b16`, digests use `b32`, sizes/counts/generations/times use `uint64`, and arrays use `uint32(count)`. File digests hash exact bytes including newlines. `checkpoint_digest = SHA256(ASCII("macprovider/relay-blind/compaction-checkpoint/v2\x00") || checkpointframe_without_digest_mac)` and its MAC is HMAC over the decoded digest. `manifest_digest = SHA256(ASCII("macprovider/relay-blind/compaction-manifest/v1\x00") || manifestframe_without_mac)` and `manifest_mac` is HMAC over that decoded digest. `pointer_mac = HMAC-SHA256(authority_key, ASCII("macprovider/relay-blind/compaction-pointer/v2\x00") || pointerframe_without_mac)`. Shared vectors freeze Go/JavaScript bytes. Unknown fields, unsorted/duplicate heads, sequence gaps, count/length mismatch, old head, pointer/head mismatch, or source/root disagreement quarantines.

Go request records remain at most 4 KiB, 4,096 current transactions, 16 MiB active and 40 MiB physical. Confirmed profiles retain the C3A 40 MiB active/88 MiB physical bounds. Browser request records are at most 2 KiB, 128 transactions, 262,144 active bytes and 768 KiB IndexedDB physical reserve. Terminal retention is 691,200 seconds. Compaction reserves complete new objects and external-head capacity before starting. At capacity new work stops before network while status and preallocated revocation remain available.

The browser uses dedicated IndexedDB stores and account/origin Web Locks. No lease takeover exists. Missing APIs, abort/quota/blocked upgrade, key loss, corrupt or rolled-back bytes, ledger mismatch/unavailability, failed CAS/readback, or capacity failure prevents sends. Two tabs/double clicks yield one committed head and at most one live sender. Neither implementation stores prompt/messages/tools/response, ciphertext, ephemeral private key, bearer/wallet key, raw provider/buyer binding, provider/session identity, local path, raw server body, or raw/unsalted request digest. Plaintext browser history remains separate and disclosed.

### C9. Capacity, retention, and fail-closed configuration

Logical bounds are exact:

| Item | Bound / retention and reachable construction |
|---|---|
| Bundle keyring/storage | 8 trusted signer keys; 4,096 bundle revisions and 64 MiB public bytes globally |
| Profiles | 32 IDs/account; 64 immutable revisions/profile; 2,048 successful create/replace heads reachable as 32 creates plus 32*63 replacements |
| Invitations | 2,048 rows/4 MiB/account; 128 live; consume updates in place |
| Normal mutation operations/audits | 2,048 operation rows/2 MiB and 2,048 audit rows/2 MiB per account; one <=1 KiB row for every reachable successful create/replace; rejected requests retain none |
| Preallocated revoke authority | Profile create allocates one fixed 1 KiB revoke-operation and one fixed 1 KiB revoke-audit slot; 32 each/account; revoke overwrites them without allocation/growth |
| Recovery quarantine | 24 fixed 1 KiB slots/account, disjoint from revoke slots and reused by recovery key |
| Reservations/recovery | 512 live reservations/account, 128/profile; gateway 1,000 admission joins plus 24 preallocated quarantine rows |
| Wallet status | 4,096 rows/2 MiB/session and 16,384 rows/8 MiB/account; 512 bytes/row; existing rows update in place |
| Browser head ledger | 8 authority IDs/account, two 512-byte kind rows/ID; existing head CAS updates in place |
| Local stores | C3A profile: 8 MiB normal + 768 KiB/active-profile revoke reserve, 40 MiB active/88 MiB physical. Go journal: 4,096/16 MiB active/40 MiB physical/4 KiB. Browser journal: 128/256 KiB active/768 KiB physical/2 KiB. |
| Other | 16 pins/models/revision; one endpoint; 64 KiB request; 60 mutations and 120 reads/status/account/minute; 16 providers/3 pool rounds; pin 30 days; bundle/invitation 24 hours; evidence 8 days |

The global revocation authority has 65,536 total tombstone rows, 64 MiB canonical row bytes, and 65,536 SQLite pages (256 MiB) including indexes/checkpoints/audits under the physical budget below. Normal operator issuance/revocation is capped at 64 committed tombstones per rolling hour and may consume only rows 1..65,280. Rows 65,281..65,536 are four disjoint emergency reserves of 64 rows each for signer, bundle, profile, and pin tombstones; a kind can consume only its own reserve. Normal admissions stop before those reserves. Tombstones and their audit/checkpoint evidence remain at least 38 days and longer while referenced by a profile, invitation, reservation, client watermark, recovery row, signer overlap, or evidence horizon.

Every 1,024 committed tombstones writes one signed checkpoint row containing exact start/end generation, predecessor root, end root, first/last retained entry digest, row count, and checkpoint digest/MAC. At most 64 checkpoint rows and 8 MiB checkpoint/audit canonical bytes are retained. Pruning deletes only a contiguous prefix covered by a verified checkpoint after all reference/horizon conditions clear; the singleton current generation/root never changes. The first retained entry names the checkpoint end root and generation. Restart rebuilds continuity from the newest retained checkpoint through all suffix entries and compares the singleton. At a full normal partition, one signer, bundle, profile, and pin emergency tombstone can each commit in its dedicated reserve. Exhaustion of a kind reserve fails closed, blocks new related issuance/admission, preserves other kinds, and alerts; it never deletes or rewrites a tombstone.

The accepted-event charge table is closed: bundle upload adds one bounded bundle row/audit; each tombstone adds one kind-reserved row/audit and may add one checkpoint; invitation issue adds <=2 KiB; invitation consume updates; create adds one revision, operation, audit, both fixed revoke slots, and browser-head capacity preflight when applicable; replace adds one revision/operation/audit; revoke updates profile plus fixed per-profile slots and separately appends the global profile tombstone; reads/preflight add no rows; recovery/status transitions update their reserved row. Auth/validation/CAS/rate/capacity rejection adds no retained row. A new retained event class reopens the plan gate.

All Build 2 SQLite databases must report `page_size=4096`, `journal_mode=WAL`, `synchronous=FULL`, `foreign_keys=ON`, `wal_autocheckpoint=1000`, and `busy_timeout<=5000`; enabled startup rejects any mismatch. The reviewed physical increments, including table/index B-trees and freelist exclusion, are:

| Database partition | Build 2 live-page ceiling | One-transaction new-page reserve | WAL frame ceiling | Required feature free-disk reserve |
|---|---:|---:|---:|---:|
| Coordinator relay-blind authority/reservations | 262,144 pages (1 GiB) | 4,096 pages (16 MiB) | 8,192 frames plus WAL headers/checksums (<34 MiB) | 1,126 MiB |
| Gateway recovery/wallet/head ledger | 131,072 pages (512 MiB) | 2,048 pages (8 MiB) | 4,096 frames plus headers/checksums (<17 MiB) | 561 MiB |

The feature page ceiling is measured from a migration-recorded `feature_baseline_page_count` and counts `max(0, page_count - freelist_count - baseline_nonfeature_pages)`; pages cannot be double-credited to another quota. Startup and every admitting transaction require `max_page_count - (page_count - freelist_count)` to cover the applicable remaining live-page ceiling plus transaction reserve, and filesystem free bytes to cover the table value. WAL above its ceiling disables new admission until a successful FULL checkpoint; checkpoint failure preserves revoke/emergency operations only when their pre-reserved page and disk margins remain. The coordinator `max_page_count` must be at least baseline plus 266,240 pages; gateway at least baseline plus 133,120. A lower observed B-tree/page reserve, larger row, or WAL growth fails the sizing test and reopens the plan gate; thresholds cannot be relaxed from implementation observations.

Slice 0 supplies exact DDL/indexes and a deterministic size fixture that reaches every logical maximum through public/internal supported APIs, runs `dbstat`, `page_count`, `freelist_count`, WAL-frame inspection, VACUUM/checkpoint/restart, and records worst observed page and transaction deltas on the supported SQLite build. Runtime storage implementation after Slice 0 is prohibited until a fresh independent plan amendment incorporates the DDL/measurement digest and confirms observations fit the frozen ceilings. This extra gate may tighten limits; it may not claim a pass from payload arithmetic or enlarge thresholds without review.

The healthy recovery scheduler has `N=1000`, batch `B=100`, workers `W=20`, per-call ceiling `L=2s`, claim transaction `C=3s`, aggregate result transaction `R=3s`, per-pass bound `P=18s`, and interpass delay `I=10s`. The last row first-call bound is exactly `floor((N-1)/B)*(P+I) + C + floor(((N-1) mod B)/W)*L = 9*28 + 3 + 4*2 = 263s`. The general formula is evaluated at startup with checked safe-integer arithmetic; non-divisible shapes use the same zero-based wave index. `P` includes claim, all network waves, aggregate persistence, and bounded overhead, while the final-row wave term identifies its start within the final pass. The 300-second go/no-go and 8-day evidence inequality use 263 seconds. Fault/restart recovery is bounded and reported separately, never folded into the healthy claim.

Pruning is indexed, bounded, oldest eligible first, and never deletes active profiles, live invitations, pending/absent local lineage, nonterminal requests, request fences, unsealed economic effects, referenced evidence, or revocation continuity. Enabled startup validates every capacity, physical, scheduler, and retention inequality. Invalid configuration disables private mode while plaintext startup and safe status remain.

## 6. Typed wire errors and client recovery reducer

Servers emit only the closed wire object `version, code, http_status, phase, retryable, message`, version `relay-blind-wire-error-v2`. A server never emits `action` and never claims knowledge of the client's journal fence. `http_status` is the actual nonzero response status. Coordinator/gateway fixtures own this tuple.

Clients produce a separate closed effective object `version, code, origin, http_status, phase, retryable, fence_class, action, message`, version `relay-blind-effective-error-v2`. `origin` is `client`, `gateway`, or `coordinator`; a local client error has status `0`, while a verified wire error retains its server status. `fence_class` is `before_send_fence` or `at_or_after_send_fence` and comes only from the authenticated local journal. The client reducer looks up the verified `(origin,code,http_status,phase,retryable)` row, applies the corresponding before/after column below, and emits `action`. A server-supplied action field is an unknown-field error. Missing/unknown/malformed/status-mismatched wire errors reduce to `relay_blind_unknown`; at/after fence they cannot authorize new work.

`phase` is exactly `bootstrap`, `profile`, `reservation`, `encryption`, `journal`, `admission`, `dispatch`, `status`, `settlement`, or `unknown`. Effective `action` is exactly `provision_profile`, `confirm_profile`, `replace_profile`, `complete_or_revoke_pending_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, `repair_local_state`, or `none`. `message` is printable public text of at most 512 bytes and never changes semantics. A server status/code/phase/retryable tuple is accepted only when it equals the manifest row; adapters do not preserve a legacy tuple while renaming only its code.

In the table, HTTP is the server value for gateway/coordinator origins. For mixed client/server rows, a locally synthesized instance uses status `0`; the named server origins use the listed status. `any` means client `0` or server `500`. Slice 0 emits distinct machine-readable `wire-errors-v2` and `client-reducer-v2` manifests; server packages consume only the first and Go/Malibu consume both. The following rows are the complete Build 2 inventory:

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
| `relay_blind_profile_unavailable` | gateway/coordinator | 503 | profile | true | `complete_or_revoke_pending_profile` | `check_status_do_not_resubmit` |
| `relay_blind_admission_unavailable` | gateway | 503 | admission | true | `wait_then_new_transaction` | `check_status_do_not_resubmit` |
| `relay_blind_settlement_unavailable` | gateway | 503 | settlement | true | `none` | `do_not_resubmit` |
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

The compatibility adapter is frozen by emission site, not by text matching. At the pinned base, these are the only legacy/non-Build-2 codes that may cross a Build 2 route; the adapter replaces the whole tuple with the referenced v2 manifest row:

| Pinned emission site / condition | Legacy code(s) | V2 row |
|---|---|---|
| `relay_blind.go` route method/body/schema/content-encoding/size precheck | `method_not_allowed`, `invalid_request_body`, `request_too_large`, `request_content_encoding_unsupported` | `relay_blind_request_invalid` |
| `relay_blind.go` required-mode envelope parse/shape | `relay_blind_envelope_invalid` | `relay_blind_request_invalid` |
| `relay_blind.go` feature/capability/downgrade | `relay_blind_disabled`, `relay_blind_required_unavailable`, `relay_blind_downgrade_rejected` | `relay_blind_feature_disabled`, `relay_blind_feature_disabled`, `relay_blind_mixed_version` respectively |
| `relay_blind.go` endpoint/model scope | `relay_blind_endpoint_unsupported`, `wallet_session_model_not_allowed` | `relay_blind_model_unsupported` |
| `relay_blind.go` replay insert/lookup | `relay_blind_replay` | `relay_blind_envelope_replay` |
| `relay_blind.go` inference metadata limiter | `relay_blind_metadata_rate_limited` | `relay_blind_admission_rate_limited` |
| `relay_blind.go` audit/store `internal_error` before quota or coordinator consume | `internal_error` | `relay_blind_admission_unavailable` |
| profile/invitation/head-ledger CRUD store `internal_error` | `internal_error` | `relay_blind_profile_unavailable` |
| preflight store/signing `internal_error` | `internal_error` | `relay_blind_revocation_preflight_unavailable` |
| v2 status/recovery store `internal_error` | `internal_error` | `relay_blind_recovery_unavailable` |
| `relay_blind_success.go` API-key quota reserve | `quota_exhausted` | `relay_blind_quota_unavailable` |
| `relay_blind_success.go` duplicate quota request ID | `duplicate_request_id` | `relay_blind_envelope_replay` |
| `relay_blind_success.go` account concurrency | `account_concurrency_exceeded` | `relay_blind_quota_unavailable` |
| `relay_blind_success.go` recovery arm/settle/refund persistence | `settlement_failed` | `relay_blind_settlement_unavailable` |
| `relay_blind_success.go` consume/dispatch upstream unavailable before dispatch proof | `relay_blind_required_unavailable` | `relay_blind_admission_unavailable` before fence; local fence still controls effective action |
| `relay_blind_success.go` committed/provider-validation/dispatch persistence uncertainty | `relay_blind_committed_failed` | `relay_blind_response_lost` |
| wallet endpoint ambiguous/missing account credential | `ambiguous_credentials`, `wallet_account_auth_required`, `missing_bearer_token` | `relay_blind_auth_invalid` |
| wallet lookup/signature/session lifecycle | `invalid_wallet_session`, `wallet_session_signature_invalid`, `wallet_session_signature_stale`, `wallet_session_not_found`, `wallet_session_inactive`, `wallet_session_expired`, `wallet_session_revoked`, `wallet_session_scope_mismatch` | `relay_blind_wallet_session_invalid` |
| wallet body/route/request-ID canonicalization | `wallet_session_request_id_required`, `wallet_session_query_forbidden`, `wallet_session_body_forbidden`, `invalid_request_body`, `request_too_large` | `relay_blind_request_invalid` |
| wallet reservation replay | `wallet_session_duplicate_request`, `wallet_session_replay_mismatch` | `relay_blind_envelope_replay` |
| wallet status monotonic replay | `wallet_session_duplicate_request`, `wallet_session_replay_mismatch` on v2 status route | `relay_blind_wallet_status_replay` |
| wallet replay-store row/byte cap | `wallet_session_replay_capacity_exhausted` | `relay_blind_admission_unavailable` for reservation; `relay_blind_recovery_unavailable` for status |
| wallet limiter | `wallet_session_rate_limited` | `relay_blind_reservation_rate_limited` on reservation; `relay_blind_status_rate_limited` on status |
| wallet model/request/session/account cap | `wallet_session_model_not_allowed`, `wallet_session_request_cap_exceeded`, `wallet_session_cap_invalid`, `wallet_session_exhausted`, `wallet_session_active_cap_exceeded`, `quota_exhausted` | model maps to `relay_blind_model_unsupported`; every cap/quota row maps to `relay_blind_quota_unavailable` |
| wallet store/admission failures | `wallet_session_load_failed`, `wallet_session_store_failed`, `wallet_session_admission_failed` | `relay_blind_admission_unavailable`; on status, `relay_blind_recovery_unavailable` |
| account-key auth failure on a Build 2 route | existing auth middleware 401/403 code | `relay_blind_auth_invalid` |
| client AbortError before `send_fenced` | local abort | `relay_blind_request_cancelled`, status 0; before-fence action from manifest |
| client AbortError at/after `send_fenced` | local abort | `relay_blind_request_cancelled`, status 0; at/after-fence action from manifest |
| client DNS/TLS/connect/timeout during bootstrap/profile/reservation before an envelope exists | local transport | `relay_blind_profile_unavailable` for mutation/reconcile, `relay_blind_revocation_preflight_unavailable` for preflight, otherwise `relay_blind_unknown`; no envelope reuse exists |
| client fetch rejection/EOF after `send_fenced` | local transport | `relay_blind_response_lost`, status 0, `do_not_resubmit` |
| empty, non-JSON, duplicate-key, unknown-field, wrong-type, tuple-mismatched, or oversized error response | any peer | `relay_blind_unknown`; raw body is discarded |

`wire-errors-v2` carries a required `emission_inventory` array whose key is repository, path, enclosing function, stable callsite label, legacy code, route/method, and v2 code. A source scanner parses all `writeError`, Anthropic error, wallet error helper, coordinator error constructor, and client adapter callsites reachable from Build 2 routes. The build fails for an unlisted callsite, a listed callsite that disappeared or changed raw code, two rows with the same key, or any v2 emission tuple absent from the primary table. Runtime lookup is by generated callsite constant and route state, never regex or message. Malformed response is the only default and always becomes unknown.


`relay_blind_emergency_capacity_exhausted` is retained only for imported pre-R5 schema/invariant-breach compatibility; an R5 revoke path cannot emit it for logical capacity. The inventory generator scans pinned coordinator/gateway exported error constants and SPEC-041 rows and fails on an unmapped emitted code. Auth, wallet, quota, cancellation and transport adapters likewise have explicit source-code mappings in `wire-errors-v2`; no regex/default mapping except malformed-to-unknown is permitted. Pairwise precedence fixtures run against the reducer, not server packages.

### C10. Isolated HTTPS real-browser harness

Pinned Malibu `dc7f425ba7d50c86467f31a82f419df6a0904b13` sets `/api/mp` in `server.proxy` to `https://api.streamvc.live`; pinned Vite 8.0.16 resolves preview proxy as `preview.proxy ?? server.proxy`. Therefore `vite preview` is forbidden for private browser acceptance. R5 adds a test-only Node-built-in HTTPS server that serves the built `dist` tree and implements the production path contract exactly: same-origin `/api/mp/*` is reverse-proxied to one explicit local gateway fixture with the `/api/mp` prefix removed. `/auth` and `/account` are either disabled or separately bound to explicit loopback fixtures. No production hostname is a default or fallback.

The command is `node scripts/private-request-browser-tests.mjs --browser safari|chrome --base-url https://127.0.0.1:<ephemeral> --gateway-url https://127.0.0.1:<ephemeral> --ca-file <owned-test-ca>`. `npm run test:private-browser` invokes both. The runner generates an ephemeral CA/leaf certificate outside the repository with SANs only for `127.0.0.1` and `localhost`, mode 0600, records public certificate fingerprints only, and deletes private material after the run. The gateway/coordinator fixtures use distinct leaf identities under the same test CA. The test server parses every upstream URL before listen and accepts only `https`, no credentials/query/fragment, and literal `127.0.0.1`, `[::1]`, or `localhost`; it resolves before each connection, verifies the connected peer is loopback, pins the test CA/expected hostname, rejects redirects, and has no environment-variable fallback. A non-loopback address, production suffix, DNS rebinding, plaintext upstream, TLS skip, or redirect makes startup/test fail before credentials are loaded. A guard test supplies `api.streamvc.live`, `api.malibu.tech`, `coordinator.streamvc.live`, public IPs, and redirect responses and proves zero outbound socket attempts.

The page's canonical origin is the trusted HTTPS base URL, satisfying C3A without an HTTP-loopback exception. Chrome starts only as a child with `--user-data-dir=<0700 private temp>` and trusts only the ephemeral leaf SPKI for that process. Safari runs under a provisioned disposable macOS test user or VM with a temporary isolated login keychain containing the test CA; the harness verifies current UID/home/keychain and refuses the run otherwise. Certificate install/removal, browser data, test credentials, fixture databases, and logs are isolated and deleted. Production-origin smoke remains a separate read-only test and never performs profile mutation/inference.

Safari uses W3C WebDriver over the disposable user's child `safaridriver`; Chrome uses child Chrome plus CDP through Node `fetch`/`WebSocket`. No npm dependency is added. Chrome tab cuts close only owned targets; process cuts terminate only its recorded child process group. Safari tab/session cuts use owned WebDriver windows/sessions. A Safari browser-process crash is acceptance evidence only when the disposable user/VM owns every Safari process and the harness terminates that owned process group. Without that environment, the process-crash case is explicitly `BLOCKED`, while tab/session/reload evidence may pass; WebDriver session deletion is never reported as a browser-process crash.

Two-tab barriers, reload, window close, driver/session termination, owned browser termination, IndexedDB faults, external-head CAS loss, and Web Lock races use test-only same-origin hooks compiled out of production. The local fixture uses isolated non-billable test credentials and asserts its configured account IDs cannot exist in production. Network capture proves all `/api/mp` connections terminate at the loopback test server and all proxy connections at the loopback gateway fixture. Artifacts contain only versions, certificate public fingerprints, endpoints with ephemeral ports, test IDs, states, counts, timings, and redacted metadata. Headers, credentials, prompts, ciphertext, response bodies, private certificate bytes, and device/user identifiers are forbidden. Zero selected cases fails.

## 7. Implementation slices

1. **Governance and vectors:** update SPEC-041, SPEC-006, SPEC-040, AUTHORITY, CONFORMANCE, and shared fixtures with C1-C10/C3A-C3B/C6A, exact nullability, local-record schemas, external heads, separate wire/reducer errors, revocation evidence, mixed-version rules, and non-claims.
2. **Sizing checkpoint only:** add the exact proposed coordinator/gateway DDL, indexes, generated error inventory, and deterministic SQLite capacity measurement harness. Run it to produce a digest-bound physical report. No route/runtime storage implementation is allowed in this slice. Submit the DDL/report and any plan delta to a fresh independent zero-C/H/M gate.
3. **Coordinator authority after sizing gate:** additive/rebuild migration, bundle keyring/config, invitation/profile/operation/audit/tombstone/head-ledger tables, operator intersection, pool snapshots, double-collect reservation/consume/dispatch, invalidation, status v2, metrics, purge.
4. **Gateway after sizing gate:** authenticated invitation/profile/head/status proxy, wallet split-credential preflight, C6A verification, atomic quota/session/recovery join, oldest-first reconciliation, bounds/metrics.
5. **Go library/CLI:** exported package, bundle verification, C3A v3 plus Keychain external heads, complete typed errors, journal/descriptor protocol, commands. Reference CLI becomes a thin adapter.
6. **Two-provider integration:** A-only/B-only/A+B, lifecycle, concurrency, recovery, streaming/nonstreaming, exact settlement.
7. **Malibu dependent repository:** isolated worktree; profile UI, Web Crypto, IndexedDB/Web Locks plus server head, isolated HTTPS harness, no-retry private transport, truthful copy/tests.
8. **Physical MLX evidence:** opt-in isolated journey using a supported cached artifact; record only safe context.

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

Run targeted contract/storage/selection/recovery/client/browser tests first, then full coordinator/gateway/integration/Swift/Malibu checks from `test-spec-r5.md`. Review each complete repository diff through independent GPT-5.6 Sol code, security, architecture, and applicable browser/product lanes. Critical, High, and Medium findings must all be zero before a slice is complete.

The handoff separately records implementation/PR references, fixture evidence, browser evidence, actual MLX evidence, deployed/production status, hardware/operator/signing blockers, skipped/timed-out/zero-selected runs, and per-repository cumulative versus dependent diffs. It confirms the provider-plaintext boundary, response relay visibility, no ciphertext failover, and verified-model/reward exclusions.
