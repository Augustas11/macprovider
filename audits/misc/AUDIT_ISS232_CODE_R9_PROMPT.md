## Lane: CODE — Round 9

## Context

R8 CODE was 0/0/0/1/0 (LOW only), but the R8 fix-pass refactored the
consumeSSE parser to a true event-boundary model. This is a
substantial code change in CODE scope.

R8 fix-pass landed as `eaf4b5c`:
- consumeSSE rewritten: buffer data lines in `eventBuf`, dispatch on
  blank line, discard pending event on EOF (per HTML5/SSE spec).
- Classification (SawTerminator / lastDispatchedWasEnvelope) moved
  from line-read time to event-dispatch time.
- State surface: 4 vars → 3 (`eventBuf`, `lastDispatchedWasEnvelope`,
  `lastDispatchedErrorCode`).
- 4 new R8 SEC HIGH tests added for the leading-[DONE] class.

## Your job

CODE LANE round 9. Re-audit the refactored parser:

- consumeSSE control flow correctness: any state-machine gap? BOM
  strip, non-data field lines, transport error, EOF, blank line
  before any data — all handled correctly?
- Multi-`data:` line events: does buffer concatenation with `\n`
  correctly match SSE spec?
- Interaction with parseChunkTokens (still per-event now, not
  per-line): any usage/completion-token accounting regression?
- Any unused imports, dead code, redundant state?
- Is #232 code complete for a closing PR?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`

R8→R9 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
