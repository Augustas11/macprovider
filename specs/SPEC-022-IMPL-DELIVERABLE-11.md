# SPEC-022 implementation deliverable 11

Status: streaming coordinator receipt verdicts now drive gateway buyer
debit/refund/hold decisions through internal HTTP trailers. Buyer-visible SSE
remains OpenAI-compatible; no settlement event frames or internal trailer
declarations are exposed to buyers.

## Result

D11 extends the D10 non-streaming money-path gate to streaming chat
completions:

- The coordinator declares gateway-internal settlement finality trailers before
  streaming dispatch when a route snapshot covers the attempt and the request is
  internally scoped to a gateway account.
- After the streaming attempt reaches a terminal state and the coordinator logs
  the attempt, it writes the same settlement outcome tuple used by D10 into
  HTTP trailers: outcome, receipt result, reason, closed flag, settlement mode,
  policy version, and pending deadline when present.
- Direct coordinator buyer calls still receive plain OpenAI-compatible SSE and
  do not receive the internal settlement finality tuple.
- The gateway strips upstream `Trailer` declarations alongside
  `X-MacProvider-*` headers so internal settlement trailer names cannot leak to
  buyers.
- After streaming EOF, the gateway reads coordinator finality from
  `resp.Trailer` and applies the same enforce-mode rules as D10:
  verified/valid/closed debits, quarantined or zero-settled closed verdicts
  refund, and pending/open/malformed/missing finality holds the reservation
  without creating a usage debit row.
- Streaming holds with a coordinator pending deadline clamp the active quota
  reservation's durable `expires_at` to that deadline, so the existing
  reservation reaper releases the hold at the SPEC-022 recovery boundary.
- Streaming holds without a trustworthy future coordinator deadline refund the
  buyer reservation immediately instead of preserving a 24h stale hold.
- Legacy streams with no settlement finality trailer declaration keep the
  existing local observed-usage settlement behavior.
- Declared-but-missing settlement trailers fail closed by holding the
  reservation instead of falling back to local debit.
- Streaming non-OK coordinator responses now use the same explicit finality
  parser as D10 non-streaming responses before writing the buyer error, and
  pending/open streaming error verdicts use the same bounded hold policy as
  committed streaming responses.

## Acceptance movement

- **AC-022-12 / AC-022-13 / AC-022-15:** streaming buyer debit is now tied to
  coordinator receipt finality for covered enforce-mode attempts; unverifiable
  or incomplete finality does not create a buyer debit row.
- **AC-022-14:** streaming finality is internal to the gateway/coordinator
  transport and does not require non-standard SSE events that would break
  OpenAI-compatible clients.
- **R-5:** normal `[DONE]`, provider disconnect, timeout, malformed stream, and
  buyer cancel paths now flow through the same finality-aware settlement helper
  when the coordinator declared streaming settlement finality.
- **AC-022-39:** buyer debit and provider-positive settlement now compose from
  the coordinator's persisted receipt verdict for covered streaming attempts.

## Tests

Validated with:

```bash
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestStreamingSettlementOutputPersistsOpenAICompatibleSSE'
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestStreamingReceiptHeaderStripped|TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit|TestSPEC022GatewayStreamingNonOKFinalityBoundsHold'
cd phase5-gateway && go test -count=1 ./internal/storage/sqlite -run 'TestClampReservationExpiryBoundsActiveHold|TestExpiredReservationsReclaimedAfter24h|TestReservationErrorBranches'
cd phase4-coordinator && go test -count=1 ./...
cd phase5-gateway && go test -count=1 ./...
```

## Remaining gap

Held enforce-mode reservations are now bounded by the coordinator pending
deadline, but gateway-side async reconciliation is still not a positive-credit
path: if the coordinator later verifies a receipt before the deadline, the
gateway has no polling callback that converts the bounded hold into a verified
buyer debit. A later deliverable should add explicit coordinator/gateway
reconciliation for pending holds; until then, bounded expiry prevents stale
buyer quota holds and preserves the rule that unverified prefixes are not
charged.
