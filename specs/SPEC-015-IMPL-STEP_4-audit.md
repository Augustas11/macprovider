# SPEC-015 implementation Step 4 audit

Step: Non-streaming receipt header emission.

Branch/worktree:

- Branch: `impl/spec-015-receipts-runtime`
- Worktree: `/Users/augstar/macprovider-poc-spec015-step02`
- Base: `origin/spec/015-receipts-v0-1` after Steps 0 and 1 landed

## Audit prompt

Checked-in prompt:

- `specs/AUDIT_SPEC_015_IMPL_STEP_4_PROMPT.md`

## Round 1

Tool:

- `omc ask codex`

Artifact:

- `.omc/artifacts/ask/codex-audit-spec-015-impl-step-4-non-streaming-receipt-header-emis-2026-06-22T14-14-29-871Z.md`

Result:

- Verdict: `FIX REQUIRED`
- Counts: `CRITICAL 0 / HIGH 1 / MEDIUM 2 / LOW 0`

Findings:

- `HIGH`: generic inference failures synthesized as `model_not_loaded`
  bypassed null-usage receipt emission.
- `MEDIUM`: `ttft_ms` was measured as request-to-completion latency rather
  than actual first-token latency.
- `MEDIUM`: tests covered helper seams but did not exercise the real
  `/v1/chat/completions` handler path.

Fixes:

- Generic inference failures now route through the same null-usage API-error
  receipt path.
- `ModelRuntime.complete(_:)` records first non-empty token emission and
  returns `CompletionResult.ttftMilliseconds`.
- Raw-socket NIO handler tests exercise successful receipt emission, missing
  key omission, null-usage error emission, and streaming header omission.

## Round 2

Tool:

- `omc ask codex`

Artifact:

- `.omc/artifacts/ask/codex-audit-spec-015-impl-step-4-non-streaming-receipt-header-emis-2026-06-22T14-34-33-958Z.md`

Result:

- Verdict: `FIX REQUIRED`
- Counts: `CRITICAL 0 / HIGH 1 / MEDIUM 1 / LOW 0`

Findings:

- `HIGH`: an early non-streaming `model_not_loaded` validation failure before
  the async request path still wrote an error without a receipt.
- `MEDIUM`: the generic-failure test asserted `ttft_ms == 0`, but SPEC-015
  permits non-negative elapsed error latency.

Fixes:

- The early parsed-request API-error catch now constructs a null-usage receipt
  for non-streaming `model_not_loaded` before writing the JSON error.
- The real-server regression asserts non-negative `ttft_ms` and adds a direct
  early-validation `model_not_loaded` receipt test.

## Round 3

Tool:

- `omc ask codex`

Artifact:

- `.omc/artifacts/ask/codex-audit-spec-015-impl-step-4-non-streaming-receipt-header-emis-2026-06-22T14-40-09-693Z.md`

Result:

- Verdict: `READY`
- Counts: `CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0`

Auditor verification evidence:

- `git diff --check`: passed, no whitespace errors.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'HTTPServerReceiptTests|ServeCommandTests|ReceiptBuilderTests|ReceiptKeyStoreTests'`: passed, 31 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary`: passed, 470 tests, 7 skipped integration-gated tests, 0 failures.

Local verification evidence:

- `git diff --check`: passed, no whitespace errors.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'HTTPServerReceiptTests|ServeCommandTests|ReceiptBuilderTests|ReceiptKeyStoreTests|ServingKnobsConfigTests'`: passed, 55 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary`: passed, 470 tests, 7 skipped integration-gated tests, 0 failures.

Residual risk:

- Live Keychain behavior is not exercised by Step 4 tests; coverage remains via
  query-shape tests plus in-memory and fixed-key stores. Step 2 owns Keychain
  lifecycle semantics.

Gate:

- Step 4 gate satisfied: 0 critical / 0 high / 0 medium findings.
