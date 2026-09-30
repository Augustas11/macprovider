Recommendation: **REQUEST CHANGES**. Architectural status: **WATCH**.

### HIGH

1. The 32,768 default depends on unmerged PR #1801

   - [ContinuousBatchScheduler.swift:263](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:263)
   - [config.go:429](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/config/config.go:429)

   Failure scenario: this branch defaults omitted `max_tokens` to 32,768, while its `origin/main` gateway base still reserves and validates only 4,096. If merged first, a no-max request generating over 4,096 tokens can become `invalid_provider_usage` or `stream_output_exceeded`, with incorrect quota/settlement handling instead of a valid completion. PR #1801 is currently open, not merged.

   Fix: rebase/stack this change on merged PR #1801 so the provider budget, gateway reservation, response validation, and SPEC-006 contract land atomically.

### MEDIUM

1. Mid-decode pool exhaustion is incorrectly reported as pre-inference

   - [ContinuousBatchScheduler.swift:3592](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:3592)
   - [ModelRuntime.swift:6274](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6274)

   Failure scenario: eight omitted-max rows may collectively grow beyond the shared 200k-token pool. The allocator safely bounds memory—no direct OOM was found—but an extension failure after tokens were emitted becomes `continuous_batching_block_extension_failed`, then a 503 with `inferenceRan: false`. The relay collapses this to `error_internal`, allowing a retryable provider error and possible provider degradation despite partial inference/output.

   Fix: classify block-extension failure according to whether decoding/output began. Post-decode failures must be inference-ran, non-retryable, non-settling, with relay/coordinator coverage.

2. Explicit over-context requests behave differently between CB and serial paths

   - [ContinuousBatchScheduler.swift:1687](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1687)
   - [ModelRuntime.swift:6525](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6525)

   Failure scenario: CB rejects `prompt + max_tokens > context` with 413, while the serial MLX path validates only prompt length. The same request therefore changes behavior based on batching eligibility, fallback, or operator mode.

   Fix: use one shared prompt-plus-output context validator before either route.

3. Exhausting the implicit 32,768 budget reports `finish_reason: "stop"`

   - [ModelRuntime.swift:5559](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5559)

   Failure scenario: a request omitted `max_tokens`, generates exactly 32,768 tokens, and is terminated by the provider budget. OpenAI-compatible clients receive `stop`, incorrectly indicating natural/model termination and potentially declining to continue.

   Fix: when the scheduler terminates with `.length` from the effective implicit budget, emit `finish_reason: "length"`.

4. The production wiring regression is not covered by an always-running test

   - [PagedKVRuntimeBridgeTests.swift:1680](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift:1680)

   Failure scenario: the only test proving `ModelRuntime` passes the served context into its scheduler skips without the MLX metallib. The direct scheduler test manually supplies `maxRequestTokens`, so removing the production factory wiring could leave the suite green. The new retained-cache rejection branch also lacks a direct allocator-release assertion.

   Fix: add a non-metallib factory/configuration seam covering initial construction and rebuild, plus an allocator-count test proving retained blocks are released on context rejection.

### LOW

1. The “omitted max always fits” contract fails at an exactly-full prompt

   - [ModelRuntime.swift:5420](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5420)
   - [ContinuousBatchSchedulerTests.swift:2651](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift:2651)

   Failure scenario: when `promptTokens == maxContextTokens`, the helper floors the output budget to one, causing the omitted-max request to receive the very 413 that SPEC-038 says omitted max never causes.

   Fix: reject full-context prompts explicitly before calculating output budget, and amend the SPEC wording to state that at least one generation token must remain.

Verified positives: initial construction and warm-swap/rebuild pass the current served context; both streaming and non-streaming CB paths use the helper; 413 relay mapping is correct and non-settling; retained cache is discarded in the new rejection branch; allocator capacity remains bounded.

Validation: four targeted unit tests passed. The production wiring test ran and skipped because the default metallib was unavailable. `git diff --check` passed.

VERDICT: C=0 H=1 M=4 L=1
