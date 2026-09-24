codex
Security / money-path audit of `30e634eb..HEAD`: no CRITICAL, HIGH, or MEDIUM findings.

Reviewed:

- Per-row logits and RNG isolation in `ContinuousBatchRowSampler.swift` and both decode paths.
- Client-controlled request-ID seeds: predictable but isolated; no cross-row or buyer impact.
- Fingerprint/idempotency propagation, including `samplerSeed`.
- Usage, receipt, cache, and settlement accounting: unchanged.
- Bounded per-row sampler cost; batch capacity remains capped at 8.
- Unsupported-parameter gates and penalty parity with the serial path.

Validation:

- `ContinuousBatchRowSamplerTests`: 3 passed, 4 Metal-dependent skipped.
- `ServingKnobsConfigTests`: 97 passed, 1 skipped.
- `PagedKVRuntimeBridgeTests`: 16 passed, 15 skipped.
- `ContinuousBatchSchedulerTests`: 75 passed, 4 skipped.
- `git diff --check`: clean.

Metal-dependent tests could not run because the default MLX metallib is unavailable on this host; no malformed payloads were constructed.

VERDICT: PASS
