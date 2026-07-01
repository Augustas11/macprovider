# SPEC-022 implementation deliverable 10

Status: non-streaming gateway buyer-debit finality now follows coordinator
receipt outcomes. Streaming receipt finality remains open because HTTP response
headers are committed before the coordinator can know the post-stream receipt
verdict; that path needs trailer or async finalization wiring.

## Result

D10 connects the coordinator's terminal receipt-verdict state to the gateway's
buyer money path for non-streaming chat completions:

- The coordinator now emits internal settlement outcome headers after it
  persists a settlement receipt verdict for receipt-capable provider attempts.
- The gateway consumes those internal headers before writing the buyer
  response and strips them from the buyer-visible response surface.
- Absent coordinator settlement headers keep the pre-existing legacy behavior.
- `verified` with `closed=true` finalizes buyer debit through the existing
  quota reservation settlement path.
- `quarantined` or `zero_settled` with `closed=true` refunds the buyer quota
  reservation and does not create a `usage_events` debit row.
- `pending`, malformed/unknown outcome, or an open `verified` verdict leaves
  the reservation active and does not create a `usage_events` debit row.
- Provider-selected error pass-through now obeys the same explicit settlement
  finality contract while preserving the old refund behavior when no internal
  settlement header is present.

## Acceptance movement

- **AC-022-8 / AC-022-13 / AC-022-15 / AC-022-33 / AC-022-63:** partial
  movement from blocked toward covered for the non-streaming gateway path.
  Buyer debit is no longer independently finalized merely because the
  coordinator returned a completed non-streaming response when a SPEC-022
  settlement outcome is present.
- **AC-022-39:** partial movement because provider-positive credit from D9 and
  buyer final debit now share the same persisted coordinator receipt verdict
  for non-streaming covered attempts.
- **AC-022-44 / AC-022-45:** unchanged; buyer-facing disclosure still needs to
  describe the verified-model settlement limit without exposing internal
  headers.

## Tests

Validated with:

```bash
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestSPEC022GatewaySettlementOutcomeControlsBuyerDebit|TestProviderAttributionHeadersEmitted|TestProviderPinningHeadersStripped'
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestRouteSnapshot|TestSettlement|TestHTTPForwardingStrips'
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestSettlementOutputDoesNotUseV04ReceiptTerminalTimestamp|TestRouteSnapshot|TestSettlement|TestHTTPForwardingStrips'
cd phase4-coordinator && go test -count=1 ./...
cd phase5-gateway && go test -count=1 ./...
```

## Remaining gap

The streaming gateway path still settles after response commit from observed
stream usage. SPEC-022 streaming finality must be carried through a trailer or
async settlement signal so the gateway can apply the same verified/refund/hold
decision after EOF without leaking internal state to buyers.
