codex
VERDICT: FAIL (0/0/3)

### MEDIUM

1. **Isolation-probe failures can be retried away**

   Location: `ModelRuntime.swift:1747-1750`, `PagedKVRuntimeParityProbe.swift:358-360`

   A probe exception returns `.failClosed` with `challengeDistinguishing == false`. The selector treats that as merely non-distinguishing and tries later prompt pairs. A later successful pair can therefore enable the hybrid attach gate after an earlier runtime probe failure.

   Fix: distinguish valid non-distinguishing results from probe failures; fail closed immediately on exceptions, incomplete decoding, or other probe errors. Add a regression test for failure-then-success.

2. **MLX cache limit fails open on invalid values**

   Locations: `MacProviderCLI.swift:673-676, 1986-1989`, `ModelRuntime.swift:1758-1763`, `Config.swift:594, 759`

   Negative limits are validated only when continuous batching is enabled. Oversized positive values overflow MiB-to-byte conversion and silently return `nil`. Startup then continues with MLX’s default cache behavior, which can grow until the provider is memory-killed.

   Fix: validate the limit unconditionally before model load, reject multiplication overflow, and make supplied invalid values a startup error.

3. **Queue wait timeout overflow becomes effectively unbounded**

   Locations: `ModelRuntime.swift:3090-3096`, `ContinuousBatchScheduler.swift:1581-1587`

   A positive but excessively large configured timeout overflows during millisecond-to-nanosecond conversion and saturates to `UInt64.max`. The scheduler then waits effectively forever, defeating the bounded-admission guarantee and retaining queued requests.

   Fix: reject values that cannot be represented in nanoseconds; never convert overflow into `UInt64.max`.

No critical or high findings were identified. Source review found no concrete cross-row billing/receipt double-settlement, relay reroute, catalog-waiver escape, or prompt-content telemetry leak.

Existing tests passed, including scheduler (78), relay (26), paged-runtime bridge (31), isolation selection (3), and serve-command (77). MLX-backed tests were skipped locally due unavailable metallib. No malformed payloads were constructed, and no repository changes were left by the audit.
