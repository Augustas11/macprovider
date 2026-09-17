You are a senior software architect auditing a Swift change to the MacProvider provider CLI.

Context:
- Repo: macprovider (Apple Silicon MLX inference provider). CoordinatorClient (an actor) and ProviderStatus (an actor) coordinate provider health/capacity reporting to the coordinator over a WebSocket.
- Branch: codex/openrouter-quality-floor-v2, issue #1570 (OpenRouter filing readiness). The prior production symptom was excess HTTP 429 capacity shedding under benchmark load; this change aims to make capacity publication precise/timely so routing admits only when a real slot is free.

The full fix diff (base = origin/main) is at:
  audits/2026-09-17-openrouter-quality-floor-v2/full-fix.diff

Also read:
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
  phase3-binary/Sources/macprovider-cli/ProviderStatus.swift

Review architecture and design only:
- Concurrency model soundness across the two actors: ProviderStatus now emits capacity transitions via a handler that hops to CoordinatorClient via Task; CoordinatorClient coalesces and sends. Is the ordering/latest-wins model coherent end to end? Are there interleavings where the wire state diverges from the true provider state for an unbounded time?
- Making beginRequest/beginRequestIfAccepting/finishRequest/updateModel async to await the thermal gate on every request: is putting a thermal-gate await on the request admission/completion hot path the right layer, or does it risk added TTFT latency / contention on the ProviderStatus actor under load? Is there a cleaner separation (e.g. cached thermal observation) more consistent with the existing design?
- Duplication: sendCapacityStateUpdateBounded reimplements the send + serialization logic of send(_:) plus a timeout. Is this duplication justified, or should the timeout wrap the shared path? Any drift risk (e.g. one path applies applyAdmissionCanaryHeartbeatOverride and the other's behavior must stay in sync)?
- The permit (acquireStateUpdateSendPermit) serializes state_update sends. Does introducing this global send permit interact correctly with heartbeat/diagnostic/drain sends that also call send(_:) but do NOT take the permit? Could a lifecycle send and a capacity send now interleave on the socket, or conversely does the permit create a new serialization bottleneck for lifecycle-critical sends?
- Generation-based lifecycle (requestCapacityTransitionGeneration, activeRequestCapacityTransitionGeneration): is this the right mechanism, and is it consistent with how the rest of the class fences reconnect/session lifecycle?
- Alignment with the governing SPEC for provider capacity/state reporting (search specs/ for the relevant SPEC-NNN, e.g. state_update / metrics_snapshot / request_capacity semantics). Flag any wire-contract drift (new reasons "request_capacity_available"/"request_capacity_full"/"thermal_throttled", state derivation) that the coordinator or a SPEC may not expect.

Do NOT report the pre-existing Swift-6 concurrency warnings as architecture defects (they predate this branch; package is not in Swift 6 mode).

Output findings severity-rated CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and concrete reasoning. State explicitly if a severity has no findings. Merge gate: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
