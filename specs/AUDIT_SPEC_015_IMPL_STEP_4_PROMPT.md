# AUDIT_SPEC_015_IMPL_STEP_4 - Non-streaming receipt header emission

You are auditing the implementation branch for BUILD_SPEC_015 Step 4 in
`/Users/augstar/macprovider-poc-spec015-step02`.

## Normative sources

- `specs/BUILD_SPEC_015_IMPL_PROMPT.md` Step 4.
- `specs/SPEC-015-receipts.md` v0.1.3, especially §6, §6.4, §7.4,
  AC-4, AC-5, AC-6, AC-7, AC-8, AC-12, and AC-15.
- `specs/SPEC-001-phase3-binary.md` v1.6 for receipt-key publication shape.
- `phase3-binary/Sources/MacProviderCore/Config.swift`.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`.
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`.
- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`.
- `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift`.
- `phase3-binary/Sources/macprovider-cli/InMemoryReceiptKeyStore.swift`.
- `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptKeyStoreTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ServeCommandTests.swift`.
- `phase3-binary/implementation-notes.html`.

## Scope under audit

Step 4 is limited to Swift provider non-streaming HTTP response emission:

1. Wire `ReceiptBuilder` into successful non-streaming
   `/v1/chat/completions` responses.
2. Emit `X-MacProvider-Receipt` before the JSON body when a receipt is
   constructed successfully.
3. Emit null-usage receipts for the `model_not_loaded` error path with
   `tokens_out = 0`, empty content, and `finish_reason = "error"`.
4. Omit receipts without failing for SPEC-015 §6.4 omission cases that apply
   in this step: no keypair/provider ID/receipt builder and streaming.
5. Keep streaming/SSE behavior byte-stable and free of all
   `X-MacProvider-*` headers.
6. Preserve the v0.1.x feature-flag rollout: receipt emission is off by
   default and requires explicit opt-in.

No auth-frame publication, coordinator parsing, gateway forwarding, Go
verifier, receipt-status accounting, or locked-spec edits should land in this
step.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'HTTPServerReceiptTests|ServeCommandTests|ReceiptBuilderTests|ReceiptKeyStoreTests'
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary
```

## Audit lenses

### Code auditor

- Verify non-streaming success responses call receipt construction after the
  model completion is known and before the JSON response body is written.
- Verify `X-MacProvider-Receipt` is attached only to JSON/non-streaming
  responses and never to streaming/SSE responses.
- Verify successful receipts use the actual completion content, finish reason,
  completion-token count, TTFT milliseconds, and Unix timestamp.
- Verify `model_not_loaded` uses the null-usage error output object:
  `content = ""`, `tool_calls = null`, `finish_reason = "error"`,
  `tokens_out = 0`.
- Verify response/header helpers preserve existing JSON and SSE headers except
  for the new opt-in receipt header on non-streaming JSON paths.

### Security auditor

- Verify response-time signing does not generate keys on demand; startup
  opt-in may create/load the key, but missing current key at response time
  must omit the receipt rather than minting a new identity.
- Verify receipt emission is feature-flagged off by default through config,
  environment, and CLI layers.
- Verify private receipt keys are not logged, serialized into headers, exposed
  in response bodies, or made available to tests except via deterministic
  in-memory/fixed-key doubles.
- Verify receipt header size is bounded at 4096 bytes and oversized headers
  fail closed without writing a partial response.
- Verify no streaming path or error path introduces a new
  `X-MacProvider-*` header that could leak receipt status or identity.

### Architect auditor

- Verify Step 4 preserves the clean-room and step boundary: no coordinator,
  gateway, auth-frame, Go verifier, or locked-spec mutation.
- Verify `ReceiptBuilder`/`ReceiptKeyStoring` remain injectable and unit tests
  do not require live Keychain access.
- Verify sendability/concurrency changes are locally justified and do not hide
  unsafe shared mutable state.
- Verify the implementation remains compatible with later Step 5 verifier work
  and Step 6 coordinator publication without needing canonicalization rewrites.
- Verify model-swap violation handling remains unchanged: model mismatch must
  still produce the existing error behavior and no receipt.

## Severity contract

Report findings with severities:

- `CRITICAL`: writes unverifiable receipts, exposes private key material,
  attaches receipts to streaming responses, or breaks existing HTTP response
  correctness in a way that can corrupt bodies/headers.
- `HIGH`: signs with an on-demand/new response-time key, emits receipts when
  the feature flag is disabled, omits required non-streaming/null-usage
  receipts, writes headers after body bytes, or fails to enforce the 4096-byte
  header bound.
- `MEDIUM`: incomplete §6.4 omission handling, missing direct tests for a Step
  4 acceptance criterion, concurrency/sendability design that will become a
  Swift 6 issue, or architecture that blocks Step 5/6.
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
