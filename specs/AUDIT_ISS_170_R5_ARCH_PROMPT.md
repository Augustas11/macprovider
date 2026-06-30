You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
an ARCHITECT lens.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `cc55003` (R4 fix-pass).
- SPEC-004 v0.3.1 LOCKED; SPEC-005 v0.4, SPEC-006 v0.9.1 on
  origin/main.

# R4 architecture-relevant absorbed findings (verify each fix landed)

- ARCH-M1: Pillar-completion checklist split into Common gates +
  Pillar D additional gates + Pillar A additional gates. Verify
  the split is clean and the Common section does not still
  reference Pillar-D-only or Pillar-A-only content.
- ARCH-M2: Pillar D money-path gate item (d) replaced with
  concrete SPEC-005 v0.4 preservation assertions. Verify the
  language is concrete enough to refuse merge.
- ARCH-M3: Pillar A money-path gate split into three explicit
  test cases against `X-MacProvider-Internal-Conv`. Verify the
  cases collectively exhaust the source-authority boundary.
- ARCH-M4: `sticky.Map.PurgeAccount(accountID)` added to the
  sticky package API. Verify the addition is consistent with the
  rest of Phase A (lookup/update/InvalidateClass + PurgeAccount
  feels like the right surface; the handler preservation note is
  correctly placed).

# Audit scope (ARCHITECT lens)

- **Scope cohesion.** Per phase, "what's in this PR vs. what's
  deferred" remains crisp. With the new SPEC-005 v0.4 preservation
  gate and the PurgeAccount addition, is any phase now over-
  scoped?
- **Sequencing.** B → C → D → A still enforced; PurgeAccount
  doesn't introduce a Phase B/C/D dependency on the new sticky
  API.
- **Composition with adjacent specs.** SPEC-005 v0.4 preservation
  (no quarantine writes from Pillar D code paths) + SPEC-006
  v0.9.1 internal-conv boundary + SPEC-006 DELETE /v1/sticky
  contract preservation — verify each is enforceable from the
  prompt alone.
- **NOT-covered surface is exhaustive.** No regression from the
  R3 NOT-covered additions.
- **Pillar-completion gates.** Verify the three-block structure
  (Common / Pillar D / Pillar A) is clean and that each block's
  items are independently checkable.
- **AC-SR-14 staging.** Re-verify leg-0 / leg-1 / leg-2 / leg-3-4
  staging is collectively exhaustive and non-overlapping.
- **FR-SR-17 logging placement.** Re-verify `internal/routing/log.go`
  is the right home with the now-expanded field set.
- **Audit cycle expectations.** Three-lane codex audit per pillar
  PR remains the discipline.
- **Worktree-per-pillar.** Pattern intact.

# Severity vocabulary

- **CRITICAL** = structural defect making convergence impossible.
- **HIGH** = scope/sequencing ambiguity forcing mid-PR rewrite.
- **MEDIUM** = precision improvement that materially helps
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

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM
blocks merge.

Read the BUILD prompt + SPEC-004 + SPEC-005 v0.4 + SPEC-006 v0.9.1
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
