# SECURITY AUDIT PROMPT — Rate-card v4 pivot PR 1 (DECISION + nemotron config)

You are the SECURITY audit lane for `fix/rate-card-v4-pr1`.
Work read-only. Do not edit files.

Audit security properties of PR 1 from `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PROMPT.md` §3 PR 1.

## Scope

- `beta/DECISION_CRITERIA.md` — Entry 114
- `phase4-coordinator/dist/coordinator.yaml` — nemotron rate-card row only

## Checklist

- No secrets, tokens, or private keys in changed files
- Rate-card YAML change does not widen auth surface or alter billing formula code
- No accidental exposure of operator credentials in decision log
- Config change is intentional nemotron row only; other rate-card rows unchanged
- Anti-scope preserved (no engine/harness changes that could affect donor opt-in)

Return findings ordered by severity with file:line references.
If no issues remain, say `No findings.`

End with:
`STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
