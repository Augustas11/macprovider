# BUILD_SPEC_045_PHASE_3I_INCREMENTAL_SSE_RELAY

Implement the next streaming slice after Phase 3H live SSE emission. This slice
owns an incremental upstream socket-to-local SSE relay for successful streaming
chat-completions responses and explicit upstream cancellation handles when the
local client disconnects. It keeps the existing buffered path for
non-streaming responses and for non-2xx upstream streaming errors.

## Target Result

Successful trusted streaming chat-completions requests are relayed from the
upstream socket to the local loopback client as each complete, validated SSE
event becomes available. The local server no longer waits for the full upstream
SSE body before sending the local response head or body events. It still
validates event framing, line/frame/event-count bounds, UTF-8, terminal
`[DONE]`, post-`[DONE]` bytes, and usage extraction. If the local client
disconnects while the upstream streaming exchange is live, the upstream
transport is cancelled and ledger-backed reservations settle conservatively.

## Required Implementation Shape

1. Preserve previous gates:
   - keep Phase 3H local auth, admission, trusted pricing, ledger, resource,
     credential, resolver, response-header allowlist, SSE bounds, and
     settlement behavior;
   - non-streaming responses continue through the bounded buffered parser;
   - non-2xx streaming upstream responses continue to be buffered and
     preserved as upstream error responses under R007.

2. Add a streaming upstream response path:
   - expose a streaming method on the upstream client abstraction so the local
     handler can receive a validated successful SSE response head before the
     full body is complete;
   - the pinned upstream client must incrementally parse the HTTP response
     header, then incrementally decode identity, fixed-length, close-delimited,
     or single-final chunked response bodies;
   - successful 2xx `text/event-stream` bodies must be parsed event-by-event
     without buffering the full body for local delivery;
   - decoded body bytes remain bounded by the existing response body cap, and
     event-line, event-frame, and event-block caps remain enforced.

3. Emit local successful SSE incrementally:
   - strip upstream `Content-Length` and `Content-Encoding`;
   - do not synthesize local `Content-Length`;
   - flush the response head once a successful event-stream upstream head is
     validated;
   - flush each validated complete SSE event block exactly once and in order;
   - write the local response end only after terminal `[DONE]` and upstream EOF
     or declared body completion.

4. Cancellation and disconnect:
   - the upstream streaming call must return a cancellation handle or otherwise
     cancel the pinned upstream connection when local channel inactivity is
     observed while the upstream stream is pending;
   - after local disconnect, suppress any late local head, event, end, or error
     writes;
   - ledger-backed streaming reservations settle to the admission estimate on
     disconnect or late streaming validation failure after local success.

5. Failure shape:
   - failures before local streaming success starts still return
     `local_upstream_unavailable` with `forwarded_upstream=true` when the
     upstream request was dispatched;
   - failures after local streaming success starts close the local response
     without attempting to write a second local error envelope;
   - terminal ledger append failures after disconnect leave the ledger in its
     existing fail-closed unavailable state.

## Acceptance Tests

- successful chunked SSE emits the local head before the upstream terminal
  chunk and emits body chunks as complete event blocks arrive;
- successful fixed-length SSE emits event blocks incrementally and omits local
  `Content-Length`;
- malformed successful SSE before the local head is emitted still returns a
  local upstream failure;
- malformed successful SSE after the local head is emitted closes the stream
  and settles to the admission estimate;
- local disconnect during an in-flight streaming upstream response invokes the
  upstream cancellation handle, suppresses late writes, settles the estimate,
  and releases resource counters.

## Non-Goals

- Do not implement mutable invalid-or-expired upstream credential state.
- Do not implement fake-gateway or real-gateway conformance journeys.
- Do not add new local endpoint paths.
- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
