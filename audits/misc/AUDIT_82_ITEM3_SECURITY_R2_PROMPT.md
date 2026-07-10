# Issue #82 item 3 r2 — SECURITY-lane closure audit

You are the **security** lane of the r2 closure audit. r1 returned 0
C/H/M with 1 LOW — but the r2 fixes (driven by code-lane H1+M1) also
close two defense-in-depth surfaces you noted. Stay narrowly in your
lane.

## r1 SEC verdict carry-over

r1 verdict was READY TO MERGE; the 24h-default rationale, lex-
comparison safety, token-prefix disclosure surface, race semantics,
and MUST-level wording all still apply unchanged in r2.

## r2 deltas relevant to security

- **Fail-closed on missing DB path**: closes the operator-typo
  attack class where a misspelled `--db` path would create an empty
  SQLite file and the audit would print `safe_to_flip=true`. Now
  the command errors with "does not exist" before creating
  anything.
- **Typed time parse with strict layout**: closes the
  non-canonical-format bypass class. Any `last_used_at` that does
  not match the canonical UTC RFC3339Z second-precision layout is
  treated as stale. (You already noted in r1 that all production
  writes go through `nowString()` and therefore the lex compare was
  safe in practice; this hardening is defense in depth — and
  it ALSO removes the future-dated row concern from r1 L1, since a
  future-dated row's parse would still succeed but the
  `parsed.Before(cutoff)` check would correctly NOT flag it as
  stale, matching the intentional design.)

## Security verification ask

1. Does the strict-layout parse close any future-dated row concern
   you noted in r1? Trace: a `last_used_at` 100 years in the future
   parses fine, `parsed.Before(cutoff)` is false → row passes. Is
   this still the right semantic, or should the audit ALSO flag
   suspicious-future timestamps?
2. The non-canonical-format reject — could any production code path
   write a non-canonical timestamp? The r1 SEC analysis confirmed
   `nowString` / `timeText` are the only writers, both canonical. r2
   adds defense-in-depth. Confirm no regression.
3. The missing-DB fail-closed: any way an attacker (rather than a
   confused operator) could exploit a missing file to cause a
   false-pass? (Probably not — pre-flip-audit is operator-only,
   running in the operator's shell.)

## Files in scope (`git diff origin/main` r2 delta only)

- `phase4-coordinator/cmd/coordinator-cli/main.go` — see r2 CODE
  prompt for the exact diff lines.
- `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go`
  — see r2 CODE prompt.

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM3_SECURITY_R2_audit.md`. If 0 C/H/M AND r2
deltas don't open any new surface, end with:
`VERDICT: security lane r2 READY TO MERGE`
