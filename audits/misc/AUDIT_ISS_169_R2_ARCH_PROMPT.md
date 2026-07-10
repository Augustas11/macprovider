You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) from an ARCHITECT lens, ROUND 2.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`, commit `b8afc03`).
- R2 — R1 produced findings in `specs/SPEC-005-v0-4-r1-audit.md`.
- The R1 ARCHITECT findings to verify-as-closed:
  - A-H1: Reconciliation exception contradicts AC-H005
  - A-H2: Mistaken force-credit has no pre-payout escape (DEFERRED
    to v0.5 — verify the deferral rationale is acceptable)
  - A-M1: Settlement timing under-specified for existing weekly rows
  - A-M2: No first-class open-quarantine worklist (DEFERRED to
    v0.5 — verify the deferral rationale is acceptable)
  - A-M3: Production launch gate not updated
  - A-M4: §17 omits v0.4 failure modes
  - A-L1: Schema and versioning rationale not pinned

# Audit scope (ARCHITECT lens)

Same scope as R1 — schema strategy, composition with v0.3.3 /
SPEC-016 / SPEC-007, reconciliation interaction, operator
experience, versioning, production launch gate, failure modes.

ALSO: the two DEFERRED items (A-H2 pre-payout hold, A-M2
open-quarantine list). Audit specifically:
- Is the DEFERRAL RATIONALE acceptable as written, given that
  SPEC-016 USDC payout is a real money-out surface?
- Is the §11.6.6.4 runbook ENOUGH compensation for the absence
  of a pre-payout hold, or is the runbook so fragile that an
  operator mistake during a busy incident is realistic?
- Is the architecture clear that v0.4 ships the SPEC + IMPL
  with the endpoints DISABLED at the route layer until the
  launch-gate item (§11.5 item 10) is cleared?

# Severity

- **CRITICAL** = fundamental design defect.
- **HIGH** = architectural gap compounding with downstream specs.
- **MEDIUM** = scoping question the spec should make explicit.
- **LOW** = nice-to-have framing.

# Output format

```
[SEVERITY] <short title>

Location: <§ or topic>
Concern: <architectural question>
Evidence: <quote or cross-spec reference>
Fix: <one-sentence proposed change OR "name as a defer with rationale">
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

If an R1 finding is closed (or explicitly DEFERRED with acceptable
rationale), do NOT re-list it; only list NEW issues OR issues
NOT actually closed.

Audit the v0.4 R2 text AS WRITTEN.
