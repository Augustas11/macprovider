# BUILD_SPEC_045_PHASE_2_PROXY_SAFETY

Implement the local HTTP proxy safety layer for SPEC-045. This slice owns parser/resource bounds, endpoint matching, browser-origin denial, upstream origin validation, header construction, gateway response preservation, and local error mapping. It may reject chargeable chat completions until Phase 3 budget admission is present.

## Target result

The local endpoint accepts only the SPEC-045 v0.1 endpoint subset, rejects unsafe local input before forwarding, constructs upstream requests from implementation-owned metadata plus decoded body bytes, and preserves gateway responses to the initiating client without becoming a general reverse proxy.

## Required implementation shape

1. Implement the endpoint subset:
   - `GET /v1/models`;
   - `POST /v1/chat/completions`;
   - local `GET /v1/status`;
   - reject unsupported paths and methods without opportunistic forwarding;
   - reject unsupported `HEAD` with `405` and no response body;
   - keep `/v1/responses`, embeddings, images, audio, batch, fine-tune, and provider-control paths out of scope.

2. Enforce pre-auth HTTP bounds:
   - request-line byte cap;
   - request-target byte cap;
   - bounded percent-decoding/parser work;
   - header byte cap;
   - header count cap;
   - header-read deadline;
   - incomplete/pre-auth connection cap.

3. Enforce path/query/framing rules:
   - reject non-empty local query strings as `local_invalid_request`;
   - after auth and before endpoint matching, percent-decode the path with bounded work;
   - reject malformed encodings, encoded slash/backslash separators, raw or encoded dot segments, and non-exact normalized paths;
   - reject duplicate `Content-Length`, conflicting `Content-Length`, `Content-Length` plus `Transfer-Encoding`, unsupported transfer coding, stacked transfer coding, non-final transfer coding, and any non-single-final `chunked` coding.

4. Enforce local body and JSON rules:
   - reject local `Content-Encoding` other than absent or `identity`;
   - decode accepted local chunked requests before body-size checks, duplicate-key detection, budget estimation, and forwarding;
   - cap request body to the minimum of local hard ceiling 100 MiB, trusted upstream cap when known, and 1 MiB default when no trusted upstream cap is known;
   - parse bounded JSON with duplicate-object-key detection and bounded nesting/parser work;
   - forward decoded entity body bytes without JSON reserialization, field reordering, whitespace normalization, or semantic rewrite.

5. Enforce browser-origin denial:
   - no permissive CORS headers;
   - reject CORS preflight;
   - reject `Origin: null`;
   - reject multiple `Origin` headers and comma-containing `Origin`;
   - accept only exact bound loopback origin including scheme, actual bound host literal, and port;
   - reject browser fetch metadata that identifies cross-site or cross-origin callers.

6. Validate upstream gateway origin and transport:
   - default to MacProvider production gateway origin;
   - require `https`;
   - reject userinfo, path, query, and fragment;
   - normal platform TLS certificate and hostname verification;
   - reject expired, untrusted-root, invalid-chain, and hostname-mismatch certificates;
   - reject loopback, link-local, wildcard, multicast, private, carrier-grade NAT, documentation, reserved, IPv6 unique-local, IPv6 special-purpose, IPv4-mapped IPv6 with non-global embedded IPv4, and other non-global address ranges;
   - disable environment proxy, redirect, and connection-rewrite bypasses;
   - validate the connected peer address before sending upstream authorization.

7. Construct upstream requests safely:
   - strip local authorization, API-key, cookie, proxy, forwarded, hop-by-hop, browser metadata, and local content-type headers;
   - generate upstream authorization and content type from implementation state;
   - forward `Accept` only for `application/json` or `text/event-stream`;
   - do not retry non-idempotent chat completions after bytes have been sent upstream.

8. Preserve and bound upstream responses:
   - bound upstream response headers, decoded body bytes, JSON nesting/parser work, signature/body work, SSE event-line and event-frame sizes, idle read deadline, and aggregate response spool bytes;
   - preserve syntactically valid upstream responses and SPEC-006 errors to the initiating local client;
   - strip `Location` from upstream redirects and never follow redirects automatically;
   - reject compressed SSE upstream responses before local response start;
   - decode compressed non-streaming upstream responses for cap enforcement and strip or set `Content-Encoding: identity` when forwarding decoded bytes;
   - close/reset non-streaming responses that truncate after local headers are sent rather than delivering partial success;
   - emit terminal redacted SSE error event on already-started streaming truncation when possible.

9. Implement local error mapping:
   - OpenAI-shaped local error envelope with `error.macprovider.forwarded_upstream`;
   - startup errors remain process exit/stderr errors;
   - include `local_invalid_request`, `local_content_encoding_unsupported`, `local_model_not_allowed`, `local_pricing_unavailable`, `local_budget_required`, `local_request_too_large`, `local_endpoint_busy`, `local_budget_exceeded`, `local_request_cap_exceeded`, `local_budget_ledger_unavailable`, `local_estimate_exceeded`, `local_endpoint_unsupported`, and `local_upstream_unavailable`;
   - deterministic `local_upstream_unavailable` 502/503 split per SPEC-045.

## Acceptance tests

- endpoint subset and unsupported method/path handling;
- request-line/request-target/header/pre-auth connection limits;
- query rejection and path normalization rejection cases;
- ambiguous framing rejection;
- local content-encoding rejection and chunked decoding;
- duplicate JSON keys, bounded nesting/parser work, and body cap behavior;
- browser-origin/CORS denial including multi-origin and comma-origin cases;
- upstream URL scheme/userinfo/path/query/fragment/address/TLS rejection;
- header stripping and generated upstream headers;
- redirect preservation with stripped `Location`;
- compressed SSE rejection;
- compressed non-streaming decode/cap/identity forwarding;
- non-streaming and streaming truncation behavior;
- local error-code/status mapping and forwarded-upstream flag behavior.

## Non-goals

- Do not implement budget admission, ledger settlement, or recovery commands.
- Do not expand the endpoint set.
- Do not add browser delegation.
