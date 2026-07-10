# Issue #82 item 3 r2 — CODE-lane closure audit

You are the **code** lane of the r2 closure audit for issue #82 item
3 — `coordinator-cli pre-flip-audit`. r1 returned 1 HIGH + 1 MEDIUM:

- **r1 H1** Missing DB path silently creates an empty SQLite file and
  passes the gate.
- **r1 M1** Non-canonical `last_used_at` strings trusted by lex
  comparison.

Both fixed in r2. Stay narrowly in your lane.

## r1 → r2 fixes

- **r1 H1 → r2 fix**: pre-flip-audit now `os.Stat(*dbPath)` BEFORE
  calling `auth.OpenStore`. If the file does not exist, returns an
  error containing "does not exist" without creating any file. New
  test `TestPreFlipAudit_MissingDBPath_FailsClosed` exercises this
  and explicitly asserts the missing path was NOT created.
- **r1 M1 → r2 fix**: `last_used_at` values are now parsed with
  `time.Parse("2006-01-02T15:04:05Z", ...)` strictly. A non-
  canonical timestamp (microseconds, +00:00 offset, etc.) flags the
  row as STALE with reason "not canonical RFC3339Z...". The cutoff
  comparison uses typed `parsed.Before(cutoff)` instead of lex `<`.
  New test `TestPreFlipAudit_NonCanonicalTimestamp_FlagsAsStale`
  exercises this by writing a microsecond-precision +00:00 timestamp
  via `writeRawLastUsed` and asserting stale + the reason-message
  contains "not canonical RFC3339Z".

## r1 LOW residuals

- **r1 L1** (JSON mode didn't test NULL last_used branch) — closed
  by new test `TestPreFlipAudit_JSONMode_NullLastUsed`.
- **r1 L2** (near-boundary cushion too tight) — widened: cutoff 30s
  / backdate 1s (was 1s / 500ms).
- **r1 L3** (exit-code comment ambiguous) — accepted; matches
  existing CLI convention (every error → exit 1). Documented in the
  function's doc comment.

## Files in scope (`git diff origin/main` r2 delta only)

- `phase4-coordinator/cmd/coordinator-cli/main.go` — `os.Stat`
  fail-closed; `time.Parse` strict layout; typed cutoff comparison.
- `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go`
  — 3 new tests + helpers `osStat`, `writeRawLastUsed`.

## Verification ask

1. Confirm r1 H1 is closed: missing path returns "does not exist"
   error AND does not create a file. The test specifically checks
   `os.Stat(missing)` after the call — does this prove fail-closed?
2. Confirm r1 M1 is closed: typed `time.Parse` with the canonical
   layout will reject any non-conforming format. Examples I expect
   to be rejected:
   - `"2099-01-01T00:00:00.000+00:00"` (microseconds + +00:00)
   - `"2099-01-01T00:00:00.123Z"` (sub-second precision)
   - `"2099-01-01 00:00:00Z"` (space instead of T)
   - `"invalid"` (totally wrong)
3. New cushion (30s/1s) — adequate for slow CI?
4. Any new issues introduced by r2 deltas?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM3_CODE_R2_audit.md`. If 0 CRITICAL/HIGH/MEDIUM
AND both r1 findings are resolved, end with:
`VERDICT: code lane r2 READY TO MERGE`
