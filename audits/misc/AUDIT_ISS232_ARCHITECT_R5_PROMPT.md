## Lane: ARCHITECT — Round 5

## Context

R4 ARCH: 0/0/2/1.

R4 fix-pass landed as commit `6c6989f`:
1. SPEC-006 §17.7.1 default mapping tightened to MUST with named-exception list.
2. SPEC-019 cross-reference split (shape rules inherit; mapping conditional on usage_events row).
3. Stale comment tightening.

## Your job

ARCHITECT LANE round 5. Re-audit:

- Are SPEC-006 §17.7.1's clauses now internally consistent and externally aligned with SPEC-019, SPEC-002 (FR-B6), etc.?
- The named-exception list currently has one entry. Are there other existing gateway divergences I missed (`response_byte_cap_exceeded` is now mentioned but does it have its own usage_events.outcome value)?
- SPEC-019's new clause about "no gateway usage_events row" for pass-through paths — does that conflict with any existing test or implementation?
- Is there anything else (CONTEXT.md, beta/DECISION_CRITERIA, the issue body, the README) that still needs updating?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/specs/SPEC-006-buyer-api.md` (§17.7.1)
- `/Users/augstar/macprovider-iss232/specs/SPEC-019-structured-output.md`
- `/Users/augstar/macprovider-iss232/test/network-harness/README.md`

R4→R5 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
