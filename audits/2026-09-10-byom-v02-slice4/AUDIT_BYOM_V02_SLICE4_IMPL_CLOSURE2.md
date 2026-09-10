# AUDIT — BYOM v0.2 slice 4 IMPL closure pass 2 (codex, code-reviewer; security and architect at bar)

Diff: `git diff origin/main` at `21f85b7f` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 0 INFO |

Closure-1 fixes confirmed (unchanged-binding re-stamp, strict actor availability).

**MEDIUM — availability counted an actor whose credential is unusable** (code). An invalid-actor entry sharing a valid actor's secret makes that actor's bearer ambiguous (refused) while the predicate skipped the invalid entry before checking secrets. Fix: secret multiplicity is counted over EVERY entry first; only strict-grammar normalized actors whose non-empty secret occurs exactly once count, and two entries normalizing to one actor disqualify. Test: `{"alice":"shared","Bob!":"shared","carol":"carol-secret"}` → `dual_control_unavailable`.
