## Code Review Summary

**Files Reviewed:** 4 modified files  
**Total Issues:** 1  
**Scope Note:** Prompt said `HEAD: c761e55`; actual checkout HEAD is `efa1385`, but the four reviewed files are unchanged between `c761e55` and `efa1385`. Review anchored to `c761e55`.

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 1
- LOW: 0

### r2 Closures Verified

- **[code:r2-2.1] CLOSED:** [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:481) now checks `recA.To`, [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:486) checks `recB.To`, and [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:492) / [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:497) check both receipts for USDC logs with `cancel_self_transfer_mismatch`.
- **[code:r2-2.2] CLOSED:** [runner_rebroadcast_test.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner_rebroadcast_test.go:15) contains `TestRunner_RebroadcastPersistedBytes_NoReSign`; [runner_rebroadcast_test.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner_rebroadcast_test.go:83) contains `TestRunner_CancelPreCheck_LiveUnbroadcastBlocksFreshAllocation`.

### Issues

[MEDIUM] Cancel confirmation still does not enforce the full cancel-specific chain-side verification  
File: [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:492)  
Confidence: HIGH  
Issue: `pollCancelOnce` now rejects USDC logs on both receipts, but confirmation still does not verify the confirmed cancel transaction’s `value == 1 wei`, empty input, or recovered sender against the hot wallet before marking the cancel confirmed. SPEC §4.3 cancel-specific verification requires those invariants, and `rpc.TransactionByHash` already exposes `Value`, `Input`, `From`, and `To`.  
Fix: In `pollCancelOnce`, fetch `TransactionByHash` from both RPCs, assert `to == hot_wallet`, `value == "0x1"`, empty input, and `from == hot_wallet` on both sides, or decode `cancel.RawSignedTx` and assert the persisted signed envelope matches `cancel.TxHash` plus the cancel constants before confirmation.

### Open Questions

None.

### Positive Observations

- `Runner.Stop` return is consumed correctly in [main.go](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:798), and lease release is gated on clean shutdown.
- `operatorKeyMiddleware` keeps empty/missing bearer paths at 401 via the `len(given) == 0` guard in [mux.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:171).
- `hasUSDCTransferLog` checks any log from the USDC address, which matches the cancel-path requirement that no USDC log of any kind is expected.

### Tests Run

- `go test ./internal/payout ./cmd/coordinator` passed.
- `go test ./...` from `phase4-coordinator` passed.
- `lsp_diagnostics` not run: no LSP diagnostics tool is available here, and `gopls` is not installed.

### Recommendation

COMMENT. The r2 closures hold, and there are no CRITICAL/HIGH blockers, but the cancel confirmation path still has one medium spec-compliance gap.
tokens used
158 953


---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-code-review-lane-round-3-r-2026-06-25T16-49-55-861Z.md._
