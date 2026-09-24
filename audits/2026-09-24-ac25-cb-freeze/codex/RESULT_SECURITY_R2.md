codex
SECURITY / MONEY PATH — PASS

Reviewed the complete non-doc/non-audit diff against `origin/main`. No CRITICAL, HIGH, or MEDIUM findings.

Key evidence:

- Cross-row isolation: Mamba state is packed and sliced per row; multi-row recurrent state without safe isolation fails closed (`PagedKVRuntimeBridge.swift:779-781`, `1018-1056`). Attention masks use per-row lengths (`1262-1294`).
- Billing/settlement: terminal results select one eligible settlement owner; replays are non-settling (`ContinuousBatchScheduler.swift:2721-2765`). Receipts require explicit eligibility, ownership, and matching request/provider/model metadata (`HTTPServer.swift:1514-1567`).
- Queue errors: only pre-admission pressure/timeouts map to `error_queue_full`; post-token delivery backpressure remains non-retryable (`InferenceRelay.swift:1184-1205`, `ContinuousBatchScheduler.swift:895-930`). No double-execution or double-charge path found.
- Config fail-closed: cache and queue-wait limits are validated in all modes and conversion is bounded (`MacProviderCLI.swift:676-692`, `ModelRuntime.swift:1785-1803`, `3170-3180`).
- Lab waiver: requires isolated lifecycle, protected credentials, literal loopback coordinator, and no catalog trust (`MacProviderCLI.swift:1575-1602`).
- Telemetry: trace and failure logs exclude prompt/completion content and sanitize bounded reasons (`ContinuousBatching.swift:407-479`).
- Isolation probes: failures, incomplete runs, divergence, and exceptions are final; only clean indistinguishable runs advance (`ModelRuntime.swift:1754-1783`).
- Architecture M1 attribution confirmed: `.on` still fails closed when unsupported (`ContinuousBatching.swift:350-362`); this diff does not add an A5 promotion path. The behavior is pre-existing.

Existing targeted tests passed, including scheduler, relay pressure, disconnects, receipts, serving knobs, isolation probes, stop tokens, and cache/bridge suites. MLX-dependent bridge cases remain skipped on this host due unavailable metallib; the supplied full-run result was 3390 tests, 42 MLX skips, 0 failures. `git diff --check` also passed.

VERDICT: PASS
