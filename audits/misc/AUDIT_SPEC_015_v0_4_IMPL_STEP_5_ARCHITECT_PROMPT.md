# SPEC-015 v0.4 Step 5 ARCHITECT Audit Prompt

You are the ARCHITECT auditor for SPEC-015 v0.4 Step 5.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 5, coordinator receipt ingestion, storage, and verdict state.
- Focus on module boundaries, SPEC-015/SPEC-022 layering, future Step 6/Step 8
  integration, and whether the state-machine abstraction is durable enough for
  SPEC-022 without premature money movement.

Key files:

- `specs/SPEC-015-receipts.md` §N.
- `specs/SPEC-022-verified-model-settlement.md`.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement_receipts.go`
- `phase4-coordinator/internal/billing/settlement_receipts_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `implementation-notes-spec-015-v0-4.md`

Audit requirements:

1. Verify the Step 5 API is internal and consumable by provider receipt
   submission work in Step 6 and SPEC-022 settlement work later.
2. Verify the verifier remains the owner of settlement outcome mapping and the
   ingestion layer does not duplicate or drift from Step 4 semantics.
3. Verify the durable state row exposes enough authorization evidence for
   SPEC-022 while keeping raw receipt retention out of audit/verdict/operator
   surfaces.
4. Verify first-terminal semantics compose with pending deadline behavior,
   late receipts, transparent failover, and per-attempt settlement.
5. Identify architectural coupling, migration risk, missing lifecycle states,
   or boundary gaps that would block Step 6/Step 8 integration.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
