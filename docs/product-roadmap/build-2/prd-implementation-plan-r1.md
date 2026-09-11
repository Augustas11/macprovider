# Product Build 2 PRD and implementation plan

**Plan revision:** R1
**Status:** draft; implementation prohibited until an independent GPT-5.6 Sol adversarial review reports zero Critical, High, and Medium findings for this exact revision and its paired test specification
**Paired test specification:** `test-spec-r1.md`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu buyer-app inspection base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`
**Baseline assessment:** `baseline-assessment.md`

## 1. Product outcome

An authenticated buyer can approve one or more provider relay-blind identities, create a reservation that the coordinator selects only from that approved set before encryption, and send nonstreaming or streaming encrypted requests through a supported CLI/library and the Malibu buyer console. The provider receives plaintext. Gateway and coordinator relays receive request ciphertext and routing metadata; they still receive the provider response and may see request content echoed in that response. This build does not provide confidential compute, provider-private execution, anonymity, unlinkability, response encryption, or proof that a provider did not retain plaintext.

The product must never trade safety for availability. A buyer trust profile is an additional restriction over the existing operator-pinned provider identity, live authenticated provider session, model, key, admission, quota, and settlement checks. Buyer approval alone cannot admit a provider, authorize a model, establish pricing, produce a verified-model receipt, or enable rewards. Existing ciphertext is permanently bound to its reservation/provider/session/key and is never retried or failed over.

## 2. Users and journeys

### J1. Provision a trust profile

1. An invited buyer receives one or more public relay-blind pin records through an authenticated channel and independently confirms their displayed fingerprints.
2. The supported CLI or Malibu console validates the closed records, file/browser integrity constraints, time windows, model scopes, endpoint scope, uniqueness, and canonical order before any mutation.
3. Using a normal account API key, the client creates an account-owned trust profile with a client-generated operation ID. Demo credentials cannot create profiles. Wallet sessions cannot mutate account trust in this build.
4. The coordinator validates every public key/fingerprint against its independent operator provider-identity map, stores an immutable revision and active pointer, and returns the exact profile ID, revision, and digest. It never returns provider IDs or assigned-session IDs.
5. The client persists only the public bundle and safe recovery metadata. It shows the provider-plaintext and relay-visible-response boundary before enabling request encryption.

### J2. Make an encrypted request with A-only approval

1. The client chooses an active local/server-matching trust profile and sends the existing closed six-field reservation body plus its exact profile ID, revision, and digest in dedicated single-value headers.
2. Gateway authenticates the account, rejects demo/ambiguous headers, canonicalizes the profile reference, strips any internal authority headers, and forwards the authenticated account plus profile reference to the coordinator.
3. In one coordinator write transaction, the reservation path loads the current active profile, verifies exact revision/digest/time/model/endpoint scope, filters the current serving WebSocket candidates by approved relay-blind identity, validates a fresh non-revoked provider key record, selects from only those candidates, and inserts the bound reservation. If B sorts before A but only A is approved, B is never selected.
4. The client verifies the returned signed key record against the exact local profile revision and selected pin before generating an ephemeral key, nonce, request ID, or ciphertext.
5. The existing consume, quota, exact-session opaque dispatch, provider claim/decrypt/validation, usage settlement, and truthful disclosure paths run. Consume and dispatch recheck the trust-profile revision/state and selected fingerprint.

### J3. Use an A+B profile

The same flow admits either A or B according to the existing stable eligible-provider ordering after filtering. The response does not disclose a stable provider ID; it exposes only the selected public identity fingerprint already present in the signed key record and the buyer-owned profile reference. A fresh reservation may choose another currently approved provider. An already-created envelope never moves.

### J4. Replace or revoke trust

1. Replacement uses an atomic compare-and-swap against the current revision/digest and requires a fresh unique operation ID.
2. The coordinator writes the new immutable revision, advances the active pointer, and rejects every old-profile `reserved` or `consumed_predispatch` reservation in the same transaction.
3. Revocation writes a retained tombstone and performs the same predispatch invalidation. `dispatched`, `terminal`, and `unknown_postdispatch` rows are never made replayable and are not rewritten as though exposure did not occur.
4. A stale client gets a typed profile error before encryption. A client that already encrypted but has not consumed receives a burned/stale-key result and must create a wholly new transaction only after loading the replacement profile.

### J5. Cancel, disconnect, or recover

The client durably records a redacted transaction journal after envelope construction and before network send. Cancellation stops the local request and never resends ciphertext. The public authenticated status API accepts only the provider-binding digest and envelope digest, dispatches nothing, and reports the existing coordinator state plus safe action. `dispatched`, `terminal`, and `unknown_postdispatch` always mean `do_not_resubmit`; terminal status does not reconstruct lost output. An expired or rejected predispatch transaction may permit a wholly new reservation/envelope. A fresh `reserved` or `consumed_predispatch` transaction remains held until fenced; it is not resent.

### J6. Malibu browser journey

The Malibu console exposes a clearly labeled **Request encryption** mode only to authenticated API-key users with a valid trust profile and supported secure-context Web Crypto primitives. The copy states: “Malibu relays do not receive this request in plaintext. The selected provider decrypts and can read it. The response travels back through Malibu and may reveal request content. This browser also stores your conversation locally.” Unsupported crypto, stale profiles, missing account auth, agent/tool mode, or API capability mismatch disables the mode without plaintext fallback.

The private transport is separate from `console/api.js::fetchChatCompletions`, whose ordinary path intentionally retries selected 502/503 responses. Each encrypted envelope is sent at most once. Abort or network loss moves the UI to status/recovery, never ordinary retry.

## 3. Ownership and trust boundaries

| Boundary | Authority and required behavior |
|---|---|
| Provider network admission | Existing SPEC-003/operator/provider-session authority. A buyer profile only narrows candidates. |
| Provider relay-blind identity | Existing coordinator operator mapping in `relayblind.Authority`; profile provisioning must match it. Duplicate public identity mappings across provider IDs are rejected in profile-required mode. |
| Buyer account authentication | Gateway API-key auth owns account identity. Demo tokens cannot provision or use supported trust profiles. Existing signed wallet sessions may use an already-provisioned profile only after their semantic signature includes the exact profile reference headers; they cannot mutate profiles. |
| Buyer approval | Coordinator relay-blind SQLite owns durable account/profile revisions, pins, operation replay, and revocation tombstones. Client local state must match the server revision/digest. |
| Provider selection | Coordinator buyer server owns the atomic acceptable-identity filter and reservation insert. Gateway and client never nominate a provider ID. |
| Encryption | Buyer client/browser owns plaintext and encryption. Gateway/coordinator must not receive plaintext request fields. |
| Decryption and inference | Exact reserved Swift provider session owns decryption, validation, runtime pin, and inference. The provider sees plaintext. |
| Response | Existing gateway/coordinator paths remain response-visible. UI and docs disclose this. |
| Settlement | Existing SPEC-005 usage settlement remains authoritative. SPEC-022 verified-model settlement and positive verified-work rewards remain excluded for relay-blind work. |
| Browser storage | Malibu origin owns local public profile bundles, chat history, and redacted recovery state. It stores no provider private key, buyer API key beyond the existing credential behavior, or plaintext in new recovery records. |

## 4. Dependency graph

```text
SPEC-041 / SPEC-006 / SPEC-040 contract amendments
        |
        +--> coordinator trust-profile schema + authority validation
        |       |
        |       +--> atomic approved-candidate reservation
        |       +--> consume/dispatch lifecycle rechecks
        |       +--> public-safe status data
        |
        +--> gateway authenticated profile CRUD proxy
        |       +--> public status proxy
        |       +--> wallet semantic-header binding
        |
        +--> shared vectors and exported Go buyer library
                +--> supported CLI and local journal
                +--> two-provider deterministic integration
                +--> Malibu browser module and UI (dependent repository/PR)
                        +--> real-browser journey

real cached MLX artifact + physical Apple Silicon Mac
        +--> one complete encrypted MLX acceptance journey
```

The MacProvider API/contract PR is a prerequisite for the Malibu application PR. If it is unmerged, the Malibu work uses an explicitly documented dependent branch and reports its per-repository diff separately. Build 1 is not a prerequisite if an already-supported, locally cached MLX catalog artifact is used; no download is introduced here.

## 5. Normative contract changes

### C1. Supported trust profile

Amend SPEC-041 and its SPEC-006/SPEC-040 mappings before runtime changes. Define a closed `relay-blind-trust-profile-v1` object:

- `version`, `profile_id`, `revision`, `profile_digest`, `state`, `pins`, `created_at_unix`, `updated_at_unix`.
- `profile_id` is 128 bits of client CSPRNG encoded as canonical unpadded base64url; it is globally non-secret and account-scoped in authority.
- `revision` starts at 1 and increments exactly by one. Revision zero exists only as the create CAS sentinel.
- `pins` contains 1..16 closed existing `relay-blind-pilot-pin-v1` public pins, sorted by fingerprint, with unique fingerprints and exact model/endpoint scopes. Active profiles reject pins marked `revoked`, expired pins, duplicate public keys/fingerprints, overlapping nonidentical pin definitions for one fingerprint, unknown algorithms, and identities not independently operator-mapped.
- `profile_digest` is canonical base64url SHA-256 over a new domain-separated binary framing containing `version`, `profile_id`, `revision`, and each complete pin field in the normative order. JSON serialization order is not authority. Shared Go/JavaScript vectors freeze the framing.
- Server authority is `(account_id, profile_id, revision, profile_digest)`. The public digest does not contain the private account ID; database lookup is always account-scoped.
- Mutation bodies are closed, duplicate-key-free, bounded to 64 KiB, and carry `version`, `operation_id`, `profile_id`, `expected_revision`, `expected_profile_digest`, and `pins` where applicable. Operation IDs are 128-bit canonical base64url and idempotent for byte-identical mutations; reuse with different bytes is a conflict.
- Create/replace/revoke use an account API key, constant-shape not-found/conflict responses, bounded per-account profile/pin/operation rows, and sanitized audit. Profile secrets do not exist.

### C2. Public and internal routes

- Public gateway routes: `POST /v1/relay-blind/trust-profiles`, `PUT /v1/relay-blind/trust-profiles/{profile_id}`, `DELETE /v1/relay-blind/trust-profiles/{profile_id}`, `GET /v1/relay-blind/trust-profiles`, `GET /v1/relay-blind/trust-profiles/{profile_id}`, and `POST /v1/relay-blind/request-status`.
- Coordinator buyer-port equivalents are internal gateway-only and require trusted account context. The gateway strips buyer-supplied internal account/session/execution headers and never treats profile fields as provider admission authority.
- List pagination has a stable opaque cursor, default 20, maximum 100. Public reads return only the caller's profiles and public pin material; they never include provider IDs, assigned sessions, internal row IDs, or operator configuration.
- Profile reads are synchronization and status data, never trust bootstrap. A supported client enables encryption only after the returned revision, digest, and pins match a previously imported and fingerprint-confirmed local public bundle. A new client with no such local trust material must remain disabled even if an authenticated profile GET succeeds; neither the gateway nor coordinator response can author buyer approval or create TOFU state.
- Every route is mounted when disabled and returns a typed no-store error. All profile and status responses use `Cache-Control: no-store` and `Pragma: no-cache`.

### C3. Reservation profile binding without changing the six-field body

The existing reservation JSON body remains byte-contract compatible. Supported mode requires exactly one canonical value for each public header:

- `X-MacProvider-Relay-Blind-Trust-Profile`
- `X-MacProvider-Relay-Blind-Trust-Revision`
- `X-MacProvider-Relay-Blind-Trust-Digest`

The gateway authenticates, validates, and forwards the reference with trusted account context. Signed wallet requests include all three headers in the SPEC-040 semantic-header digest. Demo requests are rejected before metadata mutation.

Reservation success echoes the exact reference in the same no-store headers. The existing closed reservation body and `relay-blind-request-v1` envelope remain unchanged. The selected `key_record.identity_fingerprint` must match an active pin in that exact profile revision for the requested model and endpoint; the buyer independently checks this before encryption.

The coordinator reservation row gains immutable `trust_profile_id`, `trust_profile_revision`, `trust_profile_digest`, and `selected_identity_fingerprint`. A single `BEGIN IMMEDIATE` transaction revalidates the active profile and its pins, selects the first eligible candidate only after acceptable-identity filtering, revalidates the chosen signed key row, and inserts the reservation. No reservation response is emitted from a pre-transaction pool choice. Replacement/revocation and reservation creation serialize through the same SQLite writer authority.

### C4. Lifecycle rechecks

Consume and the final pre-dispatch arm require:

- exact account/profile/revision/digest still active;
- selected fingerprint still present, unrevoked, and in time/model/endpoint scope;
- exact operator provider mapping still current;
- exact provider ID/assigned session live and routable;
- exact signed encryption key current, unexpired, and unrevoked.

Profile replacement/revocation atomically rejects old-profile `reserved` and `consumed_predispatch` rows. It never changes `dispatched`, `terminal`, or `unknown_postdispatch` into a retryable state. Provider identity rotation, X25519 rotation, account profile rotation, and API-key rotation remain separate authorities.

### C5. No ciphertext retry or failover

The following are invariants across Go library, CLI, gateway, coordinator, Swift provider, and Malibu browser:

- one ciphertext body has at most one public inference send;
- a generic HTTP retry helper cannot receive an encrypted body;
- queue-full, NAK, timeout, cancel, disconnect, key/profile/session change, and provider loss never select another provider for that envelope;
- a fresh retry creates a new reservation, buyer ephemeral key, replay nonce, request ID, and envelope;
- postdispatch uncertainty is status-only and `do_not_resubmit`;
- the plaintext endpoint never receives a relay-blind namespace through fallback.

### C6. Typed errors and recovery actions

Extend the guarded gateway/coordinator inventory with exact codes and actions for: profile required, malformed profile reference, profile not found/revoked, profile revision conflict/stale, untrusted profile pin, and no approved provider available. Each error carries `phase`, `retryable`, and one closed `retry_action`: `provision_profile`, `replace_profile`, `refresh_profile_then_new_transaction`, `wait_then_new_transaction`, `new_reservation_and_envelope`, `check_status_do_not_resubmit`, `do_not_resubmit`, or `none`.

The library maps HTTP plus body metadata into a typed error without discarding server fields. Network uncertainty after inference send is always `check_status_do_not_resubmit`. Replay and postdispatch evidence take precedence over availability or rate classifications.

The public status request remains the existing closed pair of `provider_binding_digest` and `envelope_digest`. It is authenticated, account/session-scoped, rate-limited, replay-safe, no-store, and cannot dispatch. It returns the existing state/usage/privacy fields plus the closed recovery action. It does not expose response content, provider ID, session ID, key material, raw bindings, ciphertext, or profile pins.

### C7. Client journal

The supported Go client writes a versioned JSONL journal under the user's private application-support directory or an explicit secure absolute path. It uses OS advisory locking, no-follow opens, 0700 ancestry, 0600 file mode, bounded rows/bytes, durable append, and restart parsing. Rows contain transaction ID, request ID, profile reference, binding/envelope digests, phase, safe action, timestamps, and terminal state. They contain no prompt, messages, tools, response text, ciphertext, ephemeral private key, bearer, wallet private key, raw provider binding, or provider ID.

The browser stores the same redacted logical fields in origin-local storage and validates schema/bounds before use. Clearing browser storage loses recovery convenience but never authorizes resubmission.

## 6. Implementation slices

### Slice 0 — governance and shared vectors

**MacProvider ownership:** `specs/SPEC-041-relay-blind-request-encryption.md`, `specs/SPEC-006-buyer-api.md`, `specs/SPEC-040-wallet-native-buyer-sessions.md`, `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`, `test/fixtures/relay-blind/`.

Freeze C1-C7, error inventory, profile framing vectors, mixed-version behavior, and non-claims. Run spec governance validation. Runtime work cannot precede reviewed normative contracts.

### Slice 1 — coordinator trust authority and approved reservation

**MacProvider ownership:** `phase4-coordinator/internal/relayblind/{types.go,crypto.go,authority.go,store.go}` plus focused tests; `phase4-coordinator/internal/buyer/relay_blind.go`; coordinator config/capability publication and wiring.

Add additive profile/revision/operation tables and reservation columns. Implement bounded CRUD, operator-map validation, canonical digest, atomic candidate filtering/insertion, mutation invalidation, consume/dispatch rechecks, capability advertisement, metrics, and sanitized audit.

### Slice 2 — gateway control plane and recovery proxy

**MacProvider ownership:** `phase5-gateway/internal/router/relay_blind*.go`, `server.go`, auth wallet semantic headers, storage interfaces only if gateway persistence is proven necessary, config/capability mapping, and tests.

Authenticate public profile routes, reject demo mutation/use, proxy exact closed objects to coordinator, validate/forward profile reservation headers, strip internal headers, add public status, preserve no-store and response redaction, and guard the complete error inventory. Do not duplicate profile authority in gateway SQLite.

### Slice 3 — supported Go library and CLI

**MacProvider ownership:** new exported `phase5-gateway/pkg/relayblindbuyer` package with no dependency on gateway `internal` packages; refactor `cmd/relay-blind-client` as a thin adapter; shared vectors and CLI tests.

Add trust-profile create/replace/revoke/list/show, supported nonstream/stream calls, typed errors, durable recovery journal, `status` command, and explicit safe-action rendering. Preserve legacy single-pin parsing only as an explicitly unsupported migration input that must be imported into a profile before supported requests.

### Slice 4 — two-provider and recovery integration

**MacProvider ownership:** `test/integration/relay_blind_integration_test.go`, Swift fixture helpers only where needed, and signed local evidence tooling.

Run two distinct Swift fixture providers with independent Ed25519 identities and X25519 keys. Cover A-only when B sorts first, A+B, no candidate, profile/key rotation, revocation, expiry, concurrency, stream/nonstream, cancellation, reconnect, replay, and no cross-provider ciphertext send. Preserve every plaintext, settlement-exclusion, and protected-evidence regression.

### Slice 5 — Malibu buyer application

**MalibuAI/malibu ownership, separate hidden worktree/branch:** `console/private-requests.js`, `console/api.js` metadata integration, `console/index.html`, `console/views/settings.js` or a dedicated trust view, CSS, Node tests, public security/private-request docs.

Use a separate fresh worktree from the then-current fetched Malibu `origin/main`. Implement Web Crypto capability detection, exact shared framing/vector checks, local bundle validation, authenticated profile CRUD, private chat mode, one-send transport, cancellation/status recovery, and truthful metadata. Private mode is unavailable in demo and Agent/tool mode. No new dependency is added. Run targeted Node tests, full `npm test`, docs validation, and `npm run build`; perform real-browser nonstream/stream and cancellation checks against an isolated MacProvider stack.

### Slice 6 — actual MLX physical-Mac acceptance

Add an opt-in test/runner that uses an already-present supported MLX snapshot and never downloads weights automatically. Start the real provider runtime, gateway, and coordinator in isolated local mode with two provisioned identities/profiles, perform at least one encrypted request through actual MLX generation, and capture a redacted evidence manifest. The manifest records source revisions, test command/result, Apple chip family, RAM bucket, macOS build, Swift and MLX versions, model ID, catalog artifact identity/hash, quantization, context/output bounds, stream mode, identity fingerprints, and settlement result. It omits prompts, completions, paths, API keys, private keys, hardware serials, UUIDs, MAC addresses, and operator hostnames.

## 7. Migration, compatibility, and rollback

### Database migration

Coordinator relay-blind SQLite receives additive tables for profiles, immutable revisions/pins, mutation operation replay, and tombstones, plus nullable profile-binding columns on legacy reservations. Migration is transactional and restart-idempotent. Existing rows retain a `legacy_unbound` classification and can only finish under an explicit default-off legacy pilot compatibility flag; profile-required supported mode rejects creating or consuming new unbound rows. Indexes cover account/profile active lookup, operation replay, pin fingerprint/model lookup, reservation invalidation by profile revision/state, and tombstone retention.

Migration tests open pre-Build-2 databases with active reservations and revoked keys, migrate twice, verify old terminal/replay fences remain, and prove supported mode cannot revive unbound material. Forward rollback means disabling supported profile mode while retaining tables/tombstones; database file downgrade or deletion is not a rollback.

### Mixed-version behavior

- New client + old gateway/coordinator: capability check fails before profile mutation or encryption with typed unsupported state.
- New gateway + old coordinator: gateway suppresses supported capability and rejects before encryption; it does not emulate selection.
- Old client + new profile-required stack: typed `relay_blind_trust_profile_required` before encryption/quota.
- New coordinator + old provider: eligible only if its existing signed record matches an approved profile pin; no provider protocol change is required.
- Old Malibu bundle/profile revision: stale/revoked typed error and replacement workflow; no automatic old/new joint acceptance.
- Plaintext requests and relay-blind feature-off behavior remain byte/semantic compatible.

### Feature rollback

Disable the buyer-app UI first, then gateway supported capability, then coordinator profile-required admission. In-flight dispatched work remains status-only and settles under existing rules. Reserved/consumed predispatch supported transactions are fenced and expire; they are never converted to legacy selection. Profile data and tombstones remain for audit/re-enable. No rollback enables plaintext fallback or ciphertext replay.

## 8. Observability and operations

Expose bounded counters/histograms for profile CRUD outcome, CAS conflict, rejected pin authority, reservation outcome, approved-candidate count bucket, lifecycle recheck failure phase, status query state, and client recovery action. Metric labels cannot contain account IDs, profile IDs, fingerprints, provider IDs, model IDs with unbounded cardinality, request IDs, ciphertext digests, or error text.

Sanitized audit records include event type, actor class, account-scoped opaque audit correlation, profile revision/digest prefix or keyed digest, operation replay outcome, request correlation, phase, and code. They exclude prompts, ciphertext, raw pins/public keys, full fingerprints, provider mapping, raw bindings, response text, credentials, and internal hostnames. Operator status reports capability/config/schema health and counts without revealing buyer-provider associations.

Alert on sustained profile-store failure, operator-map duplication, unexpected legacy-unbound activity in supported mode, high profile CAS conflicts, lifecycle recheck failures, and postdispatch uncertainty. Observation does not enable settlement enforcement or rewards.

## 9. Acceptance criteria and roadmap mapping

| Roadmap outcome | Implementation step | Required proof |
|---|---|---|
| A-only selects A when B sorts first | Slices 0-2 atomic approved filter | Coordinator unit + real gateway/coordinator two-provider integration. Assert zero reservation/dispatch for B. |
| A+B selection | Profile pins and filtered stable ordering | Repeated/concurrent reservation tests with both eligible; every selected fingerprint belongs to profile. |
| No candidate | Typed no-approved-provider result | No reservation, quota, dispatch, provider ID leak, or plaintext fallback. |
| Rotation/revocation/expiry | Profile CAS, tombstones, lifecycle rechecks | Race tests at reservation/consume/arm; old predispatch material burns, postdispatch remains no-resubmit. |
| No ciphertext failover | C5 and separate client transport | Instrument all provider sends and network calls; one ciphertext reaches at most one exact session once. |
| Supported client/library | Slice 3 | External-package API tests, CLI black-box stream/nonstream, typed errors, secure journal/restart status. |
| Authenticated pins | Slices 1-3 | Cross-account, demo, wrong API key, wallet mutation, replay, CAS, malformed and operator-unmapped pin negatives. |
| Malibu app | Slice 5 | Node unit tests, full build, browser stream/nonstream/cancel/recovery, truthful copy and unsupported-crypto failure. |
| Two-provider journeys | Slice 4 | Both providers independently pinned; nonstream and stream success across them; A-only/B-first case. |
| Actual MLX journey | Slice 6 | Fresh physical-Mac evidence with actual generation and model/artifact/hardware context. Deterministic fixture does not count. |
| Recovery/replay/stale keys | Slices 1-6 | Crash/restart/cancel/reconnect/replay matrix and status-only uncertain outcomes. |
| Provider plaintext truth | Governance + Malibu/CLI UX | Exact disclosure asserted in response metadata, CLI, console, and docs; prohibited claims absent. |

Implementation completion requires all code merged into reviewable branches and all non-hardware acceptance tests passing. Local verification requires fresh commands. Hardware qualification requires the actual MLX journey. Production qualification remains blocked until deployment/release/operator prerequisites and separately authorized activation evidence exist.

## 10. Hardware and environment requirements

- Deterministic integration: macOS 14+, Swift toolchain matching the repo, Go 1.26.6, loopback gateway/coordinator, two Swift fixture processes. This proves protocol behavior only.
- Browser integration: secure HTTPS or loopback origin; Safari and Chromium versions that implement the exact Web Crypto X25519/HKDF/AES-GCM primitives. Each browser is capability-tested; unsupported environments fail closed.
- MLX acceptance: physical Apple Silicon Mac with enough RAM for the selected already-cached supported artifact, compatible macOS/Metal/MLX runtime, and isolated operator state. No 64 GB requirement is assumed; record actual hardware and model memory needs.
- Docker-dependent tests count only when a Docker daemon is available. Swift CLI tests do not substitute for Malibu/Xcode/browser tests.

## 11. Explicit non-goals

- Trusted Pools or pool-selected relay-blind requests (Build 4).
- Verified private settlement, receipt-version changes beyond profile binding, useful-work rewards, payout activation, epoch/payment implementation, or economic activation.
- Confidential compute, provider blindness, response encryption, anonymity, unlinkability, zero retention, or proof of physical computation.
- Automatic provider discovery/TOFU, gateway-authored buyer approval, automatic old/new identity overlap, or using provider assertions as trust authority.
- Ciphertext retries, provider failover, output replay/resume, or reconstruction of a lost response.
- Agent/tool mode in the Malibu browser during this build.
- Automatic model download, hardware purchase/rental, deployment, release publication, or production enforcement.
- Changes to `d-inference` or inspection of its source.

## 12. Plan gate and change control

Before Slice 0 implementation, an independent native GPT-5.6 Sol reviewer receives this exact plan revision, `test-spec-r1.md`, both repository/base revisions, and scope. It must inspect code independently and return structured severity/evidence/consequence/required-correction findings covering feasibility, prerequisites, trust boundaries, economics, UX truthfulness, recovery, cross-repository ownership, and whether tests prove the claims. Revise and rerun until Critical=0, High=0, Medium=0. Do not downgrade findings or weaken acceptance.

Any material change to profile authority, protocol/header framing, lifecycle invalidation, supported auth modes, browser cryptography, recovery semantics, or acceptance strategy reopens the plan gate before implementation of the changed portion.
