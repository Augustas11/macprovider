## Lane: SECURITY — Round 5

## Context

R4 SEC: 0 C / 1 H (leading-whitespace bypass).

R4 fix-pass landed as commit `6c6989f`. Strict SSE field-line parsing now requires `data:` at column 0; leading-whitespace lines are dropped. Three new attack-vector tests cover the bypass.

## Your job

SECURITY LANE round 5. Re-audit. Specifically:

- With strict column-0 parsing, are there OTHER protocol-level forgeries? (CR-only line terminators, BOM, UTF-8 control chars, very long data lines.)
- Does `bufio.Reader.ReadBytes('\n')` handle CR-only line endings the way an OpenAI client would?
- The `bytes.HasPrefix(fieldLine, []byte("data:"))` check is byte-exact, so `Data:` or `DATA:` are rejected. Confirm gateway never emits non-lowercase `data:` (SPEC compliance).
- The single-space strip after `data:` — does it leave any room for ambiguity (e.g., what if gateway emits `data:  {...}` with TWO spaces)?
- Any timing side-channel via `time.Now()` in `firstByte` / `LastByteUTC` that could be used to fingerprint the harness?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/phase5-gateway/internal/router/chat_proxy.go` (for the gateway's SSE emission patterns)

R4→R5 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
