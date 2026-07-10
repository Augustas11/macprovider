## Lane: ARCHITECT — Round 2

## Context

R1 outcomes (convergent 3-of-3 HIGH):
- CODE  0/1/1/0 (HIGH: lossy JSON parse; MED: e2e non-trip test)
- SEC   0/1/1/1 (HIGH: same; MED: choices:[] alignment; LOW: bad fixture)
- ARCH  0/1/0/1 (HIGH: same; LOW: assertion weak)

R1 fix-pass landed as `4f11072`:
1. `terminalSSEErrorCode` rewritten as token-level JSON parser using
   `json.Decoder`. Requires top-level object; walks keys; rejects
   duplicate keys, any presence of `choices` or `usage` (regardless
   of value shape), and trailing garbage.
2. `TestTerminalSSEErrorCode_RejectsNonStandaloneShapes` expanded to
   ~15 cases: duplicate keys, total_tokens, empty containers, null
   values, non-object JSON, trailing garbage.
3. `TestStreamingStructuredOutputNonStandaloneEnvelopeDoesNotTripTerminalPath`
   rewritten to prove the non-trip claim via `assertHasUsageOutcome`
   and content-forwarding assertions on both chunks.
4. Added `assertHasUsageOutcome` helper.

## Your job

ARCHITECT LANE round 2. Re-audit the token-level parser + expanded tests.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/chat_proxy.go`
- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/streaming_structured_output_test.go`
- `/Users/augstar/macprovider-iss295/specs/SPEC-006-buyer-api.md` (§17.7.1)

R1→R2 diff: `git -C /Users/augstar/macprovider-iss295 show HEAD`
