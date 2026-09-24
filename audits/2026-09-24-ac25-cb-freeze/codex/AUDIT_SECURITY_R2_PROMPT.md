# Codex freeze audit round 2: PR #1716 (continuous batching, #1646), full diff after fixes and merging main

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-ac25-m2`. Branch:
`campaign/ac25-m2-api-lifecycle` @ `30e634eb`. It includes merges of `main`,
among them #1713, squash `57686a84`. Review the COMPLETE diff as it would land:
`git diff origin/main...HEAD -- ':!docs' ':!audits'`.

This branch is ALREADY RUNNING in production as signed Studio candidate
v1.8.192 (`9e00f8e0`, the same code as this head minus two docs commits), with
`continuous_batching: canary`, 8 seats, `mlx_cache_limit_mb: 2048`, and one
accepted tuple for Qwen3.6 on an M3 Ultra 256 GB. Findings matter for that
live deployment.

Codex round 1 (prompts in this directory): the code lane PASSED; the security
lane found 3 MEDIUM; the architecture lane found 2 HIGH and 1 MEDIUM. The fixes
are in commit `217ebfe7`:

- **Security M1 (probe failure retried away):**
  `ModelRuntime.firstDistinguishingIsolationProbe` moves on only after a clean
  indistinguishable run (`isCleanIndistinguishableIsolationRun`). An exception
  (`.failClosed`), incomplete decode, row failure or divergence is final.
  Tests: `IsolationProbePairSelectionTests`.
- **Security M2 (cache limit fails open):** `mlx_cache_limit_mb` is validated
  in `runServingKnobsPreflight` whatever the batching mode, within
  `0...ModelRuntime.maximumMLXCacheLimitMB` (1 TiB). `applyMLXCacheLimit`
  cannot overflow.
- **Security M3 (queue wait overflow):**
  `continuous_batch_queue_wait_timeout_ms` is validated to
  `1...ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutMS` (1 h)
  whatever the mode. The ms→ns conversion clamps, and the scheduler
  configuration clamps as well.
- **Architecture H1 (FR-CB10 acceptance not bound to the runtime revision):**
  `ContinuousBatchingAcceptedTuple` requires `metallib_sha256` and
  `kernel_identifier`, and `ContinuousBatchingAcceptanceCoverage.covers`
  matches them. The parity label (derived) and pool epoch (per boot) stay
  descriptor checks. Serve start logs a `[paged-kv] runtime-identity` line.
  SPEC-038 v0.2.5 FR-CB10.
- **Architecture H2 (FR-PKV13 ceiling not enforced):** the ceiling gates real
  traffic through revision-bound acceptance. An operator records acceptance
  only after that exact packaged revision meets the ceiling, and a new revision
  serial-routes until it is re-measured. A startup micro-benchmark was
  rejected as too noisy to gate on. SPEC-039 v0.1.5 FR-PKV13,
  `docs/runbooks/continuous-batching-enable-gate.md`.
- **Architecture M1 (`on` has no A5 promotion path):** carried as
  pre-existing. That code is unchanged by this diff (it dates from #1672 and
  earlier), `on` fails closed at startup today, and the rollout is `canary`
  only. Confirm or refute that attribution.

Merge with #1713: SPEC-001 FR-27 `error_queue_full` moved to v1.9.24. #1713
overlaps `Config.swift`, `CoordinatorClient.swift`, `HTTPServer.swift`,
`MacProviderCLI.swift` and `ModelRuntime.swift`, which git auto-merged; check
that the auto-merge did not silently break either side. The full swift test run
on the merged tree passes: 3390 tests, 42 MLX skips, 0 failures.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Look for:
- Cross-row (cross-buyer) data leakage in batched KV or Mamba state.
- Usage/billing token counts that a buyer or provider could inflate or deflate.
- Receipt and settlement interaction with batched rows and relay error codes
  (`error_queue_full` re-route vs double execution/double charge).
- Whether the lab catalog-readiness waiver can trigger outside the exact lab
  condition.
- Trace/telemetry leaking prompt content.
- Fail-open behavior on bad config.
