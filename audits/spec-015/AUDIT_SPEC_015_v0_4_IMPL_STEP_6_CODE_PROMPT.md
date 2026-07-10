# AUDIT_SPEC_015_v0_4_IMPL_STEP_6_CODE_PROMPT

You are the Codex code audit lane for SPEC-015 v0.4 implementation Step 6.

Scope: review the current worktree diff for provider v0.4 settlement receipt
issuance and coordinator WS ingestion plumbing. Do not modify files.

Primary files:

- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift`
- `phase4-coordinator/internal/ws/messages.go`
- `phase4-coordinator/internal/ws/relay.go`
- `phase4-coordinator/internal/ws/messages_test.go`
- `phase4-coordinator/internal/ws/relay_test.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `implementation-notes-spec-015-v0-4.md`

Requirements to audit:

1. Swift provider signs the strict SPEC-015 §N.1 v0.4 tuple with exactly the
   required fields and `signature_key_alg == "Ed25519"`.
2. `model_hash` is non-null 64-character lowercase hex from request-start
   loaded model state for v0.4 settlement receipts.
3. Non-streaming and streaming successful terminal paths return a receipt and
   coordinator ingests that receipt through the Step 5 internal path.
4. Settlement route metadata contains only required route/catalog/deadline
   material and no raw credentials, bearer tokens, prompts, or request bodies.
5. Existing v0.3 receipt behavior remains compatible when settlement metadata
   is absent.
6. Tests are meaningful and cover the changed behavior.

Report only findings that are real bugs or material test gaps. Use severity
Critical, High, Medium, Low. Include file/line evidence and exact remediation.
End with counts: critical/high/medium/low.
