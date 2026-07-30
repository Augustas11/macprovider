# Audit: ISS-165 R2 code lens — fix pass on R1 findings

R1 returned 0/3/1/1 (code+sec+arch convergent). R2 verifies the
fix pass on commit `a5e9e34` against HEAD on
`spec/iss-165-spec-016-followups`. Tree: `git log --oneline -3`.

## R1 findings to verify

- **CODE/ARCH HIGH (convergent)**: SPKI SIGHUP CloseIdleConnections
  was guarded by `rpcs.Primary.(*HTTPRPCClient)` type assertion which
  failed through the new TrackingRPCClient wrapper.
  Fix: `chronic.go` adds `(*trackingRPC).CloseIdleConnections()`
  forwarding to inner; `main.go:1429` switches to an
  `interface{ CloseIdleConnections() }` assertion.
- **SEC HIGH**: `orphans.go` LIMIT bounded the SCAN; non-actionable
  rows could permanently block stale-cancel PAGEs (denial of
  detection). Fix: scan up to `staleOutboxScanCap=1000`, loop
  produces up to `limit`, break when `produced >= limit`.
  Regression test: `TestProduceStaleOutboxRows_NonActionableRowsDoNotConsumeLimit`.
- **ARCH HIGH**: Evaluate cadence — RunInterval ∈ [5m, 24h], tracker
  window 10m → samples pruned before observation. Fix: independent
  goroutine `(*ChronicOutageTracker).Run(ctx)` ticks at
  `min(window/2, 1min)`; launched from `main.go` next to other
  payout tickers.
- **ARCH MEDIUM**: shared `max_rows_per_run` cap overload between
  §4.3 step-1 and §4.7 step-5 documented normatively in SPEC v0.1.22
  change-log + §9 alert-filter list now includes both new events.

## Files to re-inspect

- `phase4-coordinator/internal/payout/orphans.go`
- `phase4-coordinator/internal/payout/chronic.go`
- `phase4-coordinator/internal/payout/runner.go` (unchanged from R1)
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/internal/payout/iss165_a1_test.go`
- `specs/SPEC-016-payout-pipeline.md`

## What I want (R2 code lens)

Verify EACH R1 finding is actually closed AND the fix didn't open
new defects. Look for:

- Did the wrapper expose every method the SIGHUP handler / future
  callers might assert on?
- Does the new `staleOutboxScanCap=1000` constant interact with
  any other SQL limit / pagination cursor?
- Does `Run()` shut down cleanly on ctx cancel (no goroutine leak)?
- Tests cover the regression class adequately?

Find NEW defects (code lens). Same severity / output format as R1.
End with `## Convergence X/X/X/X → DECISION`.
