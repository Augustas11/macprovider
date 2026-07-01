## Lane: SECURITY — Round 2

## Context

R1 SEC: 0 C / 2 H / 0 M / 0 L. Both HIGHs absorbed.

R1 fix-pass landed as commit `9cffa7c`:
1. SawTerminator anchor replaced with `SawSSEErrorEvent` (parse `error` field in SSE chunks).
2. Suppression rule: `return p.HarnessSawSSEErrorEvent`.
3. Tests cover benign-no-DONE + production-shape-with-envelope.

## Your job

SECURITY LANE round 2: re-audit.

- Is `SawSSEErrorEvent=true` actually unforgeable by a malicious gateway? Specifically: can the gateway emit a payload containing `"error": {"code": "..."}` somewhere INSIDE a valid streaming response that the buyer would still see as "successful completion"? (E.g., inject the field in a usage chunk so the buyer thinks they got a clean stream while still triggering the corroboration.) — Confirm the harness's parseChunkTokens semantic that ANY chunk carrying error envelope marks the whole stream.
- Is the threshold (`c.Error.Code != ""`) bypassable via missing code field on a real error envelope? Look at writeSSEError in chat_proxy.go to confirm code is always populated.
- Are there OTHER SSE error envelope shapes the gateway emits (e.g. writeStructuredOutputTimeoutSSE) that have different payload structures the harness might not catch?
- Does the new field plumbing introduce any deserialization attack (e.g., a buyer.Result loaded from disk could now be crafted to flip suppression)?
- Same as R1 — is the harness fully trusted vs the gateway in this threat model?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/phase5-gateway/internal/router/chat_proxy.go` (for ALL writeSSE* helpers — confirm error envelopes are detectable)

R1→R2 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
