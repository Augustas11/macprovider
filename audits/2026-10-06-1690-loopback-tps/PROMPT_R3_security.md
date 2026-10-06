# #1690 M1 fix audit ROUND 3 (final) — lane: security (single lane only)

Anchored re-audit. Branch fix/1690-loopback-startup-throughput. The branch's own change set is ONLY the three-dot diff vs main: audits/2026-10-06-1690-loopback-tps/diff-r3.patch (= git diff origin/main...HEAD). Round-2 fix commit is beeb86b51 (after merge 26106d9b9 of origin/main). Read touched files in full. Do NOT audit code that is not in diff-r3.patch.

Note: the round-2 security lane's two Pearl-updater findings came from a stale two-dot diff that showed main's own #1861 in reverse; ops/pearl-updater is not changed by this branch and is out of scope.

1. For EACH round-2 open finding below, state FIXED / NOT FIXED / PARTIAL with file:line evidence.
2. Then report any NEW issue in diff-r3.patch for this lane only.

## Round-2 output for this lane

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



## Lane focus
Security and money path: can a provider inflate throughput_tps_estimate to win routing (it was already self-reported; does the probe make anything worse or create a new trust claim)? Does the probe leak prompts/completions/paths in logs or status? Resource exhaustion (hang at startup, unbounded body, GPU contention), SSRF/loopback-origin bounds, any path where probe output is billed or receipted. nginx: does the new location expose any provider-port (8444) admin surface beyond /v1/provider/model-admission/ (prefix match, path traversal, normalization), header handling (Authorization passthrough), and ordering vs the /v1/ catch-all.

## Output
Severity CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, failure scenario and fix; only verified issues. End with one line: "C=<n> H=<n> M=<n> L=<n>" counting OPEN in-scope issues only.
