# Phase 3 R3 audit remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R3_FINDINGS.md`  
**Date:** 2026-08-17

Maps each R3 CRITICAL/HIGH/MEDIUM finding to the fix that landed in this commit.

---

## R3-H1 — Kill token-auth pre-enrollment serial squat → FIXED

| Item | Detail |
|------|--------|
| **Finding** | Token `ClaimDevice(..., allowEnrolledUnbound=false)` allowed pending claim when serial not in MicroMDM → attacker reserved victim serial → later enrollment gave attacker MDA path. |
| **Fix** | `ClaimDevice` returns `ErrPendingClaimRejected` when `!enrolled` for **both** token and internal paths. Pending UDID-empty bindings are never creatable. |
| **Token path** | May refresh UDID on an **existing** same-provider binding; still rejects enrolled-unbound new claims (`ErrEnrolledUnboundRejected`). |
| **Internal path** | Creates first binding only for already-enrolled devices. |
| **Enroll** | Removed auto-`ClaimDevice` from `/v1/enroll` (`enroll_handler.go`). Profile generation stays; binding = ops bootstrap or check-in SetUDID. |
| **Check-in** | Optional `POST /internal/mdm/checkin-webhook` only `SetUDID` on existing binding when serial matches — never creates binding from serial alone. |
| **Tests** | `TestClaimDeviceRejectsPendingWhenNotEnrolled`, `TestAttackerCannotPreClaimBeforeVictimEnrolls`, `TestClaimDeviceTokenRefreshExistingBinding`. |

---

## R3-M1 — Static MDA must not publish `hardware` tier → FIXED

| Item | Detail |
|------|--------|
| **Finding** | WS set `AttestationTierHardware` when `attestResult.MDAHardware` was true, bypassing LiveMDAService lifecycle. |
| **Fix** | Removed that assignment in `ws/server.go`. SE path still sets `AttestationTierSelfSigned`. Hardware only via `SetMDAProof` / `tryUpgradeFromCache`. |
| **Tests** | `TestLoadMDAProofCacheDoesNotPublishHardware`; durable restore still requires re-verify before hardware. |

---

## R3-M2 — Durable MDA proof cache → FIXED

| Item | Detail |
|------|--------|
| **Finding** | MDA proof lived only on live pool provider; disconnect/restart lost ~7-day cache. |
| **Fix** | SQLite `mda_proofs` on `cfg.Storage.DBPath` (`internal/mdm/mda_store.go`). Persist on `SetMDAProof` success; delete on clear; hydrate via `LoadMDAProofCache` (bytes only) before `tryUpgradeFromCache`. |
| **Wire** | `main.go` opens store when LiveMDA enabled. |
| **Tests** | `TestDurableMDAProofSurvivesNewService` — save → new service/pool → restore hardware when fresh; expired clears store. |

---

## R3-M3 — Rate-limit-aware enqueue ledger → FIXED

| Item | Detail |
|------|--------|
| **Finding** | Reconnect loops could repeatedly enqueue DeviceInformation and burn Apple’s ~7-day budget. |
| **Fix** | Per-key ledger `provider_id\|serial\|hex(se_key_hash)` with `lastEnqueueAt`, `pendingCommandUUID`, `terminalOutcome`. In-memory + SQLite `mda_enqueue_ledger`. Before enqueue: pending within interval → reuse; otherwise within interval → rate_limited. Webhook success/fail updates terminal outcome. |
| **Tests** | `TestRequestAndMaybeUpgradeRateLimitsDoubleEnqueue` — double call does not double-enqueue; after interval allows. |

---

## Ops notes (runbook)

- No token pending claims; binding = internal bootstrap of an **enrolled** device.
- Hardware tier only via live MDA verify path — not static MDA token flag.
- Durable proof + enqueue rate limit survive reconnect/restart within refresh interval.

See `docs/runbooks/hardware-attestation-phases.md` Phase 3 section.
