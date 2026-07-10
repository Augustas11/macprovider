# Audit: ISS-231 R1 code lens

SPEC-007 v0.4 closes the R2 architect lane deferrals from PR #221:
A1 cap on `matched_account_ids` + A2 path-segment typing.

Tree at HEAD: `spec/iss-231-spec-007-v04`. `git log --oneline -3`.

## Files in scope

- `phase5-gateway/internal/storage/sqlite/explorer.go`
- `phase5-gateway/internal/storage/types.go`
- `phase5-gateway/internal/router/explorer.go`
- `phase4-coordinator/internal/explorer/handlers.go`
- `phase5-gateway/internal/storage/sqlite/iss231_test.go` (new)
- `phase5-gateway/internal/router/iss231_test.go` (new)
- `phase4-coordinator/internal/explorer/iss231_test.go` (new)
- `specs/SPEC-007-explorer.md`

## What I want (code lens)

Find **CODE DEFECTS** — bugs, races, off-by-ones, broken backward
compat, incorrect SQL semantics, error-path mishandling.

Specifically:

1. The bounded UNION `LIMIT cap+1` (cap=10) — does `ORDER BY
   account_id LIMIT 11` deterministically include the
   lexicographically-first 11 accounts under SQLite semantics?
   Could a non-deterministic ORDER cause the truncated subset to
   change across calls for the same input?
2. `explorerAccountIDsForRequestUnbounded` is the forensic
   fallback. Is the storage layer correctly degrading to the
   bounded result when the unbounded query fails (e.g. DB error
   mid-call), and does the degradation logic risk silently
   emitting an incomplete-but-flagged-as-complete audit row?
3. `parseTypedSegment` rejects empty post-strip values (`"ext_"`
   alone). Does this interact correctly with `strings.Contains(p,
   "/")` guard in the calling handler? Any URL-decoding edge
   case where `ext_` could be percent-encoded and slip through?
4. `quotedCSV` minimal escape — sufficient for arbitrary
   account_id values? account_id is gateway-derived but could
   contain control chars in edge cases — does the escape produce
   valid JSON?
5. The fire-and-forget `_ = s.store.InsertAuditEvent(...)` for
   the deprecation WARN and the truncation forensic emit — does
   ignoring the error silently swallow a money-path concern, or
   is it the right shape (best-effort observability)?
6. The coordinator's `strings.CutPrefix` is Go 1.20+ — is that
   under the project's minimum Go version?

Severity output format identical to the prior session's audits.
End with `## Convergence X/X/X/X → DECISION`.
