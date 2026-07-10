## Lane: SECURITY — Round 8

## Context

R7 SEC: 0/1/0/0/0 (HIGH: SawTerminator flipped on undispatched [DONE],
bypasses I4 at `invariants/hard.go:304`). Absorbed in R7 fix-pass
`9645974` via `atEventStart` tracking.

## Your job

SECURITY LANE round 8. Final security review:

- Does the `atEventStart` gate close every event-boundary confusion
  attack a malicious gateway could mount?
- Attack-vector matrix completeness across R1–R7: enumerate any
  combination not yet covered by the 18+ buyer-package tests
  (envelope + [DONE] combinations, whitespace prefixes, BOM,
  post-[DONE] injection, mid-event [DONE], content+[DONE], EOF,
  code/outcome mismatch).
- Any remaining shape mismatches between buyer-visible behavior and
  what the harness verifies?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`

R7→R8 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
