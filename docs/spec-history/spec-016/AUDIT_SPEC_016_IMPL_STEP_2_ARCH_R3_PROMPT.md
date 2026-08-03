# IMPL audit prompt — SPEC-016 Step 2, **ARCHITECTURE REVIEW lane, round 3**

Round 3 against fix-pass commit `c761e55` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 2
IMPL — round 3. Round 2 returned 0/0/2 MEDIUM/1 LOW (deferred).
The fix-pass `c761e55` addresses both MEDIUMs. Your r3 job:
verify closures, validate the deferral, re-confirm Step 2 → Step
3 readiness.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`. HEAD: `c761e55`.

## r2 findings to verify CLOSED

### [arch:3.1-r2] MEDIUM — Stop must distinguish clean/timeout

Verify `Runner.Stop`:
- Signature now returns `bool` (true=clean, false=timeout)
- main.go `payoutS2.stop` calls `Release` ONLY when Stop
  returns true
- On false (timeout), emits `payout_runner_lease_left_to_stale_out`
  WARN and skips Release per SPEC §4.8b "lease stale takeover"
  semantics

Probe: does Step 4's SIGHUP path (when added) interact with this
clean/timeout distinction? Step 4 will need to call Stop+Restart
the runner — the bool return helps that path too.

### [arch:3.4-r2] MEDIUM — per-day payout_capped emit fields

Verify the per-day cap emit at runner.go:563 now includes
`provider_id` + `ts_utc`. Spot-check other §7.1 events for
the same field set.

## Step 2 → Step 3 readiness — re-confirm

| Row | r2 verdict | r3 verdict |
|-----|------------|------------|
| record-orphan endpoint | FRICTION | ? |
| record-funding endpoint | READY | ? |
| pause/resume | FRICTION | ? |
| chi mux composition | READY | ? |
| Step 4 SIGHUP tuning | NOT READY | ? |

## Validate [arch:3.5] LOW deferral

Re-confirm §4.7 SPEC drift is SPEC-side and Step 2 reorg.go
doesn't encode the broken SQL.

## Regression sweep

Probe the r2 fix-pass diff for any cross-cutting drift:

1. `runner.Stop` signature change — verify all callers updated
   (only main.go calls it). The Runner test suite doesn't call
   Stop directly so no breakage there.
2. main.go shutdown ordering: `stopBackground()` → `payoutS2.stop` →
   `wsServer.DrainAll` → buyer/provider HTTP.Shutdown → swap+receipt
   drain. The payout stop happens BEFORE WS drain — is that the
   right order?

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-arch-r3-audit.md`.

## Discipline

CLEAN requires r2 closures VERIFIED + Step 2 → Step 3 readiness
matrix shows no regressions.

BLOCK only on named SPEC rule a future step can't unwind.

You may take up to 25 min wall-clock.

=== END PROMPT ===
```
