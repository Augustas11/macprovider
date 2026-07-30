# AUDIT_SPEC_015_IMPL_STEP_11_PROMPT

Audit SPEC-015 implementation Step 11, "Final integration acceptance
run", against `specs/BUILD_SPEC_015_IMPL_PROMPT.md` and
`specs/SPEC-015-receipts.md`.

Scope:
- `test/integration/spec015/`
- `.github/workflows/ci.yml`
- Any tests referenced by the SPEC-015 AC manifest.

Required checks:
1. AC-1 through AC-17 are all represented exactly once.
2. Every AC has a deterministic test command that runs in CI.
3. No AC is deferred to manual verification, TODO, or operator-only
   prose. If an AC is environment-gated, there must still be a
   deterministic CI-enforced fixture or contract test for the repo-local
   behavior.
4. The cross-service integration CI job executes the SPEC-015 AC
   manifest package as part of `go test ./...`.
5. Evidence anchors point at real tests or fixture files, not aspirational
   documentation.
6. The runner reports each AC with the specific SPEC-015 §14 verification
   step.

Report Critical, High, Medium, and Low findings. The implementation may
not be considered locked until Critical/High/Medium are all zero.
