# AUDIT_SPEC_023 v0.1 — CODE LANE

Audit target: `specs/SPEC-023-installer-autotune-recommend.md`

Role: code auditor. Review the SPEC for implementation clarity, testability, compatibility with current code surfaces, and contradictions that would cause an implementer to build the wrong behavior.

Required local reads:

- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-023-v0_1-KICKSTART-PROMPT.md`
- `phase3-binary/dist/install.sh` around `choose_model()`
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` around `defaultCandidates`
- `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift` around `MachineFingerprinter.sample()`
- `phase4-coordinator/internal/billing/formula.go` around `RateFor` and `normalizeModelKey`

Findings to prioritize:

- Spec requirements that cannot be implemented from the current code structure without hidden extra product decisions.
- Ambiguous formulas, rounding, field types, fallback behavior, or model-key normalization rules.
- Missing acceptance criteria for required behavior.
- Contradictions between JSON schema, transcript copy, donor-mode behavior, eligibility gates, and stored state.
- Accidental implementation scope creep into gateway/coordinator money-path code.

Severity rubric:

- CRITICAL: would make v0.1 unsafe or impossible to implement correctly.
- HIGH: would likely cause a wrong implementation, bad provider recommendation, or breaking incompatibility.
- MEDIUM: testability or ambiguity gap likely to create rework.
- LOW: editorial or non-blocking clarity issue.

Return format:

```text
Verdict: READY TO LOCK | NEEDS FIX PASS
Counts: CRITICAL=n HIGH=n MEDIUM=n LOW=n

Findings:
- [SEVERITY-CODE] Title
  Evidence: file/section reference
  Impact:
  Required fix:

Accepted LOWs:
- ...
```
