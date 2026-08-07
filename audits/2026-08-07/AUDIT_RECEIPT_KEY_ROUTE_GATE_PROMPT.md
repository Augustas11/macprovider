# AUDIT — Settlement receipt-key routing-gate exclusion (coordinator, money-path)

You are auditing a **money-path** coordinator fix. Review the **FULL diff of the
complete fix as it will land**, not an incremental slice.

## Scope (audit exactly this)

- Base: `origin/main` (commit `ff09258a`). Fix commits: `a7546d94` (spec doc) +
  `8e9624ea` (implementation).
- Full-fix diff: `audits/2026-08-07/receipt-key-route-gate-fulldiff.patch`
  (also read the live files in the tree).
- Changed files:
  - `phase4-coordinator/internal/routing/filter.go`
  - `phase4-coordinator/internal/routing/filter_test.go`
  - `phase4-coordinator/internal/buyer/server.go` (eligibilityCtx + settlementEnforceMode + reason map)
  - `phase4-coordinator/internal/buyer/receipt_key_route_gate_test.go`
  - `phase4-coordinator/internal/buyer/route_snapshot_test.go` (updated expectation)
- Governing spec: `specs/SPEC-022-verified-model-settlement.md` (R-2.4, R-2.5, R-2.6);
  receipt-key binding in `specs/SPEC-015-receipts.md`. Write-up:
  `specs/FIX_SPEC_SETTLEMENT_RECEIPT_KEY_ROUTE_GATE_V0_1.md`.

## What the fix does

Under `verified_model_settlement_mode: enforce`, a provider whose active
`ReceiptPubkey` is empty was selected then rejected pre-dispatch at
`internal/buyer/route_snapshot.go:51` ("missing provider receipt key"). The fix
adds a candidate-eligibility gate in `routing.EligibleCandidates` (new
`ReasonReceiptKeyMissing`, `FilteredCounts` key `receipt_key_missing`) driven by
a new `EligibilityChecker.ProviderHasSettlementReceiptKey`, implemented on
`eligibilityCtx` and gated on a `settlementEnforce` bool snapshotted once at
checker construction via `Server.settlementEnforceMode()`. The pre-dispatch guard
is retained as fail-closed defence-in-depth.

## Required invariants (verify each; a violation is CRITICAL/HIGH)

1. **Observe / unavailable-store is byte-identical.** When mode != enforce, or the
   billing store is nil, NO provider is newly excluded (predicate returns true for
   all). Confirm `settlementEnforceMode()` returns false for nil store and observe.
2. **Same source of truth as the guard.** The eligibility predicate and the
   pre-dispatch `route_snapshot.go` guard MUST read the same
   (store, SettlementConfig, VerifiedModelSettlementMode) so they cannot disagree
   (one excludes, the other would have passed, or vice-versa).
3. **Snapshot-once consistency.** `settlementEnforce` is captured once per request
   at checker construction; confirm no mid-loop re-read and that all production
   construction sites set it (grep for `eligibilityCtx{`). A construction site that
   forgets it silently disables the gate — flag if any exists.
4. **Fail-closed preserved.** No path now lets an empty-receipt-key provider serve
   paid traffic or create a route snapshot / ledger credit under enforce. "missing"
   → excluded (503 no_provider_available, retryable, no charge); "malformed"
   (present but invalid) → still reaches guard → 500. No double-charge, no
   missed-fail-closed.
5. **429-vs-503 correctness.** Excluded-for-receipt-key providers never enter the
   pre-quota set, so `PreQuotaCount` excludes them and an all-excluded case yields
   503 (not a false 429 quota envelope).
6. **Gate ordering.** Placed after model/version-floor, before context/tier2/quota,
   so a receipt-key-missing provider never consumes quota and reason attribution is
   correct.
7. **Only length is checked at eligibility.** The gate checks `len(ReceiptPubkey)>0`
   (cheap, matches guard's empty-key branch). Validity (canonical key id) stays at
   the guard — confirm this split is intentional and safe (no key-validity bypass).

## Lane focus

- **code**: correctness, logic defects, nil/edge cases, test adequacy, whether the
  updated `route_snapshot_test.go` still proves fail-closed (0 snapshots, 0 credits).
- **security**: settlement integrity — can this cause missed fail-closed, a charge
  without a valid receipt, key-validity bypass, or observe-mode leakage? Any way an
  attacker/provider forces empty-key routing or crashes routing.
- **architect**: does gating at eligibility (vs keeping only the pre-dispatch guard)
  match SPEC-022 R-2.4/R-2.5 intent; is `EligibilityChecker` the right seam; any
  layering / drift risk between the two gates; is the non-goal (not touching the
  promotion state machine) sound.

## Output

Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO with `file:line` and a
concrete failure scenario for each. The landing bar is **0 CRITICAL, 0 HIGH,
0 MEDIUM**; LOW/INFO may ship documented. If clean, say so explicitly per severity.
