# Issue #127 phase7-verify TestReasonEnumBijection AST walk — SECURITY-lane audit

You are the **security** lane of a three-lane audit (code / security /
architect) of the issue #127 AST-walking enum-bijection test. Stay
narrowly in your lane.

**Scope note.** This is a TEST-FILE-ONLY change (`enum_drift_test.go`).
No production code is modified. No new dependency surface. No new
runtime path. The security stake is small but worth confirming:
test hygiene affects ability to detect future drift on a money-path-
adjacent schema (verifier output is what buyers consume; receipt
fields downstream of this schema are part of SPEC-015's signed-receipt
trust boundary).

## Branch / commit

- Branch: `fix/phase7-verify-enum-ast-walk`
- Worktree: `../macprovider-127-enum-ast` (origin/main base: 8585586)
- File in scope (`git diff origin/main`):
  - `phase7-verify/internal/verify/enum_drift_test.go` (test-only)

## Why security cares about this diff

The verifier surfaces a `reason` field to the buyer. The mapping
between (Go reason constants) and (schema enum) is part of the
contract a buyer's tooling relies on. Drift in either direction
silently weakens trust:
- Schema lists a reason Go code never emits → buyer tooling treats
  unreachable case as live; possible false-positive defense logic.
- Go code emits a reason missing from schema → buyer JSON-schema
  validator rejects the verifier's own output; the verifier looks
  broken even when correct.

The original test had a third silent failure mode (the #127 gap):
a Go constant added but never used. The new test closes that gap.

## Security-lane scope (apply each; stay in lane)

### SEC-1. Drift detection completeness
- The new test enforces FIVE invariants:
  1. Every Go `reasonXxx` constant appears in exactly one schema
     branch (no missing, no duplicated).
  2. Every schema reason value maps back to a Go constant.
  3. Every non-reserved Go constant is referenced ≥ once in
     non-test source.
  4. Schema has exactly 3 `oneOf` branches (valid/invalid/
     inconclusive).
  5. Each branch has at least one reason const/enum.
- Are these the right invariants for the trust boundary? Specifically:
  is there any drift mode the test does NOT catch that the original
  hand-maintained slice DID catch? Trace.

### SEC-2. Escape-hatch abuse
- `hasReservedMarker` recognizes substrings `FORWARD-COMPAT` or
  `RESERVED` anywhere in the constant's doc comment. A contributor
  who wants to silence the unused-detection check can simply paste
  one of those words into a comment.
- Is this an actual attack surface? In practice the doc comment is
  visible in code review, and an unreviewed comment change won't
  silently land in production. But the marker matching is loose
  (substring, case-sensitive) — a strict word-boundary check would
  be more defensible. Recommend.
- Word-boundary alternative: require the marker as a standalone
  token (e.g. `(^|\W)(FORWARD-COMPAT|RESERVED)(\W|$)`). Cost: tiny.

### SEC-3. AST walker correctness under malicious input
- The walker parses real Go source. If a contributor injects code
  designed to fool the walker — for instance, an iota-based const
  block with no explicit string value, or a const declared in a
  build-tagged file that's not part of the default build — does
  the walker degrade safely (declared map missing the entry,
  test fails loudly) or silently?
- The walker DOES NOT respect build tags — it parses every `.go`
  file regardless of `//go:build` constraints. If a future
  contributor puts reason constants in a build-tagged file, the
  walker will count them. Is this the right semantic? (Probably
  yes — drift should be caught even for build-conditional code.)

### SEC-4. Schema parser surface
- The schema struct decodes only `oneOf[].properties.reason.{const,
  enum}`. If a contributor adds an `anyOf` or `if/then/else`
  construct at the same level, the schema walk silently misses
  reasons declared there. The current schema layout is fixed at 3
  `oneOf` branches; would a future SPEC-015 v0.4 wire-shape change
  break this assumption? Recommend.

### SEC-5. Synthetic-fixture test does not weaken the live test
- `TestReasonEnumBijection_DetectsDrift` builds synthetic packages
  via `parser.ParseFile` and constructs a wrapper `*ast.Package`.
  Confirm this does NOT mock around any of the live test's
  invariants. The synthetic case calls the SAME
  `checkReasonEnumBijection` function with synthetic inputs;
  it does NOT bypass any check.

### SEC-6. No new dependency
- Imports added: `go/ast`, `go/parser`, `go/token`, `io/fs`,
  `strconv`, `strings`, `unicode`, `fmt`. All stdlib. No third-
  party modules. Confirm `go.mod` is unchanged.

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

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/127_ENUM_AST_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
