**Summary**
Wrote the r3 architect audit to [SPEC-016-IMPL-STEP_2-arch-r3-audit.md](/Users/augstar/macprovider-poc/specs/SPEC-016-IMPL-STEP_2-arch-r3-audit.md:1).

Verdict: **CLEAN - 0 CRITICAL / 0 MAJOR / 0 MEDIUM / 0 LOW**. Both r2 architect MEDIUMs are verified closed, the §4.7 LOW remains a valid SPEC-side deferral, and Step 2 is architecturally ready for Step 3 with the same non-blocking friction rows.

**Analysis**
`Runner.Stop` now returns `bool` at [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:143). `main.go` releases the lease only on `cleanExit == true` and emits `payout_runner_lease_left_to_stale_out` on timeout at [main.go](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:798).

The per-day `payout_capped` path now includes `provider_id` and `ts_utc` at [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:561), matching §7.1’s required field set.

Shutdown ordering is acceptable for Step 2: `stopBackground()` → payout stop → WS drain → HTTP shutdown. This avoids initiating fresh payout work during shutdown; late finalized rows remain durable for the next runner holder.

**Root Cause**
The r2 defects were implicit contracts: shutdown treated “Stop returned” as “safe to release,” and inline event emission let one `payout_capped` branch drift. `c761e55` makes both contracts explicit enough for Step 2.

**Recommendations**
1. Proceed to Step 3.
2. Carry the §4.7 column-name drift into Step 3 `record-orphan` design.
3. Keep SIGHUP payout tuning as a Step 4 lifecycle change using `Runner.Stop(ctx) bool`.
4. Add lifecycle/event field-set tests in Step 3 or Step 4 to prevent recurrence.

**Trade-offs**
| Option | Pros | Cons |
|---|---|---|
| Proceed to Step 3 | All r2 architect MEDIUMs closed | Step 3 must remember the §4.7 drift |
| Patch SPEC first | Removes ambiguity | Delays implementation despite correct Step 2 workaround |
| Keep SIGHUP in Step 4 | Preserves step boundaries | Step 4 remains non-trivial |

**References**
- [Audit artifact](/Users/augstar/macprovider-poc/specs/SPEC-016-IMPL-STEP_2-arch-r3-audit.md:1)
- [runner.go:143](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:143)
- [main.go:798](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:798)
- [runner.go:561](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:561)
- [reorg.go:32](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reorg.go:32)

Verification passed: `go test -count=1 ./internal/payout ./cmd/coordinator` and `git diff --check`. Git status also shows untracked code/security r3 audit files that I did not touch.

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-architecture-review-lane-r-2026-06-25T16-51-18-126Z.md._
