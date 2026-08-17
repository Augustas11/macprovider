# Phase 3 live MDA — R5 remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Date:** 2026-08-17  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R5_FINDINGS.md`

## Summary

Fixed both MEDIUM findings (0 CRITICAL / 0 HIGH / 0 MEDIUM remaining for R5 scope).

| ID | Fix |
|----|-----|
| **R5-M1** | Webhook upgrade resolves the provider’s **current** session `AssignedID` after SE-hash checks; pending’s stored ID is diagnostics-only. |
| **R5-M2** | Cached MDA hardware requires a current device binding whose serial matches the MDA leaf (or stored proof serial). |

## R5-M1 — Current AssignedID on webhook upgrade

**Problem:** Durable pending kept the enqueue-time `assigned_id`. After reconnect, `SetMDAProof(providerID, staleID, …)` failed, the webhook marked failed, and the 168h ledger blocked retry.

**Change (`live_mda.go` `HandleMDACommandWebhook`):**
1. After SE-hash validation succeeds, `Resolve(providerID, "")` for the live session.
2. Call `verifyAndUpgrade` with **current** `AssignedID`.
3. Pending may still store the old ID; it is not required to match for upgrade success.
4. If no live session, re-queue pending (`202 Accepted`) instead of marking failed.

**Regression:** `TestWebhookUpgradeUsesCurrentAssignedIDAfterReconnect` — pending `s1`, live registry `s2`, same SE key → hardware on `s2`.

## R5-M2 — Cached hardware requires binding serial match

**Problem:** `tryUpgradeFromCache` / `AttachCachedMDAProof` could publish `hardware` from cached MDA without checking the current binding serial.

**Changes:**
1. Pool: `Provider.MDASerial`; plumbed through `SetMDAProof`, `LoadMDAProofCache`, `MDAProof`, `MigrateMDAProofFrom`, `ClearMDAProof`.
2. `hydrateDurableProof` passes durable `mda_proofs.serial` into `LoadMDAProofCache`.
3. `cachedProofMatchesBinding` before cache upgrade:
   - No binding → refuse upgrade; leave cache bytes.
   - Proof serial (leaf preferred, else stored) must match `binding.Serial` (case-insensitive); mismatch → `ClearMDAProof`.
4. Matching binding still upgrades via existing chain re-verify.

**Regressions:**
- `TestCachedMDARefusesWithoutBinding`
- `TestCachedMDARefusesBindingSerialMismatch`
- `TestCachedMDAAllowsMatchingBinding`

Also updated `TestDurableMDAProofSurvivesNewService` to persist/hydrate bindings via `SetMDAStore` so cache reattach remains honest under R5-M2.

## Verification

```bash
cd phase4-coordinator
go test ./internal/mdm ./internal/tier2 ./internal/pool ./internal/config -count=1
go test ./internal/ws -count=1 -run 'MDA|Attestation|Hardware|Tier'
go build -o /dev/null ./cmd/coordinator
```

All green.
