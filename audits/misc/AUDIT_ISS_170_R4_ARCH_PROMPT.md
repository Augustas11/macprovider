You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
an ARCHITECT lens. This is a BUILD prompt — paste-ready
instructions for an implementer LLM session to ship SPEC-004 v0.3.1
Pillars B / C / D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `0770e7d` (R3 fix-pass).
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
- origin/main current spec versions: SPEC-001 v1.6, SPEC-002
  v1.5.2, SPEC-004 v0.3.1, SPEC-005 v0.4, SPEC-006 v0.9.1.
- This is a multi-week, multi-PR build cycle. ARCH findings are
  about scope, sequencing, composition, and "is this the right
  shape for the implementer to converge".

# R3 architecture-relevant absorbed findings (verify each fix landed)

- A-H1: Pillar-letter regrouping clarifier — verify it makes the
  scope unambiguous between THIS prompt's Phase B/C/D and
  SPEC-004 §11's Pillar B/C/D.
- A-H2 / C-H1: Phase B `tiebreak_randomize=true` contradiction —
  verify Phase B's rules-implemented paragraph and the config
  bullet are mutually consistent.
- A-M1: SPEC-008 §5.7 / SPEC-010 §6.3 additive-only constraint —
  verify it now lives in Phase D body (with regression test
  requirement) and the operator-notes copy is retained as
  reference (not removed).
- A-M2: SPEC-005 OQ-5 quarantine-resolution + SPEC-008 hash +
  SPEC-010 cold-supported-model bullets in NOT-cover list.

# Audit scope (ARCHITECT lens)

For each phase (B / C / D / A), verify:

- **Scope cohesion.** Each phase has a clear, bounded "what's in
  this PR vs. what's deferred" surface. Verify the Phase-letter
  regrouping block at the top does not create a residual
  ambiguity (e.g., "I'm in Phase D — am I shipping SPEC-004
  Pillar C retry or SPEC-004 Pillar D tiebreak?"). Verify per-
  phase Files-touched + R-rule lists tightly map to the named
  scope.
- **Sequencing.** Phase order B → C → D → A is intentional;
  verify the prompt's per-phase prerequisites accurately reflect
  this (e.g., Phase A explicitly depends on Phase D's epsilon-
  cohort + class-invalidation hooks).
- **Composition with adjacent specs.** Verify the additive-only
  constraints around SPEC-008 / SPEC-010 are normatively
  enforceable from the prompt alone (no "see SPEC-010 for
  details" handwave). Verify the SPEC-005 v0.4 update is
  composed correctly (Phase D writes `request_log.retried`;
  v0.4's force-void admin surface MUST NOT be touched).
- **NOT-covered surface is exhaustive.** With the R3-added
  SPEC-005 OQ-5 + SPEC-008 + SPEC-010 bullets, verify no
  reasonable implementer would still be tempted to inline a
  scope expansion (e.g., a v0.5 force-credit, a /v1/models
  hash-block restructure, a new operator-tunable body-cap knob).
- **Audit cycle expectations.** The "Per-pillar audit discipline
  (locked)" section names three-lane codex audit per pillar PR.
  Verify the discipline is consistent with the
  `feedback-three-lane-codex-audits` user-memory pattern
  (CODE / SECURITY / ARCH lanes; converge to 0 C/H/M).
- **Worktree-per-pillar (C10).** Verify the worktree pattern is
  consistent with the `feedback-always-fresh-worktree-for-code-
  work` user-memory pattern.
- **Pillar-completion gates.** Verify each gate item is testable
  and unambiguous; specifically verify the Pillar D + Pillar A
  money-path gates are concrete enough to refuse a merge.
- **AC-SR-14 staging across phases.** With the R3 leg-0 / leg-1 /
  leg-2 / leg-3/4 staging, verify the staging is collectively
  exhaustive (do all four phases together prove "composition
  gates hold" in the SPEC-004 §8 sense?) and non-overlapping
  (does any phase double-count?).
- **FR-SR-17 logging placement.** Verify
  `internal/routing/log.go` is the right home for the
  reproducibility log (e.g., not better placed in
  `internal/buyer/` next to other request-log writers, or in
  `internal/routing/decision.go` next to selection).

# Severity vocabulary

- **CRITICAL** = the BUILD prompt has a structural defect that
  makes convergence impossible (e.g., circular phase dependency,
  contradictory spec citations).
- **HIGH** = a scope or sequencing ambiguity that would force a
  mid-PR rewrite.
- **MEDIUM** = a precision improvement that materially helps
  convergence.
- **LOW** = wording or framing.

# Output format

For each finding:

```
Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with:

```
Tally: C/H/M/L
```

Goal: 0/0/0/0 on R4. Any HIGH or MEDIUM finding blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
