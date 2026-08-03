# IMPL audit prompt — SPEC-016 FULL IMPLEMENTATION (Steps 1+2+3+4), shared context, r1

This is the holistic / cross-step audit covering the ENTIRE
SPEC-016 implementation now on `impl/spec-016`. Each of the 4
incremental Steps already converged to 0/0/0/0 in its own audit
loop (Step 1: 2 rounds; Step 2: 4 rounds; Step 3: 3 rounds;
Step 4: 8 rounds). This new round looks for defects that only
surface when ALL FOUR steps are read together:

- end-to-end money path (register → ready → broadcast → confirm
  → claim → reconcile)
- cross-step composition (Step 2 runner ↔ Step 3 reaper ↔ Step 4
  chain-balance worker / SIGHUP / run-now controller)
- holistic §7.1 event field sweep across every event introduced by
  any step
- import-graph + co-residency invariants enforced across
  modules added by all 4 steps
- shutdown ordering with ALL 5 background workers (runner,
  reorgPoller, reaper, chainWorker, SIGHUP listener)
- migration ordering (Step 1 → Step 3 schema additions; no Step
  goes backward)

Master shared-context block referenced by the three lane-specific
prompts:
- `specs/AUDIT_SPEC_016_IMPL_FULL_CODE_PROMPT_r1.md`
- `specs/AUDIT_SPEC_016_IMPL_FULL_SECURITY_PROMPT_r1.md`
- `specs/AUDIT_SPEC_016_IMPL_FULL_ARCH_PROMPT_r1.md`

All three lanes are **read-only**. Codex MUST NOT modify any
file. If the lane wants to suggest a fix, write it as recommended
text in the findings file (e.g. `specs/SPEC-016-IMPL-FULL-{lane}-r1-audit.md`).

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `47e4f24 impl(016): Step 4 CONVERGED — close [code:r8-1] LOW comment drift + write convergence summary`
- Diff base: `main` (the entire SPEC-016 implementation is on this
  branch and will land in a SINGLE PR after this audit converges)

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`

## Implementation surface (~5,000-7,000 LOC)

### Step 1 (migrations + §3.2/§3.3 register endpoint)
- `phase4-coordinator/internal/payout/migrations/00*.sql` —
  initial payout schema
- `phase4-coordinator/internal/payout/migrations.go` — migration runner
- `phase4-coordinator/internal/payout/addresses.go` — §3.3 handler +
  §3.2 EIP-712 verification + §3.4 audit emits
- `phase4-coordinator/internal/payout/config_security.go` —
  immutable security namespace
- `phase4-coordinator/internal/billing/payout_address_reader.go` —
  one-way import boundary

### Step 2 (§4.3 runner cycle + §4.6 abandon + §4.7 reorg)
- `phase4-coordinator/internal/payout/runner.go` — Runner cycle,
  RequestHalt primitive, currentHotWalletUSDCBalance,
  rowOutcomeInsufficientFunds, deductPaidAmount co-located in
  broadcast paths
- `phase4-coordinator/internal/payout/lease.go` — §4.8b lease
  (acquire/heartbeat/self-fence/release)
- `phase4-coordinator/internal/payout/attempts.go` —
  payout_attempts CRUD + AttemptRow + ErrDuplicateLiveAttempt
- `phase4-coordinator/internal/payout/eip1559.go` +
  `phase4-coordinator/internal/payout/rlp.go` — RLP/EIP-1559
  encoding
- `phase4-coordinator/internal/payout/signer.go` +
  `phase4-coordinator/internal/payout/wallet_file.go` —
  LocalFileSigner + KEK-from-systemd
- `phase4-coordinator/internal/payout/rpc.go` — TwoRPCs,
  HTTPRPCClient, makeSPKIPinVerifier with live func() string pin,
  CloseIdleConnections
- `phase4-coordinator/internal/payout/abandon.go` — §4.6 admin
- `phase4-coordinator/internal/payout/reorg.go` — §4.7 ReorgPoller

### Step 3 (§4.8a reaper + §4.9 funding + §6.4.1 pause/resume + orphans + runtime flags)
- `phase4-coordinator/internal/payout/runtime_flags.go` — outbox
  primitive (BEGIN IMMEDIATE write+audit + CAS-claim sync)
- `phase4-coordinator/internal/payout/pauseresume.go` — §6.4.1
- `phase4-coordinator/internal/payout/funding.go` — §4.9
- `phase4-coordinator/internal/payout/orphans.go` — §4.7
  record-orphan + ProduceStaleOutboxRows (runner-owned at stale
  transition)
- `phase4-coordinator/internal/payout/reaper.go` — §4.8a +
  §4.7 reaper background loops
- `phase4-coordinator/internal/payout/pause_reader.go` —
  pre-auth pause gate

### Step 4 (§6.5 SIGHUP tuning + §7.4 reconciliation + §6.2 balance + §7.3 read + §4.2 run-now)
- `phase4-coordinator/internal/payout/config_tuning.go` —
  TuningProvider + TuningSnapshot + atomic.Value +
  BoundViolationError
- `phase4-coordinator/internal/payout/reconcile.sql` +
  `phase4-coordinator/internal/payout/reconcile.go` —
  ParseLabeledQueries + ChainBalanceWorker (both-RPC balanceOf
  + drift + signed PAGE)
- `phase4-coordinator/internal/payout/payouts.go` — §7.3 GET
  /providers/{id}/payouts with sliding-window limiter
- `phase4-coordinator/internal/payout/runnow.go` — RunNowController
  (rate limit + payout_run_now_invoked + halt-race)
- `phase4-coordinator/internal/payout/mux.go` — chi path-table
  Step2/3/4 mux levels
- `phase4-coordinator/cmd/coordinator/main.go` — setupPayout
  (TuningProvider construction order, RPC clients with live SPKI
  closures, RunNowController wiring, shutdown ordering with 5
  workers, SIGHUP listener with LoadPayoutTuningOnly, halt
  callback → runner.RequestHalt, idle-pool drain on SPKI change)
- `phase4-coordinator/internal/config/config.go` —
  LoadPayoutTuningOnly + resolveEnv for payout.security.*

### Ops bundle
- `phase4-coordinator/dist/coordinator.yaml.example` — full
  payout.* block with placeholder + env:NAME indirection
- `phase4-coordinator/dist/check-deploy-config.sh` — payout deploy
  gate (placeholders, env:NAME, low_balance/low_native required,
  SPKI 64-hex, payout.enabled=false skip)
- `phase4-coordinator/dist/payout-runbook.md` — operator runbook
  (hot wallet, key rotation, caps, BetterStack alert list, SPKI
  pin rotation procedure)

### Step convergence files for context
- `specs/SPEC-016-IMPL-STEP_1-r*-audit.md` — Step 1 history
- `specs/SPEC-016-IMPL-STEP_2-r*-audit.md` — Step 2 history
- `specs/SPEC-016-IMPL-STEP_3-r*-audit.md` — Step 3 history
- `specs/SPEC-016-IMPL-STEP_4-{code,security,arch}-r*-audit.md` — Step 4 history
- `specs/SPEC-016-IMPL-STEP_4-r8-convergence.md` — Step 4 final summary

## Severity guidance

- **CRITICAL** — money-path defect or data-loss class. Examples:
  reconcile query that lets a fake-funding row through (E or F);
  bound matrix that accepts a security-namespace value; runner
  that double-spends; broadcast that bypasses self-fence; address
  rotation that silently re-enables compliance-disabled provider.
- **HIGH** — confirmed exploitable security defect OR observable
  production correctness defect that escapes through tests OR
  SPEC §7.1 normative emission missing on money-path.
- **MEDIUM** — confirmed bug not directly observable in production
  but breaks an audit invariant: cross-step composition gap,
  schema drift, test-coverage gap on money-path branch.
- **LOW** — cosmetic / docs / minor consistency.

## Per-lane BLOCK rule

Each lane returns 0/0/0/X (LOWs OK; CRITICAL/HIGH/MEDIUM must be 0)
to declare CONVERGENT. Anything ≥ MEDIUM triggers a fix-pass + r2.

## Output format

Each lane writes findings to its own file at the project root
under `specs/`:
- `specs/SPEC-016-IMPL-FULL-code-r1-audit.md`
- `specs/SPEC-016-IMPL-FULL-security-r1-audit.md`
- `specs/SPEC-016-IMPL-FULL-arch-r1-audit.md`

Standard structure: one-line Verdict, counts table
(CRITICAL/HIGH/MAJOR/MEDIUM/LOW), one section per finding with
`[full-code:r1-X]` / `[full-sec:r1-X]` / `[full-arch:r1-X]` label
+ severity + evidence (file:line) + recommended fix.

## Discipline

- This is the FULL-SCOPE audit. The 4 incremental Step audits are
  done; assume their findings are closed. Look for cross-step
  defects + holistic invariants the per-Step audits could not have
  caught.
- Wall-clock target: 35-45 min (larger surface).
- Read-only.
