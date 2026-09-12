# Audit — SPEC-047 v0.1.9: reconcile `offer_rejected` unreachability with the journey evidence contract (#1486, #1453 slice 7)

METHOD CONSTRAINT: SPEC + governance review. Do NOT modify or commit the worktree. Review the FULL diff `git diff origin/main -- specs scripts` in this worktree against the governing text. Quote what you object to with file:line. Do not read other `audits/` files; form your own view.

## What changed and why
A slice-7 contributor building the JOURNEY-NETWORK-MODEL-ADMISSION capture driver found that the journey's promotable observation `rejected_reoffer_required_fresh_evidence` (must be TRUE) cannot be produced by a real v0.2 coordinator: SPEC-047's own v0.1.5 changelog states `offer_rejected` is "stated unreachable" and no coordinator origin appends it (a failed synthetic probe yields `revoked (synthetic_probe_failed)`, not `offer_rejected`). SPEC-047-R001 nonetheless listed `offer_rejected` as if exercised, and the governance journey contract required proving a rejected→re-offer path. This is an internal SPEC-047 contradiction.

The reconciliation (v0.1.9):
- SPEC-047-R001 keeps `offer_rejected` in the closed state enum for wire compatibility but states normatively it is RESERVED and unreachable in v0.2 (no origin appends it); its re-entry edge is listed for enum completeness, not exercised.
- The governance module drops `rejected_reoffer_required_fresh_evidence` from `NETWORK_MODEL_ADMISSION_TRUE_OBSERVATIONS`; the fixture and the evidence test drop it and the step-11 assertion text; `withdrawn_reoffer_required_fresh_evidence` and `revoked_reoffer_required_fresh_evidence` remain and continue to prove the R001/R006 fresh-evidence-on-re-entry invariant.
- CONFORMANCE SPEC-047 → 0.1.9; README regenerated.

## Invariants to challenge
- Is `offer_rejected` truly unreachable in v0.2 (grep the coordinator for any append origin), making the removed observation genuinely unprovable rather than merely unimplemented? If some path DOES reach it, this reconciliation is wrong.
- Does dropping `rejected_reoffer_required_fresh_evidence` weaken what the signed journey attests about the R001/R006 fresh-evidence-on-re-entry rule, given `withdrawn` and `revoked` re-entry remain proven? Is the fresh-evidence invariant still fully covered?
- Any dangling reference to the removed observation (step→requirement map, promotable set, fixture, tests, CONFORMANCE, other specs, SPEC-044/046 enums)? Is the closed enum still internally consistent (SPEC-044, SPEC-046, the transition map keep `offer_rejected`)?
- Is R001's new "reserved/unreachable" wording consistent with the transition table row, the re-entry sentence, and the v0.1.5 changelog it cites? Does it contradict SPEC-044-R... or SPEC-046-R003 which still list `offer_rejected` as a presentable state?
- Version/changelog/CONFORMANCE hygiene: is the bump correct, the changelog entry accurate, and does the journey step count / observation count stay consistent everywhere it is asserted?

## Lanes to report (this pass is: {{LANE}})
CRITICAL / HIGH / MEDIUM / LOW / INFO; bar 0 C / 0 H / 0 M. For each finding: severity, the quoted sentence, file:line, why it fails, the minimal edit. End with a table of counts per severity.
