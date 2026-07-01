# AUDIT_BUILD_SPEC_015_v0_4_IMPL_CODE_R3_PROMPT

You are re-auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the CODE lane before implementation begins.

R2 CODE finding to verify closed:

- `CODE-H-1`: provider issuance still required streaming receipt submission
  through an internal coordinator-ingested channel before the coordinator
  ingestion API/channel and verdict state existed. Verify ingestion/storage/
  verdict scaffolding now lands before provider issuance, and that each
  numbered step remains independently auditable.

Also verify the R3 edit did not reopen the previously closed R1 findings:

- no `forward_loop.go` stale filename;
- SPEC-022 buyer debit, provider credit, payout-ready rows, and enforce-mode
  startup behavior remain downstream/deferred;
- strict `settlement_output_v1`, route snapshots, usage, timestamp authority,
  receipt-key identity, streaming/non-streaming coverage, and redaction remain
  implementable.

Do not re-audit clean security/product/adversarial/architect concerns except
where the R3 code edit creates a direct implementability contradiction.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
file paths and concrete lines.
