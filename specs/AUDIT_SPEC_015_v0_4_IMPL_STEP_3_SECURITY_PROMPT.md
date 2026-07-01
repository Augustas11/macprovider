# AUDIT_SPEC_015_v0_4_IMPL_STEP_3_SECURITY_PROMPT

You are auditing Step 3 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex security lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7 and trust caveats.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 3 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Required checks:

1. Output/usage evidence persistence cannot be silently rewritten for the same
   `(request_id, attempt_n, provider_id)` identity.
2. Provider-supplied usage, output JSON, tool-call fragments, or terminal
   status cannot produce a verified-looking settlement record without
   coordinator reconstruction and strict validation.
3. No provider private keys, bearer tokens, raw prompts beyond existing
   request-log behavior, or unrelated secrets are newly persisted.
4. Streaming parser behavior cannot be abused with malformed SSE, duplicate
   chunks, incomplete tool calls, or disconnect timing to create overlapping
   creditable ranges.
5. The implementation does not wire SPEC-022 buyer debit, provider credit,
   payout readiness, or gateway money movement.
6. Product/security claims remain honest: this evidence binds coordinator
   observed output/usage to later receipts but still does not prove a malicious
   provider cannot falsify local model measurement.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
