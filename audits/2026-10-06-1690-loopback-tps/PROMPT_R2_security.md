# #1690 M1 fix audit ROUND 2 — lane: security (single lane only)

Anchored re-audit. Branch fix/1690-loopback-startup-throughput, base origin/main 359f73e43, full combined diff in audits/2026-10-06-1690-loopback-tps/diff-r2.patch (round-1 fix commit is 9fb880247). Read touched files in full.

1. For EACH round-1 finding below, state FIXED / NOT FIXED / PARTIAL with file:line evidence.
2. Then report any NEW issue in the full combined diff for this lane only.

## Round-1 findings for this lane

```text
- **MEDIUM — Loopback upstream can inflate the routing throughput claim.**  
  `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:691-715,1343-1369,1394-1401` accepts usage-only SSE frames, does not bound `completion_tokens` by the requested `max_tokens`, and trusts arbitrary finite `timings.predicted_per_second`. The resulting value is advertised at `MacProviderCLI.swift:2738-2744,2775-2778` and directly clears/ranks providers in `phase4-coordinator/internal/buyer/server.go:645-655` and `phase4-coordinator/internal/routing/objective.go:57-65`. A loopback server can return fabricated metadata followed by `[DONE]`, making the provider routable or dominant.  
  **Fix:** require actual bounded generation evidence, enforce `completion_tokens <= max_tokens`, reject usage-only success, and ignore or cap upstream-provided timing metadata for routing purposes. This probe is not billed or receipted.

- **LOW — The documented 60-second startup bound excludes identity revalidation.**  
  `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:1279-1282,1298,1313-1316` performs `servesBoundIdentity()` before entering the timeout wrapper. For MLXLM, oMLX, and LM Studio, that revalidation performs loopback GETs (`:1721-1722`) using default request/resource timeouts of 60/120 seconds (`:268-270`). A stalled local runtime can therefore delay startup beyond the stated 60-second bound.  
  **Fix:** include identity validation inside the same deadline, using a deadline-aware HTTP client.

No verified prompt/completion/path leakage, unbounded probe body, SSRF escape, billing/receipt path, or nginx admin exposure. The nginx route test passed and the provider handlers remain exact-path and authenticated.

C=0 H=0 M=1 L=1



## Lane focus
Security and money path: can a provider inflate throughput_tps_estimate to win routing (it was already self-reported; does the probe make anything worse or create a new trust claim)? Does the probe leak prompts/completions/paths in logs or status? Resource exhaustion (hang at startup, unbounded body, GPU contention), SSRF/loopback-origin bounds, any path where probe output is billed or receipted. nginx: does the new location expose any provider-port (8444) admin surface beyond /v1/provider/model-admission/ (prefix match, path traversal, normalization), header handling (Authorization passthrough), and ordering vs the /v1/ catch-all.

## Output
Severity CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, failure scenario and fix; only verified issues. End with one line: "C=<n> H=<n> M=<n> L=<n>" counting OPEN issues only.
