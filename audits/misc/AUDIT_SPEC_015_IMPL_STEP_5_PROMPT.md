# AUDIT_SPEC_015_IMPL_STEP_5 - Auth-frame receipt public key publication

You are auditing the implementation branch for BUILD_SPEC_015 Step 5 in
`/Users/augstar/macprovider-poc-spec015-step02`.

## Normative sources

- `specs/BUILD_SPEC_015_IMPL_PROMPT.md` Step 5.
- `specs/SPEC-015-receipts.md` v0.1.3, especially §1.3, §7.2,
  §7.5, §8, AC-2, AC-3, and AC-17.
- `specs/SPEC-001-phase3-binary.md` v1.6 §6.7.1 and §6.7.5.
- `specs/SPEC-002-coordinator.md` v1.4 §7 for the later `/poolz`
  storage/exposure shape.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`.
- `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift`.
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ServeCommandTests.swift`.
- `phase4-coordinator/internal/ws/messages.go`.
- `phase4-coordinator/internal/ws/server.go`.
- `phase4-coordinator/internal/pool/provider.go`.
- `phase4-coordinator/internal/ws/messages_test.go`.
- `phase4-coordinator/internal/ws/server_test.go`.
- `phase3-binary/implementation-notes.html`.
- `phase4-coordinator/implementation-notes.html`.

## Scope under audit

Step 5 is limited to:

1. Swift v2 `auth_request` initial-stage emission of optional
   `provider_receipt_public_key`.
2. Go coordinator parsing of optional `provider_receipt_public_key`.
3. Go in-memory storage of the decoded receipt pubkey on the admitted provider.

No `/poolz` exposure, rotation, gateway forwarding, receipt verification CLI,
audit-log events, new WebSocket control frames, or locked-spec edits should
land in this step.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'CoordinatorClientTests|ServeCommandTests'
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary
cd phase4-coordinator && go test ./internal/ws ./internal/pool
cd phase4-coordinator && go test ./...
```

## Audit lenses

### Code auditor

- Verify Swift emits `provider_receipt_public_key` only on the v2
  `auth_request` initial-stage frame, never on proof-stage.
- Verify Swift omits the field when no receipt public key is available.
- Verify the serve path publishes the public key corresponding to the same
  receipt key store used for response signing.
- Verify Go accepts absent `provider_receipt_public_key` for pre-v1.6
  providers.
- Verify Go accepts a valid standard padded base64 32-byte public key and
  stores the decoded bytes on `pool.Provider`.
- Verify Go rejects invalid base64 and decoded lengths other than 32 bytes.

### Security auditor

- Verify private receipt key bytes are never emitted, logged, stored in
  coordinator structs, or serialized into auth frames.
- Verify the coordinator stores only the decoded public key bytes.
- Verify parser failures are fail-closed for malformed receipt pubkeys and do
  not silently admit a corrupted trust root.
- Verify no new WebSocket control frame or proof-stage echo was introduced for
  receipt-key publication.

### Architect auditor

- Verify Step 5 respects the step boundary: no `/poolz` JSON exposure, no
  rotation logic, no gateway changes, no verifier, and no unrelated locked-spec
  mutation.
- Verify `provider_receipt_public_key` does not collide with existing
  `provider_ecdh_public_key` semantics or Tier-2 key exchange.
- Verify the implementation is compatible with Step 6 `/poolz` exposure and
  Step 7 rotation without needing another auth parser rewrite.
- Verify the binary version bump to `1.6.0` is coherent with SPEC-001 v1.6
  field publication.

## Severity contract

Report findings with severities:

- `CRITICAL`: emits or stores private receipt key material, adds a proof-stage
  receipt key field, introduces a new rotation/control frame, or breaks v2 auth
  admission for valid existing providers.
- `HIGH`: fails to emit the field when configured, emits a malformed key, admits
  invalid malformed pubkeys, rejects absent fields, or stores the wrong bytes on
  the provider.
- `MEDIUM`: missing direct tests for required Step 5 behavior, confusing
  key-type/base64 semantics, binary-version drift, or architecture that blocks
  later `/poolz`/rotation steps.
- `LOW`: style, naming, optional extra coverage, or documentation polish.

The gate to proceed is **0 CRITICAL / 0 HIGH / 0 MEDIUM**. LOW findings may
remain if explicitly justified.

## Expected output

Return:

1. Verdict: `READY` or `FIX REQUIRED`.
2. Counts: `CRITICAL n / HIGH n / MEDIUM n / LOW n`.
3. Findings grouped by code/security/architecture lens, with concrete file and
   line references.
4. Verification commands actually run and their results.
5. Any residual risk.
