# SPEC-020 v0.1.3 — Round 4 audit narrative

**Audited SPEC:** `specs/SPEC-020-provider-autoupdate.md` v0.1.3 (DRAFT)
**Round:** r4
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | **READY TO LOCK** | 0 | 0 | 0 |
| B code | NEEDS REVISION | 0 | 0 | 2 |
| C security | **READY TO LOCK** | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 0 HIGH, 2 MEDIUM.**

Trend: r1 (4H/13M) → r2 (2H/10M) → r3 (1H/8M) → **r4 (0H/2M)**.

Two of three lanes converged to LOCK. Lane B's two MEDIUMs are
detail-level normative tightening, not architectural or security.
One more absorption + r5 audit should land at 0/0/0 across all three.

## Lane B findings to absorb

### B-r4-M-1 — Success-state cleanup atomicity + missing AC

R-4.10's "atomically: emit success event, unlink `pending.json`, delete
rollback backup, release `update.lock`" does not specify the atomicity
mechanism across heterogeneous operations (event emission + 2 filesystem
unlinks + lock release). A crash:
- After success event but before `pending.json` deletion → next startup
  treats the marker as orphaned and rolls back a successful update.
- Between pending deletion and backup deletion → orphan rollback backup
  with no specified cleanup path.

Also: no AC covers success cleanup. AC-1 ends at rejoin/reporting, AC-10
covers rollback failures, AC-22 covers trust loss.

**Fix**: pin the ordered sequence and crash-recovery semantics:
1. Atomic write of a success sentinel `<binary-dir>/.macprovider-cli.success-<update_id>` first (O_CREAT|O_EXCL|O_NOFOLLOW + fsync + rename).
2. Unlink `pending.json`.
3. Delete rollback backup `<binary-dir>/.macprovider-cli.rollback-<update_id>`.
4. Release `update.lock`.
5. Emit `outcome:"success"` event.

Crash recovery: on next startup, if the success sentinel exists and
references the current `binary_version`, the observer MUST sweep any
matching pending marker + rollback backup before proceeding (do NOT
treat as orphan-recovery). After the sweep, delete the success sentinel.
If pending.json is missing but the rollback backup exists with a stale
update_id, delete the backup without restoring.

Add AC: "AC-V0.1-N: post-start success → success sentinel written, pending.json
deleted, rollback backup deleted, lock released, `outcome:"success"` event
emitted; subsequent startup sees no orphaned state."

### B-r4-M-2 — `marker_deadline` citation drift + retry state

Two issues:
1. The malformed/missing `marker_deadline` branch cites "(R-4.8)" but R-4.8
   is path/lstat validation; the actual orphaned-recovery state machine is
   R-4.10. Fix: update the citation to R-4.10 (or merge the path/lstat with
   the recovery state machine if that's the intent).
2. "Future beyond tolerance" branch says treat as malformed but does not
   pin whether valid-backup recovery disables autoupdate for the session,
   records cooldown, or allows retry. Fix: pin: "future beyond tolerance"
   → trigger orphan-recovery (R-4.10) AND disable autoupdate for the
   remainder of the session (no retry until next coord session start)
   AND record a structured cooldown entry with `failure_class:"orphaned_pending_marker"`
   so the same target is not retried until cooldown clears.

## Non-blocking observations

- Lane A: live trust predicate complete; no irreversible-mutation gap;
  capability gate distinct from `recommended_binary_version`; SPEC-018/019
  streaming flows don't conflict (in-flight inference takes precedence);
  convergence boundary unchanged; implementable as single PR.
- Lane B: AC count = 22; all referenced `failure_class:"X"` values in R-6.5;
  `NORMALIZED_TARGET` propagation pinned for release lookup, marker, drain
  reason, cooldown key; external/local citations resolve.
- Lane C: live trust-state covered through dangerous window; persisted
  signed-policy state is monotonic-only; `autoupdate_drain_extensions:true`
  is coord-advertised only; oversized version redaction bounded; 4096-byte
  event bound respected.

## Next action

Absorb r4 → v0.1.4 with B-r4-M-1 ordered-cleanup-sequence + crash-recovery
+ AC, and B-r4-M-2 citation fix + cooldown gating. Then fire r5 across all
three lanes. Strong convergence trend suggests r5 = 0/0/0 = LOCK.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-3-round-4-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-26-33-249Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-3-round-4-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-27-01-767Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-3-round-4-audit-prompt-per-lane-you-are-auditi-2026-06-29T15-25-54-016Z.md`
