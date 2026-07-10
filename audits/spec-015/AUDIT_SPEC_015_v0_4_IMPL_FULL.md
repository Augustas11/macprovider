# AUDIT_SPEC_015_v0_4_IMPL_FULL

Status: closed for 3-lane Codex audit.

Scope: full SPEC-015 v0.4.2 settlement-capable receipt implementation,
covering Steps 1 through 8 of
`BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.

Audit lanes:

| Lane | Status | Critical | High | Medium | Low |
|---|---:|---:|---:|---:|---:|
| Codex code | APPROVE | 0 | 0 | 0 | 0 |
| Codex security | APPROVE | 0 | 0 | 0 | 0 |
| Codex architect | APPROVE | 0 | 0 | 0 | 0 |

Claude adversarial and product-design lanes are deferred until after this
Codex full-implementation pass, per operator instruction.

Initial Codex audit findings:

| Lane | Initial result | Closure |
|---|---|---|
| Code | High: non-normal runtime receipts missing; Medium: standalone verifier accepted overlong `pending_deadline_seconds`. Post-fix re-audit also found timestamp-authority/verifiability issues. | Closed. Runtime `buyer_cancel` receipts are emitted after completed streaming/non-streaming cancellation; phase7 caps pending deadlines at 900 seconds; coordinator ledger timestamp no longer comes from the signed receipt tuple, and live receipts align through the bounded terminal metadata carrier. |
| Security | High: v0.4 settlement receipt header leaked to buyer/gateway clients; Medium: stale settlement attempt state could survive failover. | Closed. Coordinator/gateway strip v0.4 buyer-visible receipt headers, and route snapshot/settlement attempt state resets before each dispatch attempt. |
| Architect | Critical: signed receipt terminal timestamp and coordinator ledger timestamp could not match safely; High: non-normal runtime receipt coverage was fixture-only; Medium: no live provider/coordinator/gateway E2E harness. | Closed. Ledger timestamp authority is no longer circular and live receipt timestamp alignment uses bounded terminal metadata outside the signed tuple; `buyer_cancel` runtime coverage landed. Live provider/coordinator/gateway v0.4 E2E coverage now verifies non-streaming and streaming settlement receipts. |

Current validation:

| Command | Result |
|---|---|
| `scripts/verify-spec015-v04-step8.sh` | PASS after final timestamp-carrier fix |
| `swift test --package-path phase3-binary` | PASS, 689 tests, 7 skipped |
| `swift test --package-path phase3-binary --filter InferenceRelayTests` | PASS |
| `cd phase4-coordinator && go test ./... -count=1` | PASS after final timestamp-carrier fix |
| `cd phase5-gateway && go test ./... -count=1` | PASS |
| `cd phase7-verify && go test ./... -count=1` | PASS |
| `go test ./internal/buyer -run 'TestRouteSnapshotsPersist\|TestSettlementOutputDoesNotUseV04ReceiptTerminalTimestamp\|TestSettlementOutputUsesBoundedTerminalTimestampHeader\|TestStreamingSettlementOutputPersists' -count=1` | PASS |
| `cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015V04SettlementReceiptCrossServiceVerifies` | PASS |
| `cd test/integration && go test -count=1 -timeout 10m ./...` | PASS |
| `bash test/integration/spec015/run_acceptance.sh` | PASS |
| `git diff --check` | PASS after final timestamp-carrier fix |
| `bash -n scripts/verify-spec015-v04-step8.sh` | PASS |

E2E gate:

- Implemented in `test/integration`: `TestSpec015V04SettlementReceiptCrossServiceVerifies`
  launches real gateway and coordinator binaries plus an in-process provider,
  loads a signed Tier 2 catalog, advertises a catalog-matching model hash over
  provider auth/state/heartbeat, and verifies signed v0.4 settlement receipts
  for both non-streaming and streaming chat requests.
- The gate asserts buyer-visible v0.4 receipt headers are stripped, coordinator
  settlement verdict rows are `receipt_result=valid`,
  `settlement_outcome=verified`, and money outcomes remain
  `no_money_movement_step5` / `excluded_until_spec022_verified`.

Known scope boundary:

- This implementation must not wire SPEC-022 enforce-mode buyer final debit,
  provider-positive settlement, payout readiness, gateway money movement, or
  payout idempotency. SPEC-015 v0.4.2 provides the signed, catalog-matching
  receipt prerequisite and exposes authorization evidence for SPEC-022.
