## Lane: ARCHITECT — Round 1

## Context

#295 closes SPEC-006 §17.7.1 producer-side enforcement holes on the
gateway. Two fixes in `phase5-gateway/internal/router/chat_proxy.go`:

1. `terminalSSEErrorCode` (line 1154): now rejects payloads with
   non-empty `choices` or non-zero `usage` tokens (clause 1:
   standalone envelope only).
2. `forwardStreamingChat.forwardLine` (line 583+): after a terminal
   envelope dispatched, non-`[DONE]` `data:` frames are dropped
   before writing to the buyer (clause 3: no content after envelope).

R1 IMPL landed as commit `2f5c7a2`. 5 new tests added, all pre-
existing tests still pass, `go vet ./...` clean.

## Your job

ARCHITECT LANE round 1. Standard severity-graded findings.

Key concerns:
- Is the standalone-envelope check byte-strict enough? Any bypass via
  JSON quirks (duplicate keys, unicode, escaped keys, null usage)?
- Is the content-drop after terminal complete? Any leak path via
  non-data field lines carrying content (event:, id: with payload
  smuggling)?
- Does the drop interact correctly with existing `emitted` byte
  accounting and `reported` usage tracking?
- SPEC-006 §17.7.1 mapping alignment: does the harness (already
  shipped in #232) and gateway (this PR) form a consistent contract?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/chat_proxy.go`
- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/streaming_structured_output_test.go`
- `/Users/augstar/macprovider-iss295/specs/SPEC-006-buyer-api.md` (§17.7.1)

R0→R1 diff: `git -C /Users/augstar/macprovider-iss295 show HEAD`
