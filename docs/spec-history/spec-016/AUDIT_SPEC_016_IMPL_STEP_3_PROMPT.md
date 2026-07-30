# IMPL audit prompt — SPEC-016 Step 3 (shared context)

This file is the master shared-context block referenced by the
three lane-specific prompts:

- `specs/AUDIT_SPEC_016_IMPL_STEP_3_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_3_SECURITY_PROMPT.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_3_ARCH_PROMPT.md`

Codex fires each lane separately via:

```
omc ask codex --agent-prompt code-reviewer  --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_3_CODE_PROMPT.md)"
omc ask codex --agent-prompt security-reviewer --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_3_SECURITY_PROMPT.md)"
omc ask codex --agent-prompt architect      --prompt "$(cat specs/AUDIT_SPEC_016_IMPL_STEP_3_ARCH_PROMPT.md)"
```

All three lanes are **read-only**. Codex MUST NOT modify any
file.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `191e3be impl(016): Step 3 — §4.9 record-funding + §6.4.1 pause/resume + §4.7 record-orphan + §4.8a/§4.8c reapers`
- Single-PR plan (commit `92c8672`): Step 3 IMPL lands on the
  same branch as Step 1+2; PR opens after Step 4 converges. Do
  NOT push, do NOT open PR.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`. All Step 3 work targets this version.

## What Step 3 lands

- `internal/payout/runtime_flags.go` (~340 LOC) — `RuntimeFlagWriter`
  shared §4.8a primitive: write+audit+commit inside ONE
  `BEGIN IMMEDIATE`, post-commit CAS claim with `RETURNING id`.
  Sentinel errors: `ErrFlagAlreadyAtTarget`, `ErrFlagRateLimited`,
  `ErrFlagMissing`.
- `internal/payout/pauseresume.go` (~225 LOC) — `PauseResumeService`:
  `ServePause` + `ServeResume`. Maps SPEC §6.4.1 response table
  to 200 / 400 / 409 / 429 / 500. `ReapOnce` runs the §4.8a
  reaper pass at the configured cadence.
- `internal/payout/funding.go` (~440 LOC) — `FundingService`:
  `ServeRecordFunding` with `source='manual'` and
  `source='rpc-confirmed'` branches; intra-txn bootstrap-trigger
  presence check (count must be 3); both-RPC receipt agreement
  on `to=USDC`, USDC Transfer log with matching from/to/value,
  block_number, status=success. UNIQUE(tx_hash) → 409.
- `internal/payout/orphans.go` (~410 LOC) — `OrphansService`:
  `ServeRecordOrphan` with new-orphan + resolve variants.
  Snapshot columns (`observed_provider_id` /
  `observed_provider_credits` / `observed_gross_credits` /
  `observed_amount_base_units`) captured at INSERT time from
  lpr+pa join. Cancel-self-transfer carve-out:
  is_cancel_self_transfer=1 + reorg_reactivated_at_utc != NULL
  → INSERT OR IGNORE the cancel_reconfirm_stale_outbox row, NO
  ledger_payout_ready revert. Also exposes
  `ListUnemittedStaleOutboxOlderThan` +
  `ClaimAndEmitStaleOutbox` for the §4.8c reaper.
- `internal/payout/reaper.go` (~170 LOC) — `Reaper` background
  loop at `payout.tuning.run_interval`. Runs BOTH outbox
  reapers each tick. `Stop(ctx) bool` returns true on clean
  exit; false on ctx.Done() timeout (mirrors `Runner.Stop`).
- `internal/payout/mux.go` — `step3PathTable` extended with the
  4 new admin routes; `NewMuxStep3` wires them with the
  operator-key middleware; SPEC §3.3 path-table verifier
  asserts parity.
- `cmd/coordinator/main.go` — `setupPayout` extended to build
  the Step 3 services + reaper; `payoutS2` struct gets a
  `reaper` field; shutdown closure stops runner first, then
  reaper, then `Release`-on-clean-exit. `Actor` string
  `"operator_key:coordinator"` (non-secret label, not the raw
  operator key).
- `internal/payout/step3_test.go` (~480 LOC) — 9 tests covering:
  write happy path, already-at-target 409, rate-limit 429,
  CAS-claim once-only, reaper CAS dedupe, reaper picks up
  orphaned audit row, pause-restart persistence, funding
  bootstrap-window gating, funding bootstrap-trigger-missing
  rejection, orphans snapshot columns bound, stale-outbox CAS,
  Step 3 mux path-table consistency.

## What carries forward from Steps 1+2

- Step 1+2 schema is already in place at migrations 0001-0010.
  Step 3 does NOT add migrations — the table set
  (`payout_reorg_orphans`, `payout_hot_wallet_funding`,
  `runtime_flags`, `runtime_flag_audit`,
  `runtime_flags_bootstrapped`, `cancel_reconfirm_stale_outbox`)
  landed in Step 1; the bootstrap triggers
  (`trg_prs_bootstrap_one_way`, `trg_pa_bootstrap_flip`,
  `trg_pa_bootstrap_flip_insert`) landed in Step 1's
  `0003_payout_runner_state.sql`.
- Step 1's `bootstrap.go` already runs `BootstrapRuntimeFlags`
  with the three-table empty check + sentinel-asymmetry
  detection. Step 3 reuses this on the write-side.
- Step 2's `Runner.Stop` bool-returns pattern is mirrored by
  `Reaper.Stop` in Step 3.

## What the audit lane MUST check

Each lane checks its own slice; the master prompt enumerates
the cross-lane invariants:

1. **§4.8a write-audit pipeline atomicity.** UPDATE
   runtime_flags + INSERT runtime_flag_audit MUST happen in
   ONE BEGIN IMMEDIATE transaction. The post-commit CAS claim
   runs in a SEPARATE txn (otherwise the reaper would observe
   emitted_to_log=0 inside the parent txn's snapshot and
   double-claim).
2. **§4.8a CAS-claim discipline.** The UPDATE on
   runtime_flag_audit MUST be `UPDATE ... SET emitted_to_log = 1
   WHERE id = ? AND emitted_to_log = 0 RETURNING id`. 0-row
   returns → another emitter beat us; skip emit. 1-row returns
   → invoke emit exactly once.
3. **§4.8a 5-minute lag for reaper cutoff.** The reaper's
   cutoff = now - 5 minutes is fixed per SPEC, NOT a config
   knob.
4. **§4.9 intra-txn trigger-presence check.** The bootstrap-
   trigger SELECT inside the source='manual' txn MUST count
   `trg_prs_bootstrap_one_way` + `trg_pa_bootstrap_flip` +
   `trg_pa_bootstrap_flip_insert`. count != 3 → 422
   `bootstrap_trigger_missing` + `payout_invariant_violation`
   (PAGE).
5. **§4.9 idempotency-key binding.** The `Idempotency-Key`
   header MUST equal the request body's `tx_hash` field
   (case-insensitive). Mismatch → 422
   `idempotency_key_mismatch`.
6. **§4.9 hot-wallet self-fund deny-list.**
   `from_address == hot_wallet` → 400.
7. **§4.9 source='rpc-confirmed' two-RPC verification.** BOTH
   receipts MUST pass `verifyFundingReceipt`. Either failure →
   422 `receipt_mismatch` with side-discriminator.
8. **§4.7 snapshot column immutability.** The
   `observed_*` columns are captured at INSERT time from a
   join against `ledger_payout_ready` AND `payout_attempts`.
   No path mutates them afterwards.
9. **§4.7 cancel-self-transfer carve-out.** When
   `is_cancel_self_transfer=1` AND `reorg_reactivated_at_utc !=
   NULL`, a `cancel_reconfirm_stale_outbox` row INSERTs.
   v0.1.14 normative: NO `ledger_payout_ready` revert on the
   cancel path.
10. **§6.4.1 rate-limit immutability.** The 60s default loads
    from `payout.security.pause_resume_min_interval` —
    immutable per §6.5.
11. **§6.4.1 409 conflict path.** Already-at-target value →
    409 with `already_paused` or `already_running` code.
12. **§3.3 path-table parity.** The 4 new Step 3 routes are in
    `step3PathTable` AND in the chi router AND in the
    same-realm column (RealmOperatorKey). Any drift →
    `verifyPathTable` fails at startup.
13. **Shutdown ordering.** main.go shuts down runner first
    (any in-flight broadcast finishes), then reaper, then
    releases the lease only on clean exit.

## Severity guidance

- CRITICAL — money-path defect or data-loss class. Examples:
  audit row written but never emittable; CAS-claim that
  double-emits; bootstrap-trigger DROP+UPDATE+CREATE attack
  not rejected; funding inserted without matching tx_hash.
- MAJOR — confirmed bug observable in production. Examples:
  shutdown closure leaks goroutine; reaper races runner; mux
  route registered without table entry.
- MEDIUM — confirmed bug NOT directly observable in production
  but breaks an audit invariant. Examples: §7.1 field set
  missing a field; helper not factored across both reaper
  paths.
- LOW — cosmetic / docs / minor consistency. Examples:
  comment outdated; sentinel error not used at one of its
  expected call sites.

## What to BLOCK on

BLOCK only on:

- A new CRITICAL.
- A SPEC normative rule that a future step cannot unwind
  (e.g. silent corruption of immutable snapshot columns).

Everything else is FIX-THEN-PROCEED.

## Output format

Each lane writes to its own findings file:

- `specs/SPEC-016-IMPL-STEP_3-code-r1-audit.md`
- `specs/SPEC-016-IMPL-STEP_3-security-r1-audit.md`
- `specs/SPEC-016-IMPL-STEP_3-arch-r1-audit.md`

Structure: one-line Verdict, counts table (CRITICAL/MAJOR/
MEDIUM/LOW), one section per finding with [code:X.Y] /
[sec:X.Y] / [arch:X.Y] label + severity + evidence (file:line)
+ recommended fix.
