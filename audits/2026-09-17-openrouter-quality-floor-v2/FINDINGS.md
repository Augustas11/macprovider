# Audit findings — openrouter-quality-floor-v2 (issue #1570)

Date: 2026-09-17
Base for full-fix diff: `origin/main` (d45ba4db) — contains no part of this fix.
Scope audited: full combined fix diff (`full-fix.diff`, 1564 lines) over
`CoordinatorClient.swift`, `ProviderStatus.swift`, and their tests.

Three independent codex (gpt-5.5) lanes were run over the full-fix diff.

## Gate result: PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

### Lane 1 — code review (correctness)
- CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0.
- INFO 1: the wedged-send test uses `FakeProviderWebSocketTask`, which still
  accepts frames after `cancel()`; the test proves operator pause no longer
  waits behind a wedged capacity send, which matches the design (cancelling the
  socket is itself the stale-route escape hatch). No correctness defect.
- Verified: 4 targeted tests passed.

### Lane 2 — security / trust boundary
- CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0.
- INFO: capacity frames are built from a fresh final `ProviderStatus.snapshot()`
  (not the queued transition), so coalescing cannot over-advertise free slots;
  thermal throttle forces `slots_free = 0`. Operator pause/drain fences are not
  overwritten by capacity refresh. Bounded-send socket teardown is fail-closed
  (snapshot not marked published unless send completes and generation matches).
  No payload/token/secret/PII logging in the new path.

### Lane 3 — architecture / design
- CRITICAL 0 / HIGH 0 / MEDIUM 0.
- LOW 1: thermal observation now sits on the request admission/completion path;
  acceptable because `ThermalGate` reads cached notification state, but a
  ProviderStatus-owned cached thermal mirror would be cleaner if TTFT becomes
  sensitive. (Carried.)
- LOW 2: `sendCapacityStateUpdateBounded` duplicates the send prepare/serialize
  path to add a timeout; behavior is currently in sync
  (`applyAdmissionCanaryHeartbeatOverride`, `sendOverride`, JSON options, send
  tracing) — drift risk only. (Carried.)
- LOW 3: thermal throttle is represented on the wire as `state:"busy"`,
  `reason:"thermal_throttled"`, `slots_free:0`; wire-compatible with the
  coordinator ready/busy state machine but slightly stretches SPEC-001's
  "busy = all request slots occupied" wording. Recommend a SPEC-001 note that
  blesses thermal-derived busy. (Carried; documented in PR body.)
- INFO: ordering/latest-wins coherent end to end; no unbounded wire-vs-truth
  divergence path; the state-update permit intentionally serializes lifecycle +
  capacity `state_update` frames while leaving heartbeat/diagnostic/drain on the
  normal path; generation fencing aligns with session lifecycle.

## Delta applied by this session on top of the handoff branch
Restored the `sending [String: Any]` annotation on `SendOverride`, `send(_:)`,
the static `send(_:to:)`, and the new `sendCapacityStateUpdateBounded(_:)`. The
handoff branch had dropped `sending`, which did not remove any warning (the
`SendingRisksDataRace` / non-Sendable `[String:Any]?` / region-isolation
warnings are pre-existing on origin/main and the package is not in Swift 6
language mode) and only made the send signatures diverge from main. Restoring it
makes the send signatures byte-identical to main and leaves the branch's only
net-new Swift-6-mode advisory in the new bounded-send function, mirroring the
already-shipping `send(_:)` pattern.

## Test evidence (this session)
- `swift build` → exit 0, no new CoordinatorClient warnings beyond the
  pre-existing origin/main pattern.
- `swift test --filter RequestCapacity` → 17 passed, 0 failures.
- `swift test --filter "CapacityRefreshDoesNotOverwriteLifecycleFenceAfterThermalAwait|ProviderStatusTests"`
  → 53 passed, 0 failures.
- Full `swift test` not run to completion locally: unrelated MLX metallib env
  failure in `StageForwardParityTests` (not in the request-capacity path).
