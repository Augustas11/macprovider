You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
an ARCHITECT lens.

# Repository context

- Branch `spec/004-build-prompt-bcda`, HEAD at commit `bfee99d`
  (R6 fix-pass). SPEC-004 v0.3.1 LOCKED. Origin/main: SPEC-005
  v0.4, SPEC-006 v0.9.1.

# R6 absorbed findings (verify each fix landed correctly)

- ARCH-M1: buyer/server.go bullet now consistent with log-block
  per-attempt emission contract.

# Audit scope (ARCHITECT lens)

Standard slate: scope cohesion, sequencing B→C→D→A, composition
with adjacent specs, NOT-covered exhaustiveness, pillar-completion
gates structure, AC-SR-14 staging, FR-SR-17 logging placement /
call-site posture, audit cycle discipline, worktree-per-pillar.

R6-specific:
- Verify the per-attempt emission contract is now described in
  exactly one place (the log block) and the buyer/server.go bullet
  defers to it without contradiction.
- Verify no other location implies a different emission cadence.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per prior rounds.

# Output format

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM
blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
