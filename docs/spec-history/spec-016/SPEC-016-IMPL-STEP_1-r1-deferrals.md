# SPEC-016 IMPL Step 1 — codex round 1 findings deferred

This file tracks the **non-blocking** findings from codex round 1
that were NOT addressed in the round-1 fix-pass commit. Each entry
names a destination (SPEC v0.1.22 candidate, Appendix B, or a
later step) and the rationale for not fixing in Step 1.

The round 1 fix-pass commit closes:

- [code:1.1] CRITICAL — rotation re-enables `payout_allowed=0`
- [code:1.2] MEDIUM — `0X` vs `0x` nonce prefix splits anti-replay
- [arch:1.2] MEDIUM — import-graph test only catches direct imports
- [arch:1.3] MEDIUM — co-residency assertion absent at startup

Remaining open from round 1:

## [arch:1.1] MAJOR — §4.7 SPEC reorg-poll query references non-existent columns

**Destination:** SPEC v0.1.22 candidate. Filed for the operator to
review against the v0.1.21 §4.7 / §4.5 wording before Step 2 IMPL
begins.

**Why NOT a Step 1 code fix:** the defect is SPEC-side, not
IMPL-side. The §4.5 schema (committed in Step 1's migration
`0002_payout_attempts.sql`) defines the PK as
`(payout_id, attempt_seq)` and the tx-hash column as `tx_hash`.
SPEC §4.7 (v0.1.21 line 1896) references
`payout_attempts.id` (does not exist) and `payout_external_id`
(does not exist on `payout_attempts`; it lives on
`ledger_payout_ready`). A Step 2 IMPL author writing the reorg-poll
runner cycle would hit a `no such column: id` error at query
prepare time.

**Codex suggested resolution:** amend SPEC §4.7 to query
`payout_id, attempt_seq, tx_hash` from `payout_attempts`, OR
explicitly join `ledger_payout_ready.payout_external_id` if the
intended canonical orphan identity is the SPEC-005 ledger column.

**Action:** surface to the operator-side SPEC author before Step 2
kickoff. Not a Step 1 IMPL action.

## [sec:1.1] LOW — schema-drift detection on `CREATE … IF NOT EXISTS`

**Destination:** SPEC-016 Appendix B (operator hardening backlog).

**Why deferred:** the threat model — a hostile operator who
pre-creates SPEC-016 tables with weaker definitions before Step 1
migrations run — is moot for the first cutover (Step 1 IS the
first time these schemas land). The hardening matters for
recovery / import / DR scenarios where the DB file is restored
from a state that pre-dates the SPEC. Codex marked this as LOW
and the audit-loop discipline permits LOW deferral with explicit
justification.

**Codex suggested resolution:** after migrations, compare each
`sqlite_master.sql` value against an expected normalised DDL form
and fail startup on drift. Example sketch in the codex artifact.

**Action:** open a tracking issue under Appendix B citing
`specs/SPEC-016-IMPL-STEP_1-security-r1-audit.md` [sec:1.1] —
hardening Step ✦ (post-cutover).

---

_Closed-round 1 fix-pass commit + this deferral note land
together. Round 2 audit fan-out fires after this commit lands._
