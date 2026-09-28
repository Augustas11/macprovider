# Audit R1 — provider streaming cleanup rewrite, receipt binding, MLX cache clear, preserve_thinking

Lane: code  
Scope: full `git diff origin/main...HEAD -- phase3-binary/`, with surrounding relay, receipt, coordinator settlement, and specification code reviewed as needed.  
Method: first-party source review plus existing targeted tests. No malformed payloads were authored or constructed, and no code was changed.

## Findings

No CRITICAL, HIGH, or MEDIUM correctness findings were identified.

### LOW-1 — Cleanup replacement equivalence is not table-tested across all rewrite boundaries

- Severity: LOW
- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4141`; `phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift:626`
- Failure condition: a future change to `ReplacementStage`, stage ordering, or provisional flushing mishandles a valid tokenizer-piece split for one of the less-tested cleanup rules (`?`, `!`, `,`, `\' `, `n't`, `\'m`, `\'ve`, or `\'re`). The incremental batched detokenizer could then diverge from the whole-prefix cleanup result, producing an unexpected buyer-visible stream or a serial/continuous-batch mismatch even though the currently covered period, apostrophe, and UTF-8 cases pass.
- Fix: add a table-driven test using valid tokenizer pieces for every replacement rule and every split point, comparing the incremental final text with a reference whole-prefix cleanup result and checking the emitted stream remains non-duplicating.

### INFO-1 — No public stream-to-receipt regression fixture covers the complete binding chain

- Severity: INFO
- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4662`, `:6195`, and `:6418`
- Failure condition: a future streaming adapter or return branch bypasses `state.emittedContent`, `emittedText`, or `textEmitter.emittedContent` while the emitter unit tests continue to pass. The stream could then deliver cleanup-rewritten deltas while a completion/receipt path retains parsed content, causing the downstream output hash to differ.
- Fix: add a deterministic valid-payload integration fixture that drives the public serial, continuous-batch, and speculative stream completion paths, collects content deltas, and asserts completion/receipt content equals the exact delivered concatenation for cleanup rewrite, stop holdback, structured output, and tool-call cases.

## Reviewed conclusions

- Re-anchoring computes the longest common Unicode-scalar prefix, preserves already-sent bytes, and removes only the overlapping emitted suffix from a rewritten tail. The four-scalar suffix bound covers the current cleanup patterns. Prefix-extension, indentation contraction, apostrophe contraction, stop-candidate holdback, finish flush, and no-rewrite byte identity are covered by the new emitter tests.
- The serial emitter and continuous-batch row state share the same emitter behavior for content, tool-call suppression, structured accumulation, stop handling, and finish flushing. Existing tool/structured/stop tests and the new batched cleanup tests passed.
- Non-Harmony serial, continuous-batch, and speculative streaming completions bind `CompletionResult.content` to the emitted content accumulator. Harmony intentionally retains its parsed content path. `withContent` also drops a loopback prefix-token table when rebinding content, avoiding stale prefix accounting.
- `Memory.clearCache()` is called once after iterator construction on serial completion, speculative serve, and serial streaming paths; continuous batching remains unchanged. No source evidence showed a cache-state or concurrency mutation in this diff.
- `preserve_thinking` is gated on the same template bytes containing both `enable_thinking` and `preserve_thinking`, and the capability is carried through initialization, target swaps, and runtime snapshots. The prompt-context and snapshot tests passed.
- Relay cancellation continues to sign only reconstructable delivered content; tool-call-open and unknown-delivery cases fail closed. Receipt content therefore remains tied to delivered stream deltas in the reviewed paths.

## Validation

- `git diff --check origin/main...HEAD -- phase3-binary/` — passed.
- `cd phase3-binary && swift test --filter StreamingEmitterCleanupRewriteTests` — 7 passed.
- `cd phase3-binary && swift test --filter ContinuousBatchToolStructuredRowTests` — 20 passed.
- `cd phase3-binary && swift test --filter ModelRuntimePromptContextTests` — 6 passed.
- `cd phase3-binary && swift test --filter ServingKnobsConfigTests` — 109 executed, 1 skipped because the MLX default metallib is unavailable on this host.
- `cd phase3-binary && swift test --filter NativeToolCallStreamEmitterTests` — 19 passed.
- `cd phase3-binary && swift test --filter ModelRuntimeStructuredOutputTests` — 13 passed.
- `cd phase3-binary && swift test --filter StreamingValidationFailureTests` — 1 passed.

Repository-wide CI, full Swift tests, and hardware-backed concurrency tests were not run because the MacProvider host boundary reserves those workloads for GitHub CI and the designated Mac Studio.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW
