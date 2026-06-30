## Lane: CODE — Round 5

## Context

R4: CODE PASS, SEC 0/1 (leading-whitespace), ARCH 0/0/2/1.

R4 fix-pass landed as commit `6c6989f`:
1. Strict SSE field-line parsing (no leading-whitespace trim).
2. SPEC-006 SHOULD→MUST + named-exception list.
3. SPEC-019 split shape vs mapping.
4. Stale comment tightening.

## Your job

CODE LANE round 5. Re-audit. Specifically:

- The new field-line parsing — `bytes.HasPrefix(fieldLine, []byte("data:"))` from column 0 after trailing-CR/LF strip. Any edge case?
- Manual CR/LF stripping: any input shape where it fails (CR-only line endings, multi-byte newline)?
- The single-space-after-colon strip — does it handle `data:[DONE]` (no space) correctly?
- Multi-line `data:` shapes per SSE spec (concatenated payloads): does the parser handle them?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`

R4→R5 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
