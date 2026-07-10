You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for SECURITY concerns, ROUND 3.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `c54e834`.
- R3 — R2 produced findings; R2 fix-pass is in the current commit.
- R2 SECURITY findings:
  - S2-H1: Settlement pause runbook targeted a non-existent runner control
  - S2-M1: Reason sanitizer still allowed invisible/display-mangling Unicode classes
  - S2-L1: Audit row did not carry the attribution caveat

# Audit scope (SECURITY lens)

Same scope as R1/R2. ALSO: any NEW exposure introduced by R2's
fix-pass — specifically:
- The new route-layer config flags
  (`billing.quarantine_resolution_force_*_enabled`). Are they
  reasonable as default-false? Could an attacker with operator key
  AND config-reload access flip them, perform a force-credit, then
  flip them back to hide the surface? (Audit log still records it,
  but is the audit log sufficient?)
- The new SPEC-016 503 gate (§11.6.6.5). Is `payout.spec016_enabled`
  the right gate semantic? What if SPEC-016 is mid-install
  (config says enabled but the runner is paused)? Is there a
  scenario where the gate is bypassed because the deployment
  doesn't have SPEC-016 *configured* even though USDC payouts are
  manually triggered?
- The expanded reason sanitizer reject list. Are there REMAINING
  forensic-display gaps?

# Severity

- **CRITICAL** = exploitable, money loss or auth bypass.
- **HIGH** = significant security gap.
- **MEDIUM** = hardening item.
- **LOW** = wording.

# Output

```
[SEVERITY] <short title>

Location: <§ anchor>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

If an R2 finding is closed, do NOT re-list. Audit the R3 text AS
WRITTEN.
