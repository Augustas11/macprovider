# Issue #126 + #128 phase7-verify hardening — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit (code / security /
architect) of the bundled #126 + #128 phase7-verify hardening. Stay
narrowly in your lane.

**This lane has authority to approve the SPEC-015 v0.3.4 bump on the
locked v0.3.3 baseline.** The lock memo says v0.3.3 was "READY TO LOCK"
on 2026-06-24 — your verdict on whether v0.3.4 is a legitimate
additive patch (vs. a wire-shape change requiring a v0.4 major bump)
is the gating decision.

## Branch / commit
- Branch: `fix/phase7-verify-tls-warn-and-exit64`
- Worktree: `../macprovider-126-128-phase7-verify-hardening`
- Files in scope (`git diff origin/main`).

## What this change does (operator summary — NOT the audit answer)

Bundled fix for two v1.0.1-followup issues:
- **#128** (MEDIUM security): silent TLS trust widening when
  `MACPROVIDER_VERIFY_TLS_CA_FILE` is honored.
- **#126** (LOW cosmetic): private-coordinator rejection exits 70
  instead of 64.

Both are post-PR-#124 follow-ups (merge commit 99d0c1e). The bundle
ships SPEC-015 v0.3.4 (additive patch on v0.3.3 LOCKED) + IMPL +
schema + tests + integration-test updates.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Is v0.3.4 a legitimate additive patch on the locked v0.3.3?
- SPEC-015 v0.3.3 was locked on 2026-06-24 via 3-lane codex audit
  (`specs/SPEC-015-v0-3-audit.md`). The lock memo characterizes
  v0.3 as "changes the wire shape (7-field tuple → 9-field tuple,
  adding `model_hash` and `receipt_version`)" — a MAJOR bump.
- v0.3.4 changes:
  - §10.4.2 `warnings[]` enum gains `non_default_tls_trust`.
  - Field `ca_file_path` (string) on the new variant.
  - Schema enum at `phase7-verify/schemas/output.schema.json` adds
    a new branch in each of the 3 result contexts.
- Wire shape: receipt tuple unchanged. Verifier output JSON gains
  a new enum value; pre-v0.3.4 consumers that ignore unknown
  `kind` values are unaffected.
- Is this an ADDITIVE patch (v0.3.4) or a wire-shape change
  requiring v0.4? Recall the project's convention: SPEC-002 v1.4.1
  shipped an additive `auth_state` field as patch; SPEC-015 v0.3.4
  shipping a new enum value should follow the same convention.
- Verify: any consumer downstream that VALIDATES strictly against
  the v0.3.3 schema would reject the new kind. The schema lives
  IN this repo and ships WITH the verifier binary, so it's
  versioned together. Cross-repo consumers? (Likely none — the
  schema is internal.)

### ARCH-2. The `nonDefaultTLSTrustWarning` helper — module boundary?
- The helper duplicates `extraTLSRootsFromEnv`'s augmentation
  predicate (file read + PEM parse + AppendCertsFromPEM). Two
  identical predicates is a single-source-of-truth violation. Is
  the architectural correct shape:
  - **A** — `extraTLSRootsFromEnv` returns `(pool, caPath string)`;
    `configuredClient` consumes the pool, ignores caPath; Resolve()
    consults caPath via a different code path (still duplicated,
    just refactored).
  - **B** — Resolve() reads the env var itself, builds the warning,
    AND constructs the augmented http.Client itself. configured-
    Client becomes a helper consuming a pre-built pool.
  - **C** — Keep current shape (two predicates, comment explains
    why). Acceptable for a low-frequency hot path; the cost of
    duplicated env-var read is negligible.
- Recommend the right shape. The author chose (C) explicitly in
  the comment.

### ARCH-3. Sentinel error placement
- `ErrPrivateCoordinatorDenied` is exported from `resolver/` and
  consumed by `cli/`. The other sentinels in the resolver package
  (`ErrFetchFailed`, `ErrRedirectOffHost`, etc.) are also exported
  and form the resolver's public error contract. Is the new
  sentinel at the right altitude?
- Alternative: put the sentinel in `cli/` (since it's only the CLI
  that maps the error to an exit code). That would be a layering
  inversion — the resolver shouldn't import CLI's error type. The
  current placement (resolver owns the sentinel) is right.

### ARCH-4. Integration test surface change
- Every integration scenario's expected `warnings[]` grew by one
  entry. The test fixture sets `MACPROVIDER_VERIFY_TLS_CA_FILE` to
  the mock CA path (line ~357) — necessary for the integration's
  TLS handshake to work. Is this an architectural smell (every
  test now warns about its own setup) or a feature (the verifier
  honestly surfaces the test harness's non-default trust posture)?
- Note: this WAS the bug. Pre-fix, the integration tests would
  have ALSO produced false `valid` results without surfacing the
  trust widening. The new warnings prove the fix works in the
  integration harness, not just unit tests.

### ARCH-5. Doc-trail
- SPEC-015 v0.3.4 change-log entry references issue #128. Should
  it also reference issue #126 (the exit-code fix in the same PR)?
  Looking at v0.3.4 carefully: the exit-code fix is NOT a SPEC
  change (SPEC-015 §10.4.3 already says private-coordinator should
  be 64; the implementation was wrong, not the spec). So the
  change-log entry correctly references only #128. Confirm.
- Should the v0.3.4 bump warrant adding the cli.go ErrPrivate-
  CoordinatorDenied mapping to SPEC-015 §10.4.3 normatively (e.g.
  "exit 64 (EX_USAGE) — includes private-coordinator rejection")?
  Or is the spec already implicitly clear and the implementation
  fix doesn't need spec text?

### ARCH-6. Lock criteria for SPEC-015 v0.3.4
- Recall v0.3.3 locked via 3-lane codex audit returning
  `READY TO LOCK` 0/0/0/0 across all three lenses.
- v0.3.4 is additive on the locked baseline. The 3-lane audit
  approach here is: code + security + architect EACH verdict
  READY TO MERGE on the v0.3.4 PR. If all three converge to 0
  CRITICAL / 0 HIGH / 0 MEDIUM, v0.3.4 is locked-equivalent.
- Confirm this is the right lock criterion for an additive patch
  (vs. a full re-lock round).

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
`specs/126_128_PHASE7_VERIFY_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND v0.3.4 is a legitimate additive patch
on v0.3.3, end with:
`VERDICT: architect lane READY TO MERGE — SPEC-015 v0.3.4 additive bump approved`
