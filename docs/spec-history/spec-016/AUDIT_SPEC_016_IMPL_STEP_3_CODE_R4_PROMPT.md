# IMPL audit prompt — SPEC-016 Step 3, **CODE REVIEW lane, round 4**

Round 4 against fix-pass commit `d7cef01` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

**Note:** Security lane converged at r2 (CLEAN). Architecture
lane converged at r3 (CLEAN with Step 4 advisories). This r4 is
**code lane only**.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 1 in r4) auditing SPEC-016
Step 3 IMPL — round 4. Round 3 returned 0/0/1 MEDIUM/0. The
fix-pass `d7cef01` addresses the one MEDIUM. Your r4 job:
verify the closure holds.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

HEAD: `d7cef01`. Branch `impl/spec-016`.

## r3 finding to verify CLOSED

### [code:r3-3.1] MEDIUM — stale-marker CAS missing updated_at_utc

SPEC §4.7 stale transition SQL sets BOTH the stale marker AND
updated_at_utc in the same UPDATE. The r2 fix-pass set only
the marker.

The r3 fix at `orphans.go` (around line 484) extends the
existing CAS:

```sql
UPDATE payout_attempts
   SET cancel_reconfirm_stale_paged_at_utc = ?,
       updated_at_utc = ?
 WHERE payout_id = ? AND attempt_seq = ?
   AND cancel_reconfirm_stale_paged_at_utc IS NULL
   AND confirmed_at_utc IS NULL
```

Both bind args use `staleStarted` so the row's update timestamp
matches the stale-paged timestamp exactly. The CAS predicate is
unchanged.

Verify:
- The UPDATE statement at orphans.go has TWO columns set.
- The bind args include `staleStarted` twice.
- The CAS predicate (`WHERE ... AND cancel_reconfirm_stale_paged_at_utc IS NULL AND confirmed_at_utc IS NULL`) is unchanged so the concurrent-runner race semantics still hold.
- The test extension at step3_r2_test.go line ~75 asserts
  `updated_at_utc == staleStarted` after the producer fires.

## Regression sweep

Probe the small fix-pass diff (~18 lines across 2 files) for:

1. Any unintended downstream consumer that read
   payout_attempts.updated_at_utc and now sees the new
   timestamp. Suspects: stale-reservation halt query (§5.3),
   reorg poll cadence, any §7.1 emit that includes
   updated_at_utc.
2. The reaper picks up rows via stale_started_at_utc cutoff,
   NOT updated_at_utc, so the change does NOT affect reaper
   timing. Confirm.
3. The §5.3 stale-reservation halt at `runner.go`:
   `updated_at_utc < :now_minus_24h` — this halt is about
   broadcast-but-never-confirmed reservations. The new
   producer touches updated_at_utc on cancel rows that have
   ALREADY been broadcast, so the halt would now correctly
   exclude these rows (good — they're being actively
   stale-paged, not loss-of-state). Confirm.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-code-r4-audit.md`.

## Discipline

CLEAN requires r3 closure VERIFIED + zero new findings.
BLOCK only on new CRITICAL.

Wall-clock target: 15-20 min.

=== END PROMPT ===
```
