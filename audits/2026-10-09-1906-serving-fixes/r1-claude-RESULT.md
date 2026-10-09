# Round 1, Claude Opus adversarial review (all three lanes)

VERDICT: 0C/0H/2M (NEW only). Recommendation: REVISE.

## Verified
- The coordinator buyer/pool/ws and gateway router Go tests pass, and the slot, queue, capacity and pool tests pass under `-race`. Spec governance and the index pass.
- The queue-lock then pool-lock order cannot deadlock. A `reserveHead` removal followed by `leave` is a harmless no-op. A queue-full refusal followed by `dropConsumedForwardedSlot` returns the seat exactly once.
- The capacity 429 is never billed. The gateway refunds it only when the coordinator marks it no-prior-dispatch.
- The relay's `endedRequestIDs` stays consistent, with identity checks on both add and remove.
- The coordinator ceiling (default 8) still clamps 32-slot advertisements.
- The verifier only requires receipt `ttft_ms` >= 0.

## MEDIUM 1 (NEW): ragged prefill offset spread
Ragged prefill groups ignore the spread between row offsets. Keys pad to the largest offset, so short rows pay long-row attention cost and memory. With the 2048 budget and 4 rows, a single long row inflates the whole forward. A failed ragged forward fails every row in it, where the equal-offset path falls back to serial. Lab runs used only uniform 1536-token prompts. Fix: cap the offset spread within a group (relative or absolute key cap), and run one mixed-length bench before the CLI cut.

## MEDIUM 2 (NEW): coordinator ahead of gateway overcharges capacity sheds
The main-branch gateway has no 429 `no_provider_available` branch. It settles the prompt estimate and returns 502. Fix: gateway first or both together, or have the coordinator emit 429 only when the gateway signals support.

## LOW (NEW)
1. A genuinely lower provider seat report can be ignored indefinitely while `awaitingReadyOccupancy` is set (`provider.go:2857`).
2. The capacity 429 message carries `provider.ModelID` instead of the buyer's requested model (`server.go:3909`).
3. `capacityRefused` is never reset, so a later unrelated failure is labelled as a capacity 429 (`server.go:2996`, `forward_state.go:157-162`).
4. The v2 calibration record drops `ttft_regression_factor`, which a rolled-back CLI requires to decode.
5. The longer coordinator hold on queue-full also inflates `request_log.retried`.

## INFO
- The receipt TTFT semantics for non-streaming responses differ from the SPEC-015 table. The serial path already behaves the same way (pre-existing drift).
- The waiter cap `max(4, slots_total)` trusts the provider-reported total. That is bounded by the ceiling.
