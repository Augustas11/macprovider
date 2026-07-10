# SPEC-022 implementation deliverable 7

Status: audit and observability implemented and locally validated.

## Result

D7 expands settlement receipt verdict audit events so each covered attempt
includes the SPEC-022 R-11.1 audit contract without raw prompts, raw outputs,
receipt envelopes, receipt signatures, receipt public keys, bearer tokens, or
raw account scope. Verdict events now include:

- redacted account scope hash, request id, attempt number, and stable attempt
  id;
- provider id plus provider session/generation id when present in the route
  snapshot;
- model id, paid entrypoint, route snapshot policy version and mode, route
  snapshot digest, catalog id, and catalog body digest;
- route-time hash status, full provider-reported model hash, and full expected
  catalog model hash;
- receipt version/profile, receipt-key fingerprint, terminal state, receipt
  verification outcome, settlement outcome, reason, and pending deadline;
- buyer debit, provider settlement, and payout exclusion outcomes.

`/admin/ledger/summary` now exposes `settlement_verdict_counters`, grouped by
policy version, model id, entrypoint, and reason code. Each grouped row includes
counters for verified, pending, quarantined, zero-settled, legacy receipt,
missing receipt, catalog mismatch, model-hash null, and receipt-key mismatch
outcomes.

## Validation

- `go test -count=1 ./internal/billing -run 'TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit|TestSummaryEndpointIncludesSettlementVerdictCounters|TestSettlementReceiptDiagnosticsQueryShapeIsBounded|TestSPEC022D8AcceptanceCoverageMapIncludesAllACs'`
- `go test -count=1 ./internal/billing`
- `cd phase4-coordinator && go test -count=1 ./...`
- `cd phase5-gateway && go test -count=1 ./...`

## Audit closure

Codex 3-lane re-audit after fixes:

- code: 0 Critical / 0 High / 0 Medium;
- security: 0 Critical / 0 High / 0 Medium;
- architecture/spec fidelity: 0 Critical / 0 High / 0 Medium.

## Remaining non-D7 gates

D7 does not implement the remaining money-path final-debit/provider-credit
settlement gates, payout-consumption gates, race harnesses, or live-network
end-to-end gates tracked by other SPEC-022 deliverables.
