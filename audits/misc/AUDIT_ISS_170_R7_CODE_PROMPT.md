You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a CODE lens.

# Repository context

- Branch `spec/004-build-prompt-bcda`, HEAD at commit `bfee99d`
  (R6 fix-pass).
- R1–R6 audit fix-passes landed; THIS round verifies R6 absorptions
  and surfaces anything new the R6 edits introduced.
- SPEC-004 v0.3.1 LOCKED. Origin/main: SPEC-005 v0.4, SPEC-006
  v0.9.1, SPEC-002 v1.5.2.

# R6 absorbed findings (verify each fix landed correctly)

- CODE-M1: FR-SR-17 `retried` field now described as integer count
  (NOT boolean), matching SPEC-004 §7 + request_log.retried column
  semantics.
- ARCH-M1: buyer/server.go bullet reworded to say
  LogRoutingDecision fires for EVERY selection attempt (incl.
  retry + preflight), not only randomized decisions.
- CODE-L1: Phase A buyer/server.go bullet now explicitly pins
  accountID source to gateway-authenticated X-MacProvider-Account
  internal header.

# Audit scope (CODE lens)

Standard slate per prior rounds: file paths, R-rule citations,
config keys, AC citations, dependency versions, default
preservation, SPEC-005 retried contract, ordering, FR-SR-7a
discipline.

R6-specific:
- Verify the reworded `retried` field is unambiguous now.
- Verify no other bullet still narrows LogRoutingDecision to
  randomized-only.
- Verify the Phase A accountID source pin is internally
  consistent with the gateway/auth-frame description elsewhere.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per prior rounds.

# Output format

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt + SPEC-004 §7 verbatim + SPEC-005 v0.4 +
SPEC-006 v0.9.1 + relevant origin/main code before writing any
finding. Do not speculate; cite quotes.
