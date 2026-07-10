# AUDIT_SPEC_015_v0_4_IMPL_STEP_2_PRODUCT_PROMPT

You are auditing Step 2 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/route_snapshot_test.go`

Audit as a product design critic. Determine whether the route snapshot slice
advances the full-product trust floor without overstating buyer protection or
shipping a beta-only shortcut.

Required checks:

1. Step 2 is framed as full-product settlement prerequisite infrastructure,
   not as a temporary beta gate or marketing claim.
2. The implementation does not imply SPEC-022 enforce-mode money settlement is
   live before later steps wire provider receipts, verifier outcomes, and money
   movement.
3. Streaming/agentic tooling remains first-class: streaming dispatch paths are
   covered by the same pre-dispatch snapshot hook as non-streaming paths.
4. Buyer/provider/operator claims remain honest about the trust model: route
   snapshot binds catalog expectation and provider-reported hash, but cannot
   independently prove local model measurement.
5. The documented placeholders (`observe` mode, policy version, null generation
   id) are acceptable product language for this implementation slice.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
