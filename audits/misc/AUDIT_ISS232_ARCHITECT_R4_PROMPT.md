## Lane: ARCHITECT — Round 4

## Context

R3 ARCH: 0/0/2/2.

R3 fix-pass landed as commit `48bdc97`:
1. SPEC-006 §17.7.1 scope tightened to "buyer-writable" cases; client-disconnect rows excluded.
2. Code-vs-outcome mapping clause added with `provider_disconnected → stream_truncated` named exception.
3. SPEC-019 cross-reference paragraph.
4. Stale comment fixes.

## Your job

ARCHITECT LANE round 4. Re-audit:

- Are SPEC-006 §17.7.1's new scope + mapping clauses now well-defined? Any remaining ambiguity (e.g., what about §17.7 rows that aren't client-disconnect but also aren't buyer-writable for some other reason)?
- The mapping table currently has 1 named exception (`provider_disconnected`). Are there OTHER existing gateway divergences that should be enumerated proactively?
- SPEC-019 cross-reference paragraph — coherent with the v0.2 streaming pass-through clause?
- Anything else (CONTEXT.md, beta/DECISION_CRITERIA.md) that should pick up the new contract?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/specs/SPEC-006-buyer-api.md` (§17.7.1)
- `/Users/augstar/macprovider-iss232/specs/SPEC-019-structured-output.md`
- `/Users/augstar/macprovider-iss232/test/network-harness/README.md`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/invariants/hard.go`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
