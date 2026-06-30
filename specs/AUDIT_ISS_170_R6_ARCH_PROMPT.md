You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
an ARCHITECT lens.

# Repository context

- Branch `spec/004-build-prompt-bcda`, HEAD at commit `2185f9d`
  (R5 fix-pass). SPEC-004 v0.3.1 LOCKED. Origin/main spec
  versions: SPEC-005 v0.4, SPEC-006 v0.9.1.

# R5 absorbed findings (verify each fix landed correctly)

- ARCH-H1 (shared with CODE-H1): sticky.Map.Update now carries
  accountID. Verify the new API surface (Lookup / Update /
  InvalidateClass / PurgeAccount with accountID-carrying entries)
  is cohesive and the handler preservation note remains correct.
- ARCH-M1 (shared with CODE-M1): FR-SR-17 log fields replaced
  with full §7 verbatim list. Verify the placement remains
  internal/routing/log.go and the call-site placement at
  selection + retry + preflight is unambiguous (e.g., does each
  attempt get its own routing-decision log row?).

# Audit scope (ARCHITECT lens)

- Scope cohesion per phase still crisp.
- Sequencing B → C → D → A still enforced; the new accountID
  thread does not introduce a Phase B/C/D dependency on Phase A.
- Composition with adjacent specs: SPEC-005 v0.4 preservation,
  SPEC-006 v0.9.1 internal-conv + DELETE /v1/sticky preservation
  + per-entry AccountID storage still enforceable from prompt.
- NOT-covered surface unchanged.
- Pillar-completion gates: three-block structure intact.
- AC-SR-14 staging unchanged.
- FR-SR-17 logging placement and call-site posture (per-attempt
  emission) are architecturally sound.
- Audit cycle discipline + worktree-per-pillar intact.

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
