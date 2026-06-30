## Lane: SECURITY — Round 4

## Context

R3 SEC: 0 C / 1 H (post-[DONE] injection).

R3 fix-pass landed as commit `48bdc97`: `consumeSSE` returns after first `[DONE]`. Two new attack-vector regression tests cover the post-`[DONE]` injection in both `[DONE]` and EOF variants.

## Your job

SECURITY LANE round 4. Re-audit:

- With the early-return at first `[DONE]`, is there ANY other attack vector that achieves corroboration without the buyer actually seeing the envelope?
- Edge cases: what if `[DONE]` arrives without the preceding `\n\n` separator? What if `[DONE]` appears as part of a content chunk's payload (`{"choices": [{"delta": {"content": "[DONE]"}}]}`)?
- Is `consumeSSE`'s `data:` prefix detection robust against malicious framing (e.g., `data:[DONE]` without space, `Data: [DONE]` with capital)?
- Now that the harness stops at first `[DONE]`, is there any leftover behavior in `Result` (bytes counter, TTFT, etc.) that would still be inflated by post-`[DONE]` content (and could be used as a side-channel signal)?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
