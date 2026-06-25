# IMPL audit prompt — SPEC-016 Step 3, **ARCHITECTURE REVIEW lane, round 3**

Round 3 against fix-pass commit `9bbec55` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (2 of 2 in r3) auditing SPEC-016
Step 3 IMPL — round 3.

Round 2 returned FIX-THEN-PROCEED with 2 MAJOR + 1 MEDIUM. The
fix-pass `9bbec55` addresses all three. Your r3 job: verify the
closures hold AND re-confirm Step 3 → Step 4 readiness.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`. HEAD: `9bbec55`.

## r2 findings to verify CLOSED

### [arch:r2-3.2-A] MAJOR — two-RPC verification in ProduceStaleOutboxRows

Verify the SPEC §4.7 escalation predicate is now correctly
enforced:

1. Producer signature is `ProduceStaleOutboxRows(ctx, db, log,
   rpcs TwoRPCs, runID string, now, runInterval)`.
2. Inside the per-candidate loop (orphans.go around line 415):
   - Both `Primary.TransactionReceipt` and
     `Secondary.TransactionReceipt` called with the candidate's
     `tx_hash`.
   - On either RPC error → skip (do NOT page).
   - On either non-nil receipt → skip (cancel is reconfirmable).
   - Only when BOTH return (nil, nil) does the CAS+INSERT path
     execute.
3. The "zero TwoRPCs disables" early-return is documented as
   a TEST-PATH disable, not a production posture.
4. runner.go RunOnce passes `r.opts.RPCs, runID` to the
   producer.

Cross-check: SPEC §4.7 lines 1998 + 2033 are the normative
"both RPCs return not-found" rule. r3 should confirm the IMPL
matches the SPEC wording.

### [arch:r2-3.2-B] MAJOR — admin-side INSERT removed

Verify `orphans.go` serveRecord no longer inserts directly
into cancel_reconfirm_stale_outbox. The branch should now:
- Still capture observed_* columns + INSERT the orphan row
  per [code:r2-2.2] r2 lock.
- Still NOT revert ledger_payout_ready (v0.1.14 carve-out).
- Have a comment explaining why the prior INSERT OR IGNORE
  was removed AND pointing at the runner-owned producer as
  the canonical path.

The runner is now the SINGLE producer of the §4.8c outbox.
Cross-check: does this break ANY operational scenario where
the operator records an orphan that the runner hasn't yet
caught? r3 should confirm:
- Operator records orphan via /admin/payout/record-orphan.
- Next runner cycle's ProduceStaleOutboxRows picks it up (the
  reorg LIVE-AGAIN UPDATE in reorg.go cleared
  cancel_reconfirm_stale_paged_at_utc to NULL when the orphan
  was first observed, so the marker is correctly NULL).
- Two-RPC check passes (orphan is unreconfirmable).
- Producer fires PAGE.

If this chain has a hole (e.g. operator records an orphan and
the LIVE-AGAIN UPDATE was never run because the reorg poll
window doesn't include the orphan time), document it as a
deferred-to-Step-4 item.

### [arch:r2-3.3] MEDIUM — stale PAGE field set

Verify:
- Migration 0012 adds nullable run_id column.
- ListUnemittedStaleOutboxOlderThan + ClaimAndEmitStaleOutbox
  read COALESCE(run_id, '').
- StaleOutboxRow has RunID field.
- Sync emit (orphans.go) AND reaper emit (reaper.go) both
  include run_id + updated_at_utc.

## Step 3 → Step 4 readiness matrix — re-confirm

| Row | r2 verdict | r3 verdict |
|-----|------------|------------|
| §6.5 config-loader split | Partial (Stop bool primitives exist) | ? |
| §7.4 reconciliation queries | Ready | ? |
| §7.4 chain-balance worker | Ready | ? |
| §6.2 balance monitoring | No regression | ? |
| Ops bundle | not in Step 3 scope | ? |

## Forward-looking probes

1. ProduceStaleOutboxRows runs at the top of every cycle and
   now makes two RPC calls per candidate row. At what
   cancel-row cardinality does this become a latency concern
   for Step 4 SLO budgets? Should there be a per-cycle limit
   (akin to MaxRowsPerRun for the ready-selection)?

2. The producer skips on RPC error — does this risk indefinite
   skipping if one RPC is chronically down? The reaper picks
   up the row eventually via the time-based cutoff, so the
   answer should be "no, the reaper is the safety net". r3
   should confirm.

3. Step 4 SIGHUP semantics: a tuning reload that changes
   `run_interval` changes the stale threshold (3 × runInterval).
   The producer reads runInterval per-call from runner.opts.
   Step 4 will need to wire the tuning hot-reload into
   RunnerOptions.RunInterval. r3 should comment if this is
   feasible OR if it requires a refactor.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-arch-r3-audit.md`.

## Discipline

CLEAN requires r2 closures VERIFIED + Step 3 → Step 4 matrix
shows no regressions.

BLOCK only on named SPEC rule a future step cannot unwind.

Wall-clock target: 25 min.

=== END PROMPT ===
```
