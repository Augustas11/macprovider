# Issue #126 + #128 phase7-verify hardening architect-lane audit

Audited branch: `fix/phase7-verify-tls-warn-and-exit64`

Scope: `git diff origin/main` for SPEC-015 v0.3.4, verifier output schema, resolver/CLI layering, and integration-test contract updates.

CRITICAL (0):
  None.

HIGH (0):
  None.

MEDIUM (0):
  None.

LOW (0):
  None.

QUESTIONS (0):
  None.

ARCHITECT NOTES:
  ARCH-1. SPEC-015 v0.3.4 is a legitimate additive patch on the locked v0.3.3 baseline, not a v0.4 wire-shape change.
      Evidence: specs/SPEC-015-receipts.md:3
      Evidence: specs/SPEC-015-receipts.md:6
      Evidence: specs/SPEC-015-receipts.md:14
      Evidence: specs/SPEC-015-receipts.md:17
      Evidence: specs/SPEC-015-receipts.md:2245
      Evidence: phase7-verify/schemas/output.schema.json:117
      Evidence: phase7-verify/schemas/output.schema.json:397
      Evidence: phase7-verify/schemas/output.schema.json:651
      Rationale: v0.3.4 adds only the `non_default_tls_trust` warning variant with `ca_file_path`; the receipt tuple remains the locked v0.3 9-field tuple. Strict validators pinned to the v0.3.3 schema would reject the new warning kind, but the schema is repo-internal and ships with the verifier binary. This matches the repo's additive-patch convention for SPEC-002 v1.4.1's optional `auth_state` field.

  ARCH-2. The current `nonDefaultTLSTrustWarning` boundary is acceptable; choose shape C.
      Evidence: phase7-verify/internal/resolver/resolver.go:123
      Evidence: phase7-verify/internal/resolver/resolver.go:401
      Evidence: phase7-verify/internal/resolver/resolver.go:407
      Evidence: phase7-verify/internal/resolver/resolver.go:430
      Evidence: phase7-verify/internal/resolver/resolver.go:440
      Rationale: `Resolve()` owns `warnings[]`; `configuredClient()` owns HTTP transport construction. Duplicating the env-var/readable-PEM/successful-AppendCerts predicate is a small, deliberate cost on a rare operator-controlled path and avoids pushing warning construction into transport setup or client construction into `Resolve()`.

  ARCH-3. `ErrPrivateCoordinatorDenied` is placed at the right altitude.
      Evidence: phase7-verify/internal/resolver/resolver.go:69
      Evidence: phase7-verify/internal/resolver/resolver.go:82
      Evidence: phase7-verify/internal/resolver/resolver.go:500
      Evidence: phase7-verify/internal/cli/cli.go:24
      Evidence: phase7-verify/internal/cli/cli.go:500
      Rationale: private-coordinator denial is resolver policy surfaced through the resolver package's public error contract, alongside existing resolver sentinels. Keeping the sentinel in `cli/` would invert the dependency direction.

  ARCH-4. The integration warning expansion is a feature, not a smell.
      Evidence: phase7-verify/integration_test.go:127
      Evidence: phase7-verify/integration_test.go:133
      Evidence: phase7-verify/integration_test.go:188
      Evidence: phase7-verify/integration_test.go:200
      Evidence: phase7-verify/integration_test.go:360
      Rationale: the harness intentionally sets `MACPROVIDER_VERIFY_TLS_CA_FILE` to trust the mock coordinator CA. The expanded expectations prove the verifier now surfaces that non-default trust posture in every scenario that depends on the widened TLS root.

  ARCH-5. The doc trail is correctly scoped.
      Evidence: specs/SPEC-015-receipts.md:6
      Evidence: specs/SPEC-015-receipts.md:2245
      Evidence: specs/SPEC-015-receipts.md:2282
      Evidence: specs/SPEC-015-receipts.md:2289
      Evidence: specs/SPEC-015-receipts.md:2297
      Rationale: v0.3.4 should reference issue #128 because the TLS warning is the only SPEC change. Issue #126 is an implementation conformance fix: §10.4.3 already classifies invocation problems as exit 64, so adding private-coordinator denial text normatively is optional clarification, not required for this additive patch.

  ARCH-6. The lock criterion for v0.3.4 is appropriate.
      Evidence: specs/SPEC-015-v0-3-audit.md:285
      Evidence: specs/SPEC-015-v0-3-audit.md:299
      Evidence: specs/SPEC-015-v0-3-audit.md:325
      Evidence: specs/SPEC-015-receipts.md:21
      Evidence: specs/SPEC-015-receipts.md:37
      Rationale: v0.3.3 was the locked baseline after the three-lane audit. Because v0.3.4 is additive on that baseline, convergence from the code, security, and architect lanes at 0 CRITICAL / 0 HIGH / 0 MEDIUM is sufficient lock-equivalent evidence; a full major-version re-lock round is not architecturally required.

VERDICT: architect lane READY TO MERGE — SPEC-015 v0.3.4 additive bump approved
