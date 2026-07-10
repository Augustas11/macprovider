# AUDIT_BUILD_SPEC_015_v0_4_IMPL_CODE_R2_PROMPT

You are re-auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the CODE lane before implementation begins.

R1 CODE findings to verify closed:

- `CODE-H-1`: Step 3 provider issuance was ordered before hard dependencies:
  terminal state/timestamp, output prefix/hash, usage authority, and ingestion.
- `CODE-M-1`: the prompt referenced non-existent
  `phase4-coordinator/internal/buyer/forward_loop.go`.
- `CODE-M-2`: SPEC-022 money-movement boundary needed tighter wording because
  Step 5/8 mentioned buyer debit, provider credit, payout-ready rows, and
  SPEC-022 startup behavior in ways that could be read as in-scope.

Also verify the R2 edits did not reopen implementability gaps around streaming,
non-streaming, zero-based `attempt_n`, strict `settlement_output_v1`,
route snapshots, usage, timestamp authority, receipt-key identity, or redaction.

Do not re-audit clean security/product/adversarial concerns except where the R2
code/architecture edits create a direct implementability contradiction.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
file paths and concrete lines.
