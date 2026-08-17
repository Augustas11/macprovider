# Phase 3 R2 audit remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R2_FINDINGS.md`  
**Date:** 2026-08-17

Maps each R2 CRITICAL/HIGH/MEDIUM finding to the fix that landed in this commit.

---

## R2-H1 — Stop MDA borrow via self-asserted serial → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `RequestAndMaybeUpgrade` used SE-asserted serial → `FindDeviceBySerial` → enqueue victim Mac with attacker SE nonce. |
| **Fix** | Coordinator-owned exclusive `DeviceBindingStore` (`internal/mdm/device_binding.go`). |
| **Claim API** | Token-auth `POST /v1/mdm/device-binding` (rejects enrolled-unbound). Internal bootstrap `POST /internal/mdm/device-binding` (webhook secret/loopback; allows enrolled-unbound once). Authenticated `/v1/enroll` auto-claims on success. |
| **Enqueue** | `RequestAndMaybeUpgrade` resolves `LookupByProvider` only; SE serial mismatch refuses enqueue; never `FindDeviceBySerial(seSerial)` for target selection. |
| **Tests** | `device_binding_test.go` — exclusive claim, enrolled-unbound reject, victim SE serial never enqueues victim UDID, matching binding still enqueues. |

---

## R2-H2 — Deliver DeviceAttestationNonce via raw plist → FIXED

| Item | Detail |
|------|--------|
| **Finding** | JSON `POST /v1/commands` with `device_attestation_nonce` dropped by MicroMDM JSON model. |
| **Fix** | `EnqueueDeviceInformationAttestation` → `POST /v1/commands/{udid}` with `Content-Type: application/xml` and Apple DeviceInformation plist including `<key>DeviceAttestationNonce</key><data>…</data>`. Returns `commandUUID`. |
| **Tests** | `client_test.go` asserts path `/v1/commands/{udid}`, body contains `DeviceAttestationNonce` + `RequestType`, not JSON `device_attestation_nonce`. |

---

## R2-H3 — Parse real MicroMDM command webhook envelope → FIXED

| Item | Detail |
|------|--------|
| **Finding** | Handler expected flat/payload JSON; real webhooks use `acknowledge_event` + base64 `raw_payload` plist. |
| **Fix** | `ParseAcknowledgeEvent` requires `topic=mdm.Connect` (or empty topic + `acknowledge_event` for tests); decodes `raw_payload`; plist-parses `QueryResponses.DeviceAttestation` via `howett.net/plist`. Pending keyed by `command_uuid` first, then UDID. Legacy flat JSON kept as secondary compat. |
| **Tests** | `TestHandleMDACommandWebhookAcknowledgeEvent` with realistic fixture; legacy happy-path retained. |

---

## R2-M1 — Migrate proof without publishing hardware early → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `MigrateMDAProofFrom` set `AttestationTierHardware` before freshness re-verify. |
| **Fix** | Migrate copies `MDACertChain` / `MDAVerifiedAt` / `MDABoundSEKeyHash` only. Tier stays `self_signed` (or current non-hardware) until `tryUpgradeFromCache` / `verifyAndUpgrade`. |
| **Tests** | Reconnect migrate expects non-hardware; `TestMigrateMDAProofDoesNotPublishHardwareUntilVerify` for expired cached proof. |

---

## Ops notes (runbook)

- Claim binding before live MDA enqueue.
- Already-enrolled unbound devices: internal bootstrap once; token path rejects to block remote borrow.
- Webhook must receive `mdm.Connect` acknowledge events with `raw_payload`.
- Enqueue uses raw plist so the device actually sees `DeviceAttestationNonce`.

See `docs/runbooks/hardware-attestation-phases.md` Phase 3 section.
