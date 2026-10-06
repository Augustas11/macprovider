
```text
Security-lane result: the throughput finding remains open as PARTIAL; the startup-bound finding is FIXED. The full patch also introduces two updater issues.

Round-1 findings

- MEDIUM — PARTIAL. Usage-only responses and over-budget counts are rejected at `OpenAICompatibleLoopbackRuntime.swift:1406-1409`, and `predicted_per_second` is ignored. However, `:1364-1379` accepts arbitrary upstream `usage.completion_tokens` or `timings.predicted_n` without proving that the count matches generated content. `predicted_n` is not restricted to llama.cpp. One content fragment plus forged `completion_tokens: 8` and `[DONE]` yields a positive estimate, which is advertised at `MacProviderCLI.swift:2738-2744,2775-2778` and affects routing at `server.go:645-655` and `objective.go:57-65`.

  Fix: require verifiable bounded-generation evidence tied to emitted output, and restrict timing-count fallback to the intended trusted runtime.

- LOW — FIXED. Both identity checks now run inside the 60-second wrapper at `OpenAICompatibleLoopbackRuntime.swift:1321-1326`. The timer returns at the deadline and cancels the worker at `:1804-1843`; the bounded-timeout test covers this at `OpenAICompatibleLoopbackRuntimeTests.swift:2010-2022`.

New issues

- HIGH — Privileged updater resolves `sqlite3` through inherited `PATH`. The production updater requires root at `ops/pearl-updater/macprovider-pearl-update:7235-7245`, but database snapshot and integrity-check commands use bare `sqlite3` at `:4280-4290`; `run_command` inherits the environment at `:1024-1042`, and the previous trusted-binary preflight is absent before `apply` at `:7410-7413`. A caller-controlled or writable `PATH` can make the root updater execute an attacker-controlled binary during money-DB handling. Restore fixed-path, root-owned executable validation and use that absolute path consistently.

- MEDIUM — Pearl updater transaction snapshots now accumulate without retention. Each apply creates a unique transaction directory at `ops/pearl-updater/macprovider-pearl-update:4309-4319` and always snapshots configured databases at `:4434-4459`, while the commit path ends without pruning at `:6921-6955`. Repeated releases can exhaust updater-state disk space, preventing future rollouts or recovery. Restore bounded snapshot retention/pruning and a free-space guard.

Nginx remains safe in the reviewed path: the exact route precedes `/v1/`, forwards `Authorization`, and the backend exposes only the three exact authenticated handlers (`nginx-coordinator.malibu.tech.conf:768-783`, `server.go:1954-1956`, `model_admission.go:2046-2069`). The route test passed. No verified prompt/completion leakage, SSRF escape, billing/receipt path, or unbounded probe body was found.

C=0 H=1 M=2 L=0


