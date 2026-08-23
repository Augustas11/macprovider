# BUILD_SPEC_045_PHASE_3E_RESOURCE_ACCOUNTING

Implement aggregate local endpoint resource admission for SPEC-045 after the
first non-streaming upstream forwarding path exists. This slice owns bounded
accounting primitives for upstream response spooling, upstream worker tasks,
upstream socket/file-descriptor reservations, and streaming-response slots.

This is a build slice, not a production-conformance declaration. Streaming
forwarding, compressed decode-to-identity, mutable invalid-credential state,
and fake/real gateway journeys remain later work.

## Target Result

Chargeable local endpoint requests that would exceed aggregate local endpoint
resource capacity fail locally as `local_endpoint_busy` before upstream
resolution, upstream credential use, durable ledger reservation, or upstream
forwarding. Accepted non-streaming upstream exchanges hold conservative
resource reservations until the upstream outcome is complete and the local
request can release active capacity.

## Required Implementation Shape

1. Extend the existing local endpoint request counter instead of adding a
   second resource subsystem:
   - keep the existing incomplete-connection, active-request, and buffered
     request-body limits;
   - add aggregate reservations for non-streaming response-spool bytes,
     upstream worker tasks, upstream socket/file-descriptor slots, and open
     streaming-response slots;
   - make each aggregate reservation and release lock-protected and monotonic
     under underflow.

2. Gate upstream non-streaming dispatch with one atomic reservation:
   - reserve one upstream worker task;
   - reserve one upstream socket/file-descriptor slot;
   - reserve the conservative non-streaming response-spool budget before
     upstream resolution;
   - reject as `503 local_endpoint_busy` with `forwarded_upstream: false` if
     any required aggregate resource is saturated;
   - perform this rejection before credential lookup, ledger mutation, DNS
     resolution, or upstream forwarding.

3. Hold and release resources deterministically:
   - hold the reservation across upstream endpoint resolution, ledger
     reservation, upstream forwarding, settlement, and local terminal response
     preparation;
   - release on resolver failure, local disconnect before forwarding, local
     admission rejection after resolver success, pre-dispatch upstream failure,
     post-dispatch upstream failure, and successful upstream response handling;
   - keep active-request capacity tied to the same pending upstream lifecycle
     established in Phase 3D.

4. Expose bounded diagnostic counts in local status:
   - report current buffered request-body bytes;
   - report current non-streaming response-spool bytes;
   - report current upstream worker-task count;
   - report current upstream socket/file-descriptor count;
   - report current open streaming-response count.

5. Add streaming-response slot primitives without enabling streaming
   forwarding:
   - `stream: true` remains fail-closed before ledger append in this slice;
   - the streaming slot counter exists for the later streaming implementation
     and must reject over-capacity reservations in unit coverage.

## Acceptance Tests

- saturated upstream worker-task capacity rejects a chargeable request as
  `local_endpoint_busy` before resolver, credential lookup, ledger mutation, or
  forwarding;
- saturated upstream socket/file-descriptor capacity rejects before resolver
  and forwarding;
- saturated non-streaming response-spool capacity rejects before resolver and
  forwarding;
- an accepted upstream exchange holds aggregate resources while pending and
  releases them after success or failure;
- resource status counts reflect held and released reservations;
- streaming-response slot primitives reject saturation even though streaming
  forwarding remains disabled.

## Follow-Up Slices

- streaming/SSE forwarding, event bounds, disconnect handling, and SSE
  settlement evidence after `[DONE]`;
- compressed non-streaming decode/cap/identity forwarding;
- mutable credential state that marks invalid or expired upstream buyer
  credentials while preserving the initiating client's upstream auth failure;
- fake-gateway and real-gateway conformance journeys.

## Non-Goals

- Do not add OS-wide process file-descriptor scanning.
- Do not implement streaming/SSE forwarding.
- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
- Do not claim SPEC-045 production readiness from this slice alone.
