# AUDIT_SPEC_015_v0_4_IMPL_STEP_2_CODE_PROMPT

You are auditing Step 2 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex code lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 2.
- `phase4-coordinator/internal/billing/jcs.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/route_snapshot_test.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/route_snapshot_test.go`

Required checks:

1. A `route_snapshot_v1` record is created after provider-specific body rewrite
   succeeds and before provider dispatch for HTTP, WS non-streaming, and
   streaming attempts.
2. `billing.RouteSnapshot.Value()` has exactly the SPEC-015 §N.2 field set and
   no extras; persisted digest is `sha256(UTF-8(JCS(route_snapshot_v1)))`.
3. `attempt_n` is zero-based and increments exactly once per provider dispatch,
   including retry/failover attempts.
4. Route-time model/catalog material is captured from the active verified
   catalog and provider route entry without post-dispatch mutation.
5. Prompt hash canonicalization matches the provider prompt canonicalizer shape
   well enough for Step 2 and handles tools/tool calls/optional fields.
6. Covered snapshot failures fail closed before contacting a provider; legacy
   non-covered routes are not accidentally broken.
7. Tests cover before-dispatch persistence, immutable rewrite rejection, digest
   sensitivity, and retry attempt numbering.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
