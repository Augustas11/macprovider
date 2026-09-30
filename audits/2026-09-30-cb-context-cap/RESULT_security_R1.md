
### HIGH — Streaming context rejection remains a retryable provider failure

File: [server.go](/Users/augstar/macprovider-cb-context-cap/phase4-coordinator/internal/buyer/server.go:4210), [transport_result.go](/Users/augstar/macprovider-cb-context-cap/phase4-coordinator/internal/buyer/transport_result.go:163), [server.go](/Users/augstar/macprovider-cb-context-cap/phase4-coordinator/internal/buyer/server.go:6142)

Failure scenario: With `stream:true`, pre-commit `error_context_exceeded` returns `wsForwardFailed`. The generic classifier marks it retryable and the renderer emits `502 provider_error`, instead of the required non-retryable `413 context_exceeds_capacity`. Buffered streaming additionally records it as `FaultBreakerQualifying` at [server.go](/Users/augstar/macprovider-cb-context-cap/phase4-coordinator/internal/buyer/server.go:4426). A buyer can therefore trigger unnecessary retries/failover and provider-fault attribution using an invalid request.

Billing remains zero: `error_context_exceeded` is null usage, and the gateway’s legacy unfinalized-502 path refunds the reservation. The wire and provider-health behavior are still incorrect.

Fix: Carry a dedicated context-exceeded stream result through the coordinator, classify it non-retryable/non-faulting, and render 413. Add incremental and buffered streaming regression tests covering status, retryability, settlement and fault classification.

### HIGH — The 32,768 implicit output cap exceeds the current 4,096 gateway reservation

File: [ContinuousBatchScheduler.swift](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:267), [ModelRuntime.swift](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5424), [config.go](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/config/config.go:428), [chat_proxy.go](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/router/chat_proxy.go:339)

Failure scenario: The gateway resolves omitted `max_tokens` to 4,096 and reserves `prompt + 4,096`, but forwards the unchanged body. The CB provider can consequently generate up to 32,768 output tokens. Eight small-prompt non-streaming requests can consume roughly 262k output-token work while reserving only roughly 32k—an 8× resource-accounting amplification suitable for compute starvation.

The claim that 32,768 matches the gateway is not true in this full diff: SPEC-006, gateway defaults and example configuration remain 4,096, with demo capped at 512.

Fix: Make the gateway forward its resolved effective `max_tokens`, or source the provider default from an authenticated coordinator/gateway limit. If 32,768 is the intended contract, update SPEC-006, gateway defaults, examples, reservations and cross-service tests in the same rollout.

### MEDIUM — Other buyer-controlled CB 4xx errors still collapse to `error_internal`

File: [ContinuousBatchScheduler.swift](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1372), [InferenceRelay.swift](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1247)

Failure scenario: Pre-inference request errors such as duplicate-request mismatch (`409`) and invalid cached-token requests (`400`) retain `inferenceRan=false` and `settlementRan=false`, but the relay’s default branch converts them to `error_internal`. The coordinator then exposes retryable `provider_error`, preserving retry/failover and provider-fault semantics for buyer errors.

Fix: Define relay end statuses for all pre-admission request-class errors, or carry the API status/code generically. Map them to non-retryable, non-settling coordinator 4xx responses and test both streaming and non-streaming paths.

## Validated behavior

- The direct scheduler rejection correctly produces 413 with `inferenceRan=false` and `settlementRan=false`.
- The 413/null-usage path produces no provider credit and no buyer charge.
- Eight rows cannot each physically reserve a full 200k KV context: multi-row initial allocation is prompt plus decode headroom, constrained by the paged-KV pool. The hardcoded output-cap mismatch above remains the practical amplification risk.
- The new stderr line contains token counts and the cap only—no prompt, output, request ID or account data.
- Reaching the implicit cap while reporting `finish_reason: stop` masks truncation, but matches the documented serial behavior; informational interoperability concern, not a separate security finding.
- `git diff --check origin/main...HEAD` passed. Full Swift/Go suites were not run because this operator Mac is prohibited from repository-wide CI workloads.

Recommendation: REQUEST CHANGES

VERDICT: C=0 H=2 M=1 L=0.
