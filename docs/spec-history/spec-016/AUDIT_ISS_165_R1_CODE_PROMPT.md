# Audit: ISS-165 R1 code lens (LIMIT + chronic-outage IMPL)

You are reviewing a code change for the macprovider monorepo. You may
NOT read external state — only files in this repo. Tree at HEAD:
`spec/iss-165-spec-016-followups` (`git log --oneline -2`).

## Scope

Issue #165 closes two LOW arch advisories deferred from PR #164:

- **A1**: `phase4-coordinator/internal/payout/orphans.go::ProduceStaleOutboxRows`
  now accepts a `limit int` (sized from `snap.MaxRowsPerRun`), uses a
  LIMIT+1 peek to detect backlog, runs a COUNT(*) for the exact figure
  on overflow, emits `payout_stale_outbox_backlog` WARN, and drops the
  overflow row so production stays bounded by `limit`.
- **A2**: new `phase4-coordinator/internal/payout/chronic.go` adds a
  `ChronicOutageTracker` (sliding-window per-RPC-label error-rate
  detector) and `TrackingRPCClient` wrapper. Wired from `main.go`;
  runner `Evaluate()`s once per cycle and emits
  `payout_rpc_chronic_outage` PAGE.

SPEC: SPEC-016 v0.1.22 documents both events in §7.1.

Tests: 4 + 7 added in `iss165_a1_test.go` + `iss165_a2_test.go`.

## Files in scope

- `phase4-coordinator/internal/payout/orphans.go` (modified)
- `phase4-coordinator/internal/payout/chronic.go` (new)
- `phase4-coordinator/internal/payout/runner.go` (modified)
- `phase4-coordinator/cmd/coordinator/main.go` (modified)
- `phase4-coordinator/internal/payout/iss165_a1_test.go` (new)
- `phase4-coordinator/internal/payout/iss165_a2_test.go` (new)
- `phase4-coordinator/internal/payout/step3_r2_test.go` (call-site update)
- `specs/SPEC-016-payout-pipeline.md` (v0.1.22 change-log + §7.1 rows)

## What I want from you (code lens)

Find **CODE DEFECTS** in this diff: bugs, races, off-by-ones, wrong
default behavior, missing nil checks, broken backward compatibility,
incorrect SQL semantics, incorrect concurrent state mutations. Stay
narrow to code — do not duplicate the architect or security lanes
(separate prompts cover those).

For each finding, label severity:
- **CRITICAL**: silent money/data loss, deadlock, panic on a
  realistic input.
- **HIGH**: observably wrong behavior in production, or test gap
  large enough to mask a real defect.
- **MEDIUM**: subtle bug, edge case missed, fragile structure that
  would bite the next change.
- **LOW**: lint-level smell, deferrable polish.

Output format:

```
## CRITICAL
- <site>:<line> — <one-line claim>
  Repro: <short repro / scenario>
  Fix: <one-line suggestion>

## HIGH
...

## MEDIUM
...

## LOW
...

## Convergence
0/0/0/0 → NO FIX PASS, or N/N/N/N → NEEDS FIX PASS
```

Mark the final convergence line as `0/0/0/0 → NO FIX PASS` only when
you found zero CRITICAL/HIGH/MEDIUM and at most ack-only LOWs.
