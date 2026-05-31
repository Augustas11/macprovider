# BUILD SPEC-008 Phase 2 — Pillars B + C: Provider-leg Encryption + Hardware Attestation

## Context

You are working on **macprovider-poc** — a P2P Mac inference marketplace.

- Coordinator: Go service at `phase4-coordinator/`
- Provider binary: Swift CLI at `phase3-binary/Sources/macprovider-cli/`
- Providers connect to the coordinator via WebSocket (`/ws/provider`)

SPEC-008 Phases 1 and 3 are complete. **This session implements Phase 2:
Pillar B (provider-leg AEAD encryption) and Pillar C (hardware attestation).**

The full normative wire spec is **SPEC-008 §10** (`specs/SPEC-008-tier2.md`
§10.1–§10.9). Read §6 (Pillar B), §7 (Pillar C), §10, §11.1, §12.3, §12.4,
and §13 before starting. SPEC-001 v1.2.4 remains valid for old providers —
backward compatibility is mandatory.

This is the largest and most complex SPEC-008 phase. Work through coordinator
and provider binary changes in order.

---

## Part 1 — Coordinator: SPEC-001 v2.0 auth flow + Pillar B relay

### 1.1 First-message dispatch (§10.1.1)

Edit `phase4-coordinator/internal/ws/server.go`.

The coordinator currently processes every provider first message as a `hello`
(SPEC-001 v1). Add dispatch on the first message:

```
if type == "auth_request" AND version == 2  → v2 auth flow (new)
if type == "hello"        AND version == 1  → existing Tier-1 path (unchanged)
otherwise                                   → close WebSocket 4000 "unrecognized auth message"
```

The coordinator MUST NOT send any frame before the provider's first message.

### 1.2 v2 auth flow — `auth_request` initial (§10.2)

When the first message is `auth_request` / `stage: "initial"`:

1. Parse the message. Required fields (same as v1 `hello`, plus):
   - `provider_ecdh_public_key`: base64url 32-byte X25519 public key
   - `tier2_capabilities.encrypted_leg`: bool
   - `tier2_capabilities.aead_suites`: `[]string`
   - `model_hash`: optional lowercase hex SHA-256
2. Validate `provider_ecdh_public_key` is exactly 32 bytes when decoded.
3. Negotiate AEAD suite: pick the first entry in `aead_suites` that the
   coordinator supports (`A256GCM` required, `CHACHA20-POLY1305` optional).
   If no common suite, close with 4001 "no_common_aead_suite".
4. Generate coordinator X25519 ephemeral keypair for this session.
5. Derive shared secret and session keys per §6.4:
   ```
   shared_secret = X25519(coordinator_private, provider_public)
   transcript = SHA256(
     "macprovider/spec008/pillar-b/transcript/v1" ||
     provider_id || assigned_id ||
     provider_public_key || coordinator_public_key ||
     selected_aead_suite
   )
   prk = HKDF-Extract(salt=transcript, IKM=shared_secret)
   c2p_key   = HKDF-Expand(prk, "macprovider/spec008/c2p/aead/v1", 32)
   p2c_key   = HKDF-Expand(prk, "macprovider/spec008/p2c/aead/v1", 32)
   c2p_nonce_base = HKDF-Expand(prk, "macprovider/spec008/c2p/nonce/v1", 4)
   p2c_nonce_base = HKDF-Expand(prk, "macprovider/spec008/p2c/nonce/v1", 4)
   key_id    = base64url(SHA256(transcript)[0:16])
   ```
6. Generate 32-byte fresh random attestation challenge for Pillar C.
7. Send `auth_challenge` (§10.3):
   ```json
   {
     "type": "auth_challenge",
     "version": 2,
     "coordinator_ecdh_public_key": "<base64url 32 bytes>",
     "selected_aead": "A256GCM",
     "key_id": "<base64url 16 bytes>",
     "attestation_challenge": "<base64url 32 bytes>",
     "attestation_formats": ["apple-managed-device-attestation-acme-v1"]
   }
   ```
8. Wait for `auth_request` / `stage: "proof"` (§10.4).

### 1.3 v2 auth flow — `auth_request` proof (§10.4)

On receiving `auth_request` / `stage: "proof"`:

1. Parse `attestation_token` object (§7.4) if present.
2. Validate attestation token per §7.5:
   - Format, signature against `tier2.attestation_roots`
   - Freshness vs `issued_at`, `expires_at`, `tier2.attestation_max_age_s`
   - Challenge binding (must match the challenge sent in step 6 above)
   - Provider identity binding
   - Session ECDH key binding
3. Compute attestation status (`attested` / `attestation_failed` /
   `attestation_stale` / `unsupported` / `not_required`) and store on the
   pool entry.
4. Send `auth_response` (§10.5):
   ```json
   {
     "type": "auth_response",
     "version": 2,
     "status": "ok",
     "assigned_id": "<assigned pool ID>",
     "pillar_b_active": true,
     "attestation_status": "attested"
   }
   ```
   On failure: `"status": "error"` with `"error": {"code": "...", "message": "..."}`,
   close WebSocket with appropriate close code per §4.6 / §4.7.
5. Register the provider in the pool with `EncryptedLeg: true` and the
   session key material stored in the pool entry (not in `s.cfg`).

### 1.4 Encrypted inference relay (§6.6, §6.7)

When relaying inference to a v2 provider (`provider.EncryptedLeg == true`):

**Outgoing request (c2p, §6.6):**

For each `inference_request` dispatched to a v2 provider:
1. Build c2p AAD (§6.5.1): deterministic JSON with `type`, `direction: "c2p"`,
   `request_id`, `stream`, `provider_id`, `assigned_id`, `seq`.
2. Encrypt the `body` field with AES-256-GCM:
   - nonce = `c2p_nonce_base || uint64_be(c2p_frame_counter)`
   - increment c2p_frame_counter
3. Send the AEAD envelope (§6.5) instead of the cleartext `inference_request`.
   The cleartext `body` field MUST be absent from the encrypted message.

**Incoming response (p2c, §6.7):**

For each `inference_response_chunk` from a v2 provider:
1. Parse the AEAD envelope; extract `enc.seq`, `enc.nonce`, `enc.aad`,
   `enc.ciphertext`, `enc.tag`, `enc.kid`.
2. Verify `enc.kid` matches the session `key_id`.
3. Verify `enc.seq` matches expected p2c_frame_counter (reject replays).
4. Reconstruct p2c AAD from the fields in `enc.aad`; verify it matches.
5. Decrypt with `p2c_key`.
6. On AEAD failure:
   - Pre-commit: return `tier2_aead_decrypt_failed` (HTTP 502), close provider
     session, log MAJOR `T2.B aead_decrypt_failed`.
   - Post-commit: emit SSE error event, close stream and provider session.
7. Pass decrypted bytes downstream (through Pillar D if enabled).

**Rekeying (§6.9):**

After `encrypted_leg_rekey_after_requests` requests or
`encrypted_leg_rekey_after_seconds` seconds, close the provider session and
let the provider reconnect with a fresh v2 handshake. Log
`T2.B session_rekeyed`.

**Restart behavior (§6.10):**

On coordinator restart, all in-memory session keys are lost. Providers
reconnect and redo the v2 handshake. Log `T2.B coordinator_restart_session_invalidated`
for each active encrypted session before shutdown if possible.

### 1.5 Pool entry changes

Add to `phase4-coordinator/internal/pool/provider.go`:

```go
EncryptedLeg        bool
AttestationStatus   string   // "attested", "attestation_failed", "attestation_stale", "unsupported", "not_required"
ModelLoadTimeMs     int64    // from auth_request, used by Pillar D TTFT baseline
// session key material — NOT serialised to disk, lost on restart
c2pKey              []byte
p2cKey              []byte
c2pNonceBase        []byte
p2cNonceBase        []byte
c2pCounter          uint64
p2cCounter          uint64
keyID               string
```

Keep key material in a separate `Tier2Session` struct inside the pool entry
to isolate it from the public `Provider` fields exported to the gateway and
buyer server.

### 1.6 Config keys for Phase 2

Add to `phase4-coordinator/internal/config/config.go` under `Tier2Config`
(§11.1):

```go
RequireEncryptedLeg               bool     `yaml:"require_encrypted_leg"`
EncryptedLegAEAD                  string   `yaml:"encrypted_leg_aead"`
EncryptedLegRekeyAfterRequests    int      `yaml:"encrypted_leg_rekey_after_requests"`
EncryptedLegRekeyAfterSeconds     int      `yaml:"encrypted_leg_rekey_after_seconds"`
RequireAttestation                bool     `yaml:"require_attestation"`
AttestationRoots                  []string `yaml:"attestation_roots"`
AttestationMaxAgeS                int      `yaml:"attestation_max_age_s"`
AttestationFormats                []string `yaml:"attestation_formats"`
```

Startup validation:
- `require_attestation: true` AND `attestation_roots` empty → fail
- `attestation_max_age_s <= 0` → fail
- `encrypted_leg_aead` not in supported suites → fail
- `encrypted_leg_rekey_after_requests <= 0` → fail
- `encrypted_leg_rekey_after_seconds <= 0` → fail

Hot-reloadable: `require_encrypted_leg`, `require_attestation`,
`attestation_max_age_s`, `behavioral_safety_enabled` group.
Startup-only: `encrypted_leg_aead`, rekey thresholds, `attestation_roots`,
`attestation_formats`.

### 1.7 Routing predicate changes (§6.8, §7.6)

In `phase4-coordinator/internal/pool/provider.go`, update `RoutingEligible()`:

When `require_encrypted_leg: true`: exclude providers where
`EncryptedLeg == false`.
When `require_attestation: true`: exclude providers where
`AttestationStatus != "attested"`.

These are additive to the existing `HashStatus` predicate.

### 1.8 Audit events (§12.3, §12.4)

T2.B events: `aead_decrypt_failed` (MAJOR), `encrypted_leg_fallback` (INFO),
`session_rekeyed` (INFO), `coordinator_restart_session_invalidated` (INFO),
`encrypted_leg_required_missing` (WARN).

T2.C events: `attestation_valid` (INFO), `attestation_failed` (WARN),
`attestation_replay` (WARN), `attestation_stale` (WARN),
`provider_binding_mismatch` (WARN), `attestation_token_too_large` (WARN).

---

## Part 2 — Provider binary: SPEC-001 v2.0 client (Swift)

Edit `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`.

### 2.1 v2 auth handshake

Replace / extend `helloMessage()` and the WebSocket connect flow:

1. At connect time, generate a fresh X25519 ephemeral keypair using
   `CryptoKit.Curve25519.KeyAgreement`.
2. Send `auth_request` / `stage: "initial"` (§10.2):
   ```swift
   var msg: [String: Any] = [
       "type": "auth_request",
       "version": 2,
       "stage": "initial",
       "provider_id": providerID,
       "model_id": snapshot.modelID ?? "",
       // ... all existing hello fields ...
       "model_hash": snapshot.modelHash as Any,
       "tier2_capabilities": [
           "encrypted_leg": true,
           "attestation": true,
           "aead_suites": ["A256GCM"]
       ],
       "provider_ecdh_public_key": ephemeralPublicKeyBase64url
   ]
   ```
3. Receive `auth_challenge`. Parse `coordinator_ecdh_public_key`,
   `selected_aead`, `key_id`, `attestation_challenge`.
4. Derive session keys using the same HKDF derivation as the coordinator
   (§6.4). Store c2p/p2c keys, nonce bases, key_id in the session state.
5. Generate attestation token (§2.3 below).
6. Send `auth_request` / `stage: "proof"` with `attestation_token`.
7. Receive `auth_response`. If `status != "ok"`, disconnect and retry.

Keep the existing v1 `hello` path as a fallback: if the coordinator closes
the connection with 4000 "unrecognized auth message" after the v2 attempt,
fall back to `hello` v1. This ensures backward compatibility during mixed
deployments.

### 2.2 Encrypted inference messages

**Receiving encrypted `inference_request` (c2p):**

Detect `"encrypted": true` in the incoming `inference_request`. Decrypt:
1. Parse the AEAD envelope.
2. Verify `enc.kid` matches the session key_id.
3. Verify `enc.seq` counter (reject replays).
4. Reconstruct c2p AAD from `enc.aad`; verify it.
5. Decrypt `enc.ciphertext` with `c2p_key` using AES-256-GCM.
6. Pass decrypted body to the existing inference handler unchanged.

**Sending encrypted `inference_response_chunk` (p2c):**

After generating each response chunk, encrypt before sending:
1. Build p2c AAD (§6.5.2): deterministic JSON.
2. Encrypt chunk `data` field with `p2c_key`.
   - nonce = `p2c_nonce_base || uint64_be(p2c_frame_counter)`
   - increment p2c_frame_counter
3. Send AEAD envelope instead of cleartext `inference_response_chunk`.

### 2.3 Apple attestation token (Pillar C)

The recommended starting point is **Managed Device Attestation (MDA)** with
ACME/device-management validation on macOS 14+ (§7.2).

For the prototype:

1. Check if `DCDevice` (DeviceCheck) is available; if not, set
   `attestation_status: "unsupported"` and send `attestation_token: nil` in
   the proof message.
2. If available, generate a DeviceCheck token bound to the coordinator's
   challenge bytes using `DCDevice.current.generateToken(completionHandler:)`.
3. Wrap in the §7.4 attestation data model:
   ```json
   {
     "format": "apple-managed-device-attestation-acme-v1",
     "token": "<base64url DeviceCheck token>",
     "challenge": "<base64url coordinator challenge>",
     "issued_at": "...",
     "expires_at": "... + 10 minutes",
     "provider_id": "...",
     "binary_version": "...",
     "claimed": {
       "hardware_family": "apple_silicon",
       "ram_gb": <actual RAM>,
       "model_id": "...",
       "model_hash": "<if available>"
     },
     "key_binding": {
       "provider_ecdh_public_key": "<base64url X25519 public key>"
     }
   }
   ```
4. If DeviceCheck token generation fails at runtime (not just unsupported),
   log the error, set `attestation_status: "unsupported"`, and proceed — never
   block inference for a failed attestation attempt.

### 2.4 Session state

Add a `Tier2Session` struct to `CoordinatorClient` to hold:

```swift
struct Tier2Session {
    let c2pKey: SymmetricKey
    let p2cKey: SymmetricKey
    let c2pNonceBase: Data    // 4 bytes
    let p2cNonceBase: Data    // 4 bytes
    let keyID: String
    var c2pCounter: UInt64 = 0
    var p2cCounter: UInt64 = 0
    let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
}
```

Reset the session on disconnect. The provider generates a fresh ephemeral
keypair on every reconnect.

---

## Part 3 — Gateway: disclosure update (§13)

In `phase5-gateway/internal/router/server.go`, add Pillar B and C disclosure
fields to `/v1/models` response when Phase 2 is active:

```json
"provider_leg_encryption": "all",   // or "partial" / "none"
"hardware_attestation": "all"        // or "partial" / "unsupported" / "none"
```

Values sourced from coordinator routing metadata. The coordinator must include
per-model encryption and attestation counts in the metadata it exports to the
gateway.

---

## Acceptance criteria

All six Pillar B criteria (AC-B-1 through AC-B-6, §6.11) and all six Pillar C
criteria (AC-C-1 through AC-C-6, §7.8) must pass.

Key tests to write:

- Mock v2 provider: coordinator sends `auth_challenge`, provider derives same
  key_id → AC-B-1.
- Test vector: known X25519 keys + HKDF → known `key_id`, `c2p_key`, `p2c_key`.
- Encrypted inference round-trip with mock provider: prompt bytes absent from
  wire frame → AC-B-2, AC-B-3.
- Old provider (v1 hello) remains routable with
  `require_encrypted_leg: false` → AC-B-5.
- Valid mock attestation token → `attested`, T2.C logged → AC-C-1.
- Replay old challenge → `attestation_stale` → AC-C-2.
- Wrong provider binding → `attestation_failed` → AC-C-3.
- Old provider with no attestation, `require_attestation: false` → routable → AC-C-4.

---

## Build and verify

```bash
# Coordinator
cd phase4-coordinator
go build ./...
go test ./... -count=1
go test -race ./... -count=1 -run TestPillarB
go test -race ./... -count=1 -run TestPillarC

# Provider binary
cd phase3-binary
swift build -c release
swift test
```

---

## Key files

```
phase4-coordinator/internal/ws/server.go              # v2 auth dispatch + encrypted relay
phase4-coordinator/internal/pool/provider.go          # EncryptedLeg, AttestationStatus, Tier2Session
phase4-coordinator/internal/config/config.go          # Pillar B + C config keys
phase4-coordinator/internal/tier2/pillar_b.go         # new — AEAD helpers, key derivation
phase4-coordinator/internal/tier2/pillar_c.go         # new — attestation verification
phase4-coordinator/internal/tier2/pillar_b_test.go    # new — AC-B-1 through AC-B-6
phase4-coordinator/internal/tier2/pillar_c_test.go    # new — AC-C-1 through AC-C-6
phase4-coordinator/cmd/coordinator/main.go            # reload class updates
phase5-gateway/internal/router/server.go              # Pillar B + C disclosure fields
phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift  # v2 auth handshake + AEAD
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift       # model_hash (if not done in Phase 1)
specs/SPEC-008-tier2.md                               # normative — §6, §7, §10, §11.1, §12.3, §12.4, §13
```

## Important constraints

- **Backward compatibility is mandatory.** Old v1 providers (no `auth_request`)
  MUST continue to work when `require_encrypted_leg: false` and
  `require_attestation: false` (both defaults).
- **Coordinator sees plaintext** — Pillar B is channel-only, not end-to-end.
  Docs and `/v1/models` MUST NOT describe it as buyer-to-provider E2E
  encryption (§6.2).
- **Never block inference for missing attestation at defaults.** If
  DeviceCheck is unavailable, the provider reports `"unsupported"` and routes
  normally unless `require_attestation: true`.
- **Session key material is in-memory only.** Never persist X25519 private
  keys or AEAD session keys to disk or logs.
- Do not activate `require_encrypted_leg: true` or `require_attestation: true`
  in this session — those are operator config steps (C4a, C4b) done after
  the pool shows sufficient encrypted/attested providers.

## SSH + deploy notes (same as other sessions)

- Pearl VPS: `ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194`
- Before any `git push`: `gh auth switch -u Augustas11`
- Build Linux binaries: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build`
- Deploy: SCP binaries → install → `systemctl restart`
