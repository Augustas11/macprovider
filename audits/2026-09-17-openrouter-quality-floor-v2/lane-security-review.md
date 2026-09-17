You are a senior security reviewer auditing a Swift change to the MacProvider provider CLI.

Context:
- Repo: macprovider (Apple Silicon MLX inference provider), provider-side CLI actor that reports request-capacity/state to the coordinator over a WebSocket. Provider capacity signals drive coordinator routing admission, which is money-path adjacent (buyers are billed for routed inference).
- Branch: codex/openrouter-quality-floor-v2, issue #1570 (OpenRouter filing readiness).
- The change makes request-capacity slot publication more precise/timely and adds a bounded (timeout) capacity state_update send path.

The full fix diff (base = origin/main, which contains none of this fix) is at:
  audits/2026-09-17-openrouter-quality-floor-v2/full-fix.diff

Also read for context:
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
  phase3-binary/Sources/macprovider-cli/ProviderStatus.swift

Review for security and trust-boundary issues only:
- Capacity misrepresentation: can the new slot-delta/coalescing logic cause the provider to advertise MORE free capacity than it truly has (over-admission → buyer requests routed to a saturated provider → failed/again-billed work), or advertise a stale "ready" after it is actually full? Focus on the wire frame built in sendStateUpdate(transition:) and the fresh-final-snapshot re-check.
- Lifecycle/operator-pause fence integrity: can a thermal/request-capacity refresh overwrite an operator pause/drain fence and cause the provider to keep accepting work after an operator told it to stop? (setRequestCapacityChangeHandler, refreshAvailabilityState guards, generation checks.)
- The bounded-send timeout cancels the WebSocket (socketRef.cancel(with: .goingAway)). Can a slow/hostile coordinator or a crafted backpressure condition weaponize this to force repeated socket teardown (self-inflicted DoS / flap), or to skip publishing a "now full" transition and strand the provider in an over-available state?
- Generation/stale-sender guards: can a stale sender mark a new baseline as published (suppressing a real capacity change) — an integrity issue for routing decisions?
- Any secret/credential/PII exposure in new log lines (keepaliveDebug ws_send, error logs). Confirm no payload contents or tokens are logged.
- Info leak or injection via the metrics_snapshot / reason fields now derived from thermal state.

Do NOT report the pre-existing Swift-6 `SendingRisksDataRace`/non-Sendable warnings (they exist on origin/main; package is not in Swift 6 mode) unless one represents an actual exploitable data race on shared mutable state.

Output findings severity-rated CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and a concrete exploit/failure scenario. State explicitly if a severity has no findings. Merge gate: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
