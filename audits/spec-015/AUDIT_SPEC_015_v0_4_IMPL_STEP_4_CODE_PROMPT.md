# SPEC-015 v0.4 Step 4 CODE Audit Prompt

You are the CODE auditor for SPEC-015 v0.4 Step 4.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 4, verifier support and settlement mapping.
- Audit only the Step 4 implementation delta plus direct dependencies needed
  to judge it.

Key files:

- `specs/SPEC-015-receipts.md` §N and AC-43 through AC-71.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 4.
- `phase7-verify/internal/verify/settlement.go`
- `phase7-verify/internal/verify/settlement_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/settlement_verifier_test.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_output.go`
- `testdata/spec015/v04_settlement_receipts.json`
- `implementation-notes-spec-015-v0-4.md`

Audit requirements:

1. Verify strict v0.4 tuple parsing, usage object parsing, canonical tuple
   byte checks, and signature verification behavior.
2. Verify settlement outcome mapping for `verified`, `zero_settled`,
   `pending`, and `quarantined`.
3. Verify fixture coverage actually exercises the Step 4 acceptance surface:
   positive terminal-state matrix, negative receipt vectors, missing/trust-root
   pending-to-quarantine, replay, and unknown future versions.
4. Verify the existing v0.3 verifier behavior is not regressed.
5. Identify correctness bugs, missing tests, or reason-code ambiguity that
   could cause false positive settlement or false quarantine.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
