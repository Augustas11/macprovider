
```text
- **MEDIUM — Loopback upstream can inflate the routing throughput claim.**  
  `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:691-715,1343-1369,1394-1401` accepts usage-only SSE frames, does not bound `completion_tokens` by the requested `max_tokens`, and trusts arbitrary finite `timings.predicted_per_second`. The resulting value is advertised at `MacProviderCLI.swift:2738-2744,2775-2778` and directly clears/ranks providers in `phase4-coordinator/internal/buyer/server.go:645-655` and `phase4-coordinator/internal/routing/objective.go:57-65`. A loopback server can return fabricated metadata followed by `[DONE]`, making the provider routable or dominant.  
  **Fix:** require actual bounded generation evidence, enforce `completion_tokens <= max_tokens`, reject usage-only success, and ignore or cap upstream-provided timing metadata for routing purposes. This probe is not billed or receipted.

- **LOW — The documented 60-second startup bound excludes identity revalidation.**  
  `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:1279-1282,1298,1313-1316` performs `servesBoundIdentity()` before entering the timeout wrapper. For MLXLM, oMLX, and LM Studio, that revalidation performs loopback GETs (`:1721-1722`) using default request/resource timeouts of 60/120 seconds (`:268-270`). A stalled local runtime can therefore delay startup beyond the stated 60-second bound.  
  **Fix:** include identity validation inside the same deadline, using a deadline-aware HTTP client.

No verified prompt/completion/path leakage, unbounded probe body, SSRF escape, billing/receipt path, or nginx admin exposure. The nginx route test passed and the provider handlers remain exact-path and authenticated.

C=0 H=0 M=1 L=1


