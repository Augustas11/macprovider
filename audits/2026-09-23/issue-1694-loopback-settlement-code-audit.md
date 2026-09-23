# Issue #1694 loopback settlement bar — code audit

Scope: full fix diff `eed9ca5b..c6116ce9`, reviewed by source inspection and existing tests only. No malformed payloads, exploit strings, or new adversarial fixtures were authored or run.

No CRITICAL findings. No HIGH findings. No MEDIUM findings. One LOW test-coverage finding. One INFO pre-existing validation observation.

| Severity | ID | File:line | Finding | Evidence | Consequence | Required correction |
| --- | --- | --- | --- | --- | --- | --- |
| LOW | CODE-LOW-1 | `phase4-coordinator/internal/buyer/settlement_unsettled_leg_test.go:199`; `phase4-coordinator/internal/buyer/server.go:2496` | Runtime-source propagation is not regression-tested through the transport and retry/failover call sites. | `TestLoopbackLegIsRecordedByteEstimatedThroughRecordRow` calls `recordRow` directly, and `TestRecordSettlementAttemptOutputLoopbackUsageIsNeverCoordinatorObserved` calls the output recorder directly. Source review confirms that the production wrappers and direct calls pass the active provider's `RuntimeSource`, and that failover advances `state.provider` only after the old attempt is logged, but no new test drives HTTP streaming, WebSocket streaming/non-streaming, or a retry/failover with distinct provider runtime sources and then inspects every persisted attempt. | The implementation is correct as reviewed, but a later caller-level regression could pass an empty or stale source; the recorder would then preserve legacy/native behavior and could label provider-reported loopback counts `coordinator_observed`. | Add existing-style transport/retry regression coverage that uses different runtime sources per attempted provider and asserts each persisted attempt's `usage_source`. This is not a blocker for the current fix because every present call site was inspected and is correct. |
| INFO | CODE-INFO-1 | `phase4-coordinator/internal/billing/quarantine_test.go:1088` | PRE-EXISTING: one load-sensitive billing test failed once during concurrent validation, then passed on all reruns. | The first four-package run, executed concurrently with `go vet`, failed only `TestAdminRateLimitBucketConsumesFailures` with zero rate-limit hits. The focused test passed, the billing package passed, and a standalone rerun of the exact requested four-package command passed all packages. The failing test and its implementation are outside `eed9ca5b..c6116ce9`. | No demonstrated consequence for issue #1694; this is validation noise in an unchanged test. | None for this change. Track separately only if the test recurs in normal serial CI. |

## Correctness evidence

- Every production `recordRow` provider path passes the serving `pool.Provider.RuntimeSource`. The two `logRow` calls that pass a non-empty assigned ID occur before provider dispatch, carry no token counts, and therefore remain `byte_estimated` even with the intentionally empty source.
- Retry and failover sequencing logs the current attempt before replacing `state.provider`; streaming, WebSocket, HTTP, and relay-blind paths therefore attribute the runtime source to the provider that served that attempt.
- Both `billing.HotPathInput` construction sites copy `providerRuntimeSource`. `recordSettlementAttemptOutput` checks that field before selecting `coordinator_observed`, and loopback attempts retain coordinator byte evidence while forcing zero billable tokens.
- `billingRecorder.recordSettlementAttemptOutput` is the only production caller of `InsertSettlementAttemptOutput` and the only production assignment of `UsageSourceCoordinatorObserved` to attempt evidence. Receipt construction derives `UsageCrossChecked` from that stored source, and verification independently requires both cross-checking and `coordinator_observed` before returning a verified settlement.
- Admission checks reject both a loopback decision source and a loopback hello/session source. The hello handler stores `RuntimeSource` on `pool.Provider`, and the settlement-session binder independently rejects loopback sessions.
- Empty legacy runtime sources and `mlx_cache` follow the pre-fix token-observed branch unchanged. The recorder regression test explicitly checks both positive controls.
- Each new negative regression test would fail if its corresponding guard were removed: buyer route binding, WebSocket settlement binding, recorder classification, and `recordRow` propagation are independently exercised. The revised positive artifact test still asserts the immutable route-time admission values and a credited settlement using an `mlx_cache` secondary `mlx_safetensors` member.

## Validation

- `go test ./internal/buyer ./internal/ws ./internal/billing ./internal/routing -count=1` — PASS on standalone rerun (`buyer`, `ws`, `billing`, and `routing`).
- `go test ./internal/billing -run '^TestAdminRateLimitBucketConsumesFailures$' -count=1` — PASS after the transient first-run failure.
- `go test ./internal/billing -count=1` — PASS.
- `go vet ./internal/buyer ./internal/ws ./internal/billing ./internal/routing` — PASS.
- `gofmt -d` over every changed Go file — no output.
- `git diff --check eed9ca5b..c6116ce9` — PASS.

VERDICT: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=1 INFO=1
