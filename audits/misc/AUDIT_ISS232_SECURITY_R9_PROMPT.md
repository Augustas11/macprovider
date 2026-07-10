## Lane: SECURITY — Round 9

## Context

R8 SEC: 0/1/0/0/1 (HIGH: leading-[DONE] undispatched attack; LOW:
comment drift). Both absorbed in R8 fix-pass `eaf4b5c` via
event-boundary parser refactor.

## Your job

SECURITY LANE round 9. Final security review of the event-boundary
parser:

- Attack-vector matrix completeness across R1–R8: enumerate any
  combination not yet covered by the 21+ buyer-package tests.
- Any remaining shape mismatch between what a spec-compliant OpenAI/
  EventSource client dispatches and what the harness dispatches?
- Edge cases: bare `\r\n` line endings, `event:`/`id:`/`retry:` field
  lines interleaved with `data:`, multiple `data:` lines that together
  spell "[DONE]" per some encoding, trailing whitespace on payloads.
- Does the refactor close the SEC R8 leading-[DONE] class definitively?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`

R8→R9 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
