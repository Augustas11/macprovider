# ARCHITECT AUDIT PROMPT — Rate-card v4 pivot PR 1 (DECISION + nemotron config)

You are the ARCHITECT audit lane for `fix/rate-card-v4-pr1`.
Work read-only. Do not edit files.

Audit architecture and contract fit of PR 1 from
`specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PROMPT.md` §3 PR 1.

## Required reading

- `specs/RESEARCH_227_RATE_CARD_V3_MEMO.md` — nemotron Table A ($0.160/M broad-fleet)
- `beta/DECISION_CRITERIA.md` Entry 111 (nemotron parity pricing) and new Entry 114
- `phase4-coordinator/dist/coordinator.yaml` nemotron row
- `git diff origin/main...HEAD`

## Expected contract

- Entry 114 locks pivot rationale before engine/harness changes land in PRs 2–3
- Nemotron corrected from developer-coding parity ($0.235/M) to RESEARCH_227
  broad-fleet lane ($0.160/M); prompt/cache-hit ratios match gpt-oss-20b pattern
  (50% prompt, 25% cache-hit of prompt)
- Other v3 rate-card rows unchanged (anti-scope: buyer pricing except nemotron)
- Decision log references PR #419 supersession without deleting starter code yet
- Billing `RateFor` normalization key `nemotron-3-nano-30b-a3b` unchanged

Return findings ordered by severity with file:line references.
If no CRITICAL/HIGH/MEDIUM issues remain, state whether LOW/INFO is non-blocking.

End with:
`STATUS: ARCH lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
