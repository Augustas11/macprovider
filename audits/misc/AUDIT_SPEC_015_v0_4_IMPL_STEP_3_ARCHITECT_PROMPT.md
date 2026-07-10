# AUDIT_SPEC_015_v0_4_IMPL_STEP_3_ARCHITECT_PROMPT

You are auditing Step 3 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex architect lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7.
- `specs/SPEC-022-verified-model-settlement.md`.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 3.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 3 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Required checks:

1. The evidence model is coherent with Step 2 route snapshots and can be joined
   later by SPEC-022 without ambiguous attempt identity.
2. The coordinator/gateway boundary is clear: OpenAI-compatible client traffic
   is preserved while coordinator-owned settlement evidence is durable.
3. Terminal-state and usage-source enums are narrow enough for later verifier
   semantics and do not overclaim settlement readiness.
4. Output prefix range handling supports transparent failover and later
   non-creditable overlap rejection.
5. The schema is sufficient for auditability without prematurely introducing
   SPEC-022 money-path state.
6. Failure handling is fail-safe for covered routes and does not silently mark
   incomplete or malformed evidence as settlement-capable.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
