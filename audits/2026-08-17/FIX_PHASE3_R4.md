# Phase 3 R4 audit remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R4_FINDINGS.md`  
**Date:** 2026-08-17

Maps each R4 CRITICAL/HIGH/MEDIUM finding to the fix that landed in this commit.

---

## R4-M1 — Durable pending webhook correlation → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `markEnqueued` persisted `pending_command_uuid` but `takePending` only read the in-memory map → restart dropped correlation while ledger blocked re-enqueue. |
| **Fix** | SQLite `mda_pending` stores full pending request (`provider_id`, `assigned_id`, `serial`, `udid`, `se_key_hash`, `command_uuid`, `enqueued_at`). `recordPending` persists; `takePending` hydrates on memory miss then deletes durable+memory aliases. Terminal webhook outcomes clear durable pending. |
| **Tests** | `TestDurablePendingSurvivesNewServiceWebhook` — markEnqueued/recordPending → new `LiveMDAService` (same DB) → webhook by `command_uuid` upgrades hardware. |

---

## R4-M2 — Persist device bindings → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `DeviceBindingStore` was in-memory only; restart lost one-time bootstrap. |
| **Fix** | SQLite `mda_device_bindings`. `SetMDAStore` hydrates via `Restore`. `ClaimDevice` / UDID refresh / check-in `SetUDID` call `persistBinding`. |
| **Tests** | `TestDurableDeviceBindingSurvivesNewService` — bootstrap claim → new service → `LookupByProvider` + enqueue finds binding UDID. |

---

## R4-M3 — Require EnrollmentStatus + UDID → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `ClaimDevice` treated any `FindDeviceBySerial` hit as enrolled. |
| **Fix** | `isEnrolledDevice`: `EnrollmentStatus == true` AND non-empty UDID. Gated in `ClaimDevice` and enqueue UDID fill path. `FindDeviceBySerial` still returns raw rows. |
| **Tests** | `TestClaimDeviceRejectsUnenrolledMicroMDMRow`, `TestClaimDeviceRejectsEnrolledEmptyUDID`. Existing fixtures set `EnrollmentStatus: true`. |

---

## R4-M4 — Atomic enqueue reservation (TOCTOU) → FIXED

| Item | Detail |
|------|--------|
| **Finding** | `enqueueAllowed` then HTTP then `markEnqueued` allowed concurrent double-enqueue. |
| **Fix** | Per-ledger-key mutex for check+reserve+HTTP+confirm. `reserve` = provisional UUID in pending+ledger **before** HTTP; `confirmEnqueue` swaps to real command UUID; `releaseEnqueueReservation` on HTTP error. |
| **Tests** | `TestConcurrentEnqueueOnlyOnce` — 16 goroutines → exactly one MicroMDM enqueue. |

---

## R4-M5 — Floor refresh interval at 168h → FIXED

| Item | Detail |
|------|--------|
| **Finding** | Config allowed ≥24h; Apple budget ~7 days; runbook says ≥7 days. |
| **Fix** | When `live_mda_enabled`, config Load clamps `mda_refresh_interval_hours` &lt; 168 → 168. Runtime `mdmRefreshIntervalHours` also floors at 168. yaml.example + runbook updated. |
| **Tests** | `TestMDMRefreshIntervalFloor` (48→168); `TestLoadClampsMDARefreshIntervalWhenLiveMDAEnabled`. |

---

## LOW (touched)

- `pillar_c.go` `MDAHardware` comment corrected to match R3-M1 (does not alone publish pool hardware tier).

---

## Verification

```bash
cd phase4-coordinator
go test ./internal/mdm ./internal/tier2 ./internal/pool ./internal/config -count=1
go test ./internal/ws -count=1 -run 'MDA|Attestation|Hardware|Tier'
go build -o /dev/null ./cmd/coordinator
```

All green.
