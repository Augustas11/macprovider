# SPEC-015 v0.4 settlement receipts plan audit

Date: 2026-06-30

Status: prerequisite plan lock bar met.

Scope audited:

- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- Audit target was the receipt-profile build plan, not implementation code.
- This is SPEC-022 Deliverable 0. It does not authorize SPEC-022 enforce-mode
  buyer debit or provider-positive settlement against SPEC-015 v0.3 receipts.

## Final lane status

All lanes are at 0 critical, 0 high, and 0 medium.

| Lane | Final verdict | Evidence |
| --- | --- | --- |
| Codex code | READY, 0/0/0 | `.omc/artifacts/ask/codex-audit-spec-015-v0-4-settlement-receipts-plan-code-prompt-you-2026-06-30T16-39-47-247Z.md` |
| Codex architect | READY, 0/0/0 | `.omc/artifacts/ask/codex-audit-spec-015-v0-4-settlement-receipts-plan-architect-promp-2026-06-30T16-40-03-272Z.md` |
| Codex security | READY, 0/0/0 after R2 | `.omc/artifacts/ask/codex-audit-spec-015-v0-4-settlement-receipts-plan-security-r2-pro-2026-06-30T16-46-11-194Z.md` |
| Claude adversarial verification | READY, 0/0/0 after R2 | Claude subscription CLI transcript, self-contained R2 prompt |
| Claude product design critic | READY, 0/0/0 | Claude subscription CLI transcript |

## Closed blocking findings

Security R1:

- `SEC-M-1`: audit/storage redaction omitted receipt signatures and receipt
  public keys as explicitly prohibited audit material.

Adversarial R1:

- Missing explicit SPEC-022 R-3.3 three-way model-hash equality.
- Missing explicit R-5.6 unavailable partial-output binding ->
  pending-then-quarantine behavior.
- Timestamp policy was not strict enough for R-4.5.
- Receipt verifier results were not explicitly mapped into SPEC-022
  `pending`, `verified`, `quarantined`, and `zero_settled` outcomes.
- Route-attempt identity needed the monotonic requirement restored.
- Security R1 signature/public-key redaction needed to be included in
  adversarial closure.

The build prompt now requires:

- monotonic route-attempt identity;
- audit/telemetry/verdict/operator redaction of raw receipt signatures, raw
  receipt public keys, raw receipt envelopes, raw prompts, raw outputs, bearer
  tokens, receipt private keys, and provider-private state;
- SPEC-022 R-3.3 three-way equality:
  `receipt.model_hash == route_snapshot.provider_reported_model_hash ==
  route_snapshot.expected_catalog_model_hash`;
- provider-visible receipt deadline or `pending_deadline_seconds` basis;
- partial-output unavailable binding -> pending until deadline, then
  quarantine with buyer reservation released and no provider credit;
- raw receipt retention segregation from audit/telemetry/verdict rows;
- verifier-result mapping into SPEC-022 settlement outcomes;
- strict timestamp/window anti-replay policy;
- acceptance tests for the above.

## Non-blocking advisories

Claude adversarial R2 returned two low advisories:

- `ADV-L-1`: clarify that full route-snapshot fields needed for settlement,
  or at minimum `provider_reported_model_hash` and
  `expected_catalog_model_hash`, remain retrievable at verification time; the
  digest is only the binding anchor.
- `ADV-L-2`: add an explicit non-streaming canonical prompt/output hash
  unavailable acceptance criterion mirroring SPEC-022 AC-022-42b.

These are low severity and did not block the requested lock bar.

## Stop rule

SPEC-022 enforce-mode implementation remains blocked until the SPEC-015 v0.4
or successor settlement-capable receipt profile is locked, implemented, and
audited. The next implementation work should start from
`specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`, not by wiring
SPEC-022 money movement directly against SPEC-015 v0.3 receipts.
