## Lane: ARCHITECT — Round 3

## Context

R2 outcomes:
- CODE 0/1/0/0 (HIGH: SPEC/impl drift on `usage`)
- SEC  0/1/1/1 (HIGH: trailing-garbage bypass; MED: nested error.code dup; LOW: SPEC/impl drift)
- ARCH 0/1/1/1 (HIGH: SPEC/impl drift; MED: trailing garbage; LOW: nested error dup)

R2 fix-pass landed as `0ff5a85`:
1. Trailing-garbage check now requires `io.EOF` (was accepting syntax errors).
2. `error` object parsed token-by-token; nested duplicates rejected.
3. SPEC-006 bumped to v0.9.5: §17.7.1 clause 1 tightened to "no `choices` field, no `usage` field" (literal absence) + duplicate-key rejection clause.
4. 8+ new test cases: invalid suffixes, nested dup error.code/type, usage:null.

## Your job

ARCHITECT LANE round 3. Re-audit token-level parser + SPEC v0.9.5 + tests.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/chat_proxy.go`
- `/Users/augstar/macprovider-iss295/phase5-gateway/internal/router/streaming_structured_output_test.go`
- `/Users/augstar/macprovider-iss295/specs/SPEC-006-buyer-api.md` (§17.7.1, v0.9.5)

R2→R3 diff: `git -C /Users/augstar/macprovider-iss295 show HEAD`
