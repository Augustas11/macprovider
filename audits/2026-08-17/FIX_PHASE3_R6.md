# Phase 3 live MDA — R6 remediation

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda`  
**Date:** 2026-08-17  
**Source findings:** `audits/2026-08-17/AUDIT_PHASE3_R6_FINDINGS.md`

## Summary

Fixed the single MEDIUM finding (0 CRITICAL / 0 HIGH / 0 MEDIUM remaining for R6 scope).

| ID | Fix |
|----|-----|
| **R6-M1** | Fresh MDA webhook reloads current durable binding and requires serial match to both `pending.ExpectedSerial` and the MDA leaf before `verifyAndUpgrade` / `SetMDAProof`. |

Also hardened exported `UpgradeFromParsedAttestation` with the same binding↔leaf serial check (ARCHITECT INFO).

## R6-M1 — Webhook re-checks current binding before hardware

**Problem:** `HandleMDACommandWebhook` validated the MDA leaf only against `pending.ExpectedSerial` (snapshotted at enqueue), then upgraded without reloading `bindings.LookupByProvider`. Rebind A→B while an A webhook was pending could still publish `hardware`.

**Change (`live_mda.go`):**
1. Helper `currentBindingMatchesSerial(providerID, wantSerial)` — binding present, non-empty serial, case-insensitive match.
2. In `HandleMDACommandWebhook`, after resolving the current session and **before** `verifyAndUpgrade`: require current binding matches both `pending.ExpectedSerial` and `ExtractMDASerialNumber(leaf)`.
3. On absent/mismatch: do not `SetMDAProof`; `markEnqueueFailed` (clears pending + terminal failed); `403` with clear rebind-TOCTOU log.
4. `UpgradeFromParsedAttestation`: parse leaf serial and require the same binding match before `verifyAndUpgrade`.

**Regression:** `TestWebhookRefusesAfterRebindSerialChange` — enqueue pending for serial A, `Claim` rebind to B, deliver webhook for A → `attestation_tier` stays non-hardware; no MDA proof published.

Happy-path webhook tests now `Claim` a matching binding so they stay honest under R6-M1.

## Verification

```bash
cd phase4-coordinator
go test ./internal/mdm ./internal/tier2 ./internal/pool ./internal/config -count=1
go test ./internal/ws -count=1 -run 'MDA|Attestation|Hardware|Tier'
go build -o /dev/null ./cmd/coordinator
```

All green.
