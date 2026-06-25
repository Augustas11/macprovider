# SPEC-016 IMPL Step 3 — round 4 CONVERGED

Three-lane parallel codex audit fan-out converged at round 4
across all three lanes at **0 CRITICAL / 0 MAJOR / 0 MEDIUM /
0 LOW**.

## Final scoreboard

| Lane         | r1                | r2                  | r3                | r4                  | Final |
|--------------|-------------------|---------------------|-------------------|---------------------|-------|
| Code         | 0/0/5Md/3L FIX-THEN | 0/0/2Md/0 FIX-THEN  | 0/0/1Md/0 FIX-THEN | **0/0/0/0 CLEAN** ✅ | CONVERGED |
| Security     | **1C/1H/1Md BLOCK** | **0/0/0/1 CLEAN** ✅ | (held r2)         | (held r2)           | CONVERGED |
| Architecture | 0/2M/1Md FIX-THEN  | 0/2M/1Md FIX-THEN   | **0/0/0/0 CLEAN** ✅ | (held r3)           | CONVERGED |
| **Total r4** | — | — | — | **0 / 0 / 0 / 0**   | **CONVERGED** |

The audit-loop discipline at
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §3 is satisfied.
Step 3 IMPL is green to proceed to Step 4 on the same
`impl/spec-016` branch.

## Round-by-round narrative

### Round 1 (codex against `191e3be`)

**Code lane (FIX-THEN-PROCEED).** 5 MEDIUM + 3 LOW.
**Security lane (BLOCK).** 1 CRITICAL + 1 HIGH + 1 MEDIUM.
**Architecture lane (FIX-THEN-PROCEED).** 2 MAJOR + 1 MEDIUM.

Top of the BLOCK class:
- [sec:1] CRITICAL — manual-funding bootstrap window reopen
  via DROP+UPDATE+CREATE on `trg_prs_bootstrap_one_way`.
- [sec:2] HIGH — `uint256FromData` truncates high 24 bytes
  silently, accepting fabricated > uint64 values.
- [arch:3.1] MAJOR — ReorgPoller used `context.Background()`
  + no Stop primitive; lease released while poller mid-RPC.
- [arch:3.2] MAJOR — §4.8c outbox producer was admin-only;
  no runner-side stale-transition CAS.

### Round 1 fix-pass (commit `6044056`)

10 files modified + 1 new migration. 13 findings closed
(1 CRITICAL + 1 HIGH + 2 MAJOR + 6 MEDIUM + 3 LOW).

Key changes:
- `funding.go` `serveManual` adds EXISTS check on
  `payout_attempts.confirmed_at_utc IS NOT NULL` inside the
  same BEGIN IMMEDIATE; emits
  `payout_invariant_violation where=bootstrap_flag_reopened`
  PAGE on tamper.
- `funding.go` `verifyFundingReceipt` strict 32-byte big.Int
  decode; rejects non-zero high 24 bytes.
- `reorg.go` adds `Start/Stop(ctx) bool` mirroring
  `Runner.Stop`. `main.go` shutdown gates Release on
  `runnerClean && pollerClean`.
- New `ProduceStaleOutboxRows` in `orphans.go` called from
  `runner.RunOnce` top of cycle. CAS marker NULL→now AND
  INSERT outbox in same BEGIN IMMEDIATE; sync CAS-claim emit
  via `ClaimAndEmitStaleOutbox`.
- `lease.go` redacts `holder_token` via new `tokenPrefix`
  helper.
- Migration `0011_orphan_uniqueness.sql` adds partial UNIQUE
  index on `payout_reorg_orphans(payout_id, attempt_seq,
  orphan_tx_hash) WHERE resolved_at_utc IS NULL`. serveRecord
  maps `isUniqueViolation` to 409.
- §7.1 field-set drift swept across reaper, funding, orphans
  emits.
- New `step3_http_test.go` (~330 LOC) covers all handlers
  including the CRITICAL closure lock.

### Round 2 (codex against `6044056`)

All r1 closures VERIFIED.

- Code lane: 0/0/2 MEDIUM/0 (folded into the arch fix).
- Security lane: **CLEAN ✅** (one LOW perf hint — partial
  index on `confirmed_at_utc` for the EXISTS query).
- Architecture lane: 2 new MAJOR + 1 MEDIUM that the r1 fix-
  pass missed:
  - [arch:r2-3.2-A] MAJOR — `ProduceStaleOutboxRows` was DB-
    only. SPEC §4.7 requires BOTH RPCs return not-found
    before stale PAGE. Producer ran BEFORE `pollCancelOnce`
    so a reconfirmable cancel got paged first.
  - [arch:r2-3.2-B] MAJOR — admin-side INSERT OR IGNORE in
    `orphans.go` parallel to the runner-owned producer; the
    UNIQUE INDEX on `(payout_id, attempt_seq,
    stale_started_at_utc)` couldn't dedup across producers
    with different timestamps.
  - [arch:r2-3.3] + [code:r2-2.1] MEDIUM — stale PAGE emit
    missing `run_id` + `updated_at_utc`; reaper can't
    reconstruct `run_id` because not persisted.

### Round 2 fix-pass (commit `9bbec55`)

5 files modified + 1 new migration. 2 MAJOR + 1 MEDIUM closed.

Key changes:
- `ProduceStaleOutboxRows` signature now takes `TwoRPCs +
  runID`. Per-candidate loop calls both RPCs'
  `TransactionReceipt` BEFORE CAS. Skips on either RPC error
  or non-nil receipt.
- Removed admin-side INSERT OR IGNORE from `orphans.go`
  serveRecord. Runner is now the single producer.
- Migration `0012_stale_outbox_run_id.sql` adds nullable
  `run_id` column. Producer persists it; sync + reaper emits
  both add `run_id` + `updated_at_utc`.
- New `step3_r2_test.go` (3 tests) locks the closures:
  `BothRPCsMissAfterThreshold_Produces`,
  `PrimaryReturnsReceipt_DoesNotPage`, `NoRPCs_Disabled`.

### Round 3 (codex against `9bbec55`)

Security lane held CLEAN at r2. Code + arch fan-out.

- Architecture: **CLEAN ✅** with Step 4 advisories (per-cycle
  cap; single-RPC outage telemetry; SIGHUP tuning rebuild).
- Code: 1 new MEDIUM ([code:r3-3.1]) — stale-marker CAS sets
  `cancel_reconfirm_stale_paged_at_utc` but NOT
  `updated_at_utc`. SPEC §4.7 sets both in same UPDATE.

### Round 3 fix-pass (commit `d7cef01`)

Single-statement SQL change + test extension.

- `ProduceStaleOutboxRows` CAS now sets both columns to
  `staleStarted`.
- `TestProduceStaleOutboxRows_BothRPCsMissAfterThreshold_Produces`
  asserts `updated_at_utc == staleStarted` after producer.

### Round 4 (codex code-only against `d7cef01`)

Architecture + security held CLEAN. Code lane:

> r3 closure is verified and I found no new r4 code-lane
> findings. APPROVE / CLEAN.

The reviewer's regression sweep explicitly confirmed:
- Reaper timing unaffected (reads
  `cancel_reconfirm_stale_outbox.stale_started_at_utc`).
- Stale-reservation halt only counts unbroadcast attempts
  (`broadcast_at_utc IS NULL`), so producer's timestamp
  update on broadcast cancel rows doesn't introduce a new
  halt path.
- §7.1 stale PAGE emits read `updated_at_utc` from the outbox
  row's `reorg_reactivated_at_utc`, NOT from the newly
  advanced `payout_attempts.updated_at_utc`.

Verdict: **CLEAN 0/0/0/0** ✅.

## Step 3 → Step 4 readiness matrix

Per architect r3 evidence:

| Row | r3 verdict | Notes |
|-----|------------|-------|
| §6.5 config-loader split | **Partial, no regression** | Security/tuning structs + bounds exist; SIGHUP is Tier2-only. Step 4 adds payout-aware reload semantics. |
| §7.4 reconciliation queries | **Ready** | `payout_hot_wallet_funding` table + cancel-exclusion key exist; `reconcile.sql` is Step 4 scope. |
| §7.4 chain-balance worker | **Ready** | `TwoRPCs` wired; `chain_recon_interval` + tolerance configured. |
| §6.2 balance monitoring | **No regression** | Step 3 records funding rows + event fields; live low-balance is Step 4. |
| Ops bundle | **Not Step 3 scope** | No Step 3 implementation change blocks it. |

## Step 4 advisories (carried forward from r3 architect)

1. **Per-cycle stale producer cap.** `ProduceStaleOutboxRows`
   has no `LIMIT`. At cancel-row cardinality > low-double-
   digits, Step 4 should cap rows per cycle akin to
   `MaxRowsPerRun` for ready selection.

2. **Chronic single-RPC outage telemetry.** The producer
   correctly skips on RPC error (skip ≠ PAGE because skip
   isn't a not-found signal). The reaper recovers only rows
   that the producer already CAS+INSERTed, NOT rows the
   producer skipped. Step 4 should add explicit RPC-health
   telemetry so chronic single-RPC outage gets a separate
   operator signal.

3. **SIGHUP tuning reload as lifecycle-aware rebuild.**
   `run_interval` reads per-call in the producer, but the
   runner, reorg poller, and reaper all bind their tickers
   and stale ages at construction. Step 4 needs a controlled
   stop+rebuild path OR shared atomic config, not just a
   SIGHUP assignment.

## Code lane LOW deferrals (not closures-blocking)

- **[code:r4-low/r3-open] migration tracking-insert atomicity.**
  `ALTER TABLE ADD COLUMN` succeeds but tracking insert isn't
  in the same txn (existing migration-runner limitation, not
  Step 3 specific). Documented for Step 4 scope.
- **[code:r3-3.2 open question] per-cycle producer scale.**
  Defer index addition to Step 4 (see advisory 1).

## Audit artifacts

Persisted findings:

- specs/SPEC-016-IMPL-STEP_3-{code,security,arch}-r1-audit.md
- specs/SPEC-016-IMPL-STEP_3-{code,security,arch}-r2-audit.md
- specs/SPEC-016-IMPL-STEP_3-{code,arch}-r3-audit.md
- specs/SPEC-016-IMPL-STEP_3-code-r4-audit.md
- specs/SPEC-016-IMPL-STEP_3-r4-convergence.md (this file)

Source codex artifacts under `.omc/artifacts/ask/`:
- 3× r1 lanes (code/security/architecture)
- 3× r2 lanes
- 2× r3 lanes (code/architecture)
- 1× r4 code

## Commit chain

```
HEAD  d7cef01 impl(016): Step 3 r3 fix-pass — close [code:r3-3.1] stale CAS updated_at_utc
      …      spec(016): Step 3 r4 code-only audit prompt
      …      spec(016): Step 3 audit r3 findings — arch CLEAN, code 1 MEDIUM
      9bbec55 impl(016): Step 3 r2 fix-pass — close 2 MAJOR + 1 MEDIUM
      …      spec(016): Step 3 r3 audit prompts
      …      spec(016): Step 3 audit r2 findings — security CLEAN, code 2 MEDIUM, arch 2 MAJOR
      …      spec(016): Step 3 r2 audit prompts
      6044056 impl(016): Step 3 r1 fix-pass — close 1 CRITICAL + 1 HIGH + 2 MAJOR + 6 MEDIUM + 3 LOW
      635a709 spec(016): Step 3 audit r1 findings — 3 parallel codex lanes
      359a609 spec(016): Step 3 audit prompts — 3 parallel codex lanes
      191e3be impl(016): Step 3 — §4.9 record-funding + §6.4.1 pause/resume + §4.7 record-orphan + §4.8a/§4.8c reapers
      bd35686 spec(016): Step 2 audit CONVERGED — r4 across all 3 lanes 0/0/0/0
```

## Step 3 production surface

Net IMPL additions over Step 2 (~2,300 LOC payout + ~810 LOC
tests, plus 2 migrations):

- `internal/payout/runtime_flags.go` — §4.8a primitive
- `internal/payout/pauseresume.go` — §6.4.1 endpoints + reaper
- `internal/payout/funding.go` — §4.9 record-funding
- `internal/payout/orphans.go` — §4.7 record-orphan +
  ProduceStaleOutboxRows + outbox helpers
- `internal/payout/reaper.go` — §4.8a + §4.8c background loop
- `internal/payout/step3_test.go` — bootstrap + write/CAS + reap
- `internal/payout/step3_http_test.go` — handler-level coverage
- `internal/payout/step3_r2_test.go` — runner-owned producer
- Migrations 0011 (orphan uniqueness) + 0012 (outbox run_id)
- mux.go `step3PathTable` + `NewMuxStep3`
- main.go `setupPayout` extended with Step 3 services + reaper

Full coordinator test suite + race detector green.

## Next action

Per `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §2: proceed
to Step 4 (§6.5 dual-namespace config loader + §7.4
reconciliation queries + §7.4 chain-balance worker + ops
bundle) on the same `impl/spec-016` branch.

**Do NOT push and do NOT open the PR yet.** The single PR
opens once after Step 4's audit converges per the
consolidation plan in commit `92c8672`.
