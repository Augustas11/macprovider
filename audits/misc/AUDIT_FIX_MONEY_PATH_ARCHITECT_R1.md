# Money-path accounting fixes — R1 architecture audit prompt

You are the architecture-lane auditor for a money-path accounting fix. Review
whether the branch preserves the intended accounting boundaries between buyer,
gateway, coordinator, provider-reported data, and harness verification.

Scope:
- Coordinator ledger schema and settlement finality model.
- Gateway reservation, finality-header interpretation, and settlement
  reconciliation model.
- Network harness reconciliation and hard invariant model.

Architecture contracts:
- Provider-reported usage is evidence, not sole authority, when an independent
  prompt bound exists.
- Gateway reservations represent worst-case buyer exposure before provider
  work: prompt estimate plus requested completion allowance.
- Receipt/finality state controls whether a settlement is final, held,
  refundable, or unverified; legacy streaming fallback must not look verified.
- Reconciliation must prefer holding ambiguous coordinator-missing state over
  refunding away potentially valid holds.
- Harness invariants should measure settlement rows and token deltas directly,
  with explicit per-scenario tolerance for known model/tokenizer drift.

Audit tasks:
1. Evaluate whether the implementation puts each decision in the right layer.
2. Identify coupling, migration, or backwards-compatibility risks.
3. Confirm the data model can support future audits of charged vs reported
   prompt tokens.
4. Run or request focused tests if architecture concerns need proof.

Expected output:
- Findings first, ordered by severity.
- Then architectural fit summary.
- Then test evidence and residual risks.
