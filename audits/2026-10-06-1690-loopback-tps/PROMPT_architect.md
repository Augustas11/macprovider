# #1690 M1 fix audit — lane: architect (single lane only)

You are auditing ONE lane (architect) of a two-commit fix on branch fix/1690-loopback-startup-throughput
(repo root = current directory, base origin/main 359f73e43). The full diff is in
audits/2026-10-06-1690-loopback-tps/diff.patch; read the touched files in full where needed.

## Context (production-verified 2026-10-06)
- Loopback serving runtimes (llama.cpp/Ollama/mlx_lm/LM Studio/oMLX via OpenAICompatibleLoopbackRuntime)
  reported throughput_tps_estimate 0 forever (startup-only estimate). Production coordinator applies
  min_provider_throughput_tps 1.0 (phase4-coordinator/internal/buyer/server.go providerMeetsRoutingQuality, #1560),
  so every loopback provider, incl. Trusted Pool (#1690) members, was excluded from routing
  (observed provider_throughput_floor_excluded). Commit a25ee8514 adds a one-shot startup throughput probe
  through the loopback runtime's own upstream leg (SPEC-001 FR-20 amended, v1.9.29).
- Commit a0624edc5 adds the BYOM provider model-admission nginx location (/v1/provider/model-admission/ ->
  127.0.0.1:8444) to the coordinator vhost template plus a static test; Pearl had carried it by hand and a
  vhost rewrite dropped it (all BYOM offers 404'd).

## Lane focus
Architecture: is a CLI-side probe the right layer vs coordinator floor semantics; single source of truth for the probe constant/semantics shared with native ModelRuntime; coupling between MacProviderCLI serve wiring and the runtime actor; SPEC-001 FR-20/FR-17 amendment consistency with SPEC-002 routing and SPEC-046/SPEC-010 loopback SPECs; whether the nginx template + test are the right durable home (vs deploy tooling) and consistent with existing route tests.

## Output
List findings with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, each with file:line, the concrete failure scenario, and a fix. Only report what you verified in code. End with a one-line verdict: "C=<n> H=<n> M=<n> L=<n>".
