# SPEC-015 IMPL Step 9 Audit Summary

## Scope

Provider and coordinator audit log emission for SPEC-015 Section 11 events:
`receipt_issued`, `receipt_omitted`, and `receipt_rotation_detected`.

## Implementation Evidence

- `phase3-binary/Sources/macprovider-cli/ReceiptAudit.swift` defines the five SPEC-015 omission reasons and emits newline-delimited structured JSON through the provider's existing stderr operational event sink.
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` emits `receipt_issued` only when a non-streaming response writes a receipt, and emits `receipt_omitted` for streaming, pre-v1.6/no-builder, no keypair, model-swap violation, and explicit buyer pre-token cancellation.
- Unrelated non-null-usage API errors are not mislabeled as `pre_token_cancel`; they return the normal error envelope without receipt audit emission.
- `phase4-coordinator/internal/pool/provider.go` creates a rotation audit event only after a changed pending receipt pubkey commits on `state_update`, then invokes the emitter after releasing `Registry.mu`.
- `phase4-coordinator/internal/audit/receipt_rotation.go` writes `receipt_rotation_detected` rows through the existing audit store with `provider_id`, base64 `old_pubkey`, base64 `new_pubkey`, and `rotated_at` only.
- `phase4-coordinator/cmd/coordinator/main.go` drains rotation audit events through a bounded cap-64 queue and shutdown drain path.

## Validation

```bash
cd phase3-binary && swift test --filter ReceiptAuditTests --filter HTTPServerReceiptTests
cd phase3-binary && swift test
cd phase4-coordinator && go test ./internal/audit ./internal/pool ./internal/ws -run 'TestEmitReceiptRotationWritesAuditRow|TestProviderAuthV2ReceiptRotationDetectedAuditEvent|TestProviderAuthV2ReceiptRotationMovesPriorPubkeyToPrevious' -count=1
cd phase4-coordinator && go test ./... -count=1
git diff --check
```

Validation passed. The full Swift suite executed 506 tests with 7 expected integration-gated skips and 0 failures. The full coordinator Go suite passed.

## Auditor Results

- Code auditor: first pass found 0 Critical / 1 High / 1 Medium; fixes narrowed `pre_token_cancel` to explicit `buyer_cancelled` and added handler-level audit sink tests. Re-audit: 0 Critical / 0 High / 0 Medium.
- Security auditor: 0 Critical / 0 High / 0 Medium.
- Architecture auditor: 0 Critical / 0 High / 0 Medium.

## Final Verdict

0 Critical / 0 High / 0 Medium.
