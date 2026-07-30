# Issue #127 phase7-verify TestReasonEnumBijection AST walk — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of the issue #127 AST-walking enum-bijection test. Stay
narrowly in your lane.

## Branch / commit

- Branch: `fix/phase7-verify-enum-ast-walk`
- Worktree: `../macprovider-127-enum-ast` (origin/main base: 8585586)
- Files in scope (`git diff origin/main`):
  - `phase7-verify/internal/verify/enum_drift_test.go` — entire file
    rewritten. Hand-maintained 20-entry `expectedReasons` slice
    replaced by an AST walk of the verify package's `reasonXxx`
    constants. Adds unused-constant detection (with
    `FORWARD-COMPAT`/`RESERVED` doc-comment escape hatch) and a
    `TestReasonEnumBijection_DetectsDrift` table-driven test that
    exercises 5 distinct drift scenarios via synthetic in-memory
    packages. Helper `isReasonConstName` + tiny `TestIsReasonConstName`.

## What this change does (operator summary — NOT the audit answer)

Closes the issue #127 gap: a contributor adding a new `reasonXxx`
constant but never referencing it now fails the bijection test
silently. Original test relied on a hand-maintained slice as the
source of truth; new test uses `go/parser` + `go/ast` to extract the
constant set from `verify.go` itself, then enforces the bijection
against `schemas/output.schema.json`. The `reasonBundlePubkey-
ProviderMismatch` constant (intentionally reserved for future SPEC
revision per the in-source `FORWARD-COMPAT` block comment) passes
the unused check because the test recognizes its doc-comment marker.

## Code-lane scope (apply each; stay in lane)

### CODE-1. AST extraction correctness
- The walker only collects identifiers whose name matches
  `isReasonConstName` (literal prefix `reason` + first-character-of-
  suffix is uppercase). Confirm this REJECTS:
  - `reason` (bare prefix)
  - `reasonable` (lowercase suffix start)
  - `Reason` (wrong case start)
  - `warningReasonProviderIDUnresolvable` (wrong prefix despite
    embedded "reason"; this IS declared in verify.go const block but
    must NOT be picked up by the reason walker).
- The walker only collects from `*ast.GenDecl` with `Tok ==
  token.CONST`. Confirm it does NOT pick up:
  - `var reasonFoo = "..."` declarations (var, not const)
  - `reasonFoo := "..."` short-var assignments (not GenDecl)
- The walker requires `vs.Values[i]` to exist for each name in
  `vs.Names`. For iota-style declarations like `const ( a = iota;
  b; c )`, only `a` has a value; `b` and `c` reuse the previous
  expression. Confirm this case can never apply to `reasonXxx`
  string constants (which never use iota).
- `strconv.Unquote` parses the value. Confirm it correctly handles
  raw-string literals `\`foo\`` if a contributor ever uses them.
  (Strict double-quoted is the convention.)

### CODE-2. Reference counting / unused-constant detection
- The walker uses `ast.Inspect` to count `*ast.Ident` nodes whose
  name matches a declared reason constant, EXCLUDING the
  declaration's own `name.Pos()`. Trace whether this correctly
  separates the declaration site from subsequent uses. The
  declaration site's `ident.Pos()` is the position of the name
  inside the `ValueSpec`; subsequent references to the same name
  have different positions. Confirm.
- Edge case: if a reason constant is declared in one file and
  referenced in another file in the same package, does the walker
  count the reference? It walks `pkg.Files` (all non-test files in
  the package), so yes. Trace: `reasonProviderIDNotInPool` is
  referenced in `catalog_check.go`? Or only in `verify.go`?
- Edge case: a reason constant could be referenced ONLY in a test
  file. With test files excluded from the parser, it would appear
  unused. Is this the correct semantic? (Yes — the architectural
  claim is that any reason constant must be USED in production
  code; tests-only is the same as unused for this purpose.)

### CODE-3. Reserved-marker escape hatch
- `hasReservedMarker` checks `vs.Doc` for the substring
  `FORWARD-COMPAT` or `RESERVED`. It does NOT check `gen.Doc` (the
  GenDecl-level doc). Is that the right boundary?
- The current FORWARD-COMPAT comment on
  `reasonBundlePubkeyProviderMismatch` is placed BETWEEN
  `reasonPreviousKeyOutsideGraceWindow` and itself, inside the
  const block. `go/parser` with `parser.ParseComments` attaches it
  as `vs.Doc` on the `reasonBundlePubkeyProviderMismatch` ValueSpec.
  Confirm with `go test` actually runs.
- Substring match (vs. word-boundary or all-caps requirement) — is
  this overly permissive? A contributor could write "DEFINITELY
  NOT RESERVED" and the test would consider it reserved. Acceptable?

### CODE-4. Schema-bijection check
- The schema struct only decodes `oneOf[].properties.reason.{const,
  enum}`. Confirm this matches the actual schema layout (3
  branches, each with a `reason` property at that path).
- The `expected` map uses `value → constName` (not just a set).
  When a schema reason has no matching Go constant, the error
  message says `"schema reason %q has no matching reasonXxx Go
  constant"` — informative.
- The duplication check (`want exactly one branch`) catches the
  case where the same reason value appears in multiple `oneOf`
  branches. Confirm the message names the Go constant + value +
  the branches.

### CODE-5. Drift-detection table tests
- `TestReasonEnumBijection_DetectsDrift` covers 5 scenarios:
  1. Go constant missing from schema
  2. Schema reason missing from Go constants
  3. Unused non-reserved constant fails
  4. Unused reserved constant passes
  5. Go constant appears in multiple schema branches
- Each fixture is self-contained: a synthetic Go source string + a
  synthetic JSON schema. The walker is invoked via
  `parser.ParseFile` → constructed `*ast.Package` wrapper. Confirm
  this faithfully exercises the same code path as the live test.
- `wantErrFrag` does substring containment; if the error message
  text changes, only the matching fragment matters. Acceptable.

### CODE-6. Test packaging
- `enum_drift_test.go` is in `package verify` (not `package
  verify_test`), so it has access to unexported `checkReasonEnum-
  Bijection` and the helpers. Confirm no other file in this
  package defines a symbol that collides with the new helpers
  (`isReasonConstName`, `hasReservedMarker`,
  `checkReasonEnumBijection`).

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
`specs/127_ENUM_AST_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
