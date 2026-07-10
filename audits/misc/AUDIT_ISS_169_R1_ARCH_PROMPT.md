You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) from an ARCHITECT lens.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`).
- The SPEC corpus is in `specs/`. Sibling specs you may cross-cite:
  SPEC-007 (explorer surface — v0.4 just landed for #231); SPEC-016
  (USDC-on-Base payout pipeline; downstream consumer of
  `ledger_payout_ready`); SPEC-002 v1.5.2 (the `attempt_n` patch
  v0.3.3 absorbed).

# Audit scope (ARCHITECT lens)

You are NOT auditing line-level correctness (CODE lens) or auth
mechanics (SECURITY lens). You ARE asking the higher-altitude
questions:

- **Schema strategy.** Is "new table with UNIQUE per request_credit_id"
  the right shape vs. e.g. extending `ledger_request_credits` with a
  `resolution_kind` column? Defend or refute v0.4's choice.
- **Composition with v0.3.3.** v0.3.3 narrowed the quarantine
  creation class. v0.4 resolves quarantines. Is the boundary clear
  enough that future incident-response runbooks can answer "which
  spec governs?" without reading both end-to-end?
- **Composition with SPEC-016 payout pipeline.** Force-credited rows
  enter `ledger_payout_ready`. SPEC-016 (PR #164) pays out from that
  table to a real chain. Does v0.4 risk paying out a force-credited
  row that was created in error? Is the "immutable resolution" policy
  the right call given SPEC-016's permanence?
- **Composition with SPEC-007 explorer.** v0.4 §11.6.6 names a LEFT
  JOIN in the explorer detail view. Is the explorer the right
  surface, or does v0.4 need a dedicated `GET /admin/ledger/quarantine`
  list endpoint? The issue body suggested a "Resolve" UI button —
  is v0.4 right to defer that to the operator portal repo, or is
  the omission scope-shrinkage?
- **Reconciliation interaction.** §11.6.6 "Reconciliation
  interaction" paragraph says a force-credit issued between two
  reconcile runs is "intended behavior, not an AC-H005 failure." Is
  that the right call, or should AC-H005 be amended to subtract
  `rows_force_resolved_in_range` from the delta?
- **Operator experience.** Two POST endpoints + an immutable rule +
  no UI is the v0.4 surface. Is that enough for an operator who's
  about to force-credit ten quarantined rows after a recovery
  incident? Or does v0.4 need batch endpoints / dry-run / a "list
  open quarantines" endpoint to make the surface usable in anger?
- **Versioning.** v0.4 is a minor bump from v0.3.3. Should this be
  v1.0 instead (first money-path operator write)? Or v0.4 with a
  separate v0.5 for "list open quarantines" if needed? Make a call.
- **Production launch gate.** v0.3.1 has a production launch gate
  list (search the SPEC). Does v0.4 add to it? Should it?
- **Failure modes.** Search §17. Are the new failure modes from
  v0.4 (audit-log write fails after resolution INSERT, resolution
  conflict under settlement-sweep race) named? Should they be?

# Severity

- **CRITICAL** = a fundamental design defect that would force a v0.5
  redesign within weeks.
- **HIGH** = an architectural gap that compounds with downstream
  specs (SPEC-007 / SPEC-016 / SPEC-002) over time.
- **MEDIUM** = a scoping question the spec should make explicit (in
  or out, named or omitted).
- **LOW** = nice-to-have framing improvements.

# Output format

```
[SEVERITY] <short title>

Location: <§ or topic>
Concern: <architectural question>
Evidence: <quote or cross-spec reference>
Fix: <one-sentence proposed change OR "name as a defer with rationale">
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the v0.4 text AS WRITTEN. Don't propose unrelated features.
