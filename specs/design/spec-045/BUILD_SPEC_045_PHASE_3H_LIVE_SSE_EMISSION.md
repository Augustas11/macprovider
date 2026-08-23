# BUILD_SPEC_045_PHASE_3H_LIVE_SSE_EMISSION

Implement the next streaming slice after the Phase 3G buffered SSE foundation.
This slice owns local live SSE emission semantics, SSE event-line and event-frame
bounds, upstream idle-read deadline refresh, and conservative local-disconnect
settlement. It does not replace the bounded upstream response parser with a
fully incremental upstream transport API.

## Target Result

Successful trusted streaming chat-completions requests still pass the existing
admission, resource, credential, forwarding, validation, and ledger gates, but
the local response is emitted as an SSE stream: no `Content-Length`, response
headers are flushed before event bodies, and each validated SSE event is written
as its own flushed body part. Oversized SSE lines or events fail before local
success. If the local client disconnects while a streaming upstream exchange is
pending, local delivery is skipped, upstream work is abandoned when the current
transport can observe completion, and any ledger reservation settles
conservatively to the admission estimate.

## Required Implementation Shape

1. Preserve Phase 3G admission and validation:
   - do not weaken local auth, model allowlist, pricing, ledger, credential,
     resolver, resource, content-type, content-encoding, terminal `[DONE]`, or
     post-`[DONE]` validation;
   - non-2xx streaming upstream responses remain preserved as upstream error
     responses, not reclassified as malformed SSE;
   - streaming validation failures still return local upstream failures before
     any local success response is started.

2. Add bounded SSE parser metadata:
   - enforce a maximum SSE line byte count;
   - enforce a maximum SSE event frame byte count across all lines in one
     event;
   - enforce a maximum emitted event-block count so tiny-event floods cannot
     create unbounded flush churn within the response body byte cap;
   - keep terminal `[DONE]`, duplicate-DONE, missing-DONE, post-DONE, and JSON
     event-data validation unchanged;
   - return validated event blocks for local emission without reserializing
     JSON payloads.

3. Emit successful SSE responses as live local streams:
   - strip upstream `Content-Length` and `Content-Encoding`;
   - do not synthesize `Content-Length` for successful local SSE;
   - flush the response head before event bodies;
   - write each validated SSE event block as a separate flushed response body;
   - close the local connection only after the terminal event and response end.

4. Refresh upstream idle read deadline:
   - treat upstream receive progress as activity;
   - refresh the read deadline after every non-empty upstream receive chunk so
     slow but progressing streams are not failed by a single absolute read
     timer.

5. Handle local disconnect conservatively:
   - if the local channel closes while a streaming upstream exchange is pending,
     mark the request disconnected;
   - do not write a late local success or local error response to the closed
     channel;
   - for ledger-backed streaming reservations, settle to the admission estimate
     rather than trusting partial or late stream usage evidence;
   - if that terminal ledger append fails after disconnect, treat the ledger as
     unavailable so subsequent ledger-backed admission fails closed rather than
     continuing with an apparently live reservation;
   - release all upstream worker/socket/streaming-slot reservations and active
     request accounting after the upstream future reaches a terminal state.

## Acceptance Tests

- successful streaming responses omit `Content-Length`, preserve event order,
  and expose multiple body chunks matching validated SSE event blocks;
- oversized SSE event lines fail as forwarded upstream failures and settle to
  the admission estimate;
- oversized SSE event frames fail as forwarded upstream failures and settle to
  the admission estimate;
- too many tiny SSE event blocks fail as forwarded upstream failures and settle
  to the admission estimate;
- local disconnect during a pending streaming upstream exchange causes
  conservative estimate settlement and releases streaming resources without
  emitting a late local response.
- local disconnect plus terminal ledger append failure marks the ledger
  unavailable, releases streaming resources, suppresses late local output, and
  causes the next ledger-backed request to fail closed.

## Follow-Up Slices

- fully incremental upstream socket-to-local relay with upstream cancellation
  handles;
- mutable credential state that marks invalid or expired upstream buyer
  credentials while preserving the initiating client's upstream auth failure;
- fake-gateway and real-gateway conformance journeys.

## Non-Goals

- Do not implement request compression or compressed SSE decoding.
- Do not add new OpenAI-compatible endpoint paths.
- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
- Do not claim SPEC-045 production readiness from this slice alone.
