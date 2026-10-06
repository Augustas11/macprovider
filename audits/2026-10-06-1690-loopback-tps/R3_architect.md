
```text
Architect lane re-audit of `git diff origin/main...HEAD` only. Pearl-updater findings remain out of scope.

1. **MEDIUM — PARTIAL — incompatible throughput semantics**

   Fixed: SPEC-002 now defines the cross-runtime routing quantity and tests share the rate helper: `SPEC-002-coordinator.md:2000-2011`, `ModelRuntime.swift:8213-8222`, `OpenAICompatibleLoopbackRuntimeTests.swift:1919-1933`.

   Still open: loopback caps upstream completion tokens by SSE delta count: `OpenAICompatibleLoopbackRuntime.swift:1389-1428`. An honest 8-token completion in one content delta reports 1 token, unlike native MLX. The regression explicitly codifies this behavior at `OpenAICompatibleLoopbackRuntimeTests.swift:1868-1902`.

   Failure: loopback providers can be falsely excluded by the throughput floor or ranked below native providers.

2. **MEDIUM — FIXED — chunk-count fallback**

   Startup measurement now uses only upstream usage or llama.cpp `predicted_n`: `OpenAICompatibleLoopbackRuntime.swift:1389-1394`. Chunk-only SSE fails closed at `OpenAICompatibleLoopbackRuntimeTests.swift:1985-2000`; the remaining accumulator fallback is display-only at `OpenAICompatibleLoopbackRuntime.swift:599-601`.

3. **MEDIUM — FIXED — stale deploy artifact verification**

   The route test accepts an explicit config path and checks the exact vhost: `check_nginx_model_admission_routes_test.sh:7-24`. Deploy passes `$NGINX_SITE` at `deploy-pearl-vps.sh:1798-1802`, and uploads that same file at `deploy-pearl-vps.sh:3518`.

4. **LOW — NOT FIXED — metadata affects measured elapsed time**

   Timing still starts before the HTTP request and ends after stream finalization: `OpenAICompatibleLoopbackRuntime.swift:1358-1399`. Finish, usage, and `[DONE]` metadata remain inside the interval, as shown by the fixture at `OpenAICompatibleLoopbackRuntimeTests.swift:1784-1795`.

   Failure: delayed metadata can lower the reported throughput. Fix: measure through the final content-bearing event or use authoritative upstream timing metadata.

5. **LOW — NOT FIXED — concrete runtime coupling and duplicated probe contract**

   `ModelRuntimeServing` still has no probe requirement: `ModelRuntime.swift:13-57`. Native and loopback probes remain separate concrete methods at `ModelRuntime.swift:8224-8261` and `OpenAICompatibleLoopbackRuntime.swift:1308-1311`; serve dispatch still downcasts at `MacProviderCLI.swift:2733-2746`.

   Failure: a new conforming runtime can serve successfully but advertise zero throughput.

New architect-lane issue:

6. **LOW — tool-call-only SSE can satisfy the no-content gate**

   `contentDeltaCount` aliases `deltaEvents`: `OpenAICompatibleLoopbackRuntime.swift:623-625`, while tool-call deltas increment that counter at `:760-767`. The startup gate accepts any positive count at `:1392-1394` and `:1422-1428`.

   Failure: a tool-call-only response with usage and `[DONE]` can produce a positive startup rate despite no text content. Fix: count only actual content deltas or require non-empty received content.

Validation passed: patch artifact equality, `git diff --check`, deploy shell syntax, nginx route test, and 16 BYOM contract-lock unit tests. Full Swift/Go suites were not run due the MacProvider local CI resource boundary.

C=0 H=0 M=1 L=3


