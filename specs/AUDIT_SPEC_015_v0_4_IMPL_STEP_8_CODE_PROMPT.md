# AUDIT_SPEC_015_v0_4_IMPL_STEP_8_CODE_PROMPT

You are the Codex code audit lane for SPEC-015 v0.4 implementation Step 8.

Scope: review the current worktree diff for Step 8 integration acceptance.
Do not modify files.

Primary files:

- `phase4-coordinator/internal/billing/spec015_v04_acceptance_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier_test.go`
- `phase4-coordinator/internal/billing/settlement_receipts_test.go`
- `phase4-coordinator/internal/buyer/route_snapshot_test.go`
- `phase3-binary/Tests/macprovider-cliTests/*Receipt*Tests.swift`
- `phase7-verify/internal/verify/settlement_test.go`
- `implementation-notes-spec-015-v0-4.md` Step 8
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 8
- `specs/SPEC-015-receipts.md` §N.11 AC-43 through AC-71

Requirements to audit:

1. `TestSPEC015V04AcceptanceCriteria` materially proves AC-43 through AC-71
   and cannot pass with an untested AC marker.
2. The acceptance test uses real shared v0.4 fixtures/verifier/store surfaces
   rather than fake-only assertions.
3. Positive/negative fixture checks align with SPEC-015 §N.11 public outcomes,
   including `verified`, `zero_settled`, `pending`, and `quarantined`.
4. Full-suite validation evidence matches Step 8 build-prompt requirements.
5. Step 8 does not add production behavior unrelated to acceptance coverage.
6. Tests are deterministic and not brittle to harmless fixture ordering changes.

Report only real bugs or material test gaps. Use severity Critical, High,
Medium, Low. Include file/line evidence and exact remediation. End with counts:
critical/high/medium/low.
