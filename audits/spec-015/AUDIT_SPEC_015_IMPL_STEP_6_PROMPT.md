# AUDIT_SPEC_015_IMPL_STEP_6 — `/poolz` receipt pubkey exposure

You are auditing Step 6 of `specs/BUILD_SPEC_015_IMPL_PROMPT.md` in the
`macprovider-poc` repository. Treat this as a code, security, and architecture
audit. The implementation target is SPEC-015 v0.1.3 Step 6 only: expose
provider receipt public keys on coordinator `/poolz`.

## Scope

Review the working tree diff for these files:

- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/server_test.go`
- `phase4-coordinator/implementation-notes.html`
- this audit prompt

Do not request or inspect `d-inference` source. Do not propose edits to locked
specs. Step 6 intentionally does not implement receipt key rotation mechanics;
it only adds the storage seam and `/poolz` serializer contract required for the
current key and a simulated previous-key grace window.

## Required contract

Verify all of the following:

1. `/poolz` provider rows add `receipt_pubkey` and `receipt_pubkey_prev`
   additively, without removing or renaming existing fields.
2. `receipt_pubkey` is a nullable standard padded base64 string generated from
   the raw 32-byte ed25519 public key captured during v2 auth.
3. Providers that did not publish a SPEC-001 v1.6
   `provider_receipt_public_key` serialize `receipt_pubkey: null` and
   `receipt_pubkey_prev: null` explicitly, not by omission.
4. `receipt_pubkey_prev` is `null` outside the rotation grace window and, when
   present, has the documented shape:
   `{ "pubkey": "<old-base64>", "rotated_at": <unix-seconds>, "expires_at": <unix-seconds> }`.
5. The serializer does not leak raw private key material, tokens, auth proof
   material, or unexported WebSocket connection state.
6. Existing `/poolz` consumers remain compatible with additive fields; legacy
   Tier-1 shape tests still pass except for the new explicit nullable receipt
   fields.
7. Tests cover:
   - v1.6 provider with populated `receipt_pubkey`.
   - pre-v1.6 provider with explicit JSON null receipt fields.
   - simulated previous-key grace-window object with base64 pubkey and Unix
     timestamp fields.

## Verification already run by implementer

- `git diff --check`
- `go test ./internal/ws -run 'Test(PoolzReceiptPubkeyForV16Provider|PoolzReceiptPubkeyNullForPreV16Provider|PoolzReceiptPubkeyPrevShape|PoolzShapeUnchangedForL1Provider|PoolzDefaultOmitsTier2HashFieldsAfterWSAdmission|ProviderAuthV2InitialReceiptPublicKeyAdmitsAndStoresPubkey)' -count=1 -v`
- `go test ./internal/ws ./internal/pool -count=1`
- `go test ./... -count=1` in `phase4-coordinator`

## Output format

Return a concise audit report with separate sections:

- Code findings
- Security findings
- Architecture findings
- Test gaps
- Verdict

For every finding, include severity `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or
`INFO`, with file and line references when possible. The Step 6 implementation
is acceptable only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings. If
you find any CRITICAL/HIGH/MEDIUM issue, provide the exact remediation needed.
