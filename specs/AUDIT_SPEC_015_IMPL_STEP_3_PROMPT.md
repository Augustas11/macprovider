# AUDIT_SPEC_015_IMPL_STEP_3 — Receipt canonicalization and signing

You are auditing the implementation branch for BUILD_SPEC_015 Step 3 in
`/Users/augstar/macprovider-poc-spec015-step02`.

## Normative sources

- `specs/BUILD_SPEC_015_IMPL_PROMPT.md` Step 3.
- `specs/SPEC-015-receipts.md` v0.1.3, especially §3, §4, §5, §6, §13,
  AC-4, AC-5, AC-6, AC-7, and AC-12.
- `phase3-binary/Sources/MacProviderCore/JSONValue.swift`.
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`.
- `phase3-binary/Sources/macprovider-cli/JSONValueJCS.swift`.
- `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`.
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift`.
- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`.
- `phase3-binary/Tests/macprovider-cliTests/PromptCanonicalizerTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/OutputCanonicalizerTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptTestSupport.swift`.
- `phase3-binary/implementation-notes.html`.

## Scope under audit

Step 3 is limited to Swift receipt canonicalization and signing:

1. Preserve the request fields needed for the SPEC-015 16-key prompt object
   without breaking existing serving defaults.
2. Implement prompt canonicalization for the exact 16 top-level keys, absent
   fields as JSON null, five-key message objects, allowed content parts,
   function tools, and tool-call commitment.
3. Implement output canonicalization for the exact 3-key output object.
4. Implement receipt tuple construction and `X-MacProvider-Receipt` header
   payload formatting as `<base64(JCS(T))>.<base64(SIG)>`.
5. Sign the UTF-8 canonical tuple bytes with the provider receipt key and
   expose no network/serve/coordinator/gateway wiring in this step.

No HTTP response header wiring, auth-frame publication, coordinator parsing,
gateway behavior, Go verifier implementation, or locked-spec edits should land
in this step.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'PromptCanonicalizerTests|OutputCanonicalizerTests|ReceiptBuilderTests'
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary
```

## Audit lenses

### Code auditor

- Verify prompt canonicalization emits exactly the §4.2 keys:
  `model`, `messages`, `tools`, `temperature`, `top_p`, `max_tokens`, `stop`,
  `seed`, `response_format`, `tool_choice`, `presence_penalty`,
  `frequency_penalty`, `logit_bias`, `logprobs`, `top_logprobs`, and `n`.
- Verify absent committed prompt fields become JSON null and existing runtime
  defaults are not substituted into the receipt hash.
- Verify message objects contain exactly `role`, `content`, `name`,
  `tool_call_id`, and `tool_calls`.
- Verify content strings normalize CRLF and bare CR to LF before JCS string NFC
  normalization, and content arrays preserve allowed part shapes.
- Verify output canonicalization emits exactly `content`, `tool_calls`, and
  `finish_reason`, with allowed finish-reason validation.
- Verify known-good prompt/output/null-usage hash fixtures are pinned by tests.

### Security auditor

- Verify tool-call `function.arguments` are committed byte-for-byte as a JSON
  string and are not parsed/re-serialized before hashing.
- Verify tuple signature input is exactly UTF-8 `JCS(T)` bytes and the header
  uses standard padded base64 for both tuple and signature with one ASCII `.`
  separator.
- Verify `provider_pubkey` is derived from the signing key, base64-encoded, and
  included in the signed tuple.
- Verify non-ASCII `model_id`, negative integer fields, unsupported finish
  reasons, and non-finite JSON/JCS numbers are rejected before signing.
- Verify private key material is not logged, serialized into the tuple, written
  to files, or exposed in tests beyond deterministic in-memory/fixed-key test
  doubles.

### Architect auditor

- Verify Step 3 remains a narrow pure-build boundary and is injectable through
  `ReceiptKeyStoring`, without forcing live Keychain access in unit tests.
- Verify the added raw JSON capture is scoped to receipt hashing needs and does
  not silently change model validation semantics, model ID case handling, or
  served response behavior beyond preserving content-part text projection.
- Verify the design is usable by Step 4 HTTP response wiring and Step 5 verifier
  work without additional canonicalization rewrites.
- Verify no new package dependencies are introduced.

## Severity contract

Report findings with severities:

- `CRITICAL`: signs different bytes from `JCS(T)`, exposes or persists private
  key material outside the key store/test double, omits a required tuple field,
  or implements out-of-scope wire/coordinator/gateway behavior.
- `HIGH`: wrong prompt/output object shape, default-vs-null hash divergence,
  tool-call arguments not byte-committed, wrong header encoding/separator, or
  missing signature verification coverage.
- `MEDIUM`: incomplete content normalization, missing fixture coverage for an
  acceptance criterion, architecture that blocks Step 4/5, or unclear rejection
  behavior that could produce unverifiable receipts.
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
