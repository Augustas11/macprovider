# IMPL audit prompt — SPEC-016 Step 4 (shared context)

This file is the master shared-context block referenced by the
three lane-specific prompts:

- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_ARCH_PROMPT.md`

Codex fires each lane separately via:

```
omc ask codex --agent-prompt code-reviewer    --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT.md)"
omc ask codex --agent-prompt security-reviewer --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT.md)"
omc ask codex --agent-prompt architect        --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_4_ARCH_PROMPT.md)"
```

All three lanes are **read-only**. Codex MUST NOT modify any
file.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `dbf7e78 impl(016): Step 4 — §6.5 dual-namespace loader + §7.4 reconcile + §6.2 balance monitoring + §7.3 read endpoint + ops bundle`
- Step 4 is the LAST step before the single PR opens. Per the
  consolidation plan in commit `92c8672`, the PR opens after
  Step 4's audit loop converges to 0/0/0 across all three
  lanes. Do NOT push, do NOT open PR until convergence.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What Step 4 lands

### §6.5 dual-namespace config loader

- `internal/payout/config_tuning.go` (~280 LOC) — `TuningProvider`
  with `sync.RWMutex` + `atomic.Value` snapshot; `NewTuningProvider`
  validates initial snapshot at construction; `Reload` is the
  SIGHUP entry point. Per SPEC §6.5 normative:
  - Successful reload → `payout_config_reloaded` PAGE per
    changed key (key + old + new + ts_utc).
  - Bound violation → `payout_config_reload_rejected` PAGE +
    LIVE VALUE RETAINED. Returns `ErrTuningBoundViolation`
    wrapping the failing field.
- `internal/payout/config_tuning_test.go` (~200 LOC) — 12 tests
  including the AST static-check that `config_tuning.go` has
  zero references to any `payout.security.*` identifier
  (`TestTuningStaticCheck_NoSecurityNamespaceReference`).
- `cmd/coordinator/main.go` — `startPayoutSIGHUPListener` is the
  SIGHUP-only signal handler. Re-reads YAML on signal, calls
  `TuningProvider.Reload`. fsnotify / runtime endpoint reload is
  NOT installed.

### §7.4 reconciliation queries + chain-balance worker

- `internal/payout/reconcile.sql` (~170 LOC) — verbatim §7.4
  queries: 3 unlabeled regression + 6 SPEC-labeled (A..F).
  Each labeled query has a `-- @label: X` directive. Embedded
  via `go:embed` in `reconcile.go`.
- `internal/payout/reconcile.go` (~440 LOC):
  - `ParseLabeledQueries()` — returns
    (LabeledQueries{"A":..., "F":...}, unlabeled[]) by
    walking the embedded SQL.
  - `ChainBalanceWorker` — periodic worker at
    `payout.security.chain_recon_interval` (default 1h):
    both RPCs `eth_call(USDC.balanceOf(hot_wallet))`,
    agreement check, drift comparison vs
    `total_funded - total_paid_out` (cancels excluded),
    signed-drift emit + haltRunner callback on negative.
- `internal/payout/rpc.go` — `RPCClient` extended with
  `CallContract(ctx, to, data) ([]byte, error)` +
  `NativeBalance(ctx, address) (uint64, error)`. `HTTPRPCClient`
  implementations + `mockRPCClient` test stubs updated.

### §6.2 balance monitoring

- `internal/payout/runner.go` — `RunnerOptions` extended with
  `LowBalanceThreshold` + `LowNativeThreshold`. `RunOnce` calls
  `emitBalanceAlerts` at top of every cycle before
  `SelectReadyPayouts`. Reads USDC + native balances via primary
  RPC; emits `payout_low_balance` / `payout_low_native_balance`
  WARN when below threshold. 0 disables that probe.

### §7.3 provider-scoped payouts read

- `internal/payout/payouts.go` (~270 LOC) — `PayoutsHandler`
  with provider-token auth + per-provider sliding-window rate
  limiter (60/min default; mirrors billing/endpoints.go::allowEarnings
  but kept package-local to keep the §4.1 import-graph one-way).
  Returns the last 50 payouts joined from `payout_attempts +
  ledger_payout_ready`. `is_cancel_self_transfer = 1` rows
  FILTERED OUT (providers MUST NOT see operator cancels).
- `internal/payout/mux.go` — `step4PathTable` adds the new
  route; `NewMuxStep4` wires it.

### Ops bundle

- `dist/coordinator.yaml.example` — full `payout.*` block with
  placeholder values (`<...>`), `env:NAME` indirection examples
  for RPC URLs, and SPEC §6.5 link comments.
- `dist/check-deploy-config.sh` — extended with payout.* deploy
  gate: placeholder strings + missing required keys → HARD;
  `env:NAME` deferred to runtime; SPKI pin 64-hex OR empty.
  Skipped when `payout.enabled: false`.
- `dist/payout-runbook.md` (~280 LOC) — operator runbook:
  hot-wallet provisioning + funding, cap-decision worksheet,
  BetterStack synthetic-alert verification list, cutover
  sequence, key-rotation 5 steps, weekly reconciliation triage.

### main.go wiring

- `payoutStep2` struct gets `chainWorker` + `tuning` fields.
- `setupPayout` constructs `TuningProvider` (validates initial
  snapshot) + `ChainBalanceWorker` (with haltRunner callback).
- runner-start site adds `chainWorker.Start(shutdownCtx)` + a
  goroutine for `startPayoutSIGHUPListener`.
- Shutdown closure stops chainWorker BEFORE runner so a final
  reconcile gets a chance to fire on clean shutdown; only
  releases lease when `runnerClean && pollerClean`.

## What the audit lane MUST check

Each lane checks its own slice; this master prompt enumerates
the cross-lane invariants:

1. **§6.5 security/tuning loader split.** `config_tuning.go`
   MUST have zero references to security-namespace
   identifiers — the unit test makes this a compile-time
   guarantee via AST walk. Verify no path in setupPayout
   threads a security key through the tuning provider.
2. **§6.5 SIGHUP-only.** No fsnotify watcher installed. No
   runtime debug endpoint reload. Only `syscall.SIGHUP` triggers
   `TuningProvider.Reload`. Verify.
3. **§6.5 bound re-enforcement.** `validateBounds` is called by
   BOTH `NewTuningProvider` AND `Reload`. The bound matrix is
   centralised so a future SPEC bump touches one place.
4. **§6.5 emit shape.** `payout_config_reloaded` emits ONE
   event PER CHANGED key (not one aggregate event); operators
   get audit-trail granularity. `payout_config_reload_rejected`
   names the failing field.
5. **§7.4 reconcile.sql verbatim.** All 6 labeled queries
   (A..F) AND 3 unlabeled regression queries present. Compare
   query body against SPEC §7.4 lines (cited in the comment
   blocks).
6. **§7.4 chain-balance worker.**
   - Both RPCs eth_call AND both must agree within tolerance
     (otherwise `payout_rpc_disagreement` + skip drift).
   - Expected balance = `total_funded - total_paid_out`
     EXCLUDING `is_cancel_self_transfer = 1`.
   - Positive drift → WARN. Negative drift → PAGE + haltRunner.
7. **§7.4 cancel exclusion across the board.** Query (D) MUST
   filter `is_cancel_self_transfer = 1`. Queries (F) +
   chain-balance recon MUST exclude `is_cancel_self_transfer = 0`
   from outflow.
8. **§7.3 provider-token + provider-mismatch 403.** The token
   provider returned by `ValidateToken` MUST equal the path
   provider_id — mismatch is 403, not 401.
9. **§7.3 cancel exclusion.** The SELECT MUST filter
   `is_cancel_self_transfer = 0`.
10. **§6.2 thresholds = 0 disables.** Don't probe the RPC if
    both thresholds are 0.
11. **Shutdown ordering.** chainWorker before runner before
    poller; reaper Stop bool doesn't gate Release.

## Severity guidance

- CRITICAL — money-path defect or data-loss class. Examples:
  reconcile.sql query that lets a fake-funding row through (E
  or F); bound matrix that accepts a security-namespace value;
  ChainBalanceWorker that compares wrong values.
- MAJOR — confirmed bug observable in production. Examples:
  SIGHUP listener registered for fsnotify; reload that mutates
  live value on rejection; deploy-gate that passes a
  placeholder; mux route registered without table entry.
- MEDIUM — confirmed bug NOT directly observable in production
  but breaks an audit invariant. Examples: §7.1 field set
  missing a field on the new events; race in TuningProvider
  Snapshot/Reload.
- LOW — cosmetic / docs / minor consistency.

## What to BLOCK on

BLOCK only on:

- A new CRITICAL.
- A SPEC normative rule that a future step cannot unwind
  (e.g. immutable security namespace gets a tuning-side
  mutation path).

Everything else is FIX-THEN-PROCEED.

## Output format

Each lane writes findings to its own file:

- `specs/SPEC-016-IMPL-STEP_4-code-r1-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-security-r1-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-arch-r1-audit.md`

Structure: one-line Verdict, counts table (CRITICAL/MAJOR/
MEDIUM/LOW), one section per finding with [code:X.Y] /
[sec:X.Y] / [arch:X.Y] label + severity + evidence (file:line)
+ recommended fix.
