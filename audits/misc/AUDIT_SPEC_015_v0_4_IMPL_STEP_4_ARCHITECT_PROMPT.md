# SPEC-015 v0.4 Step 4 ARCHITECT Audit Prompt

You are the ARCHITECT auditor for SPEC-015 v0.4 Step 4.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 4, verifier support and settlement mapping.
- Focus on module boundaries, SPEC-015/SPEC-022 layering, future integration
  risk, and whether this is the right abstraction for Step 5 ingestion.

Key files:

- `specs/SPEC-015-receipts.md` §N.
- `specs/SPEC-022-verified-model-settlement.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
- `phase7-verify/internal/verify/settlement.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_output.go`
- `implementation-notes-spec-015-v0-4.md`

Audit requirements:

1. Verify the coordinator does not import `phase7-verify/internal/*` and that
   verifier semantics are still fixture-locked across modules.
2. Verify Step 4 does not prematurely wire buyer final debit,
   provider-positive settlement, payout readiness, gateway money movement, or
   SPEC-022 enforce activation.
3. Verify the API shape can be consumed by Step 5 ingestion/storage without
   carrying raw receipt material into audit/telemetry/operator surfaces.
4. Verify settlement outcomes and reason classes are precise enough for later
   state-machine/idempotency work.
5. Identify architectural coupling, duplication drift risk, or missing
   boundary tests that would block Step 5.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
