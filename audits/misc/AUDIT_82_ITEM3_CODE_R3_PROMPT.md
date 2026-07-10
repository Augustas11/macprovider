# Issue #82 item 3 r3 — CODE-lane closure audit

You are the **code** lane of the r3 closure audit. r2 returned 0/0/1/0
— a MEDIUM that `time.Parse(canonicalTimeLayout, …)` accepts fractional
seconds even when the layout omits them, so `"2099-01-01T00:00:00.123Z"`
parsed successfully and the gate would not flag it as non-canonical.

## r2 M1 → r3 fix

Added a **round-trip check** after `time.Parse`:

```go
parsed, parseErr := time.Parse(canonicalTimeLayout, r.LastUsedAt.String)
canonicalRoundTrip := parseErr == nil &&
    parsed.UTC().Format(canonicalTimeLayout) == r.LastUsedAt.String
if !canonicalRoundTrip { /* flag stale */ }
```

A row is canonical IFF: (a) parse succeeds AND (b)
`parsed.UTC().Format(layout)` reproduces the original string byte-for-
byte. Fractional seconds, missing-Z, +offset etc. all fail this check.

New test `TestPreFlipAudit_NonCanonicalTimestamp_FlagsAsStale` now table-
drives 4 cases: `offset_instead_of_Z`, `fractional_seconds_Z`,
`space_instead_of_T`, `totally_garbage`. All four flagged stale with the
"not canonical RFC3339Z" reason.

## Files in scope (r3 delta only)

- `phase4-coordinator/cmd/coordinator-cli/main.go` — round-trip check
  added; offender reason message distinguishes parse error vs round-
  trip mismatch.
- `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go` —
  test promoted to table-driven with 4 cases (was 1).

## Verification ask

1. Confirm r2 M1 is fully closed: the fractional-seconds case
   `"2099-01-01T00:00:00.123Z"` now flags as stale.
2. Any other format Go's `time.Parse` permits that the round-trip
   misses? Specifically: timezone suffix forms (`+00:00`, `-00:00`,
   `Z`, lowercase `z`), padded vs unpadded fields.
3. Any production code path that legitimately produces a non-
   canonical format that would be falsely rejected? (Expected: no —
   `nowString()` / `timeText()` always emit the canonical form, and
   the existing CI tests confirm.)
4. Any new bugs introduced by r3 deltas?

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM3_CODE_R3_audit.md`. If 0 C/H/M AND r2 M1 is
fully closed, end with: `VERDICT: code lane r3 READY TO MERGE`
