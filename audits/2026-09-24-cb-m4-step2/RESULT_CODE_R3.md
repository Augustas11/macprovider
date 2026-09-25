codex
Audit result: one remaining MEDIUM correctness finding. No CRITICAL or HIGH findings.

M-1 — cancellation can still be lost during retained-owner cleanup

`phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2686-2693`

`finishQueued` consumes `cancelledIDs` before awaiting `discardUnacceptedRetainedCache`. While that allocator await is suspended, `cancel(requestID:)` can record a cancellation because the request remains known. `finishQueued` then constructs the original `.requestFailed`/`.rejected` result without rechecking cancellation.

Scenario: a retained admission failure or rejection enters `finishQueued`; the caller cancels during retained-owner discard; the request completes as failure instead of `cancelled/request_cancelled`.

Fix: perform retained-owner cleanup, then re-check and consume `cancelledIDs` immediately before constructing the result, while preserving `continuous_batching_cleanup_failed` precedence. The R2 test only covers cancellation before the cleanup phase and would not catch this window.

Reviewed and found correct:

- Reattach trims the allocator and bridge state to `cachedPromptTokens`; scheduler sets `prefillCursor` to the same C (`ContinuousBatchScheduler.swift:2390-2408`).
- Mamba restore validates layer keys, two-slot layout, rank, batch dimension, positive dimensions, and dtype before installation (`PagedKVRuntimeBridge.swift:454-469, 677-707`).
- Checkpoint selection and chaining are consistent (`ConversationCache.swift:304-320, 530-535`; scheduler checkpoint carry/snapshot paths).
- Flag-off hybrid behavior preserves the serial materialization path (`ModelRuntime.swift:3286-3291, 4007-4009`).
- Retained ownership is generally released or discarded correctly; duplicate discard attempts resolve as `unknownHandle` without double-free.

Existing tests run:

`swift test --filter 'macprovider_cliTests.(ContinuousBatchSchedulerTests|PagedKVRuntimeMixedCacheTests)'`

Result: 96 executed, 8 skipped due unavailable MLX metallib, 0 failures. The actual MLX restore tests were skipped, so hardware-backed restore remains unverified here.

No source changes were made.

VERDICT: FAIL (0/0/1)
