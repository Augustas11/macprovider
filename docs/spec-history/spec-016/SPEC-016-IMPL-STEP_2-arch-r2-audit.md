## Summary

Round 2 verdict: **0 CRITICAL / 0 MAJOR / 2 MEDIUM / 1 deferred LOW**. The r1 MAJOR lifecycle and admin mux findings are mostly closed, SPKI pinning is wired, and chi composition is no longer blocked. I did **not** write `specs/SPEC-016-IMPL-STEP_2-arch-r2-audit.md` because the prompt also says this lane is read-only and must not modify files.

Validation passed:

```text
go test -count=1 ./internal/payout ./cmd/coordinator
```

## Analysis

**[arch:3.1-r2] MEDIUM - shutdown can release the lease after Stop times out, not only after the cycle finishes.**  
`payoutS2.stop` calls `runner.Stop(stopCtx)` and then always calls `Release` at [main.go:790](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:790)-[795](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:795). But `Runner.Stop` returns either when `r.done` closes or when `ctx.Done()` fires at [runner.go:135](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:135)-[140](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:140). That means the SIGTERM 30s path does not strictly prove “cycle complete before lease delete.”  
Recommendation: make `Stop` return `error`/`bool`, and release only on confirmed stop; otherwise let the lease stale out.

**[arch:3.2-r2] CLOSED - admin mux mounting is fixed.**  
`main.go` mounts the same payout handler at both `/providers/` and `/admin/payout/` at [main.go:327](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:327)-[335](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:335). `NewMuxStep2` registers provider payout address, `abandon-attempt`, and `run-now` routes at [mux.go:136](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:136)-[153](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:153). Missing/wrong operator key returns 401 at [mux.go:161](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:161)-[167](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:167). Unknown `/admin/payout/*` falls to chi 404.

**[arch:3.3-r2] CLOSED by code trace - SPKI pinning is wired.**  
`main.go` passes primary/secondary SPKI pins into `NewHTTPRPCClient` at [main.go:670](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:670)-[672](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:672). The constructor installs `tls.Config.VerifyPeerCertificate` when a pin is non-empty at [rpc.go:123](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/rpc.go:123)-[131](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/rpc.go:131), and mismatch returns `SPKI pin mismatch` at [rpc.go:158](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/rpc.go:158)-[162](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/rpc.go:162). Test gap: I found no SPKI-specific unit test.

**[arch:3.4-r2] MEDIUM - one `payout_capped` emit still drops §7.1 fields.**  
The per-payout cap event includes `provider_id` and `ts_utc` at [runner.go:287](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:287)-[294](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:294), but the per-day cap event omits both at [runner.go:539](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:539)-[544](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:544). Other requested fields are now present for run started/finished, paid, failed, signer unavailable, and invariant violation.  
Recommendation: add a typed event helper or table-driven log-field test before Step 3 adds more operator events.

**[arch:3.5-r2] LOW deferral remains valid.**  
The deferral file tracks §4.7 column drift as SPEC v0.1.22 work at [SPEC-016-IMPL-STEP_2-r1-deferrals.md:27](/Users/augstar/macprovider-poc/specs/SPEC-016-IMPL-STEP_2-r1-deferrals.md:27)-[41](/Users/augstar/macprovider-poc/specs/SPEC-016-IMPL-STEP_2-r1-deferrals.md:41). `reorg.go` avoids the broken `payout_attempts.id` / `payout_external_id` SQL and uses `(payout_id, attempt_seq, tx_hash)` at [reorg.go:32](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reorg.go:32)-[38](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reorg.go:38) and [reorg.go:72](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reorg.go:72)-[78](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reorg.go:78).

## Root Cause

The fix-pass closed the large coordinator wiring gaps, but two boundaries are still too informal: lifecycle shutdown does not distinguish “stopped” from “timed out,” and event emission remains inline, allowing one §7.1 field-set drift to survive.

## Recommendations

1. Fix `Runner.Stop`/lease release contract - low/medium effort - high impact for §4.8b safety.
2. Add typed payout event emitters or field-set tests - medium effort - prevents Step 3/4 event drift.
3. Add SPKI unit tests - low effort - locks the r2 closure.
4. Add a Step 4 payout tuning owner - medium effort - `payout.tuning.*` is value-captured today in `RunnerOptions` and `ReorgPoller`, while SIGHUP reload currently only updates Tier2/billing paths at [main.go:374](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:374)-[375](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:375).

## Step 2 -> Step 3 Readiness

| Row | r2 verdict | Reason |
|---|---|---|
| record-orphan endpoint | FRICTION | Schema path is workable, but SPEC §4.7 drift should be corrected before endpoint text hardens. |
| record-funding endpoint | READY | Admin mux composition is no longer blocked. |
| pause/resume | FRICTION | Runtime flag foundation exists, but Step 3 should add field-set/rate-limit tests with the endpoint. |
| chi mux composition | READY | `/providers/` and `/admin/payout/` are both mounted and chi route parity is enforced. |
| Step 4 SIGHUP tuning | NOT READY | Values are captured at startup; add an atomic payout tuning provider and ticker-reset semantics. |

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| Patch the two r2 MEDIUMs directly | Small, fast, unblocks convergence | Leaves event/lifecycle patterns easy to regress |
| Add typed event and lifecycle helpers now | Better Step 3/4 foundation | More structure before endpoint work |
| Defer hot-reload seam to Step 4 | Keeps Step 2 smaller | Step 4 will touch runner, reorg poller, abandon service, and main shutdown/reload paths together |

## References

- [main.go:321](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:321) - `setupPayout` receives `billingStore` as `PayoutClaimer`.
- [main.go:341](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:341) - runner and reorg poller start only when `payoutS2 != nil`.
- [runner.go:539](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:539) - per-day `payout_capped` missing `provider_id`, `ts_utc`.
- [rpc.go:119](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/rpc.go:119) - SPKI-aware RPC constructor signature.
- [SPEC-016-payout-pipeline.md:3570](/Users/augstar/macprovider-poc/specs/SPEC-016-payout-pipeline.md:3570) - `payout.tuning.*` must be SIGHUP hot-reloadable.
tokens used
115 004

```

## Concise summary

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-architecture-review-lane-r-2026-06-25T16-38-18-061Z.md._
