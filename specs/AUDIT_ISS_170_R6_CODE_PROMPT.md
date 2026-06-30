You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a CODE lens.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`,
  HEAD at commit `2185f9d` (R5 fix-pass).
- R1–R5 audit fix-passes landed; THIS round verifies R5 absorptions
  and surfaces anything new the R5 edits introduced.
- SPEC-004 v0.3.1 LOCKED. origin/main spec versions: SPEC-001 v1.6,
  SPEC-002 v1.5.2, SPEC-004 v0.3.1, SPEC-005 v0.4, SPEC-006 v0.9.1.

# R5 absorbed findings (verify each fix landed correctly)

- CODE-H1 / ARCH-H1 (shared): sticky.Map.Update signature now
  carries accountID:
  `Update(conversationKey, accountID, providerID, modelScope)`.
  Verify the call site description in the buyer/server.go bullet
  is consistent and explicit that accountID comes from gateway-
  authenticated X-MacProvider-Account, never from a direct-buyer
  header.
- CODE-M1 / ARCH-M1: FR-SR-17 / SPEC-004 §7 log field list now
  replaced with the FULL §7 verbatim list. Verify against
  `specs/SPEC-004-smart-router.md` §7 line-by-line that no
  required field is still missing.
- CODE-M2: SPEC-002 v1.5.2 / v1.3.3 reconciliation. Verify C2 and
  Phase B both use the "current SPEC-002 v1.5.2 / origin/main"
  anchor with the v1.3.3 historical note.

# Audit scope (CODE lens)

For each phase (B / C / D / A) verify the standard slate:
file-path accuracy, R-rule citation completeness, config-key
consistency with SPEC-004 §5, AC citation accuracy, dependency-
version freshness, default-config preservation, SPEC-005 retried
contract, cross-phase ordering, FR-SR-7a test discipline.

Additional R5-specific checks:
- The Update signature change cascades correctly through the
  buyer/server.go bullet and the Phase A pillar-completion gate.
- The FR-SR-17 field list matches SPEC-004 §7 verbatim — note §7
  uses `x_request_id` (underscore), not `external_request_id`.
- The C2 anchor reword does not break any other section's
  default-preservation language.

# Severity vocabulary

- CRITICAL = money-path-corrupting; HIGH = implementer would fill
  INCORRECTLY; MEDIUM = precision improvement; LOW = wording.

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
