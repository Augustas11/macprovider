# AUDIT_SPEC_015_IMPL_STEP_9 - Receipt audit log emission

Audit SPEC-015 Step 9 in `/private/tmp/macprovider-poc-spec015-step02-continue`. Do not edit files.

## Scope

Step 9 is limited to SPEC-015 Section 11 audit events across the provider and coordinator:

1. Provider-side `receipt_issued` events for non-streaming responses that emit a receipt. Event-specific fields are exactly `model_id`, `tokens_out`, `ttft_ms`, and `unix_ts`, with `provider_id` and `request_id` carried by the local event envelope.
2. Provider-side `receipt_omitted` events for `pre_v1_6_binary`, `no_keypair`, `model_swap_violation`, `pre_token_cancel`, and `streaming_request`.
3. Coordinator-side `receipt_rotation_detected` events when a provider reconnect publishes a changed receipt pubkey.
4. No audit log may include a receipt body, `provider_pubkey`, `prompt_hash`, `output_hash`, signature bytes, or the `X-MacProvider-Receipt` header value.
5. The coordinator audit destination must reuse `phase4-coordinator/internal/audit`; the provider may use the existing structured stderr operational event sink because there is no durable provider-side audit store in `phase3-binary`.

## Files to inspect

- `phase3-binary/Sources/macprovider-cli/ReceiptAudit.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Tests/macprovider-cliTests/ReceiptAuditTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift`
- `phase4-coordinator/internal/audit/receipt_rotation.go`
- `phase4-coordinator/internal/audit/receipt_rotation_test.go`
- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/ws/server_test.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `specs/SPEC-015-receipts.md` Section 6.4, Section 11, AC-17

## Validation evidence

Run or verify:

```bash
cd phase3-binary && swift test --filter ReceiptAuditTests
cd phase3-binary && swift test --filter HTTPServerReceiptTests
cd phase4-coordinator && go test ./internal/audit ./internal/pool ./internal/ws -run 'TestEmitReceiptRotationWritesAuditRow|TestProviderAuthV2ReceiptRotationDetectedAuditEvent|TestProviderAuthV2ReceiptRotationMovesPriorPubkeyToPrevious' -count=1
cd phase3-binary && swift test
cd phase4-coordinator && go test ./... -count=1
git diff --check
```

## Findings format

Report only Critical, High, or Medium findings. Include concrete file/line references. Final verdict must state counts as `0 Critical / 0 High / 0 Medium` when clean.

## Severity guide

- Critical: logs receipt body/header/signature/hash material, breaks receipt issuance or rotation publication, writes coordinator audit rows outside the existing audit sink, or changes locked SPEC semantics.
- High: misses one of the five required omission reasons, maps a required omission condition to the wrong reason, emits rotation events before publication is committed, or blocks pre-v1.6/no-key providers that SPEC-015 requires to admit.
- Medium: missing focused tests for event field shape or rotation detection, unbounded coordinator audit emission path, ambiguous provider audit destination, missing implementation notes, or non-deterministic audit payload shape that makes future validation brittle.
