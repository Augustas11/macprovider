## Lane: SECURITY — Round 3

## Context

R2 SEC: 0 C / 1 H (envelope-injection bypass).

R2 fix-pass landed as commit `1ee46e8`. Key changes:
1. Standalone-envelope detection: error.code non-empty AND no choices AND zero usage tokens.
2. Position-aware: only the LAST data chunk before `[DONE]`/EOF flips the bit.
3. 6 attack-vector tests covering both injection modes.

## Your job

SECURITY LANE round 3. Re-audit. Specifically:

- The "no choices AND zero usage tokens" check — any way to satisfy this while ALSO having a content-bearing chunk? (e.g., `choices: []` empty array — does that count? `usage: null`?)
- The position check — what if the gateway emits MULTIPLE `[DONE]` markers? What if the gateway emits whitespace-only data lines between the error envelope and `[DONE]`?
- What if the gateway sends the error envelope as the LAST chunk but without a trailing `[DONE]` (EOF path)? Is this still corroborating in all cases? Are there malicious shapes here?
- The error envelope's parsed code is captured into `SSEErrorCode`. Could a malicious gateway craft a code field that exceeds the JSON tag's expected size (DoS via memory)? — Go json.Unmarshal handles bounds; just confirm.
- Any new SSE chunk shape the gateway emits (`writeProviderDisconnectedSSE`, `writeStructuredOutputTimeoutSSE`) that we haven't verified detection on?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/phase5-gateway/internal/router/chat_proxy.go`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
