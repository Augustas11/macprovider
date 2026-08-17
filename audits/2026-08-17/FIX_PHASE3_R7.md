# Phase 3 live MDA — R7 remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Date:** 2026-08-17  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R7_FINDINGS.md`

## Summary

Fixed the single MEDIUM finding (0 CRITICAL / 0 HIGH / 0 MEDIUM remaining for R7 scope).

| ID | Fix |
|----|-----|
| **R7-M1** | Successful `ClaimDevice` that changes serial (or differs from live/durable MDA proof serial) clears live + durable MDA proof, downgrades `AttestationTierHardware` → `self_signed`, and drops stale pending for the old serial/UDID. |

## R7-M1 — Rebind clears published hardware

**Problem:** `ClaimDevice` could move provider `p` from serial A to B via `bindings.Claim` without clearing a previously published MDA proof / `AttestationTierHardware` for A. R6-M1 only blocked a *pending* A webhook from newly publishing after rebind; it did not clear proof already published for A.

**Change (`live_mda.go`):**
1. `ClaimDevice` snapshots prior binding serial/UDID before claim.
2. After successful claim, `clearHardwareAfterSerialClaim` clears when the new serial differs from any of: prior binding serial, live `MDASerial` / MDA proof serial, or durable proof serial (covers “no in-memory binding but durable proof exists”).
3. Clear path reuses `clearMDAProof` (`ClearMDAProof` + durable `DeleteProof`) so hardware → self_signed.
4. `clearPendingForProviderOldSerial` removes in-memory + durable pending for the provider matching old ExpectedSerial or prior UDID.

**Regression:** `TestClaimDeviceClearsHardwareOnSerialRebind` — Claim A → `verifyAndUpgrade` hardware + durable proof → ClaimDevice to B → assert non-hardware, no in-memory MDAProof, durable proof gone, binding is B; stale A webhook does not restore hardware.

## Verification

```bash
cd phase4-coordinator
go test ./internal/mdm ./internal/tier2 ./internal/pool ./internal/config -count=1
go test ./internal/ws -count=1 -run 'MDA|Attestation|Hardware|Tier'
go build -o /dev/null ./cmd/coordinator
```

All green.
