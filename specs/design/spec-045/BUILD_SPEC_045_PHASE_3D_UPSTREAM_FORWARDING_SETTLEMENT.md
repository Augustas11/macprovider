# BUILD_SPEC_045_PHASE_3D_UPSTREAM_FORWARDING_SETTLEMENT

Implement the first chargeable upstream forwarding path for SPEC-045 after
trusted local pricing admission exists. This slice owns non-streaming
`POST /v1/chat/completions` forwarding, pinned upstream origin use, durable
reservation-to-terminal settlement, and failure provenance for the buffered
non-streaming path.

This is a build slice, not a production-conformance declaration. The remaining
SPEC-045 transport conformance work is intentionally left to later slices.

## Target Result

Allowed, trusted-priced, non-streaming chat-completion requests are forwarded to
the configured upstream gateway only after local authentication, request
validation, model admission, local exposure admission, credential presence, and
durable ledger reservation have succeeded. Terminal upstream outcomes settle,
hold, or stop future chargeable admission deterministically before the local
client receives a terminal response.

## Required Implementation Shape

1. Forward non-streaming chat completions:
   - keep `stream: true` fail-closed before ledger append in this slice;
   - forward the original decoded JSON entity body bytes without
     reserialization;
   - construct upstream request headers from implementation-owned metadata:
     `Authorization`, `Content-Type`, `Accept`, `Accept-Encoding: identity`,
     `Connection: close`, and `Content-Length`;
   - never forward arbitrary local client headers.

2. Pin upstream dispatch to validated global endpoints:
   - normalize the upstream as an HTTPS origin only;
   - reject userinfo, path, query, fragment, and non-global resolved addresses;
   - re-resolve and revalidate before each upstream connection;
   - connect to a validated numeric address while preserving the original host
     for TLS SNI and hostname verification;
   - send the upstream credential only after the connection is ready.

3. Bound the non-streaming upstream exchange:
   - enforce upstream response header byte and count caps;
   - enforce the existing decoded/body cap on the buffered upstream response;
   - reject ambiguous or unsupported upstream response framing;
   - for `Content-Length` and chunked responses, return only after the complete
     body has arrived;
   - for close-delimited responses, return only after EOF;
   - use explicit connect, send, and read deadlines so an upstream stall cannot
     pin local active-request capacity or ledger state indefinitely.

4. Preserve failure provenance:
   - pre-ready or pre-send failures are `503 local_upstream_unavailable` with
     `forwarded_upstream: false`;
   - failures after request bytes are accepted by the upstream transport are
     `502 local_upstream_unavailable` with `forwarded_upstream: true`;
   - pre-dispatch failures settle the reservation to zero;
   - post-dispatch failures hold the reservation for recovery.

5. Settle durable ledger rows before terminal response:
   - priced budgeted requests reserve before forwarding;
   - explicit `--no-budget --ledger` requests reserve and settle audit rows;
   - missing upstream credentials never mutate the ledger;
   - local cap and budget exhaustion win over missing credentials;
   - trusted non-streaming usage settles to actual usage when parseable and
     priceable;
   - missing, malformed, or unpriceable trusted usage settles to the admission
     estimate;
   - actual usage above the reservation records `estimate_exceeded`, marks the
     process pricing trust state `estimate_exceeded`, and stops later
     chargeable admission.

6. Preserve only safe upstream response metadata:
   - allowlist response headers instead of denylisting;
   - strip redirect `Location`, cookies, hop-by-hop headers, and arbitrary
     upstream metadata;
   - reject non-identity compressed non-streaming responses before local
     success in this slice, after any ledger reservation has reached a terminal
     state.

7. Reject unsafe credential material:
   - credentials loaded from files or environment must be non-empty after outer
     ASCII whitespace trimming;
   - embedded HTTP control characters, spaces, DEL, CR, LF, and NUL are invalid
     credential material and must not reach raw upstream header construction.

## Acceptance Tests

- missing credentials reject before any reservation on otherwise admissible
  priced requests;
- exhausted budgets and per-request caps are reported before missing
  credentials and do not mutate the ledger;
- dispatched transport failures hold reservations and set
  `forwarded_upstream: true`;
- pre-dispatch failures settle reservations to zero and set
  `forwarded_upstream: false`;
- compressed non-streaming upstream responses fail before local success while
  settling the reservation to the admission estimate;
- trusted non-streaming usage settles to actual usage before response;
- missing or unpriceable usage settles to the admission estimate;
- explicit `--no-budget --ledger` records and settles forwarded requests;
- `estimate_exceeded` stops later chargeable admission;
- streaming requests remain fail-closed before ledger append for this slice;
- credentials containing embedded HTTP control characters are rejected;
- response framing does not treat close-delimited bodies as complete before EOF.

## Follow-Up Slices

The following SPEC-045 requirements remain mandatory before production
promotion, but are intentionally outside Phase 3D:

- streaming/SSE forwarding, event bounds, disconnect handling, and SSE
  settlement evidence after `[DONE]`;
- bounded aggregate non-streaming response-spool bytes, open streaming response
  count, upstream worker-task count, and local endpoint socket/file-descriptor
  accounting;
- compressed non-streaming decode/cap/identity forwarding;
- mutable credential state that marks invalid or expired upstream buyer
  credentials while preserving the initiating client's upstream auth failure;
- fake-gateway and real-gateway conformance journeys.

## Non-Goals

- Do not change gateway billing, coordinator settlement, provider payout, or
  receipt semantics.
- Do not implement new OpenAI-compatible endpoint paths.
- Do not claim SPEC-045 production readiness from this slice alone.
