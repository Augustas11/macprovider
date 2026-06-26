# Issue #126 + #128 phase7-verify hardening — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of the bundled #126 + #128 phase7-verify hardening on
top of the SPEC-015 v0.3.3 LOCKED baseline. Stay narrowly in your
lane.

## Branch / commit
- Branch: `fix/phase7-verify-tls-warn-and-exit64`
- Worktree: `../macprovider-126-128-phase7-verify-hardening` (origin/main base: 9ff708d)
- Files in scope (`git diff origin/main`):
  - `phase7-verify/internal/resolver/resolver.go` — new `ErrPrivateCoordinatorDenied` sentinel + `nonDefaultTLSTrustWarning` helper; `normalizeCoordinator` wraps the sentinel.
  - `phase7-verify/internal/cli/cli.go` — `exitForError` recognizes `resolver.ErrPrivateCoordinatorDenied` → `exitUsage` (64).
  - `phase7-verify/internal/resolver/resolver_test.go` — 4 new TLS-trust-warning tests + 2 new normalizeCoordinator tests + `writeFakeCAPEM` helper (real generated cert).
  - `phase7-verify/internal/cli/cli_test.go` — new `TestCLIPrivateCoordinatorExitsUsage` (locally clears the escape-hatch env var).
  - `phase7-verify/integration_test.go` — every scenario's expected `warnings[]` now includes `non_default_tls_trust` because the integration harness sets `MACPROVIDER_VERIFY_TLS_CA_FILE`.
  - `phase7-verify/schemas/output.schema.json` — `non_default_tls_trust` enum branch added in all 3 result contexts.
  - `specs/SPEC-015-receipts.md` — v0.3.4 additive bump; §10.4.2 `warnings[]` taxonomy gains `non_default_tls_trust`.

## What this change does (operator summary — NOT the audit answer)

Two v1.0.1-followup bugs bundled:
- **#128 (MEDIUM security)**: `MACPROVIDER_VERIFY_TLS_CA_FILE` silently widens TLS trust when honored. No warning, no log, no `--explain` notice. Combined with a public-DNS attacker-controlled coordinator host (private-coordinator deny from PR #124 only blocks the localhost / RFC1918 variant), the verifier silently trusts the attacker's pubkey response.
- **#126 (LOW cosmetic)**: `--coordinator` private/loopback rejection exits 70 (software) instead of 64 (usage) per SPEC-015 §10.4.3.

The fix introduces `nonDefaultTLSTrustWarning()` mirroring
`extraTLSRootsFromEnv()`'s successful-augmentation predicate (file
readable + `AppendCertsFromPEM` returns true). Resolve() prepends
this warning when the predicate fires. The exit-code fix adds an
exported `ErrPrivateCoordinatorDenied` sentinel; `normalizeCoordinator`
wraps it with `fmt.Errorf("%w: …")`; cli.exitForError recognizes via
`errors.Is`.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Warning-emission correctness
- `nonDefaultTLSTrustWarning()` re-reads the env var AND re-reads
  the file AND re-calls `x509.SystemCertPool` AND re-calls
  `AppendCertsFromPEM`. This is intentional duplication of
  `extraTLSRootsFromEnv` (the comment names it). Is the duplication
  load-bearing or fragile?
  - Risk: if `extraTLSRootsFromEnv` ever changes its predicate
    (e.g. adds a new way to augment the pool) the warning will go
    stale.
  - Alternative: have `extraTLSRootsFromEnv` return `(pool, caPath)`
    where caPath is non-empty IFF augmentation succeeded; both the
    pool installer and the warning emitter consult the same return.
  - Recommend one or the other. (The current duplication is the
    minimal-change shape; the unified return is the
    single-source-of-truth shape.)
- The warning is added to `warnings` in Resolve() at the top, BEFORE
  the explicit-pubkey / cache / live branches diverge. So every
  branch carries it forward. Confirm no branch resets or replaces
  the slice.

### CODE-2. Error sentinel + exit mapping
- `ErrPrivateCoordinatorDenied` is exported from `resolver/`. The
  CLI imports `resolver` only for this sentinel. Confirm the import
  is alphabetical and consistent with the other resolver imports
  in the codebase.
- `exitForError` uses `errors.Is(err, resolver.ErrPrivateCoordinator-
  Denied)`. The wrap site in `normalizeCoordinator` is
  `fmt.Errorf("%w: …", ErrPrivateCoordinatorDenied, …)` so `errors.Is`
  matches. Confirm the wrap depth doesn't get lost as the error
  propagates through `Resolve → verify.Verify → run → exitForError`
  call chain. (Each layer either returns the err verbatim or wraps
  it with %w; trace through verify.Verify.)
- The new case in `exitForError` is placed BEFORE the `formatErr`
  case. Order matters only if the same error could match multiple
  branches; here ErrPrivateCoordinatorDenied is structurally
  distinct from `UsageError` / `InputFormatError`. Confirm.

### CODE-3. Test fidelity
- The new resolver tests use `t.Setenv("MACPROVIDER_VERIFY_TLS_CA_FILE", …)`.
  TestMain sets `MACPROVIDER_VERIFY_ALLOW_PRIVATE_COORDINATOR=1`
  globally — does the t.Setenv unset behavior interact safely
  (t.Setenv restores at teardown). Confirm.
- `writeFakeCAPEM` generates a real P-256 self-signed cert at
  runtime. The cert is never trust-validated — only its DER must be
  well-formed so `AppendCertsFromPEM` accepts it. Worth a comment
  pinning this expectation.
- `TestCLIPrivateCoordinatorExitsUsage` calls `t.Setenv` to clear
  the escape-hatch BEFORE running. Confirm t.Setenv restores it at
  teardown so adjacent tests aren't affected.
- Integration test changes: every scenario's `warnings[]` grew by
  one entry. Is there any scenario the env var ISN'T set for that
  should NOT have grown? Trace: `MACPROVIDER_VERIFY_TLS_CA_FILE=` is
  set at line ~357 in the env-prepend block, which runs for every
  case. So all 10 cases correctly grow. Confirm.

### CODE-4. Schema enum sites
- `output.schema.json` has 3 contexts (valid / invalid / inconclusive
  result schemas). Each context's `warnings[]` allOf branch needs
  the new enum value. `grep` confirms 3 additions. Confirm no other
  schema site needs updating.

### CODE-5. SPEC v0.3.4 wording
- SPEC-015 v0.3.4 is an ADDITIVE patch bump on the LOCKED v0.3.3.
  The change-log entry says "preserves wire shape" — confirm by
  reading the new §10.4.2 table row: only adds a new enum value and
  its associated fields; no existing row touched.
- The new row uses `ca_file_path` (snake_case) consistent with
  other `warnings[]` field names. Confirm.

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
`specs/126_128_PHASE7_VERIFY_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
