# BUILD_SPEC_045_PHASE_3G_BUFFERED_SSE_FOUNDATION

Implement the first bounded SSE-compatible forwarding foundation for SPEC-045
local consumer endpoint mode after compressed non-streaming response handling
exists. This slice owns accepting `stream: true` chat-completions requests
through the existing admission, resource, credential, and ledger gates, then
relaying a complete bounded `text/event-stream` upstream response after terminal
stream validation.

This is a build slice, not a production-conformance declaration. Live
incremental flush, client-disconnect upstream cancellation, mutable
invalid-credential state, and fake/real gateway journeys remain later work.

## Target Result

Allowed, trusted-priced streaming chat-completions requests are no longer
rejected solely because `stream: true` is present. They reserve an open
streaming-response slot plus upstream worker/socket resources, request
`text/event-stream` from the upstream gateway, require an identity
`text/event-stream` response, validate a terminal `data: [DONE]` frame before
local success, settle ledger exposure from the last parseable stream usage
object before `[DONE]`, and return the bounded SSE bytes to the local client.

## Required Implementation Shape

1. Keep the existing admission order:
   - local auth, request validation, model allowlist, pricing revalidation,
     request cap, ledger preview/reservation, credential lookup, resolver, and
     upstream dispatch order must remain equivalent to non-streaming requests;
   - missing credentials must still reject before ledger mutation;
   - local budget/cap failures must still win over missing credentials.

2. Reserve streaming resources atomically:
   - accepted streaming upstream exchanges reserve one upstream worker task,
     one upstream socket/file-descriptor slot, and one open streaming-response
     slot;
   - streaming requests do not reserve non-streaming response-spool bytes;
   - saturated streaming slots fail locally as `503 local_endpoint_busy` before
     resolver, credential lookup, ledger mutation, or upstream forwarding;
   - release the streaming reservation on every terminal success/failure path.

3. Request and normalize SSE responses:
   - upstream streaming requests use implementation-owned
     `Accept: text/event-stream`;
   - successful local streaming responses must have `Content-Type:
     text/event-stream`, and the SSE success contract applies only to
     successful upstream statuses;
   - non-2xx upstream error responses for streaming requests are preserved
     through the existing R007 response-header allowlist instead of being
     reclassified as invalid SSE;
   - compressed, ambiguous, malformed, post-terminal, missing-terminal, or
     oversized successful SSE responses fail closed after dispatch as
     `502 local_upstream_unavailable` with `forwarded_upstream: true`;
   - strip upstream `Content-Length`, reject upstream `Content-Encoding`
     unless absent or exactly `identity`, and preserve only the existing
     allowlisted response headers.

4. Settle after terminal stream evidence:
   - parse complete SSE frames from the bounded upstream body;
   - require a terminal `data: [DONE]` event before local success;
   - settle from the most recent parseable JSON `usage` object before `[DONE]`
     when usage is priceable;
   - otherwise settle to the admission estimate;
   - on terminal validation failure after reservation, settle to the admission
     estimate before returning the local upstream failure.

## Acceptance Tests

- trusted budgeted `stream: true` requests forward and settle from SSE usage
  only after `[DONE]`;
- local streaming success returns `text/event-stream`, preserves event order,
  strips upstream `Content-Length`, and reports a local decoded length;
- no-budget ledger mode records and settles streaming audit rows;
- streaming slot saturation rejects before resolver, credential lookup, ledger
  mutation, or upstream forwarding;
- missing `[DONE]`, compressed SSE, wrong content type, malformed event data,
  or post-`[DONE]` events fail as forwarded upstream failures and settle to the
  admission estimate;
- non-2xx upstream JSON error responses for streaming requests preserve the
  upstream status/body/allowlisted headers and settle to the admission estimate;
- post-dispatch streaming ledger-write failures keep
  `forwarded_upstream: true`.

## Follow-Up Slices

- live incremental SSE flushing, event-line/event-frame limits, idle stream
  deadlines, disconnect cancellation, and conservative disconnect settlement;
- mutable credential state that marks invalid or expired upstream buyer
  credentials while preserving the initiating client's upstream auth failure;
- fake-gateway and real-gateway conformance journeys.

## Non-Goals

- Do not implement live incremental local flushing in this slice.
- Do not implement request compression or compressed SSE decoding.
- Do not add new OpenAI-compatible endpoint paths.
- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
- Do not claim SPEC-045 production readiness from this slice alone.
