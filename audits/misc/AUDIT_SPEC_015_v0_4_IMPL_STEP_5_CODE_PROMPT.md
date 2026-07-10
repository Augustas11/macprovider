# SPEC-015 v0.4 Step 5 CODE Audit Prompt

You are the CODE auditor for SPEC-015 v0.4 Step 5.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 5, coordinator receipt ingestion, storage, and verdict state.
- Audit only the Step 5 implementation delta plus direct dependencies needed
  to judge it.

Key files:

- `specs/SPEC-015-receipts.md` §N.8 through §N.9 and AC-43 through AC-71.
- `specs/SPEC-022-verified-model-settlement.md`.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 5.
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement_receipts.go`
- `phase4-coordinator/internal/billing/settlement_receipts_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_output.go`
- `implementation-notes-spec-015-v0-4.md`

Audit requirements:

1. Verify receipt ingestion loads the immutable route snapshot and attempt
   output evidence, then delegates outcome mapping to the Step 4 verifier.
2. Verify `settlement_receipt_verdicts` contains the parsed verifier-safe
   fields required by §N.9 and no raw receipt material.
3. Verify first-terminal selection and idempotency are correct for pending,
   verified, quarantined, zero-settled, deadline quarantine, and resubmission.
4. Verify tests cover valid ingestion, missing-before/after deadline,
   pending-to-verified, direct late receipt, resubmission no-op, and no
   premature ledger/payout writes.
5. Identify correctness bugs, missing tests, race risks, or state-machine
   ambiguity that could cause false positive settlement authorization or
   incorrect terminal no-op behavior.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
