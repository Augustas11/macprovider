**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

The r3 security blocker is closed for commit `a27d129`.

`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:488-492` no longer emits a `data:` JSON event for `macprovider_tool_call_open`. The only remaining emission is byte-exact SSE comment syntax: `writer.writeRawSSE(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")`. `writeRawSSE` forwards that payload without wrapping it in `data:` (`HTTPServer.swift:1055-1058`, `:1100-1104`), so the previous buyer-visible JSON event shape is gone.

The coordinator parser now matches the comment form only by prefix (`": macprovider_tool_call_open unix_ms="`) and parses the suffix as an integer Unix millisecond timestamp (`phase4-coordinator/internal/buyer/streaming_timing.go:108-118`). The direct coordinator use is metrics-only: `server.go:2567-2570` stores the parsed timestamp as `providerToolCallOpen`, and `server.go:2631-2637` passes it only into `streamingTiming.observeFromHeadersAndProviderOpen(...)`.

Money-path posture is unchanged. The parsed timestamp does not feed billing, settlement, final-close, downgrade, sticky-route, or fault classification. Settlement still gates on the existing `FaultBreakerQualifying` paths (`server.go:2595-2617`, `:2649-2658`, `:2680-2727`), and the billing formula still returns immediately for breaker-qualified rows before provider-positive credit calculation (`phase4-coordinator/internal/billing/formula.go:112-114`).

Buyer SDK compatibility is also restored for the r3 security concern. The pinned EventSource parser used by the local Vercel AI SDK stack treats `:` lines as comments and returns without dispatching a data event (`test/integration/streaming_terminal_error/node_modules/eventsource-parser/dist/index.js:105-110`). This avoids the previous `@ai-sdk/openai-compatible` schema path that required `choices` for chunk data (`test/integration/streaming_terminal_error/node_modules/@ai-sdk/openai-compatible/dist/index.mjs:925-961`).

Security answer: the comment does not leak settlement-relevant timing a malicious buyer can use to game payout or breaker behavior. A raw SSE client can see comment bytes on the wire, but the value is provider-originated, SDK-ignored, and consumed by the coordinator only for `/metrics/streaming` observability. It is not accepted back from the buyer as settlement input.

Validation run:

- `cd phase4-coordinator && go test -count=1 ./internal/buyer` - pass (`ok`, 1.947s).
- `rg` over `phase3-binary/Sources` and `phase4-coordinator/internal/buyer` found exactly one `macprovider_tool_call_open` emission site, the raw comment write in `HTTPServer.swift:491`, and no remaining `writer.writeSSEJSON({...macprovider_tool_call_open...})` source emission.

## Fresh findings

None.

## Verdict justification

READY TO MERGE for the security lane. The r3 issue was an in-band JSON `data:` event that both escaped the telemetry boundary and could perturb downstream parsers. `a27d129` replaces that with an EventSource comment, keeps coordinator timing observability, and leaves settlement/fault logic untouched. No critical, high, or medium security finding remains in the changed surface.
