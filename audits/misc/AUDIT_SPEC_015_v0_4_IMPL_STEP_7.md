# AUDIT_SPEC_015_v0_4_IMPL_STEP_7

Status: complete.

Step: SPEC-015 v0.4 Step 7 - Product disclosures and operator diagnostics.

Audit lanes:

| Lane | Status | Critical | High | Medium | Low |
|---|---:|---:|---:|---:|---:|
| Codex code | pass | 0 | 0 | 0 | 1 fixed locally |
| Codex security | pass | 0 | 0 | 0 | 0 |
| Codex architect | pass | 0 | 0 | 0 | 0 |

Claude adversarial and product-design lanes are intentionally deferred until
the full implementation lands, per updated implementation instruction.

Audit findings closed:

- Codex code reported one low stale SPEC-006 property-number reference. Fixed
  locally by updating the disclosure reference from property 5 to property 6.
  The lane already had 0 critical / 0 high / 0 medium, so it was not re-fired
  per instruction.
- Codex security reported one medium unbounded-diagnostics risk on provider hot
  paths. Fixed with a bounded 31-day default diagnostics window, explicit
  window bounds in responses, per-provider recent-failure limits, a
  closed-quarantined partial index, and a static query-shape regression test.
  Rerun result: 0 critical / 0 high / 0 medium / 0 low.
- Codex architect reported two medium design gaps: zero-settled receipts were
  grouped with failures, and diagnostics omitted route-policy/hash context.
  Fixed by splitting verified / zero-settled / quarantined / pending counts and
  by exposing redacted route policy, mode, paid-entrypoint, SPEC-008 hash
  status, catalog/model/prompt/output/usage digests, and receipt-key
  fingerprint fields. Rerun result: 0 critical / 0 high / 0 medium / 0 low.

Validation:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing -run 'TestEarningsEndpointIncludesProviderSettlementReceiptReasonCodes\|TestProvidersEndpointIncludesRedactedSettlementReceiptDiagnostics\|TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider\|TestSettlementReceiptDiagnosticsQueryShapeIsBounded' -count=1 -timeout 60s -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -run TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider -count=1 -timeout 30s -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -count=1 -timeout 180s` | PASS |
| `cd phase4-coordinator && go test ./... -count=1` | PASS |
| `cd phase5-gateway && go test ./internal/router -run 'TestModelsResponseIncludesTier1Disclosure\|TestTier1DisclosureMatchesSpecSection16' -count=1 -timeout 60s -v` | PASS |
| `cd phase5-gateway && go test ./internal/router -count=1 -timeout 120s` | PASS |
| `cd phase5-gateway && go test ./... -count=1` | PASS |
| `git diff --check` | PASS |
