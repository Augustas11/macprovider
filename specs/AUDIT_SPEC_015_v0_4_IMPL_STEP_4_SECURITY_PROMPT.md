# SPEC-015 v0.4 Step 4 SECURITY Audit Prompt

You are the SECURITY auditor for SPEC-015 v0.4 Step 4.

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: Step 4, verifier support and settlement mapping.
- Focus on trust-boundary, anti-replay, key binding, signature/canonicalization,
  and raw secret/receipt exposure risks.

Key files:

- `specs/SPEC-015-receipts.md` §N.1 through §N.11.
- `phase7-verify/internal/verify/settlement.go`
- `phase7-verify/internal/verify/settlement_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/settlement_verifier_test.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_output.go`
- `testdata/spec015/v04_settlement_receipts.json`

Audit requirements:

1. Verify provider signatures are accepted only for the route-snapshot-pinned
   Ed25519 receipt key and exact `provider_receipt_key_id`.
2. Verify replay onto another account, request, attempt, provider, key,
   route snapshot, terminal state, or timestamp window cannot produce
   `verified` or `zero_settled`.
3. Verify unknown future versions, legacy/hashless/malformed receipts, missing
   canonical hashes, missing receipts, and trust-root inconclusive states do
   not become payable.
4. Verify raw receipt signatures, raw receipt public keys, prompts, outputs,
   bearer tokens, private keys, and provider-private material are not copied
   into verifier result surfaces.
5. Identify any acceptance path where provider-controlled fields override
   coordinator/route-snapshot authority.

Return:

- Findings grouped as CRITICAL / HIGH / MEDIUM / LOW.
- For every CRITICAL/HIGH/MEDIUM finding, include file/line evidence and a
  concrete fix recommendation.
- End with a count summary: `CRITICAL=x HIGH=y MEDIUM=z`.
