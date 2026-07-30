# IMPL audit prompt — SPEC-016 FULL implementation, **SECURITY REVIEW lane, r3**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r3.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 2) auditing the FULL
SPEC-016 implementation — round 3.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r3.md`. HEAD: `90e3dbf`.
r2 found 1 MEDIUM (ADD COLUMN regex); fix-pass at this commit.

## r2 closure verification

### [full-sec:r2-1] ADD COLUMN regex skip comments + string literals

Walk `stripExistingColumnAlters` + `buildExecutableMask` in
migrations.go. Verify:
- A per-byte mask tracks whether each byte is in executable SQL
  context (NOT a `-- line comment`, NOT inside `'` or `"` literal).
- The mask is true at byte index N when execution at N is the
  intended interpretation.
- `stripExistingColumnAlters` checks `skipMask[start]` before
  doing the PRAGMA lookup + rewrite.
- The new test
  `TestStripExistingColumnAlters_SkipsCommentsAndStringLiterals`
  feeds a body with `-- ALTER TABLE ... ADD COLUMN ...` AND
  `SELECT 'ALTER TABLE ... ADD COLUMN ...'`, both targeting
  EXISTING columns (gas_reserved_native_wei + run_id), and
  asserts the body is byte-identical (no rewrite).
- A separate sub-case feeds a REAL top-level ALTER on an existing
  column and asserts the rewrite IS active.

### Edge cases the mask should handle

- `''` escape inside a single-quoted string (SQLite doubles to
  escape). Does the mask treat the inner `'` correctly? Walk
  the escape behavior in `buildExecutableMask`. Note: SQLite's
  `''` is "end string + start new string"; if the byte after
  `'` is another `'`, the mask toggles in/out twice — effectively
  remaining in single-quote state. Is this what
  buildExecutableMask does? Test by constructing a body like
  `'foo''bar ALTER TABLE x ADD COLUMN y'`.

- `"` double-quoted identifier with escaped `""`. Same logic.

- Mixed `'..."..."..'` — verify nesting is correct (single
  ignores `"`, double ignores `'`).

- Multi-line `--` comment ends only on `\n`. Verify newline
  resets `inLineComment`.

- Empty body returns empty mask without panic.

## New cross-step probes (round 3)

### A. Mask state machine — provable correctness

Manually trace `buildExecutableMask` over a few hand-crafted
bodies and confirm the resulting mask:

1. `"ALTER TABLE t ADD COLUMN c INTEGER;"` — mask all true.
2. `"-- A\nALTER TABLE t ADD COLUMN c INTEGER;"` — mask: false
   for `-- A`, true at `\n` and onward.
3. `"SELECT 'ALTER TABLE x ADD COLUMN y INTEGER';"` — mask: true
   for `SELECT `, false inside the quoted string, true for `;`.
4. `"'a''b' c"` — mask: false for `'a''b'`, true for ` c`.

If any case fails, flag as defect with the specific byte index.

### B. Other r2 changes — security review

The r2 code-lane changes (confirmedDepth refactor) are inside
runner.go pollAndConfirm. Security probe:
- Does the new code emit any new log line that could leak
  secrets? (Should not — the log line at deadline mentions only
  payout_id + tx_hash, both non-secret.)
- Does the confirmedDepth=false path correctly skip both
  markConfirmedStandalone AND ClaimPayoutReady? Verify by
  walking the post-loop guard.

### C. govulncheck + race + secrets scan

- `govulncheck ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./...`
- Scan r2 fix-pass files for any new bearer/key/raw-tx log lines.

### D. OWASP Top 10 — r2 deltas

- A04 Insecure Design: was MEDIUM at r2 due to regex robustness;
  closed at this commit.
- A03 Injection: re-verify the new mask handles input correctly
  even on malformed bodies.
- A02 Cryptographic Failures / A05 Misconfiguration / A10 SSRF:
  unchanged from r2.

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-security-r3-audit.md`.
Standard structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Verify r2 closure holds + cross-probe the mask state machine.
- Wall-clock target: 20-30 min.

=== END PROMPT ===
```
