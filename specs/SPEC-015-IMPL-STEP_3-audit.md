# SPEC-015 implementation Step 3 audit

Step: Receipt canonicalization and signing.

Branch/worktree:

- Branch: `impl/spec-015-receipts-runtime`
- Worktree: `/Users/augstar/macprovider-poc-spec015-step02`
- Base: `origin/spec/015-receipts-v0-1` after Steps 0 and 1 landed

## Audit prompt

Checked-in prompt:

- `specs/AUDIT_SPEC_015_IMPL_STEP_3_PROMPT.md`

## Round 1

Tool:

- `omc ask codex`

Artifact:

- `.omc/artifacts/ask/codex-audit-spec-015-impl-step-3-receipt-canonicalization-and-sign-2026-06-22T13-50-09-207Z.md`

Result:

- Verdict: `FIX REQUIRED`
- Counts: `CRITICAL 0 / HIGH 1 / MEDIUM 0 / LOW 0`

Finding:

- `HIGH`: tool-call `function.arguments` used the normal JCS string path, so
  actual decomposed Unicode argument bytes could be NFC-normalized before
  hashing. The fix added a raw/no-NFC JCS string value used only for prompt and
  output tool-call argument strings, plus Unicode regression tests proving
  decomposed and precomposed argument strings hash differently.

## Round 2

Tool:

- `omc ask codex`

Artifact:

- `.omc/artifacts/ask/codex-audit-spec-015-impl-step-3-receipt-canonicalization-and-sign-2026-06-22T13-55-48-028Z.md`

Result:

- Verdict: `READY`
- Counts: `CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0`

Auditor verification evidence:

- `git diff --check`: passed, no whitespace/errors.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter 'PromptCanonicalizerTests|OutputCanonicalizerTests|ReceiptBuilderTests'`: passed, 11 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary`: passed, 450 tests, 7 skipped integration-gated tests, 0 failures.

Residual risk:

- Go cross-implementation receipt verification is intentionally deferred to the
  later verifier step in the build prompt. Step 3 has Swift self-verification
  plus pinned canonical prompt/output hash fixtures.

Gate:

- Step 3 gate satisfied: 0 critical / 0 high / 0 medium findings.
