# AUDIT_SPEC_015_v0_4_IMPL_FULL_CODE_PROMPT

You are the Codex code audit lane for the full SPEC-015 v0.4.2 implementation.

Worktree: `/Users/augstar/macprovider-impl-spec-015-v0-4`
Branch: `impl/spec-015-v0-4-settlement-receipts`

Scope: read-only code review of the full current worktree diff for
`BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Steps 1 through 8.
Do not modify files.

Required reading:

- `CLAUDE.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
- `specs/SPEC-015-receipts.md` v0.4.2, especially §N and AC-43 through AC-71
- `specs/SPEC-015-v0-4-audit.md`
- `specs/SPEC-022-verified-model-settlement.md`
- `implementation-notes-spec-015-v0-4.md`
- `specs/AUDIT_SPEC_015_v0_4_IMPL_STEP_{1,2,3,4,5,6,7,8}.md` where present
- `scripts/verify-spec015-v04-step8.sh`

Primary implementation surfaces:

- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Tests/macprovider-cliTests/*Receipt*Tests.swift`
- `phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift`
- `phase4-coordinator/internal/billing/*settlement*`
- `phase4-coordinator/internal/billing/*route_snapshot*`
- `phase4-coordinator/internal/billing/spec015_v04_acceptance_test.go`
- `phase4-coordinator/internal/buyer/*settlement*`
- `phase4-coordinator/internal/buyer/route_snapshot*`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/ws/*`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase5-gateway/internal/router/*`
- `phase7-verify/internal/verify/settlement*`
- shared SPEC-015 fixture/contract test packages under coordinator, gateway,
  and phase7.

Code audit questions:

1. Does the code implement the strict v0.4 receipt profile without accepting
   v0.1/v0.2/v0.3 receipts as settlement-capable?
2. Are `receipt_version: "4"`, Ed25519 key/fingerprint binding, JCS
   canonicalization, route snapshot digest, output hash, prompt hash, usage
   hash, and terminal-state checks implemented consistently across Swift,
   coordinator, gateway fixture checks, and phase7?
3. Are streaming and non-streaming paths both wired end-to-end without
   requiring non-standard SSE body events?
4. Are route snapshots, output prefixes, usage evidence, receipt ingestion,
   verdict state, and authorization evidence deterministic and resilient to
   retries, failover, duplicates, overlaps, and resubmission?
5. Do tests materially cover AC-43 through AC-71 and the build prompt Step 8
   evidence, including `scripts/verify-spec015-v04-step8.sh`?
6. Is there avoidable duplication, brittle fixture handling, racey ordering, or
   module-boundary coupling that could cause incorrect settlement behavior?
7. Confirm no SPEC-022 money movement or payout readiness is implemented in
   this diff.

Report only real bugs or material test gaps. Use severity Critical, High,
Medium, Low. Include file/line evidence and exact remediation. End with:

Critical: N
High: N
Medium: N
Low: N

Then list validation you ran.
