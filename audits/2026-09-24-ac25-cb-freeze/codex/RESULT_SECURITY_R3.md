codex
Reviewed `b332156b` and the surrounding scheduler state machine.

No CRITICAL, HIGH, or MEDIUM findings.

- Actor reentrancy is safe: `expireQueueWait` removes the queued row and captures waiters before its cleanup `await` (`ContinuousBatchScheduler.swift:1640-1666`). The admission loop rechecks `waiting` after `await`, so it cannot index an empty/different queue unsafely.
- Cancellation and draining remain guarded by existing stale-wake checks.
- Replay claims are released only for pre-admission expiry; no row, inference, receipt, usage, or settlement is created (`:1653-1666`, `:2538-2559`).
- The loop makes progress by removing the expired head; no spin scenario found.
- No cross-row KV/Mamba leakage, billing-token mutation, relay/double-charge path, waiver expansion, prompt telemetry leak, or fail-open config behavior is introduced.
- Existing tests passed:
  - `swift test --filter ContinuousBatchSchedulerTests.testAC25`: 9/9
  - `swift test --filter ContinuousBatchSchedulerTests`: 79 passed, 4 skipped due unavailable MLX metallib

VERDICT: PASS
