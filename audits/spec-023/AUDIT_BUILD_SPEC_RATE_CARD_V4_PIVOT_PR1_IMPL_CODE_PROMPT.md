# CODE AUDIT PROMPT — Rate-card v4 pivot PR 1 (DECISION + nemotron config)

You are the CODE audit lane for `fix/rate-card-v4-pr1`.
Work read-only. Do not edit files.

Audit the implementation of PR 1 from `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PROMPT.md` §3 PR 1.

## Scope (in-scope files only)

- `beta/DECISION_CRITERIA.md` — new Entry 114
- `phase4-coordinator/dist/coordinator.yaml` — nemotron-3-nano-30b-a3b rate-card row

## Anti-scope (must NOT appear in diff)

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `test/network-harness/**`
- `specs/SPEC-023-installer-autotune-recommend.md`
- billing formula, gateway, starter-tier code deletion

## Expected contract

Entry 114 documents: old hourly-net model, harness 2026-07-06 finding, pivot to
per-token payout (recommended/donor), nemotron $0.235/M → $0.160/M, PR #419
starter tier superseded in follow-up PR 2.

Nemotron row values:
- `prompt_credits_per_mtok: 80000` ($0.080/M — 50% of completion)
- `prompt_cache_hit_credits_per_mtok: 20000` ($0.020/M — 25% of prompt)
- `completion_credits_per_mtok: 160000` ($0.160/M — RESEARCH_227 broad-fleet)

Compare `git diff origin/main...HEAD` against scope.

Return findings ordered by severity with file:line references.
If no issues remain, say `No findings.`

End with:
`STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
