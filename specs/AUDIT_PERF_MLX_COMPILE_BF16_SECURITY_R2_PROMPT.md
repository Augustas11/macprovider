# perf/mlx-compile-bf16 — SECURITY-lane audit (round 2)

Round 1 returned ONE LOW (SEC-2, decode-bench label/filename path
traversal). This round verifies the fix.

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Files touched since round 1:
  - `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` —
    introduces `sanitizeFilenameComponent(_:)` (allow ASCII alnum
    `_`, `.`, `-`; replace others with `_`; collapse runs; trim
    leading `_`/`.`; cap at 80; empty → `"unlabeled"`). Both `label`
    and `modelTag` are sanitized before being interpolated into the
    output filename.
  - `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift` —
    3 new tests (`testSanitizeFilenameComponentRejectsPathTraversal`,
    `KeepsSafeChars`, `HandlesEdgeCases`).

## Round-2 scope (narrow)

### SEC-2 (R1) verification
- Does the sanitizer fully neutralize the originally-flagged risk
  (label = `"../etc/passwd"` cannot escape `--output-dir`)?
- Does it leak any new edge-case (e.g. label collisions when two
  meaningfully-different operator values both sanitize to the same
  slug)? Acceptable risk for an operator-local CLI?
- Is `sanitizeFilenameComponent` symmetric — i.e. does it handle a
  `modelTag` value that legitimately contains `.` (e.g.
  "Qwen2.5-32B-Instruct-4bit") without mutilating it? Verify against
  the included test.
- Are there encoding pitfalls — NUL byte, BOM, combining marks,
  RTL override (U+202E)? The allowlist is ASCII; non-ASCII collapses
  to `_`. Confirm that's the desired posture, or recommend stricter
  handling.

### Regression check on unchanged SEC scope
- All other SEC-* items from round 1 were ACCEPTed implicitly (no
  finding). Re-confirm the change does not introduce new surface in
  the other SEC-* areas (env-flag handling, ModelRuntime cast wire-in,
  CompiledDecode adapter scope, dependency posture).

## Required output format
Same as round 1. Bar: 0 CRITICAL/HIGH/MEDIUM.

If fully accepted, the body can be `ACCEPT — SEC-2 (R1) resolved, no
new findings`.
