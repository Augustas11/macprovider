# IMPL audit prompt — SPEC-016 Step 4, **SECURITY REVIEW lane, round 4**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016 Step 4
IMPL — round 4.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`. HEAD: `6eb49c0`.

The r3 audit returned 0 / 1 HIGH / 1 MEDIUM / 0 LOW. The r3 fix-pass
landed at `6eb49c0`. Verify closure + look for new attack surface.

## High-leverage probes (r4)

### A. SPKI close-idle correctness [sec:r3-1] closure

1. **Pin rotation completeness.** Operator updates pin via SIGHUP →
   handler calls `CloseIdleConnections` → next request opens a fresh
   handshake → verifier uses NEW pin via live read. Verify the
   sequence.
2. **In-flight request lifecycle.** An RPC was in flight when SIGHUP
   landed. CloseIdleConnections only closes idle conns; in-flight
   completes on the old pin. Acceptable per the documented runbook.
   Verify the runbook section actually exists and is correct.
3. **Empty-pin reload.** Operator SIGHUP'd to empty pin (disabling
   pinning). The next handshake skips pinning. Does
   CloseIdleConnections also fire? If not, an attacker holding a
   stale handshake doesn't get pinning disabled until the
   90-second idle timeout. Probably acceptable but worth noting.
4. **Multiple SIGHUPs in 90s.** Each updates the live snapshot AND
   triggers the close. Verify no race in the changedKeys computation
   between rapid reloads.

### B. §7.1 reload event field set [sec:r3-2] closure

1. **payout_config_reloaded.** Verify the emit has `key, old_value,
   new_value, actor, ts_utc` exactly. The `actor` value should be
   `operator_key:coordinator` (or equivalent — must NOT be a bearer).
2. **payout_config_reload_rejected.** Same set + `bound`. The
   `bound` field should be a HUMAN-READABLE description of the
   constraint (e.g. "5..200"), not internal Go error text.
3. **Bound-violation error path.** `BoundViolationError` exposes
   Field, Attempted, Bound, Actor. The emit pulls from these via
   `errors.As`.
4. **YAML-load-failure path.** The audit said this path should emit
   `key=yaml_parse`. Verify the actor is still set; the rest of the
   fields are reasonable (attempted="<contents>" probably not, but
   the bound should be the parse error class).

### C. Run-now run_id correlation [code:r3-1] closure

The run-now event now uses the SAME run_id as the cycle. Verify:
1. The event's run_id appears in `payout_run_started`,
   `payout_run_finished` for the SAME cycle.
2. Operators tracing a run-now → can correlate the cycle's row-level
   events (`payout_paid`, `payout_failed`, `payout_capped`) via the
   same run_id.

### D. Halt-race coverage [code:r3-4] closure

1. The new test exercises the post-RunOnce ErrRunnerHalted branch
   specifically — IsHalted returns false at admission, RunOnce
   returns ErrRunnerHalted.
2. The fakeRunner implementation is correct (the runnerExecutor
   interface contract).
3. Production wiring still passes the real Runner concretely.

### E. Chain-balance event rename [code:r3-3] closure

1. The new event name `payout_chain_balance_rpc_disagreement` does
   NOT collide with the SPEC §7.1 `payout_rpc_disagreement` schema.
2. SPEC §7.1 entry for the SPEC-original
   `payout_rpc_disagreement` is unchanged (this is a NEW event, not
   a SPEC rename).
3. BetterStack alert list documents the new event.

### F. govulncheck + race

- `govulncheck ./...` from `phase4-coordinator/`.
- `go test -race -count=1 ./internal/payout/...`.

### G. Secrets/log scan

- No bearer / KEK / wallet plaintext in the new SIGHUP rejection
  emit paths.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-security-r4-audit.md`. Standard
structure.

If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
