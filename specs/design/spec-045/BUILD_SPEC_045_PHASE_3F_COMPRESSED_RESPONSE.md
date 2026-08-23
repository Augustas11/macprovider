# BUILD_SPEC_045_PHASE_3F_COMPRESSED_RESPONSE

Implement compressed non-streaming upstream response normalization for the
SPEC-045 local consumer endpoint after aggregate resource admission exists.
This slice owns gzip response decoding before local delivery and before budget
settlement.

This is a build slice, not a production-conformance declaration. Streaming
forwarding, mutable invalid-credential state, and fake/real gateway journeys
remain later work.

## Target Result

For non-streaming chargeable upstream responses, the local endpoint accepts an
upstream `Content-Encoding: gzip` response, decodes it under the existing local
response body cap, strips compression metadata, settles ledger usage from the
decoded JSON body when possible, and returns an identity response to the local
client. Unsupported, ambiguous, malformed, or oversized response codings fail
closed after upstream dispatch as `502 local_upstream_unavailable` with
`forwarded_upstream: true`.

## Required Implementation Shape

1. Normalize upstream responses before settlement and local delivery:
   - parse all upstream `Content-Encoding` header values as comma-separated
     tokens;
   - no content coding and explicit `identity`-only coding are identity;
   - exactly one `gzip` coding is supported;
   - blank, duplicated, stacked, mixed, or unsupported codings are rejected.

2. Decode gzip responses with bounded output:
   - use a real gzip decoder, not ad hoc header stripping;
   - cap decoded bytes at `ConsumeLocalLimits.bodyBytes`;
   - reject malformed gzip data, trailing compressed junk, zlib failures, and
     decoded output larger than the cap as dispatched upstream failures.
   - reserve aggregate non-streaming response-spool capacity for the
     compression-capable peak where encoded and decoded bodies can coexist.

3. Preserve local response safety:
   - remove upstream `Content-Encoding` and upstream `Content-Length` from the
     normalized response;
   - let the existing local response writer set the decoded `Content-Length`;
   - continue to forward only the existing allowed upstream response headers;
   - do not add streaming response support in this slice.

4. Settle from decoded usage:
   - compute actual usage settlement from the decoded upstream JSON body when
     usage is parseable;
   - retain the existing admission-estimate fallback when decoded usage is
     absent, unparsable, or out of settlement bounds;
   - on compressed response normalization failure after ledger reservation,
     settle to the admission estimate before returning the local upstream
     failure.

## Acceptance Tests

- gzip upstream response bodies decode to identity before local success;
- local success strips `Content-Encoding`, rewrites `Content-Length` to the
  decoded byte count, and preserves allowed response headers;
- ledger settlement uses decoded upstream usage when present;
- malformed gzip upstream responses fail as `502 local_upstream_unavailable`
  with `forwarded_upstream: true` and settle to the admission estimate;
- gzip responses whose decoded body exceeds `ConsumeLocalLimits.bodyBytes`
  fail before local success and settle to the admission estimate;
- unsupported or ambiguous response codings remain fail-closed.

## Follow-Up Slices

- streaming/SSE forwarding, event bounds, disconnect handling, and SSE
  settlement evidence after `[DONE]`;
- mutable credential state that marks invalid or expired upstream buyer
  credentials while preserving the initiating client's upstream auth failure;
- fake-gateway and real-gateway conformance journeys.

## Non-Goals

- Do not implement request compression; local request `Content-Encoding`
  remains rejected.
- Do not implement Brotli, deflate, zstd, stacked encodings, or transparent
  streaming decompression.
- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
- Do not claim SPEC-045 production readiness from this slice alone.
