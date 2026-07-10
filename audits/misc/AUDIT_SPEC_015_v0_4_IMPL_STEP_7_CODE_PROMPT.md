# AUDIT_SPEC_015_v0_4_IMPL_STEP_7_CODE_PROMPT

You are the Codex code audit lane for SPEC-015 v0.4 implementation Step 7.

Scope: review the current worktree diff for product disclosures and operator
diagnostics. Do not modify files.

Primary files:

- `phase5-gateway/internal/router/disclosure.go`
- `phase5-gateway/internal/router/pages.go`
- `phase5-gateway/internal/router/server_test.go`
- `phase5-gateway/internal/router/pages_test.go`
- `phase5-gateway/internal/router/templates/docs.md`
- `frontdoor/console/index.html`
- `phase4-coordinator/internal/billing/endpoints.go`
- `phase4-coordinator/internal/billing/endpoints_test.go`
- `phase4-coordinator/internal/billing/store.go`
- `specs/SPEC-006-buyer-api.md`
- `implementation-notes-spec-015-v0-4.md`

Requirements to audit:

1. `/v1/models tier1_disclosure` includes the v0.4 model-verification limit
   and cannot be overridden by upstream coordinator disclosure fields.
2. Account/docs/console/spec disclosure surfaces remain in parity and state
   that v0.4 verifies the provider-reported request-start model hash against
   the route-time catalog snapshot, but does not detect provider falsification
   of its own loaded-model hash measurement.
3. Provider earnings responses expose provider-facing v0.4 receipt rejection
   reason codes without changing existing provider-token authorization or
   rate-limit behavior.
4. Operator provider-list diagnostics expose reason codes plus
   digests/fingerprints and remain bounded for existing pagination limits.
5. SQLite cursor lifetimes avoid `MaxOpenConns(1)` deadlocks when diagnostics
   queries run after provider-list scans.
6. Tests are meaningful and cover the changed behavior, including disclosure
   parity, provider-visible reasons, redaction, and cursor ordering.

Report only findings that are real bugs or material test gaps. Use severity
Critical, High, Medium, Low. Include file/line evidence and exact remediation.
End with counts: critical/high/medium/low.
