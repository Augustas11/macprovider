# BUILD_SPEC_045_PHASE_4_CONFORMANCE_JOURNEY

Implement the conformance harness, compatibility tests, and signed journey evidence required to promote SPEC-045 beyond draft. This slice verifies the prior implementation slices; it should not add new product behavior.

## Target result

SPEC-045 has automated coverage for its local command, proxy, security boundaries, pricing/ledger behavior, status/redaction, error mapping, recovery, and a signed staging-or-production journey showing real OpenAI SDK compatibility through the local endpoint.

## Required implementation shape

1. Build a fake-gateway integration harness:
   - OpenAI-compatible `/v1/models`;
   - OpenAI-compatible non-streaming and streaming `/v1/chat/completions`;
   - `/v1/rate-card` and `/v1/rate-card.sig` fixtures;
   - controllable upstream errors, redirects, truncation, compression, TLS failures where feasible, response-header bounds, and usage/cost evidence.

2. Add CLI and local endpoint test coverage:
   - startup bind, collision, redaction, stdout/stderr separation, descriptor lock/write, status discovery, credential precedence, credential reload/deletion, local token verifier, local auth rejection, and idle status behavior;
   - endpoint subset, path/query rejection, request-target/parser/header bounds, ambiguous framing rejection, content-encoding rejection, chunked decoding, body caps, duplicate JSON keys, bounded JSON nesting/parser work, and aggregate resource limits;
   - browser-origin denial including `Origin: null`, multiple Origin headers, comma Origin, different-port loopback origins, and accepted bound-host origins.

3. Add upstream safety and proxy coverage:
   - upstream URL scheme/userinfo/path/query/fragment rejection;
   - IPv4/IPv6 non-global and IPv4-mapped IPv6 rejection;
   - repeated DNS validation before credential send;
   - proxy/redirect bypass disabling;
   - connected-peer address validation before upstream authorization;
   - header stripping and generated upstream content type;
   - upstream redirect preservation without `Location`;
   - compressed SSE rejection;
   - compressed non-streaming decode/cap/identity behavior;
   - non-streaming and streaming truncation behavior;
   - tool-calling and structured-output pass-through without body reserialization.

4. Add budget, pricing, and ledger coverage:
   - model allowlists and budget-required behavior;
   - budget flag parsing;
   - per-request cap;
   - no-budget and unpriced override warnings;
   - trusted rate-card signature, keyring, policy, freshness, stale warning, maximum age, and future skew;
   - exact arithmetic vectors;
   - durable append-before-forwarding;
   - fsync failure rollback;
   - micro-USD string amount fields;
   - schema version on every row;
   - closed state transitions;
   - held reservation restart/release/no-match/wrong-run cases;
   - non-streaming and SSE settlement evidence timing;
   - `estimate_exceeded` process stop and in-flight behavior.

5. Add status/error/redaction coverage:
   - `Cache-Control: no-store`;
   - closed `pricing_warning_codes`;
   - bounded error ring count, total bytes, per-field bytes, per-entry bytes, and `truncated: true`;
   - local error status-code mapping;
   - forwarded-upstream flag;
   - absence of upstream credential, local token, prompt, completion, full credential path, receipt body, full upstream body, hostname, OS username, hardware serial, MAC address, stable hardware UUID, and interface name in logs/status/ledger/evidence.

6. Add signed real-gateway journey:
   - use staging or production gateway, not a fake gateway;
   - use an OpenAI SDK configured with local base URL and generated local token as `api_key`;
   - perform a permitted chat completion;
   - show an over-budget denial;
   - restart with an unreconciled reservation held;
   - release the held reservation through recovery command;
   - capture redacted logs/status proving no credential, local token, prompt, or completion leakage;
   - sign and store journey result according to existing repo evidence conventions.

## Acceptance tests

- Fake-gateway tests cover all Phase 1-3 acceptance criteria that do not require real gateway behavior.
- The signed real-gateway journey covers SDK interoperability, admission, budget denial, restart-held recovery, and redaction.
- `specs/CONFORMANCE.json` remains pending until implementation evidence and journey artifacts are actually committed and reconciled.

## Non-goals

- Do not use fake-gateway evidence as production-promotion proof.
- Do not expand SPEC-045 endpoint scope.
- Do not claim conformance before implementation and signed journey artifacts exist.
