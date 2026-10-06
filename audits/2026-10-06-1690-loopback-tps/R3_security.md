
```text
Security-lane result: one open MEDIUM remains. Startup-bound finding is FIXED. Pearl-updater findings are out of scope because no `ops/pearl-updater` file is in `git diff origin/main...HEAD`.

- MEDIUM — throughput finding: PARTIAL. Timing fallback is restricted to llama.cpp at `OpenAICompatibleLoopbackRuntime.swift:1325`, usage-only and over-budget claims are rejected at `:1422-1425`, and the count is capped at `:1426-1428`. However, `contentDeltaCount` is actually `deltaEvents` at `:623-625`; it increments for each content fragment at `:738-743` and also for tool-call deltas at `:760-766`. A local upstream can split one token across multiple deltas, or emit tool-call-only deltas, set `usage.completion_tokens: 8`, and obtain a positive/inflated estimate. That value is advertised as a startup probe at `MacProviderCLI.swift:2757-2761,2775-2778`.

  Fix: verify emitted-token count with a trusted tokenizer/runtime-specific attestation; reject tool-only output and do not treat SSE fragment count as token evidence.

- LOW — startup-bound finding: FIXED. The deadline begins before both identity checks and generation at `OpenAICompatibleLoopbackRuntime.swift:1327-1335`; the timer cancels the worker at `:1830-1863`. Coverage passes in `OpenAICompatibleLoopbackRuntimeTests.swift:2103-2131`.

No separate independent new issue found. The nginx route remains bounded to the intended prefix, forwards `Authorization`, targets fixed loopback `8444`, and precedes `/v1/` at `nginx-coordinator.malibu.tech.conf:772-783`; its route test passed.

Validation: 12 targeted Swift tests passed, nginx route test passed, `git diff --check` passed.

C=0 H=0 M=1 L=0


