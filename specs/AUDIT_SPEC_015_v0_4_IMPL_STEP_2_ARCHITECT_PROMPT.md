# AUDIT_SPEC_015_v0_4_IMPL_STEP_2_ARCHITECT_PROMPT

You are auditing Step 2 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex architect lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/jcs.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`

Required checks:

1. The route snapshot store is the right durability boundary for later
   SPEC-022 settlement joins and does not overload request_log semantics.
2. The pre-dispatch hook placement composes with HTTP, WS, streaming, retry,
   and failover state machines without duplicate or missing attempt identities.
3. Catalog material is captured as an immutable route-time snapshot and has a
   clear path for later receipt verifier / settlement joins.
4. Prompt hash canonicalization is placed in an acceptable module and does not
   introduce illegal cross-module imports or reuse test-only code.
5. Step 2 leaves later responsibilities to Step 3-6: terminal/output/usage
   canonicalization, provider v0.4 issuance, verifier ingestion, and SPEC-022
   enforce-mode money movement.
6. Known placeholders (`provider_generation_id: null`,
   `route_snapshot_policy_version: spec022-prereq-v0`,
   `route_snapshot_mode: observe`) are acceptable for Step 2 and documented
   clearly enough for later migration.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
