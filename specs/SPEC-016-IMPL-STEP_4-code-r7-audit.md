# SPEC-016 Step 4 IMPL Code Audit - r7

## Code Review Summary

**Lane:** code-only r7 audit  
**Branch:** `impl/spec-016`  
**Prompt commit under audit:** `2935ed6`  
**Observed workspace HEAD:** `a13cb1d` (adds the r7 audit prompt only; implementation diff under review remains `2935ed6^..2935ed6`)  
**Files Reviewed:** 2 modified Go files, plus related runner paths and SPEC section 7.1 lines 3712-3732  
**Total Issues:** 1

### By Severity

- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0

### Issues

[HIGH] Running balance is deducted for paid outcomes that did not spend hot-wallet funds in this cycle

File: `phase4-coordinator/internal/payout/runner.go:515`

Confidence: HIGH

Issue: `RunOnce` deducts `row.ProviderCredits` from `Runner.runningBalance` for every `rowOutcomePaid` (`runner.go:515-521`). That outcome is overloaded: it is returned not only after the fresh `allocateBuildSignBroadcast` path, but also when `processRow` sees an existing confirmed attempt and calls `claimAndLog` directly (`runner.go:641-643`), and when `pollAndConfirm` confirms a previously broadcast attempt (`runner.go:656-658`, `runner.go:1166`, `runner.go:1223`). The cycle-scoped balance is read from chain at the top of `RunOnce`; for an already-confirmed attempt, that on-chain balance already reflects the prior transfer. Deducting again makes the in-memory tally too low, so a later fresh payout in the same cycle can incorrectly emit `payout_insufficient_funds`, increment `skipped_funds`, and halt even when the hot wallet actually has enough USDC for that later transfer.

Concrete failure shape: row 1 has an existing confirmed attempt for 80 and row 2 is a fresh payout for 100. If the top-of-cycle on-chain balance is 100, row 1 should claim without affecting the available balance for new transfers; current code deducts 80 after row 1 and causes row 2's in-broadcast guard to see only 20 available.

Fix: separate "provider payout claimed/paid" from "fresh hot-wallet spend occurred in this cycle." For example, return a distinct outcome or transfer-spent amount from `processRow`, and call `deductPaidAmount` only for the fresh transfer path after the cycle actually initiated/confirmed a transfer whose spend was not already reflected in the top-of-cycle balance. Add a regression test with an existing confirmed attempt followed by a fresh payout that exactly fits the top-of-cycle balance.

### Open Questions (low-confidence findings - surfaced, not blocking)

None.

### r6 Closure Verification

- The misplaced r5 top-of-row-loop insufficient-funds guard is gone.
- The new insufficient-funds guard exists inside `allocateBuildSignBroadcast` after the per-day cap check and before the attempt insert.
- On insufficient balance, `payout_insufficient_funds` includes the SPEC section 7.1 required fields and returns distinct `rowOutcomeInsufficientFunds`; the transaction is left uncommitted so the deferred rollback runs.
- `Runner.runningBalance` is set after ready-row selection and cleared by defer at cycle exit.
- `hotWalletBalance` returns a defensive `big.Int` copy.
- `rowOutcomeInsufficientFunds` is distinct from capped, daily-cap-tripped, failed, and skipped outcomes, and `RunOnce` handles it with `skippedFunds++` plus `break rowLoop`.
- The three new r6 boundary tests cover over-per-payout-cap, daily-cap-trip, and existing-confirmed rows with low balance. They close the r6 guard-placement regression, but they do not cover an existing-confirmed row followed by a fresh payout that relies on the same cycle-scoped balance.

### No Regression Spot-Check

- Per-payout cap still emits `payout_capped` with `run_id`, `payout_id`, `provider_id`, `reason`, and `ts_utc`.
- Daily cap still emits `payout_daily_cap_tripped` and breaks the row loop.
- Fresh insufficient-funds still emits `payout_insufficient_funds`, increments `skipped_funds`, inserts no attempt row, and halts the row loop.
- RPC failure during the initial balance read leaves `runningBalance == nil`; the in-broadcast guard falls through, preserving the documented fallback.

### Section 7.1 Event Sweep

The Step 4 event rows in SPEC section 7.1 lines 3712-3732 were rechecked against the touched runner paths and related event emitters. The r6 fix-pass did not remove required fields from the touched events: `payout_run_started`, `payout_run_finished`, `payout_paid`, `payout_failed`, `payout_capped`, `payout_insufficient_funds`, and `payout_daily_cap_tripped`. Related existing emitters for run-now, balance alerts, reorg, RPC disagreement, chain-balance drift, nonce cold-start, config reload/reject, and registration pause/resume were spot-checked and no field regression was found.

### Validation Evidence

- `go test -count=1 ./...` from `phase4-coordinator/`: PASS
- `go test -race -count=1 ./internal/payout/...` from `phase4-coordinator/`: PASS
- `gofmt -l phase4-coordinator/internal/payout/ phase4-coordinator/cmd/coordinator/`: PASS, no output
- `git diff --check 2935ed6^..2935ed6`: PASS, no output
- `lsp_diagnostics`: unavailable in this Codex environment (`gopls` is not installed); Go tests were used as the type/build validation substitute.
- `ast_grep_search`: unavailable (`sg` is not installed); targeted `rg` static-pattern scan over the audited payout/coordinator paths found no empty-catch, `console.log`, or hardcoded `apiKey/password/secret/token =` patterns.

### Positive Observations

- The r6 relocation correctly puts the insufficient-funds guard at the broadcast authority layer, after per-payout-cap, daily-cap, and existing-attempt decisions.
- The `hotWalletBalance` defensive copy prevents accidental mutation by the guard caller.
- The new insufficient-funds outcome makes loop-halting behavior explicit instead of overloading capped or failed outcomes.
- The r6 tests lock the previously missed event-identity boundaries for capped, daily-cap, and existing-confirmed single-row cases.

### Recommendation

REQUEST CHANGES

r7 is **not CONVERGENT**: 0/1/0/0.
