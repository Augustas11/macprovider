# SPEC-022 implementation deliverable 10

Status: closed non-streaming coordinator receipt verdicts now drive gateway
buyer debit/refund decisions. Non-streaming pending/open verdict lifecycle and
streaming receipt finality remain open because they need async finalization or
trailer wiring after the first response.

## Result

D10 connects the coordinator's closed receipt-verdict state to the gateway's
buyer money path for non-streaming chat completions:

- The coordinator now emits gateway-internal settlement outcome headers after
  it persists a settlement receipt verdict for receipt-capable provider
  attempts. Direct coordinator buyer calls do not receive this internal tuple.
- The gateway consumes those internal headers before writing the buyer response
  and strips them from the buyer-visible response surface.
- SPEC-022 settlement defaults remain observe-mode. Enforce-mode money behavior
  is activated only by explicit coordinator settlement configuration.
- Absent coordinator settlement headers keep the pre-existing legacy behavior.
- Observe-mode settlement headers keep the pre-existing legacy buyer behavior.
- Enforce-mode `verified` with `receipt_result=valid` and `closed=true`
  finalizes buyer debit through the existing quota reservation settlement path.
- Enforce-mode `quarantined` with `receipt_result=invalid|inconclusive` and
  `closed=true`, or `zero_settled` with `receipt_result=valid` and
  `closed=true`, refunds the buyer quota reservation and does not create a
  `usage_events` debit row.
- Enforce-mode `pending`, malformed/unknown outcome, incomplete tuple, or an
  open `verified` verdict leaves the reservation active and does not create a
  `usage_events` debit row. This is a fail-closed interim state, not full
  lifecycle closure.
- Provider-selected error pass-through now obeys the same explicit settlement
  finality contract while preserving the old refund behavior when no internal
  settlement header is present.

## Acceptance movement

- **AC-022-8 / AC-022-13 / AC-022-15 / AC-022-33 / AC-022-63:** partial
  movement from blocked toward covered for closed non-streaming verdicts.
  Buyer debit is no longer independently finalized merely because the
  coordinator returned a completed non-streaming response when a complete
  enforce-mode SPEC-022 settlement tuple is present.
- **AC-022-39:** partial movement because provider-positive credit from D9 and
  buyer final debit now share the same persisted coordinator receipt verdict
  for closed non-streaming covered attempts. Coordinator-verified /
  gateway-debit-failed reconciliation remains open.
- **AC-022-44 / AC-022-45:** unchanged; buyer-facing disclosure still needs to
  describe the verified-model settlement limit without exposing internal
  headers.

## Tests

Validated with:

```bash
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestSPEC022GatewaySettlementOutcomeControlsBuyerDebit|TestProviderAttributionHeadersEmitted|TestProviderPinningHeadersStripped'
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestSPEC022GatewayProviderErrorFinalityHoldsBuyerDebit|TestSPEC022GatewaySettlementOutcomeControlsBuyerDebit'
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestVerifiedModelSettlementModeDefaultsObserve'
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestWSTunneledNonStreamingEmitsInternalSettlementHeaders|TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts|TestSettlementOutputDoesNotUseV04ReceiptTerminalTimestamp'
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestRouteSnapshot|TestSettlement|TestHTTPForwardingStrips'
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestSettlementOutputDoesNotUseV04ReceiptTerminalTimestamp|TestRouteSnapshot|TestSettlement|TestHTTPForwardingStrips'
cd phase4-coordinator && go test -count=1 ./...
cd phase5-gateway && go test -count=1 ./...
```

## Remaining gap

The gateway still needs a durable finalization loop for held enforce-mode
reservations. Pending/open non-streaming verdicts currently fail closed by
keeping the reservation active without a debit row, but there is no coordinator
callback or gateway reconciler that later turns the hold into verified debit or
terminal refund at the SPEC-022 pending deadline.

The streaming gateway path also still settles after response commit from
observed stream usage. SPEC-022 streaming finality must be carried through a
trailer or async settlement signal so the gateway can apply the same
verified/refund/hold decision after EOF without leaking internal state to
buyers.
