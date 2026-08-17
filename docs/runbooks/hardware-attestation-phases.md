# Hardware Attestation Implementation Runbook (Scenario B)

**Status:** Phase 3 IN PROGRESS  
**Branch:** `feat/attestation-phase3`  
**Worktree:** `/Users/augstar/macprovider-attest-phase3`  
**Base:** `origin/main`  
**Confirmed scope:** macprovider-native attestation only (not Darkbloom integration).

## Trust ladder (target end state)

| Tier | Primitive | macprovider label | Routing when enforced |
|------|-----------|-------------------|----------------------|
| 0 | None | `attestation_status: unsupported` | Tier-1 cooperative |
| 1 | SE P-256 signed blob + periodic challenges | `self_signed` (internal) / `attested` observe | Optional observe |
| 2 | MDM + Apple MDA + SE freshness bind | `hardware` / `attested` enforce | `require_attestation: true` |

**Do not implement:** ACME `device-attest-01` (deleted upstream). Deprecate naming `*-acme-v1` over time.

---

## Phase 0 — Baseline (DONE / no code)

**Goal:** Honest Tier-1 cooperative network; no false hardware claims.

| Item | State |
|------|-------|
| `tier2.require_attestation: false` | Production default |
| Tier-1 disclosure | SPEC-006 v0.8.1 |
| C4b script exists | `scripts/activate-tier2-attestation.sh` |

**Exit criteria:** None (maintain until Phase 4).

---

## Phase 1 — SE foundation (IN PROGRESS)

**Goal:** Persistent Secure Enclave P-256 identity, signed attestation at v2 auth, periodic liveness challenges, X25519 session bind. **Not hardware tier** — closes liveness/key-continuity only.

**Effort:** 2–3 eng-weeks  
**Agents:** 3 parallel implementation tracks (see below)

### 1.1 Wire contracts (normative for Phase 1)

#### A. Auth proof — new attestation format

Add `macprovider-se-p256-v1` to `tier2.attestation_formats` (coordinator config example + defaults).

`attestation_token` on `auth_request` stage `proof`:

```jsonc
{
  "format": "macprovider-se-p256-v1",
  "token": "<base64url UTF-8 bytes of SignedSEAttestation JSON>",
  "challenge": "<base64url 32-byte auth attestation_challenge>",
  "issued_at": "RFC3339",
  "expires_at": "RFC3339",
  "provider_id": "<provider_id>",
  "binary_version": "<semver>",
  "claimed": {
    "hardware_family": "apple_silicon",
    "ram_gb": 16,
    "model_id": "<model>",
    "model_hash": "<optional hex>"
  },
  "key_binding": {
    "provider_ecdh_public_key": "<base64url 32-byte X25519 from auth initial>"
  },
  "signature": {
    "alg": "ES256",
    "signature": "<base64url DER ECDSA over binding payload>"
  }
}
```

`token` decodes to:

```jsonc
{
  "attestation": {
    "authenticatedRootEnabled": true,
    "binaryHash": "<optional sha256 hex>",
    "chipName": "Apple M4",
    "encryptionPublicKey": "<same as provider_ecdh_public_key>",
    "hardwareModel": "Mac15,3",
    "osVersion": "15.5",
    "publicKey": "<base64 raw P-256 pubkey 64 bytes>",
    "rdmaDisabled": true,
    "secureBootEnabled": true,
    "secureEnclaveAvailable": true,
    "serialNumber": "<optional>",
    "sipEnabled": true,
    "systemVolumeHash": "<optional>",
    "timestamp": "RFC3339"
  },
  "signature": "<base64 DER ECDSA over canonical JSON attestation object>"
}
```

Canonical JSON for SE blob signature: **sorted keys**, UTF-8, matching coordinator verifier.

Binding signature payload (existing SPEC-008 shape):

- `version`: `macprovider/spec008/attestation-binding/v1`
- Same fields as `tier2.BuildAttestationBindingPayload` / `Tier2Attestation.bindingPayload`

#### B. Post-connect liveness — new message types

Distinct from auth `attestation_challenge` (Pillar C token freshness).

**Coordinator → Provider:**

```json
{
  "type": "se_liveness_challenge",
  "version": 1,
  "nonce": "<base64url 32 bytes>",
  "timestamp": "2026-07-08T12:00:00Z"
}
```

**Provider → Coordinator:**

```json
{
  "type": "se_liveness_response",
  "version": 1,
  "nonce": "<echo>",
  "timestamp": "<echo>",
  "public_key": "<base64 SE pubkey from registration>",
  "signature": "<base64 DER ECDSA over UTF-8(nonce+timestamp)>"
}
```

**Coordinator policy:**

- Interval: `tier2.se_liveness_interval_s` (default **300**, hot-reloadable)
- Timeout: `tier2.se_liveness_timeout_s` (default **30**)
- Max consecutive failures: `tier2.se_liveness_max_failures` (default **3**) → set `attestation_status: attestation_stale` or disconnect per SPEC-008 observe/enforce flags
- Only sent when provider connected with verified `macprovider-se-p256-v1` at auth

#### C. Pool metadata (coordinator)

Extend `pool.Provider` (non-breaking JSON fields):

- `se_public_key` — base64 raw P-256 (64 bytes)
- `attestation_tier` — `none` | `self_signed` | `hardware` (Phase 1 sets `self_signed` when SE verified; `hardware` reserved for Phase 3)
- `last_se_liveness_at` — internal

### 1.2 Implementation tracks

| Track | Owner agent | Files (primary) | Deliverables |
|-------|-------------|-----------------|--------------|
| **P1-A Provider SE** | executor | `phase3-binary/Sources/macprovider-cli/SecureEnclaveIdentity.swift`, `SEAttestationBuilder.swift`, `Tier2Attestation.swift`, `CoordinatorClient.swift`, tests | Persistent SE key; build signed blob; emit `macprovider-se-p256-v1` token at auth proof; `#if !arch(arm64)` graceful unsupported |
| **P1-B Coordinator verify** | executor | `phase4-coordinator/internal/tier2/pillar_c_se.go`, `pillar_c.go`, `config/config.go`, `coordinator.yaml.example`, tests | Verify SE blob + binding sig; store SE pubkey; set `attestation_tier=self_signed`; format allowlist |
| **P1-C Liveness loop** | executor | `phase4-coordinator/internal/ws/server.go`, `messages.go`, `phase3-binary/.../CoordinatorClient.swift`, tests | Periodic `se_liveness_challenge` / response; failure counting; provider handler in `receiveLoop` |

### 1.3 Entitlements / signing notes

- SE persistent key requires **keychain-access-groups** entitlement on distributed `macprovider-cli` binary.
- Team ID prefix in access group must match codesign team (document in `phase3-binary` release notes).
- Simulator / x86: SE path returns `unsupported` (no fake attestation).

### 1.4 Tests (mandatory)

| Test | Location |
|------|----------|
| SE blob sign/verify roundtrip | Swift unit + Go unit |
| Auth v2 with `macprovider-se-p256-v1` accepted | `ws/server_test.go` integration |
| Wrong challenge → `attestation_stale` | Go unit |
| ECDH bind mismatch → reject | Go unit |
| Liveness challenge/response | Go + Swift tests |
| 3 liveness failures → stale | Go integration |
| arm64-only SE skipped on other arch | Swift conditional compile test |

### 1.5 Phase 1 exit criteria

- [ ] Provider on Apple Silicon produces `macprovider-se-p256-v1` at auth when SE available
- [ ] Coordinator verifies and marks provider `attestation_tier=self_signed`
- [ ] Periodic liveness challenges work on established WS sessions
- [ ] `tier2.require_attestation: false` — SE attestation is **observed**, not required
- [ ] `/v1/models` shows accurate partial attestation counts when observe enabled
- [ ] All new tests pass: `go test ./internal/tier2 ./internal/ws` and `swift test` (macprovider-cli)
- [ ] No regression to existing MDA artifact path (`apple-managed-device-attestation-acme-v1`)

### 1.6 Phase 1 explicit non-goals

- MDM server, `/v1/enroll`, APNs push cert
- Live MDA / FreshnessCode
- `require_attestation: true` production flip
- Malibu App Attest changes (SPEC-026)

---

## Phase 2 — MDM MVP (DONE — 2026-08-17)

**Goal:** macprovider-run MDM so enrolled Macs can receive `DeviceInformation` commands.

**Effort:** 3–5 eng-weeks + Apple MDM push cert calendar time

### 2.1 Prerequisites (ops — start in parallel)

**Partner handoff (ABM + push identity):** [`docs/runbooks/apple-mdm-partner-registration.md`](./apple-mdm-partner-registration.md)

| Step | Link |
|------|------|
| Apple Business Manager org | https://business.apple.com/ |
| MDM Push cert portal | https://identity.apple.com/pushcert/ |
| MicroMDM cert guide | https://micromdm.io/blog/certificates/ |
| MicroMDM quickstart | https://github.com/micromdm/micromdm/blob/main/docs/user-guide/quickstart.md |

### 2.2 Engineering deliverables

| # | Deliverable | Owner |
|---|-------------|-------|
| 2.1 | Deploy MicroMDM (staging + prod) on Pearl VPS | ops + backend |
| 2.2 | `POST /v1/enroll` — SCEP + MDM `.mobileconfig` (CMS-signed) | coordinator |
| 2.3 | Profile signer cert + `tier2.mdm.*` config keys | coordinator |
| 2.4 | `macprovider enroll` CLI subcommand (serial → download → open Settings) | phase3-binary |
| 2.5 | `macprovider mdm-status` / doctor integration | phase3-binary |
| 2.6 | AccessRights=1041 (read-only: profiles + device info + security queries) | coordinator enroll template |
| 2.7 | Integration test: enroll test Mac → MDM check-in visible | QA |

### 2.3 Exit criteria

- [ ] Test Mac enrolls in **macprovider** MDM (not foreign MDM)
- [ ] Coordinator receives MDM check-in + UDID
- [ ] APNs push cert installed and wakes device
- [ ] Enroll flow documented for operators

---

## Phase 3 — Live MDA + cache (IN PROGRESS — 2026-08-17)

**Goal:** Apple-rooted hardware proof bound to SE pubkey; survive 7-day rate limit.

**Effort:** 2–3 eng-weeks

### 3.1 Engineering deliverables

| # | Deliverable |
|---|-------------|
| 3.1 | Fix `verifyMDAFreshness` to expect `SHA256(se_public_key)` when nonce sourced from MDM (not `SHA256(token)`) |
| 3.2 | `verifyAppleDeviceAttestation` equivalent: send `DeviceInformation` + `DeviceAttestationNonce` via MDM client |
| 3.3 | Persist `mda_cert_chain` + metadata on provider record (SQLite or pool store) |
| 3.4 | `attachCachedMDAProof` on reconnect — re-verify chain + Freshness bind to SE key |
| 3.5 | Upgrade `attestation_tier` to `hardware` when MDA valid |
| 3.6 | Remove static-artifact path as default; keep operator override for dev |
| 3.7 | Rate-limit aware refresh scheduler (≥7 days) |

### 3.2 Progress (2026-08-17)

**Landed this PR (`feat/attestation-phase3`):**
- [x] `verifyMDAFreshness` extended: also accepts `SHA256(sePublicKey)` nonce; `MDAHardware=true` returned when SE key digest matched
- [x] `AttestationVerifyResult.MDAHardware bool` — WS sets `AttestationTier=hardware` when true
- [x] `internal/mdm/client.go` — MicroMDM API client (`ListDevices`, `FindDeviceBySerial`, raw-plist `EnqueueDeviceInformationAttestation`, `ParseAcknowledgeEvent`)
- [x] `internal/mdm/live_mda.go` — `LiveMDAService` with `RequestAndMaybeUpgrade` + `AttachCachedMDAProof` + `UpgradeFromParsedAttestation`
- [x] `internal/mdm/device_binding.go` — exclusive provider↔serial `DeviceBindingStore` (R2-H1); token `/v1/mdm/device-binding` + internal bootstrap `/internal/mdm/device-binding`
- [x] Pool `MDACertChain`, `MDAVerifiedAt`, `MDABoundSEKeyHash` cache fields + `SetMDAProof` / `ClearMDAProof` / `MDAProof` / `MigrateMDAProofFrom` (bytes only — no early hardware tier)
- [x] `tier2.VerifyMDACertChainWithSEKey` public helper for LiveMDAService chain re-verify
- [x] `Tier2MDMConfig.APIURL/APIToken/LiveMDAEnabled/MDARefreshIntervalHours` config fields
- [x] WS observe wiring: `liveMDAUpgrader` interface, `WithLiveMDA` option, goroutine trigger after SE auth
- [x] Config documented in `dist/coordinator.yaml.example`
- [x] Tests: freshness dual-mode, MDM client HTTP tests, binding borrow-block, acknowledge_event webhook, migrate-without-hardware

**Still needs (manual Mac E2E):**
- [ ] Deploy `live_mda_enabled: true` on Pearl with MicroMDM running
- [ ] **Claim device binding before live MDA enqueue**
  - Already-enrolled fleet (e.g. H2XX74T43X): one-time ops bootstrap via
    `POST /internal/mdm/device-binding` with webhook secret/loopback +
    `{"provider_id":"...","serial_number":"..."}` (token-auth claim of
    enrolled-unbound serial is rejected to block remote borrow)
  - New devices: `POST /v1/mdm/device-binding` with provider Bearer +
    `{"serial_number":"..."}` before or after enroll; authenticated
    `/v1/enroll` also auto-claims when Bearer is present
- [ ] Enroll test Mac via `macprovider enroll` and see UDID in MicroMDM
- [ ] Point MicroMDM `-command-webhook-url` at coordinator
      `https://<provider-bind>/internal/mdm/command-webhook` (default Pearl:
      loopback `http://127.0.0.1:8444/internal/mdm/command-webhook`, or set
      `tier2.mdm.command_webhook_secret` / `X-MDM-Webhook-Secret` if exposed)
- [ ] Verify DeviceInformation attestation arrives via **raw plist**
      `POST /v1/commands/{udid}` with `DeviceAttestationNonce` `<data>`, and
      webhook `mdm.Connect` / `acknowledge_event.raw_payload` upgrades
      `attestation_tier=hardware`
- [ ] Provider reconnects: proof bytes migrate but tier stays non-hardware
      until cache re-verify / fresh webhook; then `/poolz` shows `hardware`

### 3.3 Exit criteria

- [ ] Fresh MDA round-trip on enrolled test Mac
- [ ] Reconnect reuses cached chain (no new Apple request within 7 days)
- [ ] SE key rotation invalidates stale chain (forces refresh)
- [x] `pillar_c_test.go` covers Freshness=SE pubkey binding
- [x] Coordinator-owned device binding required before enqueue (no SE-serial target selection)
- [x] Raw plist nonce delivery + acknowledge_event webhook ingest

---

## Phase 4 — C4b enforcement flip

**Goal:** Require attestation for routing; disclose `hardware_attestation: all`.

**Effort:** ~2–3 days (mostly ops)

### 4.1 Steps

1. All routable providers ≥ v1.2.6, `encrypted_leg=true`, `attestation_status=attested`, `attestation_tier=hardware`
2. `tier2.attestation_roots` = Apple Enterprise Attestation Root CA (production PEM)
3. `scripts/activate-tier2-attestation.sh --plan` — review
4. `DEMO_TOKEN=... OPERATOR_KEY=... scripts/activate-tier2-attestation.sh --apply`
5. Verify `/v1/models` + `/poolz`
6. Monitor `T2.C` audit logs 24h

### 4.2 Rollback

Script auto-restores config backup on verification failure. Manual: set `require_attestation: false`, SIGHUP.

### 4.3 Exit criteria

- [ ] `tier2.require_attestation: true` in production
- [ ] No routable unattested providers
- [ ] Gateway disclosure `hardware_attestation: all`

---

## Orchestration log

| Date | Event |
|------|-------|
| 2026-07-08 | Runbook created; Phase 1 agents spawned (P1-A, P1-B, P1-C) |
| 2026-07-08 | All three tracks landed in worktree; focused tests pass (Go SE+Liveness, Swift SEAttestation 12/12). Swift liveness unit tests still TODO. Entitlements blocker documented. |
| 2026-07-09 | **Phase 1 merged** — PR #477 squash-merged to main (`001fb405`). Augustas11 approved (PR author was antfleet-ops). |
| 2026-07-09 | **Phase 2 started** — worktree `/Users/augstar/macprovider-attest-phase2`, branch `fix/attestation-phase2`. Operator registering Apple MDM push cert in parallel. |
| 2026-08-07 | Partner ABM + identity.apple.com instructions added: `docs/runbooks/apple-mdm-partner-registration.md`. P2-A/P2-C already on main via PR #509. |
| 2026-08-17 | APNs push cert issued (topic `com.apple.mgmt.External.b3ba8c97-…`). P2-B: nginx `/v1/enroll`+`/mdm/`+`/scep`, MicroMDM Pearl install — see `docs/runbooks/pearl-micromdm-install.md`. |
| 2026-08-17 | **Phase 2 enroll E2E done** — coordinator `/v1/enroll` tested, MicroMDM on Pearl, APNs cert live. Phase 2 exit criteria met. |
| 2026-08-17 | **Phase 3 started** — worktree `/Users/augstar/macprovider-attest-phase3`, branch `feat/attestation-phase3`. Dual-mode MDA freshness, MicroMDM API client, LiveMDAService, pool MDA cache, WS observe wiring. |
| 2026-08-17 | **Phase 3 R2 remediation** — exclusive device binding (blocks SE-serial borrow), raw plist `DeviceAttestationNonce`, `acknowledge_event` webhook parse, migrate proof without early hardware tier. |

## Phase 2 — IN PROGRESS

**Goal:** macprovider-run MDM enrollment path (`POST /v1/enroll` + provider `enroll` CLI). APNs cert ops parallel (operator).

### Phase 2 tracks

| Track | Scope | Deliverables |
|-------|-------|--------------|
| **P2-A** | Coordinator enroll API | `POST /v1/enroll`, SCEP+MDM `.mobileconfig` generator, AccessRights=1041, config keys |
| **P2-B** | Routing + nginx + config | `coordinator.yaml` MDM block, nginx exact route, tests |
| **P2-C** | Provider CLI | `macprovider enroll`, `mdm-status`, serial via ioreg, open System Settings |

### Phase 2 exit criteria

- [ ] `POST /v1/enroll` returns valid `.mobileconfig` for a serial
- [ ] Provider `enroll` command downloads and opens profile
- [ ] `mdm-status` reports enrolled / not enrolled / foreign MDM
- [ ] Config documented in `coordinator.yaml.example`
- [ ] Tests (Go handler + Swift enroll parser)
- [ ] **Ops (parallel):** APNs push cert at identity.apple.com/pushcert

### Phase 1 exit criteria status

- [x] Coordinator verifies `macprovider-se-p256-v1` and sets `attestation_tier=self_signed`
- [x] Provider on Apple Silicon produces `macprovider-se-p256-v1` at auth when SE available
- [x] Periodic `se_liveness_challenge` / response on coordinator
- [x] Provider `handleSELivenessChallenge` wired
- [ ] End-to-end auth + liveness integration test (Swift + Go)
- [ ] `keychain-access-groups` entitlement on release binary
- [ ] Phase 1 commit + PR

---

## References

- `research-brief.md` (repo root canonical checkout)
- `specs/SPEC-008-tier2.md` — Pillar C
- Apple MDA: https://support.apple.com/guide/security/sec8a37b4cb2/web
- Darkbloom reference (read-only via `git show origin/master:...`): `coordinator/api/provider.go`, `provider-swift/.../PersistentEnclaveKey.swift`
