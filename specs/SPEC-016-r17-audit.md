# SPEC-016 v0.1.15 Codex Round 17 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.15 at commit `f6d4918` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.16.
**Date:** 2026-06-25.

---

## Codex verdict

VERDICT: NOT CONVERGED — 0 CRITICAL / 0 MAJOR / 1 MEDIUM / 0 new LOW.

**MEDIUM**
1. [/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3204](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3204)

Issue: Reconfirm-stale paging says the event fires once per cancel-row transition, but then explicitly allows the suppression state to live “in memory or via a flag column” at lines 3204-3207. An in-memory tracker resets on coordinator restart, so an unresolved stale cancel can re-page after every restart even though it has not entered a new stale period.

Impact: A cold IMPL can follow the spec literally and still violate the once-per-transition alert contract. In a restart loop, BetterStack gets repeated PAGE alerts for the same stale cancel row, increasing alert noise while fresh non-cancel allocation remains halted.

Paste-ready fix:

```md
The event fires once per cancel-row-transition-into-stale
(NOT every cycle and NOT every coordinator restart). IMPL MUST
persist this suppression state in SQLite, not process memory. Add
`cancel_reconfirm_stale_paged_at_utc TEXT NULL` to `payout_attempts`.
The §4.7 reorg-reactivation UPDATE MUST set this column to NULL.
When the stale threshold is crossed and BOTH RPCs still return "not
found", the runner MUST atomically mark the row stale-paged only if
`cancel_reconfirm_stale_paged_at_utc IS NULL`; only the successful
marker transition emits `payout_cancel_self_transfer_reconfirm_stale`.
The §4.3 cancel-confirmation UPDATE MUST clear this column so a later
reorg can re-arm a new stale period.
```

**Closure Checks**
Round-16 MED-1 is closed: §4.3 now says emit only on the `confirmed_at_utc NULL -> non-NULL` transition and later already-confirmed pre-checks must not re-emit.

Round-16 MED-2 is closed: §7.1 includes `is_cancel_self_transfer` on `payout_reorg_revert` with 0/1 semantics.

Round-16 MED-3 is partially closed: event, threshold, BetterStack enumeration, and re-arm wording exist; durable suppression is the remaining gap.

No new replay, MEV, Signer, reorg money-out, race, or operator-key drain defect found in this pass. `git diff --check` is clean, markdown fences are balanced, and the 4 intentionally deferred LOWs remain in place.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-15-commit-f6d4918-branch-spec-016-payout-2026-06-25T05-29-25-770Z.md`
- Fix pass commit message: see `git log f6d4918..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.16 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
