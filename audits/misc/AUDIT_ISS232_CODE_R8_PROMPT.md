## Lane: CODE — Round 8

## Context

R7 outcomes:
- CODE 0/0/1/0/0 (MED: SawTerminator flipped on undispatched [DONE])
- SEC  0/1/0/0/0 (HIGH: same finding, I4 bypass)
- ARCH 0/0/0/1/0 (LOW: stale ledger.go:535 comment)

R7 fix-pass landed as commit `9645974`:
1. Added `atEventStart` bool in consumeSSE, set true at stream start
   and after every blank-line dispatch, false after any data line.
2. `data: [DONE]` only flips SawTerminator when `atEventStart=true`;
   mid-event [DONE] is continuation data (resets envelope state, keeps
   reading).
3. `parseChunkTokens=isStandalone` on a data line only sets
   lastWasErrorEnvelope=true when `atEventStart=true`.
4. Tightened R6 test: now asserts SawTerminator=false.
5. Added R7 tests: content+immediate-[DONE], leading-[DONE].
6. Updated ledger.go comment to name the corroboration gate.

## Your job

CODE LANE round 8. Final code review before merge:

- consumeSSE control flow: any state-machine gap? Does atEventStart
  transition correctly for BOM strip, non-data field lines, EOF?
- Test coverage: is the buyer package now fully covering the SSE
  dispatch state machine? Any remaining shape not exercised?
- Any unused imports, dead code, lint warnings?
- Is #232 code complete for a closing PR?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`

R7→R8 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
