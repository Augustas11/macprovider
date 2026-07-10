# SPEC-016 v0.1.17 Codex Round 19 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.17 at commit `7be223d` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** none — CONVERGED at user's 0/0/0 bar. (v0.1.18 is post-convergence LOW sweep + this audit-narrative-split refactor PR.)
**Date:** 2026-06-25.

---

## Codex verdict

CONVERGED — audit verdict: 0 CRITICAL, 0 MAJOR, 0 MEDIUM.

I audited `specs/SPEC-016-payout-pipeline.md` at `7be223d` on `spec/016-payout-pipeline-v0.1`, read the full 5,852-line spec, and verified the v0.1.17 body rather than relying on the changelog.

Round-18 closure verified:
- MED-1 closed: §4.7 step 5 now does marker CAS plus `cancel_reconfirm_stale_outbox` insert in the same `BEGIN IMMEDIATE` txn at `/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3471`; post-commit CAS claim + sync emit + reaper are specified at line 3514.
- §4.8c table is present with FK `ON DELETE RESTRICT`, unemitted index, unique `(payout_id, attempt_seq, stale_started_at_utc)`, and same-DB pin at line 4243.
- MED-2 closed: §4.7 step-4 SQL literally clears `cancel_reconfirm_stale_paged_at_utc = NULL` at line 3407.
- `event_id` is in the §7.1 stale PAGE schema, and `payout_stale_outbox_reaped` is added at lines 5074-5075.
- BetterStack §9 prereq includes the new WARN event at line 5663.

New v0.1.17 surface checked:
- FK restriction is acceptable; this is audit-retention state, and no operator recovery path depends on deleting `payout_attempts`.
- Shared vs separate reaper goroutine is acceptable; the contract is the mandatory scan/CAS/emit behavior, not goroutine topology.
- The 5-minute reaper threshold is aligned with §4.8a and is not a money-path tuning parameter.
- Timestamp drift is not a spec gap: the literal SQL uses the same `:now` for marker and outbox `stale_started_at_utc`.
- Same-DB pin is present for the new table.

Spec hygiene:
- `git diff --check 7be223d^ 7be223d -- specs/SPEC-016-payout-pipeline.md` is clean.
- Markdown fence count is even (`60`).
- The 4 intentionally deferred LOWs remain documented and unchanged.
- I found no new replay, MEV, Signer, reorg, race, or operator-key money-OUT defect from v0.1.17.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-17-commit-7be223d-branch-spec-016-payout-2026-06-25T05-45-54-573Z.md`
- This is the convergence-declaration round; no fix-pass commit follows.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
