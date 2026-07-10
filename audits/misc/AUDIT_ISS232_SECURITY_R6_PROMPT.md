## Lane: SECURITY — Round 6

## Context

R5 SEC: 0 C / 2 H (BOM bypass + EOF dispatch).

R5 fix-pass landed as commit `5d60114`. Strip BOM + require blank-line termination on EOF + 4 new attack-vector tests.

## Your job

SECURITY LANE round 6. Re-audit:

- Is the BOM strip correctly scoped (only at stream start, never mid-stream)?
- Is the `envelopeDispatched` flag correctly tracking dispatch? Can an attacker still race the harness with some other combination of envelope + non-blank + EOF?
- Any other UTF-8 / encoding edge that spec-compliant clients handle but my parser doesn't? (BOM is one; UTF-16 not relevant; multi-byte chars in error.code?)

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`

R5→R6 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
