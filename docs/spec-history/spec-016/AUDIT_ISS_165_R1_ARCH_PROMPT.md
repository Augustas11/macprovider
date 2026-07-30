# Audit: ISS-165 R1 architect lens

Issue #165 IMPLs two LOW arch advisories deferred from PR #164:
- **A1**: `ProduceStaleOutboxRows` accepts a `limit` from
  `snap.MaxRowsPerRun`; LIMIT+1 peek + COUNT(*) for backlog;
  emits `payout_stale_outbox_backlog` WARN.
- **A2**: `ChronicOutageTracker` + `TrackingRPCClient` wrapper +
  `payout_rpc_chronic_outage` PAGE, evaluated once per runner cycle.

SPEC: SPEC-016 v0.1.22 documents both events in §7.1.

Tree at HEAD: `spec/iss-165-spec-016-followups` (`git log --oneline -2`).

## Files in scope

- `phase4-coordinator/internal/payout/orphans.go` (modified)
- `phase4-coordinator/internal/payout/chronic.go` (new)
- `phase4-coordinator/internal/payout/runner.go` (modified)
- `phase4-coordinator/cmd/coordinator/main.go` (modified)
- `phase4-coordinator/internal/payout/iss165_a1_test.go` (new)
- `phase4-coordinator/internal/payout/iss165_a2_test.go` (new)
- `specs/SPEC-016-payout-pipeline.md` (v0.1.22)

## What I want from you (architect lens)

Find **DESIGN DEFECTS**: SPEC↔IMPL drift, missing call sites where
the new abstraction SHOULD be authoritative, cross-spec contracts
the change forgot, scaling/concurrency model errors,
observability gaps that make the IMPL fail-quiet, missing operator
runbook anchors.

Specifically inspect:

1. **A1 LIMIT semantics**: Is `snap.MaxRowsPerRun` the right cap for
   §4.7 step-5 production? The §4.3 ready-row scan uses the same
   cap. If the operator sets `max_rows_per_run=200`, is 200 stale
   cancels per cycle too many (PAGE storm) or too few (slow
   drain)? Should §4.7 have its own cap or share one?
2. **Backlog drain convergence**: when backlog persists across many
   cycles, does the `payout_stale_outbox_backlog` WARN repeat each
   cycle? Is that the desired operator behavior, or should it
   throttle?
3. **Cooldown vs window interaction**: A2's PAGE cooldown is 10min
   and window is 10min — once a label PAGEs, the next PAGE can only
   fire when fresh samples accumulate AND the cooldown expires.
   Is the steady-state behavior reasonable (PAGE-fire-then-quiet
   while still failing)?
4. **Wrapper completeness**: does `TrackingRPCClient` cover every
   `RPCClient` method? Are there call sites that bypass the wrapper
   (direct `payout.NewHTTPRPCClient` callers, fake test clients)?
   Verify `main.go` is the only construction site.
5. **Tracker location**: tracker is owned by the runner and
   evaluated once per cycle. But the reorg poller, chain-balance
   worker, and admin endpoints also share the same RPCs via the
   wrapper. Does the once-per-cycle Evaluate cadence miss a chronic
   outage that ONLY shows up during the chain-balance worker's
   independent ticker? Should other tickers also Evaluate?
6. **SPEC v0.1.22 entry**: does the §7.1 row set match the IMPL
   emits exactly? Any prose elsewhere in the SPEC body that now
   contradicts the new events?
7. **Test coverage adequacy**: do the regression tests pin the
   FAILURE class each advisory was supposed to close, or do they
   only test the happy path?

Find **DESIGN DEFECTS**. Stay narrow — separate code + security
lanes cover correctness + threat-model.

Severity:
- CRITICAL: SPEC↔IMPL drift on money path; missing
  authority-everywhere coverage; broken cross-spec contract.
- HIGH: observability gap that hides a real failure mode in
  production; runbook anchor missing for a PAGE event.
- MEDIUM: design awkwardness that will force a churn-y refactor
  in the next change.
- LOW: deferrable architectural polish.

Output format identical to the code lens. End with
`## Convergence X/X/X/X → DECISION`.
