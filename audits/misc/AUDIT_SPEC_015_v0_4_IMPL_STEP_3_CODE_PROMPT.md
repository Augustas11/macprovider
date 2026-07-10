# AUDIT_SPEC_015_v0_4_IMPL_STEP_3_CODE_PROMPT

You are auditing Step 3 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex code lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7 and AC-43 through AC-71.
- `specs/SPEC-022-verified-model-settlement.md`.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 3.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement_output_test.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/route_snapshot_test.go`

Required checks:

1. `settlement_output_v1` and `usage` canonical objects have exactly the
   SPEC-015 strict fields, stable JCS hashing, and no legacy v0.3 hash input.
2. Terminal states are reconstructed for normal completion, provider error,
   buyer cancellation, gateway timeout, and upstream transport disconnect.
3. Non-streaming and streaming attempts both persist output rows before any
   later receipt could be settlement-capable.
4. Client-facing streaming remains OpenAI-compatible SSE with no non-standard
   receipt frames.
5. Output ranges are half-open, byte-counted after NFC normalization, and
   duplicate/overlap markers are set for non-creditable evidence.
6. Usage source is coordinator-observed or byte-estimated in Step 3; provider
   cross-checking is not accepted until a real coordinator/gateway input/output
   usage cross-check exists, and provider-only usage cannot silently become
   verified settlement evidence.
7. Tests cover strict keys, immutable persistence, overlap marking, retry
   output rows, and streaming reconstruction.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
