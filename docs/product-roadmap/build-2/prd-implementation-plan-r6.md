# Product Build 2 PRD and implementation plan

**Plan revision:** R6
**Status:** draft; implementation is prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for these exact bytes and the paired R6 test specification
**Paired test specification:** `test-spec-r6.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu buyer-app base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)
**Predecessor:** `prd-implementation-plan-r5.md`
**Failed predecessor review:** `reviews/plan-r5-sol.md`

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

Slice 1 publishes one machine-readable schema manifest consumed by Go, Swift, JavaScript, and conformance tests. It includes positive, missing, duplicate, unknown, explicit-null, omitted, wrong-type, oversized, unsafe-integer, and trailing-byte vectors for every object above. The status locator is frozen as:

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

Every authenticated, schema-valid create/replace/revoke body is itself the recovery operation. The client may replay only the exact method, canonical route without query, canonical lowercase media type `application/json`, and byte-identical body persisted in its `sent_or_unknown` record; Authorization is reauthenticated and may rotate, but must resolve to the same account subject. `mutation_request_digest = SHA256(ASCII("macprovider/relay-blind/profile-mutation-request/v1\x00") || u16str(method) || u16str(canonical_route) || u16str(content_type) || u32bytes(exact_body))`.

Coordinator stores a closed `profile_mutation_operation` row keyed by `(account_id,operation_id)` containing exactly `version, operation, profile_id, mutation_request_digest, disposition, http_status, response_digest, response_body, created_at_unix_ms, terminal_at_unix_ms`; version is `relay-blind-profile-mutation-operation-v1`, disposition is `committed` or `rejected_no_commit`, and the response is the exact closed success document or v2 wire error emitted to the original caller. `response_digest = SHA256(ASCII("macprovider/relay-blind/profile-mutation-response/v1\x00") || uint16(http_status) || u32bytes(response_body))`. After authentication and closed-body validation, one `BEGIN IMMEDIATE` transaction first reserves the bounded operation row, then performs every profile/invitation/revocation/capacity check, commits the mutation and invitation consumption when valid and seals `committed`, or makes no profile/invitation/revocation change and seals `rejected_no_commit`. A revoke uses its profile's fixed account-local revoke operation/audit slot when the normal operation or audit cap is full and seals the same terminal operation record. A crash/storage rollback leaves neither row nor mutation. There is no durable `receiving` state. If SQLite or operation-row capacity prevents that first reservation, the server returns a transient unsealed unavailable response and performs no semantic mutation; the client remains `sent_or_unknown` and may only replay until a later attempt can reserve and seal an outcome. Such a transient response can never restore expected/absent local authority.

A matching replay returns the stored status/body byte-for-byte without revalidating expired activation windows, consuming an invitation again, advancing a revision/tombstone, or adding audit/economic effects. A changed method/route/body under the same operation ID returns `relay_blind_operation_replay_conflict`. Concurrent first delivery/replay serializes on the row and has one terminal outcome. Rows remain while their profile/invitation/revocation result is referenced and at least 38 days after terminal; rejected create rows without a resulting profile remain 38 days. After eligible pruning, create/replace activation evidence has already expired, while an exact revoke replay is still safe to execute as a new idempotent revoke against its expected revision/digest. The client retries exact bytes with bounded 1,2,4,8,15,30-second backoff and no parallel request until it receives the stored terminal response; it never treats GET/list, invitation consumption, 404, timeout, or local clock as absence authority.

### C3A. Durable locally confirmed profile authority and revocation freshness

The coordinator adds account-key-only `GET /v1/account/identity`, returning exactly `version: relay-blind-account-identity-v1` and a stable opaque 16-byte canonical base64url `account_subject`. It is scoped to the authenticated account, contains no email or credential material, and cannot create local profile trust. A client may use a server profile only when the committed local `stable_authority` payload matches `(origin, account_subject, profile_id, revision, profile_digest, state)` exactly, its externally anchored C8 head is current, and C3B preflight is fresh.

R6 retains the R5 closed discriminated union so a first create has a representable predecessor, and adds the executable replay authority below. Every record has exactly this envelope:

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
target_authority, target_public_authority_digest, request_method,
canonical_route, content_type, exact_request_body, mutation_request_digest,
started_at_unix_ms
```

`operation` is `create`, `replace`, or `revoke`; `request_disposition` is `not_sent` or `sent_or_unknown`. Request method/route/content type/body are the exact replay tuple above, and the digest must recompute before every attempt. `expected_authority` is a tagged closed union: an absent expectation is exactly `presence, absence_predecessor`, where `presence` is `absent` and `absence_predecessor` is literal `genesis` for the first local record or the digest of the current `absent_marker`; a present expectation is exactly `presence, authority`, where `presence` is `present` and `authority` is a byte-identical `stable_authority` payload. `target_authority` is a complete `stable_authority` payload. Create requires absent expected authority and target `active`, revision 1. Replace requires present active expected authority and a complete independently verified active successor at revision +1. Revoke requires present active expected authority and a revoked target with unchanged immutable revision/profile digest; before the server call its revocation generation/root remain the prior valid watermark, and after success the still-pending successor is advanced to the signed tombstone-bearing watermark before stable revoke.

An `absent_marker` payload contains exactly `abandoned_operation_id, abandoned_target_public_authority_digest, abandoned_at_unix_ms`. It is local negative authority, never a server profile and never usable for encryption. Only cancellation of a create whose disposition is still `not_sent` may append it. A later create names its digest as `absence_predecessor`; a server GET can never replace it or bootstrap trust.

`authorityframe`, `expectedauthorityframe`, and each payload frame follow the displayed field order. Strings use `u16str`; account/profile/bundle/invitation/operation IDs use decoded `b16`; digests/fingerprints/roots use decoded `b32`; revisions/times/generations use `uint64`; signed bundle uses `u32bytes`; arrays are counted. `expectedauthorityframe` begins `0x00 || (0x00 for genesis, else 0x01||b32(absence_predecessor))` for absent and `0x01 || authorityframe` for present. `payloadframe` begins `0x00`, `0x01`, or `0x02` for stable, pending, or absent. `record_digest = SHA256(ASCII("macprovider/relay-blind/confirmed-profile-record/v3\x00") || envelope_without_digest_mac_frame)` and `record_mac = HMAC-SHA256(profile_authority_key, decoded_record_digest)`. `target_public_authority_digest = SHA256(ASCII("macprovider/relay-blind/trust-profile-authority/v1\x00") || profile_digest_input_bytes_from_C3 || u16str(target_state))`. Shared Go/JavaScript vectors freeze every byte before runtime work.

Before every create, replace, or revoke HTTP request, the client appends and reads back the complete pending record and commits its C8 external head. Immediately before the request it appends/anchors `sent_or_unknown`. Create generation 1 therefore durably contains the complete locally verified target before invitation consumption or server mutation. A first-create cancellation is permitted only from `not_sent` and appends/anchors `absent_marker`; replace/revoke cancellation from `not_sent` appends/anchors the exact expected stable authority. At `sent_or_unknown`, cancellation, response loss, restart, or a concurrent process can only reconcile.

Recovery uses only the locally persisted verified target and exact replay tuple. From `sent_or_unknown`, the sole mutation recovery action is bounded byte-identical replay to the same method/route; the sealed operation response proves committed or rejected-no-commit. A committed authenticated response must equal every public authority-bearing target field and target digest; client-local confirmation time is retained unchanged, while server timestamps are syntax/monotonicity checks but not trust input. A sealed rejection appends the exact expected stable authority, or an absent marker for create, only when its request digest matches. On restart the client reverifies the stored bundle/signature/pins, replays as needed, performs C3B after committed success, and commits stable state only when the stored terminal response and fresh revocation evidence agree. GET/list and invitation state never prove absence. Conflicts, expired replay evidence, and mismatches remain disabled. Concurrent same-profile attempts serialize on C8 and coordinator operation/profile CAS; only one pending lineage may reach the network.

The Go library uses the single authority lock and external Keychain head in C8. Malibu uses one account/origin Web Lock plus the authenticated browser-head service in C8. The threat claim covers corruption, file/record/tail prefix rollback, pointer-only rollback, retained-old-generation rollback, record substitution, and server-visible profile/revocation rollback. Rollback, deletion, or authorized replacement of the non-synchronizable Keychain bootstrap/key/head items by the same logged-in user is outside the Go claim. Browser rollback is checked against the server head. Request records still never restore send ownership.

Each variant is at most 192 KiB. A create admission reserves bytes for pending-not-sent, pending-sent-or-unknown, stable-success, and absent cancellation before the first append. Existing per-active-profile 768 KiB revoke headroom reserves four worst-case revoke records and cannot be consumed by normal work. Normal content stops at 8 MiB; active generation remains capped at 40 MiB and physical old/new/checkpoint peak at 88 MiB. Stable current, pending, absent marker, and every externally anchored head remain until a checkpoint proves their successor. Revoked authority remains at least 8 days and until no server/recovery reference exists. Capacity, durability, or external-head failure occurs before server mutation and disables private mode.

Ordinary invitation, bundle, or signer validity-window expiry after activation does not erase confirmed authority; selected-pin expiry and explicit signer/bundle/profile/pin revocation disable it. Every new private transaction, including wallet-authenticated reservation, requires C3B under the credential split below. Cached/offline evidence is stale and cannot authorize reservation. Clearing either local authority disables affected profiles and does not revoke server state or authorize ciphertext reuse.

### C3B. Authenticated revocation synchronization

The signed empty revocation-log state is exact: `revocation_generation = 0` and `revocation_root_digest = base64url(SHA256(ASCII("macprovider/relay-blind/revocation-empty/v1\x00")))`. It is stored in the database singleton at migration, returned in a normally signed preflight on a fresh deployment, and is the only valid generation-zero root. The first tombstone is generation 1 with that empty root as predecessor; every later tombstone uses the immediately preceding committed root. There is no all-zero root sentinel.

The account-key-only public preflight is `POST /v1/relay-blind/revocation-preflight`. Its request contains exactly `version, challenge, reservation_auth_mode, wallet_session_id, profile_id, revision, profile_digest, state, signer_kid, bundle_id, bundle_revision, bundle_digest, selected_fingerprints, prior_generation, prior_root_digest`. `reservation_auth_mode` is `api_key` or `wallet_session`; `wallet_session_id` is the literal empty string only for API-key reservation and is the exact active wallet-session ID otherwise. The response echoes all request fields and then exactly `revocation_generation, revocation_root_digest, profile_revoked, signer_revoked, bundle_revoked, revoked_fingerprints, issued_at_unix, expires_at_unix, evidence_kid, signature`. Versions are `relay-blind-revocation-preflight-request-v2` and `relay-blind-revocation-preflight-v2`.

For wallet reservation, the supported client holds two separate credentials: an account API key used only for account identity/profile reads and this preflight, and the wallet bearer/signing key used only for the later wallet reservation/status routes. They are never placed together on one HTTP request. Preflight resolves the account API key, loads the named active wallet session, and requires its account to equal the API-key account and local `account_subject`; the signed response binds the exact wallet session. A missing account key, mismatched/revoked/expired wallet session, or changed wallet session after preflight disables new private work. Gateway reservation independently reauthenticates the wallet, and coordinator lifecycle rechecks profile/revocations. Malibu R6 supports account-key private mode only; wallet private mode is a Go library/CLI journey and its account-key prerequisite is stated before enablement.

The closed tombstone record is `version, generation, operation_id, kind, target_digest, created_at_unix, predecessor_root_digest, entry_digest`, version `relay-blind-revocation-tombstone-v1`. Target digests are domain-separated exact frames:

```text
signer:  SHA256(ASCII("macprovider/relay-blind/revocation-target/signer/v1\x00")  || b16(signer_kid))
bundle:  SHA256(ASCII("macprovider/relay-blind/revocation-target/bundle/v1\x00")  || b16(bundle_id) || uint64(bundle_revision) || b32(bundle_digest))
profile: SHA256(ASCII("macprovider/relay-blind/revocation-target/profile/v1\x00") || b16(account_subject) || b16(profile_id) || uint64(revision) || b32(profile_digest))
pin:     SHA256(ASCII("macprovider/relay-blind/revocation-target/pin/v1\x00")     || b32(fingerprint))
```

`entry_digest = SHA256(ASCII("macprovider/relay-blind/revocation-entry/v1\x00") || uint64(generation) || b16(operation_id) || u16str(kind) || b32(target_digest) || uint64(created_at_unix) || b32(predecessor_root_digest))`. The root is `SHA256(ASCII("macprovider/relay-blind/revocation-root/v1\x00") || uint64(generation) || b32(predecessor_root_digest) || b32(entry_digest))`. Tombstone row, singleton generation/root, the target's preallocated emergency slot or one normal slot, and audit commit in one SQLite transaction. Checkpoint/pruning follows C9 and never changes the current generation/root.

The revocation checkpoint is a closed object with fields in this exact order: `version, start_generation, end_generation, predecessor_root_digest, end_root_digest, first_entry_digest, last_entry_digest, row_count, created_at_unix, evidence_kid, checkpoint_digest, signature`; version is `relay-blind-revocation-checkpoint-v1`. All fields are present and non-null. Integers are `uint64`; digests are decoded `b32`; `evidence_kid` is `b16`; `row_count = end_generation - start_generation + 1`; and the first/last entry digests name those exact endpoint rows. `revocationcheckpointframe_without_digest_signature` follows the displayed order through `evidence_kid`. `checkpoint_digest = SHA256(ASCII("macprovider/relay-blind/revocation-checkpoint-digest/v1\x00") || revocationcheckpointframe_without_digest_signature)`. `signature = Ed25519-Sign(revocation_evidence_private_key[evidence_kid], ASCII("macprovider/relay-blind/revocation-checkpoint-signature/v1\x00") || b32(checkpoint_digest))`. The signing key is the dedicated C3B revocation-evidence key, must be active when the checkpoint is created, and its public key remains in the release-baked verification keyring until that checkpoint and every derived suffix have drained; bundle, provider, wallet, C6A, payout, and test keys cannot sign it. Key rollover changes only `evidence_kid` for a later checkpoint and never resigns or rewrites an existing checkpoint.

Checkpoint ranges are contiguous, nonoverlapping, and exactly 1,024 entries except the final checkpoint produced solely for an eligible pruning boundary. Pruning commits the verified checkpoint before removing its covered prefix. If a suffix remains, its first entry is generation `end_generation + 1` and names `end_root_digest` as predecessor. If the suffix is empty, the singleton generation/root must equal the checkpoint end generation/root. Restart verifies the checkpoint signature and digest, reconstructs every retained suffix entry, and compares the singleton. A missing, corrupt, wrong-key, rolled-back, overlapping, gapped, or singleton-inconsistent checkpoint disables revocation preflight and private admission; it never falls back to directory or row-count inference. Generation zero has no checkpoint and is represented only by the exact signed empty state above.

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

The Go root defaults to canonical macOS Application Support; overrides are absolute. Root-to-leaf `openat`/`O_NOFOLLOW` traversal, owner/mode/sticky checks, retained directory descriptors, link-count checks, and edge recapture remain mandatory. Under the retained private-root descriptor there is exactly one advisory lock pathname, `private.lock`, shared by the `requests` and `confirmed-profiles` authorities. Acquire and verify it before opening an authority descriptor or reading the corresponding Keychain items. The lock order is `directory descriptors -> private.lock -> authority descriptors/Keychain`; code holding it may do file and Keychain I/O but no HTTP, SQLite, callback, or browser work. HMAC keys are distinct non-synchronizable Keychain items with fixed service/account selectors; no HMAC key file exists in the private root. Nonblocking lock acquisition, including contention polling, has a five-second admission deadline. After acquisition, the process retains the lock until every started file/Keychain mutation has synchronously completed and its authoritative result has been read back; the five-second deadline becomes an alert and blocks new admission but never releases the lock around a possibly late noncancellable Security-framework operation.

Before load/append/fsync, every live immutable-object descriptor must equal its pathname and captured `(dev,ino)`; immutable objects use their final unique `O_EXCL|O_NOFOLLOW` name and are never renamed over another object. Only non-authoritative `CURRENT.tmp` is renamed over the `CURRENT` cache. Immediately before that cache rename, the old descriptor must equal `CURRENT`; afterward the old descriptor/path mismatch is expected, the reopened path must equal the captured temporary identity, and old close checks only its captured identity. Parent fsync follows cache rename and retirement. The lock descriptor equals `private.lock` at every boundary. Any other equality, replacement, link-count, or ownership result quarantines writes.

#### C8B. Externally anchored generations and compaction

File-backed authorities use immutable objects under each authority directory: `base.<generation-id>.jsonl`, `tail.<generation-id>.<tail-sequence>.jsonl`, `manifest.<generation-id>.json`, and `pointer.<pointer-generation>.json`. `CURRENT` is only a replaceable cache of the externally anchored pointer bytes; it is never authority. Names use lowercase hex generation IDs and canonical decimal sequences. A new immutable pointer is published for **every** append and compaction; a Keychain head never advances without naming that new pointer. A pointer contains exactly `version, authority, generation_id, prior_generation_id, manifest_digest, pointer_generation, prior_pointer_digest, tail_sequence, committed_tail_size, committed_tail_digest, committed_head_digest, external_head_generation, pointer_mac`, version `relay-blind-compaction-pointer-v3`. Genesis `prior_pointer_digest` is 32 all-zero bytes; later pointers name the exact prior externally anchored pointer digest. A manifest contains exactly `version, authority, generation_id, source_generation_id, source_manifest_digest, base_data_digest, base_size, base_record_count, checkpoint_digest, created_at_unix_ms, manifest_mac`, version `relay-blind-compaction-manifest-v1`. A tail object is never mutated after committed external-head publication; the next append writes one fresh full-copy tail containing the prior exact tail bytes plus one record. The current pointer, external head, and tail fields must agree byte-for-byte after every publication.

The first base line is a checkpoint containing exactly `version, authority, generation_id, source_generation_id, source_pointer_digest, source_manifest_digest, source_base_digest, source_tails, cutoff_record_digest, retained_heads, omitted_heads, created_at_unix_ms, checkpoint_digest, checkpoint_mac`, version `relay-blind-compaction-checkpoint-v2`. Each sorted `source_tails` entry is exactly `tail_sequence, tail_size, tail_digest, tail_record_count`. Each sorted retained head is exactly `key, logical_generation, original_head_digest, original_predecessor_digest, state_or_terminal_class, snapshot_authority_digest`; each sorted omitted head is exactly `key, original_head_digest, terminal_at_unix_ms, removal_reason`. Genesis source ID/digests use 16/32 all-zero bytes only in a generation-1 checkpoint. Snapshot records preserve logical generation, use predecessor tag `0x02||checkpoint_digest`, and become the subsequent per-key heads. Omission is allowed only for terminal keys past every retention/reference horizon.

Each Go authority has three non-synchronizable, this-device-only macOS Keychain generic-password items with application-specific access control: bootstrap, HMAC key, and external head. Their services are `macprovider.relay-blind.<authority>.bootstrap.v1`, `macprovider.relay-blind.<authority>.hmac.v1`, and `macprovider.relay-blind.<authority>.head.v1`; all use account `base64url(SHA256(ASCII("macprovider/relay-blind/keychain-account/v1\x00") || u16str(origin) || b16(account_subject)))`. The external-head value is exactly `version, authority, account_scope_digest, external_head_generation, prior_external_head_digest, pointer_generation, pointer_digest, generation_id, tail_sequence, committed_tail_size, committed_tail_digest, committed_head_digest, head_mac`, version `relay-blind-external-head-v2`. Genesis `prior_external_head_digest` is 32 all-zero bytes; later heads name `external_head_digest` of the prior exact head. `external_head_digest = SHA256(ASCII("macprovider/relay-blind/external-head-digest/v2\x00") || externalheadframe_including_head_mac)`. `external_head_generation` starts at 1 and advances exactly once with every pointer. `head_mac = HMAC-SHA256(authority_key, ASCII("macprovider/relay-blind/external-head/v2\x00") || externalheadframe_without_mac)`. Synchronizable/iCloud Keychain items are forbidden.

Fresh initialization is authorized only by a successful creation-only `SecItemAdd` of the exact bootstrap selector while, under `private.lock`, all three selectors were first queried, none existed, and the authority directory contained no recognized or unrecognized object. Directory emptiness alone is never fresh evidence. The bootstrap value is exactly `version, authority, account_scope_digest, bootstrap_id, state, genesis_pointer_digest, genesis_external_head_digest, bootstrap_mac`; version is `relay-blind-keychain-bootstrap-v1`, `bootstrap_id` is 16 CSPRNG bytes and also the lowercase-hex genesis generation ID, and `state` is `initializing` or `committed`. In `initializing`, both digests and `bootstrap_mac` are 32 all-zero bytes; this is the only unsigned state and is trusted solely as the creation-only, fixed-selector Keychain record within the stated same-user Keychain boundary. In `committed`, both digests are exact and `bootstrap_mac = HMAC-SHA256(authority_key, ASCII("macprovider/relay-blind/bootstrap/v1\x00") || bootstrapframe_without_mac)`. A duplicate item never restarts initialization.

Bootstrap then performs, in order: creation-only add/readback of the 32-byte HMAC item; write/fsync/reopen a generation-1 checkpoint line whose source IDs/digests, cutoff digest, and all arrays are the defined zero/empty genesis values; write/fsync/reopen the base containing exactly that line, the manifest, an empty tail sequence zero, and pointer generation 1; compute the pointer digest; creation-only add/readback of external head generation 1 naming those exact objects; update/readback the bootstrap value to `committed`; write/fsync `CURRENT`; then fsync the authority directory. Genesis committed head is the checkpoint digest, not an all-zero sentinel. Every object uses the normal closed schema and MAC. If bootstrap is `initializing`, recovery under the lock resumes the same `bootstrap_id`: it may create a missing HMAC only by creation-only add, removes and deterministically rebuilds partial files while no external head exists, validates an existing head and all named bytes before committing the bootstrap value, and otherwise quarantines. A committed bootstrap with any missing/mismatched item or named file quarantines. Files or HMAC/head items without the bootstrap item quarantine rather than becoming genesis. Collision, duplicate selector, wrong ACL, synchronizable item, unexpected file, or inconsistent partial state quarantines. Same-user deletion or authorized replacement of all Keychain discriminators remains outside the claim; with the bootstrap item intact, missing state never becomes fresh.

Under `private.lock`, append is: read/authenticate the committed bootstrap, HMAC item, current Keychain head, and its exact pointer/base/manifest/tail; require pointer/head equality for generation, pointer generation/digest, tail sequence/size/digest, committed head, and external generation; retire any already-safe predecessor objects before admitting another append; write/fsync/reopen the next full-copy immutable tail; write/fsync/reopen pointer generation +1 binding the prior pointer digest and prospective external generation; replace the Keychain head with generation +1 binding the prior external-head digest and new pointer/live-tail tuple; synchronously wait for the noncancellable call, read back the exact value, and only then update/fsync `CURRENT`. A failed or reported-late replacement is reconciled by exact readback while the lock remains held. Old head means delete/fsync the candidate tail/pointer and retain the old set; new head means the new pair is mandatory. Any other result quarantines. No network work is performed, and a deadline overrun alerts and leaves new admission blocked until completion/readback; it never releases the lock while a late Keychain mutation can advance authority.

After a new head readback and one complete successful load of the newly named set, retirement may unlink the immediately prior full-copy tail and pointer, then fsync the directory. Base/manifest objects remain while the current generation uses them. A retirement crash permits both old and new objects but the current Keychain head selects only new; restart validates new fully and finishes deletion before another append. Thus normal append peak is exactly one current full-copy tail plus one candidate full-copy tail and two small pointers; a third tail candidate is prohibited. Compaction similarly validates the entire current source, writes/fsyncs/reopens the new base/checkpoint/manifest/empty tail/new pointer, publishes/readbacks a new Keychain head with both prior digests, updates `CURRENT`, and retires the old generation only after one subsequent successful load. Restoring old `CURRENT`, pointer, complete generation, or a tail prefix disagrees with the Keychain tuple and quarantines. Publication crash vectors have only authenticated old-head/new-head outcomes; directory contents never select authority.

The browser uses the same logical record/checkpoint/pointer frames in IndexedDB and an account-key-authenticated opaque two-kind head ledger through Malibu's production-shaped `/api/mp` same-origin path. `authority_id` is 16 browser-CSPRNG bytes stored locally. An allocation transaction always preallocates both `confirmed_profiles` and `request_journal` rows; there is no valid one-kind active authority. Each row contains exactly `version, authority_id, authority_kind, origin_digest, head_generation, pointer_digest, committed_head_digest, state, updated_at_unix_ms`, version `relay-blind-browser-head-v1`; generation zero has both digests equal 32 all-zero bytes and state `active`. `origin_digest = SHA256(ASCII("macprovider/relay-blind/browser-origin/v1\x00") || u16str(origin) || b16(account_subject))`. The ledger stores no profile, provider, request, prompt, ciphertext, or key material.

The closed HTTP protocol is:

| Operation | Exact method/path | Exact request and success response |
|---|---|---|
| Paired allocation | `POST /v1/relay-blind/client-authority-heads` | Request `version, operation_id, authority_id, origin_digest`, version `relay-blind-browser-head-allocate-request-v1`. Response `version, operation_id, authority_id, heads`, version `relay-blind-browser-head-pair-v1`; `heads` is exactly two rows sorted `confirmed_profiles`, `request_journal`. |
| Per-kind read | `GET /v1/relay-blind/client-authority-heads/{authority_id}/{authority_kind}` | Empty body. Response is the exact `relay-blind-browser-head-v1` row. |
| Per-kind CAS | `PUT /v1/relay-blind/client-authority-heads/{authority_id}/{authority_kind}` | Request `version, operation_id, expected_head_generation, expected_pointer_digest, expected_committed_head_digest, new_pointer_digest, new_committed_head_digest`, version `relay-blind-browser-head-cas-request-v1`. Response `version, operation_id, head`, version `relay-blind-browser-head-cas-response-v1`. Success increments generation exactly once. |
| Recovery list | `GET /v1/relay-blind/client-authority-heads?cursor={cursor}&limit={limit}` | Empty body. Response `version, authorities, next_cursor`, version `relay-blind-browser-head-list-v1`; each sorted authority is `authority_id, origin_digest, state, kind_expectations, updated_at_unix_ms`, and each of the two sorted expectations is the tagged union `authority_kind, presence` plus the three head fields only when `presence: present`. `next_cursor` is canonical or null. |
| Atomic revoke/cleanup | `DELETE /v1/relay-blind/client-authority-heads/{authority_id}` | Request `version, operation_id, expected_origin_digest, kind_expectations`, version `relay-blind-browser-head-revoke-request-v1`, using the same exact two-kind presence union. Success is 204 with an empty body. |

All routes are account-key-only, `Cache-Control: no-store`, reject queries except the exact paginated list grammar, and use the C1 64 KiB body ceiling. Allocation and mutation operation IDs are byte-identical idempotency authorities retained eight days plus references: an identical replay returns the stored status/body, changed bytes conflict, and a lost response is reconciled by exact replay or GET/list. Cross-account and unknown identifiers return the same fixed 404 v2 tuple and timing bucket. Each account has 4,096 normal fixed 2 KiB allocation/CAS operation slots and allocation preassigns one disjoint fixed 2 KiB DELETE operation slot to each of its eight pairs. If a normal slot is unavailable, allocation/CAS performs no row/head mutation and returns transient unavailable; exact retry may proceed only after capacity drains. DELETE never depends on normal operation capacity. Allocation reserves both head rows and the fixed DELETE slot before response. CAS validates account, origin, active state, kind, operation replay, and exact prior triple in one transaction. Generation-zero CAS uses expected zero/zero/zero; no later CAS may use zero.

Each retained browser operation row contains exactly `version, account_subject, operation_id, method, canonical_route, request_digest, disposition, http_status, response_digest, response_body, terminal_at_unix_ms`, version `relay-blind-browser-head-operation-v1`; disposition is `committed` or `rejected_no_commit`. `request_digest = SHA256(ASCII("macprovider/relay-blind/browser-head-request/v1\x00") || u16str(method) || u16str(canonical_route) || u32bytes(exact_body))`; GET/list have no operation row. `response_digest = SHA256(ASCII("macprovider/relay-blind/browser-head-response/v1\x00") || uint16(http_status) || u32bytes(response_body))`, including an empty byte string for 204. The operation row and paired allocation, one-kind CAS, or atomic pair revoke/cleanup seal in one transaction; a rollback leaves neither. The fixed DELETE row is bound to the pair at allocation and may be sealed only by that pair's exact DELETE route.

Normal storage can never create an absent kind. Migration/startup marks a legacy or fault-injected one-kind pair `incomplete`; it cannot GET/CAS or authorize private mode. List exposes only the tagged absent expectation. DELETE validates both expectations atomically, changes the present row to revoked, materializes the absent kind directly as a generation-zero revoked sentinel from the allocation's pre-reserved row, and returns 204. Both-absent is unknown and cannot create an authority. A normal two-kind DELETE atomically revokes both. Revoked pairs reject CAS, remain eight days plus every request/profile recovery reference, then prune together with their operation rows. There are at most 8 allocated pair IDs per account; incomplete and revoked-but-retained pairs count. A ninth remains disabled until explicit cleanup and reference drain; the service never evicts a live pair.

A browser transition under the account/origin Web Lock first commits a `prepared` IndexedDB generation containing the complete successor and prior server-head tuple, then performs the server CAS, then reads GET if the CAS response is lost, and finally marks the matching local generation committed. Before any profile mutation or inference fetch, local committed bytes and fresh server head must match. If CAS did not commit, the prepared generation is discarded. If CAS committed but local bytes are missing/corrupt after restart, private mode remains disabled; server head never supplies content. Concurrent tabs/devices cannot advance one authority ID from the same predecessor twice. Clearing IndexedDB loses the authority ID/key and cannot reacquire trust from the ledger. Browser offline/head-ledger outage blocks private transitions.

Checkpoint/manifest/pointer/head/bootstrap/browser framing is binary exact displayed order: strings use `u16str`, IDs/keys use `b16`, digests use `b32`, sizes/counts/generations/times use `uint64`, tagged presence uses one byte, and arrays use `uint32(count)`. File digests hash exact bytes including newlines. `checkpoint_digest = SHA256(ASCII("macprovider/relay-blind/compaction-checkpoint/v2\x00") || checkpointframe_without_digest_mac)` and its MAC is HMAC over the decoded digest. `manifest_digest = SHA256(ASCII("macprovider/relay-blind/compaction-manifest/v1\x00") || manifestframe_without_mac)` and `manifest_mac` is HMAC over that decoded digest. `pointer_mac = HMAC-SHA256(authority_key, ASCII("macprovider/relay-blind/compaction-pointer/v3\x00") || pointerframe_without_mac)`. Shared vectors freeze Go/JavaScript bytes, including accepted genesis, first append, second append after retirement, compaction, browser pair allocation/CAS/list/revoke, and absent-kind cleanup. Unknown fields, unsorted/duplicate heads, sequence gaps, count/length mismatch, old head, pointer/head mismatch, prior-digest disagreement, or source/root disagreement quarantines.

Go request records remain at most 4 KiB, 4,096 current transactions, 16 MiB active and 40 MiB physical. Confirmed profiles retain the C3A 40 MiB active/88 MiB physical bounds. Browser request records are at most 2 KiB, 128 transactions, 262,144 active bytes and 768 KiB IndexedDB physical reserve. Terminal retention is 691,200 seconds. Compaction reserves complete new objects and external-head capacity before starting. At capacity new work stops before network while status and preallocated revocation remain available.

The browser uses dedicated IndexedDB stores and account/origin Web Locks. No lease takeover exists. Missing APIs, abort/quota/blocked upgrade, key loss, corrupt or rolled-back bytes, ledger mismatch/unavailability, failed CAS/readback, or capacity failure prevents sends. Two tabs/double clicks yield one committed head and at most one live sender. Neither implementation stores prompt/messages/tools/response, ciphertext, ephemeral private key, bearer/wallet key, raw provider/buyer binding, provider/session identity, local path, raw server body, or raw/unsalted request digest. Plaintext browser history remains separate and disclosed.

### C9. Capacity, retention, and fail-closed configuration

Logical bounds are exact:

| Item | Bound / retention and reachable construction |
|---|---|
| Bundle keyring/storage | 8 trusted signer keys; 4,096 bundle revisions and 64 MiB public bytes globally |
| Profiles | 32 IDs/account; at most 1,024 accounts with Build 2 profile authority and therefore 32,768 independently revocable live profile IDs globally; 64 immutable revisions/profile, bounded further by 32,768 revision rows/256 MiB canonical globally; 2,048 successful create/replace heads/account only while the global cap remains |
| Invitations | 2,048 rows/4 MiB/account and 65,536 rows/128 MiB globally; 128 live/account; consume updates in place |
| Normal mutation operations/audits | 4,096 terminal operation rows/4 MiB and 2,048 committed audit rows/2 MiB per account, further bounded by 65,536 operation rows/64 MiB and 65,536 audit rows/64 MiB globally; every authenticated closed request that reaches semantic validation reserves one <=1 KiB terminal-disposition row; only committed mutations add audit rows |
| Preallocated revoke authority | Profile create allocates one fixed 1 KiB revoke-operation and one fixed 1 KiB revoke-audit slot; 32 each/account; revoke overwrites them without allocation/growth |
| Recovery quarantine | 24 fixed 1 KiB slots/account, disjoint from revoke slots and reused by recovery key |
| Reservations/recovery | 512 live reservations/account, 128/profile, 32,768 globally; gateway 1,000 admission joins plus 24 preallocated quarantine rows |
| Wallet status | 4,096 rows/2 MiB/session, 16,384 rows/8 MiB/account, and 262,144 rows/128 MiB globally; 512 bytes/row; existing rows update in place |
| Browser head ledger | 8 authority IDs/account and 8,192 pair IDs globally, two 512-byte kind rows/ID; 4,096 fixed 2 KiB normal operation slots/account but 65,536/128 MiB globally, plus one fixed 2 KiB DELETE slot/pair; pair allocation reserves both rows plus DELETE capacity; existing head CAS updates in place |
| Revocable live targets | 8 active bundle signers, 4,096 stored bundle revisions, 32,768 live profile IDs, and 8,192 unique active selected-pin fingerprints; total 45,064 independently revocable targets |
| Local stores | C3A profile: 8 MiB normal + 768 KiB/active-profile revoke reserve, 40 MiB active/88 MiB physical. Go journal: 4,096/16 MiB active/40 MiB physical/4 KiB. Browser journal: 128/256 KiB active/768 KiB physical/2 KiB. |
| Other | 16 pins/models/revision; one endpoint; 64 KiB request; 60 mutations and 120 reads/status/account/minute; 16 providers/3 pool rounds; pin 30 days; bundle/invitation 24 hours; evidence 8 days |

The global revocation authority preallocates 65,536 fixed 1 KiB normal tombstone slots and one fixed 1 KiB emergency tombstone slot plus audit/index margin for every reachable live target: 8 signer, 4,096 bundle, 32,768 profile, and 8,192 pin slots, exactly 45,064 emergency slots and 110,600 tombstone slots total. Slot identity is physical only; logical ordering is always the committed global generation. Normal operator issuance/revocation is capped at 64 committed tombstones per rolling hour and uses the next free normal slot. At normal saturation, revocation of a live target seals that target's already allocated emergency slot with the next generation in the same singleton/tombstone/audit transaction and therefore requires no row, index-key, or blob growth. A sealed emergency slot becomes historical evidence and is never reused until its 38-day/reference horizon drains and pruning retires it; target activation remains blocked until a free emergency slot can be allocated again.

The reachability inequalities are startup and transaction invariants: `active_signers <= 8`, `stored_bundle_revisions <= 4096`, `accounts_with_profile_authority <= 1024`, `live_profile_ids <= 32 * accounts_with_profile_authority <= 32768`, `unique_pin_fingerprints_referenced_by_stored_bundles <= 8192`, and `allocated_unsealed_emergency_slots = active_signers + stored_bundle_revisions + live_profile_ids + unique_stored_pin_fingerprints <= 45064`. Signer activation, bundle-revision insertion, first creation of a live profile ID, and first stored-bundle reference to a unique pin atomically allocate their typed emergency slot before making the target reachable. A bundle upload that would exceed the unique-pin cap fails before publication. Profile replacement updates the existing profile slot's bound target digest in the same transaction that retires the prior revision and activates the successor; it never creates a second live profile target. Pin slots are reference-counted over stored bundles and active/reference-retained profiles and release only after the final bundle/profile/reference horizon drains. No cap is inferred per process or per account.

Every 1,024 committed tombstones writes the exact C3B Ed25519 checkpoint. At most 128 checkpoint rows and 8 MiB checkpoint/audit canonical bytes are retained. Pruning deletes only a contiguous prefix covered by a verified checkpoint after all reference/horizon conditions clear; the singleton current generation/root never changes. At full normal saturation, every one of the maximum 45,064 live targets can be revoked serially from its own reserve. A missing/unsealed slot is an invariant breach that disables related activation and private admission and alerts, but never turns an already reachable target's revoke into a capacity error; startup refuses enabled mode unless all live targets and slots form a bijection. Tombstones and checkpoint/audit evidence remain at least 38 days and longer while referenced by a profile, invitation, reservation, client watermark, recovery row, signer overlap, or evidence horizon.

The accepted-event charge table is closed: signer activation allocates its emergency slot; bundle upload adds one bounded bundle row/audit and allocates its bundle slot; invitation issue adds <=2 KiB and consumes no revocation slot; invitation consume updates; each authenticated closed profile mutation that reaches semantic validation reserves one terminal operation row; profile create additionally adds one revision/audit, both account-local fixed revoke slots, one profile emergency slot, and any newly active unique-pin slots, plus browser-head capacity preflight when applicable; replace adds one revision/audit, retargets the profile slot, adjusts pin reference/slot charges, and cannot publish until every successor slot exists; revoke updates profile plus fixed account-local slots and seals its global profile emergency slot when normal capacity is unavailable; each signer/bundle/pin revoke likewise seals the matching target slot when needed. Reads/preflight add no rows; recovery/status transitions update their reserved row. Authentication/body-validation rejection and operation-row/storage unavailability add no retained row and cannot produce a sealed no-commit disposition; semantic/CAS/rate/capacity rejection after operation reservation seals that row but adds no mutation audit. A new retained event class reopens the plan gate.

All Build 2 SQLite databases must report `page_size=4096`, `journal_mode=WAL`, `synchronous=FULL`, `foreign_keys=ON`, `wal_autocheckpoint=1000`, and `busy_timeout<=5000`; enabled startup rejects any mismatch. The reviewed physical increments, including table/index B-trees and freelist exclusion, are:

| Database partition | Build 2 live-page ceiling | One-transaction new-page reserve | WAL frame ceiling | Required feature free-disk reserve |
|---|---:|---:|---:|---:|
| Coordinator relay-blind authority/reservations | 262,144 pages (1 GiB), including all 110,600 fixed tombstone slots and 128 checkpoints | 4,096 pages (16 MiB) | 8,192 frames plus WAL headers/checksums (<34 MiB) | 1,126 MiB |
| Gateway recovery/wallet/head ledger | 131,072 pages (512 MiB) | 2,048 pages (8 MiB) | 4,096 frames plus headers/checksums (<17 MiB) | 561 MiB |

The feature page ceiling is measured from a migration-recorded `feature_baseline_page_count` and counts `max(0, page_count - freelist_count - baseline_nonfeature_pages)`; pages cannot be double-credited to another quota. Startup and every admitting transaction require `max_page_count - (page_count - freelist_count)` to cover the applicable remaining live-page ceiling plus transaction reserve, and filesystem free bytes to cover the table value. WAL above its ceiling disables new admission until a successful FULL checkpoint; checkpoint failure preserves revoke/emergency operations only when their pre-reserved page and disk margins remain. The coordinator `max_page_count` must be at least baseline plus 266,240 pages; gateway at least baseline plus 133,120. A lower observed B-tree/page reserve, larger row, or WAL growth fails the sizing test and reopens the plan gate; thresholds cannot be relaxed from implementation observations.

Slice 2 supplies exact DDL/indexes and a deterministic size fixture that reaches every logical maximum through public/internal supported APIs, runs `dbstat`, `page_count`, `freelist_count`, WAL-frame inspection, VACUUM/checkpoint/restart, and records worst observed page and transaction deltas on the supported SQLite build. Runtime storage implementation after Slice 2 is prohibited until a fresh independent plan amendment incorporates the DDL/measurement digest and confirms observations fit the frozen ceilings. This extra gate may tighten limits; it may not claim a pass from payload arithmetic or enlarge thresholds without review.

The healthy recovery scheduler has `N=1000`, batch `B=100`, workers `W=20`, per-call ceiling `L=2s`, claim transaction `C=3s`, aggregate result transaction `R=3s`, per-pass bound `P=18s`, and interpass delay `I=10s`. The last row first-call bound is exactly `floor((N-1)/B)*(P+I) + C + floor(((N-1) mod B)/W)*L = 9*28 + 3 + 4*2 = 263s`. The general formula is evaluated at startup with checked safe-integer arithmetic; non-divisible shapes use the same zero-based wave index. `P` includes claim, all network waves, aggregate persistence, and bounded overhead, while the final-row wave term identifies its start within the final pass. The 300-second go/no-go and 8-day evidence inequality use 263 seconds. Fault/restart recovery is bounded and reported separately, never folded into the healthy claim.

Pruning is indexed, bounded, oldest eligible first, and never deletes active profiles, live invitations, pending/absent local lineage, nonterminal requests, request fences, unsealed economic effects, referenced evidence, or revocation continuity. Enabled startup validates every capacity, physical, scheduler, and retention inequality. Invalid configuration disables private mode while plaintext startup and safe status remain.

## 6. Typed wire errors and client recovery reducer

Servers emit only the closed wire object `version, code, http_status, phase, retryable, message`, version `relay-blind-wire-error-v2`. A server never emits `action` and never claims knowledge of the client's journal fence. `http_status` is the actual nonzero response status. Coordinator/gateway fixtures own this tuple.

Clients produce a separate closed effective object `version, code, origin, http_status, phase, retryable, fence_class, action, message`, version `relay-blind-effective-error-v2`. `origin` is `client`, `gateway`, or `coordinator`; a local client error has status `0`, while a verified wire error retains its server status. `fence_class` is `before_send_fence` or `at_or_after_send_fence` and comes only from the authenticated local journal. The client reducer looks up the verified `(origin,code,http_status,phase,retryable)` row, applies the corresponding before/after column below, and emits `action`. A server-supplied action field is an unknown-field error. Missing/unknown/malformed/status-mismatched wire errors reduce to `relay_blind_unknown`; at/after fence they cannot authorize new work.

`phase` is exactly `bootstrap`, `profile`, `reservation`, `encryption`, `journal`, `admission`, `dispatch`, `status`, `settlement`, or `unknown`. Effective `action` is exactly `provision_profile`, `confirm_profile`, `replace_profile`, `complete_or_revoke_pending_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, `repair_local_state`, or `none`. `message` is printable public text of at most 512 bytes and never changes semantics. A server status/code/phase/retryable tuple is accepted only when it equals the manifest row; adapters do not preserve a legacy tuple while renaming only its code.

In the table, HTTP is the server value for gateway/coordinator origins. For mixed client/server rows, a locally synthesized instance uses status `0`; the named server origins use the listed status. `any` means client `0` or server `500`. Slice 1 emits distinct machine-readable `wire-errors-v2` and `client-reducer-v2` tuple manifests; server packages consume only the first and Go/Malibu consume both. Slice 2 adds the exact emission inventory after stable labels exist. The following rows are the complete Build 2 tuple inventory:

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

`wire-errors-v2` carries a required `emission_inventory` array. Each row contains exactly `emission_key, repository, commit, path, enclosing_function, stable_callsite_label, legacy_code, route_method, v2_code, http_status, phase, retryable, action_before_send_fence, action_at_or_after_send_fence`. `emission_key` is lowercase hex SHA-256 of `ASCII("macprovider/relay-blind/error-emission-key/v1\x00") || u16str(repository) || u16str(commit_lowercase_hex) || u16str(path) || u16str(enclosing_function) || u16str(stable_callsite_label) || u16str(legacy_code) || u16str(route_method)`. `route_method` is one exact `METHOD SP PATH` value; a helper reachable from two routes expands to two rows. `stable_callsite_label` is a source constant at the emission branch, never a line number or message. The complete replacement tuple/actions must equal one primary-table row; no inheritance or context-dependent blank is allowed.

The pinned-base scanner currently selects exactly 87 direct gateway emitters: 40 in `phase5-gateway/internal/router/relay_blind.go`, 22 in `relay_blind_success.go`, and 25 in the three reachable wallet helpers `requireWalletSessionBearer`, `requireWalletSessionSignature`, and `writeWalletAdmissionError`; three are dynamic writer branches and must expand into their finite returned-code/route rows. It separately selects every `writeRelayBlindError` branch reachable from coordinator reserve/consume/status and every planned profile, invitation, preflight, head-ledger, status, Go-client, and Malibu-client emitter. It traverses the pinned call graph from exact Build 2 methods/routes, so unrelated wallet-management or plaintext-only emissions are explicitly out of scope and a newly reachable branch is a hard failure.

The exact generated rows do not exist in the historical source because stable callsite constants and the new routes are planned changes. Therefore the sizing checkpoint is also a mandatory **error-inventory gate**: it must include every expanded row in a durable `error-emission-inventory-v2.json`, the scanner version and command, both exact source commits, selected/expanded counts by repository/path/function/route, and the artifact SHA-256. The fresh independent reviewer receives the full JSON bytes, not a summary, and must report zero missing, duplicate, ambiguous, stale, unexpanded-dynamic, tuple-mismatched, or out-of-scope-yet-reachable sites. No server/client error adapter, route emitter, reducer, or error-facing Malibu implementation may begin before that digest passes the second zero-C/H/M gate. Afterward CI regenerates and byte-compares the inventory; runtime lookup is by the reviewed callsite constant and exact route, never regex/message. Malformed peer response is the only default and always becomes unknown.

`relay_blind_emergency_capacity_exhausted` is retained only for imported pre-R6 schema/invariant-breach compatibility; an R6 revoke path cannot emit it for logical capacity because every reachable live target owns a slot. The inventory generator scans pinned coordinator/gateway exported error constants and SPEC-041 rows and fails on an unmapped emitted code. Auth, wallet, quota, cancellation and transport adapters likewise require explicit rows; no regex/default mapping except malformed-to-unknown is permitted. Pairwise precedence fixtures run against the reducer, not server packages.

### C10. Isolated HTTPS real-browser harness

Pinned Malibu `dc7f425ba7d50c86467f31a82f419df6a0904b13` sets `/api/mp` in `server.proxy` to `https://api.streamvc.live`; pinned Vite 8.0.16 resolves preview proxy as `preview.proxy ?? server.proxy`. Therefore `vite preview` is forbidden for private browser acceptance. R6 retains the test-only Node-built-in HTTPS server that serves the built `dist` tree and implements the production path contract exactly: same-origin `/api/mp/*` is reverse-proxied to one explicit local gateway fixture with the `/api/mp` prefix removed. `/auth` and `/account` are either disabled or separately bound to explicit loopback fixtures. No production hostname is a default or fallback.

The command is `node scripts/private-request-browser-tests.mjs --browser safari|chrome --base-url https://127.0.0.1:<ephemeral> --gateway-url https://127.0.0.1:<ephemeral> --ca-file <owned-test-ca>`. `npm run test:private-browser` invokes both. The runner generates an ephemeral CA/leaf certificate outside the repository with SANs only for `127.0.0.1` and `localhost`, mode 0600, records public certificate fingerprints only, and deletes private material after the run. The gateway/coordinator fixtures use distinct leaf identities under the same test CA. The test server parses every upstream URL before listen and accepts only `https`, no credentials/query/fragment, and literal `127.0.0.1`, `[::1]`, or `localhost`; it resolves before each connection, verifies the connected peer is loopback, pins the test CA/expected hostname, rejects redirects, and has no environment-variable fallback. A non-loopback address, production suffix, DNS rebinding, plaintext upstream, TLS skip, or redirect makes startup/test fail before credentials are loaded. A guard test supplies `api.streamvc.live`, `api.malibu.tech`, `coordinator.streamvc.live`, public IPs, and redirect responses and proves zero outbound socket attempts.

The page's canonical origin is the trusted HTTPS base URL, satisfying C3A without an HTTP-loopback exception. Chrome starts only as a child with `--user-data-dir=<0700 private temp>` and trusts only the ephemeral leaf SPKI for that process. Safari runs under a provisioned disposable macOS test user or VM with a temporary isolated login keychain containing the test CA; the harness verifies current UID/home/keychain and refuses the run otherwise. Certificate install/removal, browser data, test credentials, fixture databases, and logs are isolated and deleted. Production-origin smoke remains a separate read-only test and never performs profile mutation/inference.

Safari uses W3C WebDriver over the disposable user's child `safaridriver`; Chrome uses child Chrome plus CDP through Node `fetch`/`WebSocket`. No npm dependency is added. Chrome tab cuts close only owned targets; process cuts terminate only its recorded child process group. Safari tab/session cuts use owned WebDriver windows/sessions. A Safari browser-process crash is acceptance evidence only when the disposable user/VM owns every Safari process and the harness terminates that owned process group. Without that environment, the process-crash case is explicitly `BLOCKED`, while tab/session/reload evidence may pass; WebDriver session deletion is never reported as a browser-process crash.

Two-tab barriers, reload, window close, driver/session termination, owned browser termination, IndexedDB faults, external-head CAS loss, and Web Lock races use test-only same-origin hooks compiled out of production. The local fixture uses isolated non-billable test credentials and asserts its configured account IDs cannot exist in production. Network capture proves all `/api/mp` connections terminate at the loopback test server and all proxy connections at the loopback gateway fixture. Artifacts contain only versions, certificate public fingerprints, endpoints with ephemeral ports, test IDs, states, counts, timings, and redacted metadata. Headers, credentials, prompts, ciphertext, response bodies, private certificate bytes, and device/user identifiers are forbidden. Zero selected cases fails.

## 7. Implementation slices

1. **Governance and vectors:** update SPEC-041, SPEC-006, SPEC-040, AUTHORITY, CONFORMANCE, and shared fixtures with C1-C10/C3A-C3B/C6A, exact nullability, local-record schemas, external heads, separate wire/reducer errors, revocation evidence, mixed-version rules, and non-claims.
2. **Sizing and exact error-inventory checkpoint only:** add the exact proposed coordinator/gateway DDL and indexes, deterministic SQLite capacity measurement harness, stable callsite labels, and the complete generated `error-emission-inventory-v2.json`. Run the measurement and source scan to produce digest-bound physical and inventory reports. No route/runtime storage, error adapter/reducer/emitter, or Malibu error implementation is allowed in this slice. Submit every row and both report digests to a fresh independent zero-C/H/M gate.
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

Run targeted contract/storage/selection/recovery/client/browser tests first, then full coordinator/gateway/integration/Swift/Malibu checks from `test-spec-r6.md`. Review each complete repository diff through independent GPT-5.6 Sol code, security, architecture, and applicable browser/product lanes. Critical, High, and Medium findings must all be zero before a slice is complete.

The handoff separately records implementation/PR references, fixture evidence, browser evidence, actual MLX evidence, deployed/production status, hardware/operator/signing blockers, skipped/timed-out/zero-selected runs, and per-repository cumulative versus dependent diffs. It confirms the provider-plaintext boundary, response relay visibility, no ciphertext failover, and verified-model/reward exclusions.
