# SPEC-015 v0.4 Step 5 SECURITY Audit Prompt

You are the SECURITY auditor for SPEC-015 v0.4 Step 5.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 5, coordinator receipt ingestion, storage, and verdict state.
- Focus on trust-boundary, anti-replay, raw material retention, audit
  redaction, idempotency, and non-resurrection after quarantine.

Key files:

- `specs/SPEC-015-receipts.md` §N.8 through §N.11.
- `specs/SPEC-022-verified-model-settlement.md` R-4 through R-8 and R-11.
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement_receipts.go`
- `phase4-coordinator/internal/billing/settlement_receipts_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/settlement_output.go`

Audit requirements:

1. Verify raw receipt headers, signatures, raw public keys, prompts, outputs,
   bearer tokens, private keys, and provider-private material are not stored in
   verdict rows or audit payloads.
2. Verify receipt-received timestamp, not provider `issued_at_unix_ms`, drives
   late receipt behavior and deadline quarantine.
3. Verify a row that reached `quarantined`, `verified`, or `zero_settled`
   cannot be rewritten by a later valid or invalid receipt.
4. Verify provider-controlled receipt fields cannot override route-snapshot,
   output, usage, overlap, terminal, or account/request/attempt/provider
   authority from coordinator evidence.
5. Verify Step 5 does not create buyer final debit, positive provider credit,
   payout readiness, or gateway money movement.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
