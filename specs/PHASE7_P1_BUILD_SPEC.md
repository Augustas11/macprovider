# Phase 7 P1 Build Spec — Provider Availability & Fitness (server-side)

**Date:** 2026-05-29
**Status:** BUILD SPEC — ready to implement, pending operator nod on sequence.
**Parent:** `specs/PHASE7_HARDENING_PLAN.md` (P1).
**Scope decision (operator, 2026-05-29):** P1.1 = Both, P1.2 = Both, P1.3 =
**no client update for now.** Reconciled: build everything **server-side**
(coordinator + gateway); the v1.2.5 `beginActivity` no-sleep assertion (client
half of P1.1 "Both") is **explicitly deferred** to a future partner update.
**No phase3-binary change in this build.**

Touch points below are from a 2026-05-29 code map; verify at implementation.
Specs affected: **SPEC-002** (coordinator) and **SPEC-006** (gateway status).

> **NORMATIVE AUTHORITY (read first).** For **Feature 3**, the spec-first step
> is DONE: **SPEC-002 v1.2.0 `FR-P11a`** (committed) is the source of truth.
> Implement the code to match `FR-P11a` exactly. Where this build spec's
> Feature-3 prose and `FR-P11a` differ, **`FR-P11a` wins** — it incorporates
> two independent review rounds (the streaming-vs-non-streaming cancel
> attribution, the qualified zero-token rule, the re-trip→`unavailable` flap
> guard, per-relay fault attribution, counter-reset semantics, and the
> `pool.breaker_*` config keys). Do NOT change any SPEC-001 / phase3-binary
> code. Features 1 and 2 still need their SPEC-006 / SPEC-002 normative text
> drafted before they are implemented (Step 0 per feature).

---

## Feature 3 — Runtime circuit-breaker (do FIRST: highest leverage, lowest risk)

**Goal.** A provider that repeatedly fails *in-flight* inference (dead WS
mid-request, relay timeout, or zero tokens produced) is automatically marked
`degraded`, removed from buyer routing, and recovered via probe — exactly like
HTTP 502/504 already are. Stops the "augustass keeps getting traffic it can't
serve" failure.

**Current behavior (map).**
- `internal/buyer/server.go:1078` `handleProviderFailure()` degrades on HTTP
  502/504 and calls `startRecoveryProbe()` (`:1092`, exponential backoff,
  preflight-based recovery, defaults 30s / 3 retries).
- Config keys `degraded_backoff_s`, `degraded_max_retries`,
  `degraded_probe_after_502` exist (`internal/config/config.go:47-49`) but are
  **never read** — the values are hardcoded via `s.recoveryBackoff` /
  `s.recoveryMaxRetries`.
- WS-dead-mid-request (`:349-375`, `:391-412`), relay timeout
  (`internal/ws/relay.go:208`), and the HTTP network-error path (`:440-450`)
  **only log + fast_fail/failover** — they never degrade the provider. So a
  stuck provider keeps receiving traffic.

**Design.**
1. **Wire the existing config keys** (`degraded_backoff_s`,
   `degraded_max_retries`) into `s.recoveryBackoff` / `s.recoveryMaxRetries` so
   they're operator-tunable instead of hardcoded. (Pure cleanup; removes dead
   config.)
2. **Trip the breaker on in-flight failures.** Add a per-provider failure
   counter (rolling window) in the registry. On `ws_dead_mid_request`,
   relay-timeout, and "completed with zero tokens", increment it; when it
   crosses a threshold (`pool.breaker_failure_threshold`, default e.g. 2
   within `pool.breaker_window_s`, default 120s), call the existing
   `handleProviderFailure()`/degrade path + `startRecoveryProbe()`. A single
   transient blip should NOT degrade (avoid flapping healthy providers on one
   buyer cancel) — hence threshold + window.
3. **Distinguish buyer-cancel from provider-fault.** A buyer hangup (context
   canceled by `r.Context()`) MUST NOT count against the provider — only
   provider-side faults (WS death the provider caused, relay timeout with no
   bytes, zero-token completion) trip the breaker.

**Config (SPEC-002).** Wire `pool.degraded_backoff_s`,
`pool.degraded_max_retries`; add `pool.breaker_failure_threshold` (default 2)
and `pool.breaker_window_s` (default 120).

**Acceptance.**
- A provider that dead-WSes / 0-tokens ≥ threshold within the window is marked
  `degraded`, receives no buyer routing, and is recovery-probed back to `ready`
  on success.
- A buyer-canceled request does not degrade the provider (regression test).
- The previously-unused `degraded_*` config keys now take effect.

**Tests.** Extend `internal/buyer/server_test.go` fault doubles
(`internal/testfaults/`): simulate repeated dead-WS → assert degrade + no
routing + recovery; simulate buyer-cancel → assert NO degrade.

**Touch points.** `internal/buyer/server.go` (`handleProviderFailure`,
`logWSDeadMidRequest`, the WS-dead + timeout paths), `internal/pool/provider.go`
(failure counter), `internal/config/config.go` (wire + add keys),
`internal/ws/relay.go` (timeout signal). Reuses `startRecoveryProbe`.

**Risk.** Touches the money path's failure handling. Mitigate: threshold+window
to avoid flapping; strict buyer-cancel exclusion; full test coverage; review pass.

---

## Feature 1 — Sleep-tolerant status & messaging

**Goal.** Idle providers napping is normal, not "down." A buyer/console should
never see an alarming red "down" when the system is healthy and providers are
simply asleep; and per-model availability should be clear.

**Current behavior (map).** Gateway `aggregateStatus()`
(`internal/router/server.go:1114-1172`): `status="down"` iff `Pool.Ready==0`;
`degraded` iff `Ready < readyProviderDegradedThreshold`. Routing itself is
already sleep-tolerant (`no_provider_available` on empty). Coordinator
`/healthz` + `/poolz` are plain snapshots.

**Design.**
1. **Reframe top-level status semantics (SPEC-006):**
   - `down` should mean **infrastructure broken** (coordinator unreachable) —
     keep that.
   - `Ready==0` but coordinator reachable → new state **`idle`** (or
     `no_providers_available`), NOT `down`. Distinct, non-alarming.
   - Keep `degraded` for partial capacity.
2. **Per-model clarity:** ensure the `models[]` block clearly conveys
   "currently no awake provider for this model" vs "available", so the console
   can show "providers asleep — wake one / try again" instead of a generic
   failure.
3. **Console copy (frontdoor/console/index.html):** render the `idle` state as a
   friendly "no providers awake right now" with the per-model detail, not a
   hard error. (Static-site copy change only.)

**Config.** None required (reuse `ready_provider_degraded_threshold`).

**Acceptance.**
- Coordinator reachable + 0 ready → status `idle` (not `down`); console shows a
  friendly message, not a red error.
- Coordinator unreachable → status `down` (unchanged).
- A buyer requesting a model with ≥1 awake provider never sees a system-level
  down/idle.

**Tests.** Gateway `internal/router/server_test.go`: `aggregateStatus()` cases
for reachable-but-empty (→ idle), unreachable (→ down), partial (→ degraded).

**Touch points.** `phase5-gateway/internal/router/server.go`
(`aggregateStatus`, `statusFromPoolz`, status struct), `frontdoor/console/index.html`,
SPEC-006 status-semantics section.

**Risk.** Low. Status-label + copy change; no routing impact. Confirm no
downstream consumer treats the new `idle` string as fatal.

---

## Feature 2 — Warm-up capability gate (do LAST: most new code)

**Goal.** A provider must *prove it can produce a token* before it receives
buyer traffic, so a box that reports `ready` but can't actually serve (cold-load
forever / swap) never gets a buyer request.

**Current behavior (map).** `handleConn()` (`internal/ws/server.go:206-231`)
sets `State=Ready` immediately on hello — no capability check. The `warm_up`
flow (`markDegradedForWarmup` `:513`, 60s hardcoded fallback `warmupFallback`
`:603`, recovery via provider `state_update` `:480`) exists only for
wake-from-sleep. `throughput_tps_estimate` is self-reported and only used as a
routing tie-breaker.

**Design.**
1. **Admission starts NOT-routable.** On hello, register the provider in a new
   state (reuse `StateDegraded`, or add `StateWarming`) — eligible for nothing
   buyer-facing until it passes the gate.
2. **Capability probe.** Coordinator issues a minimal self-test inference
   (1–2 tokens) — either a new `capability_check` message or a reuse of the
   preflight+tiny-inference path. Provider must return a token within
   `pool.warmup_gate_timeout_s` (default generous, e.g. 90s to allow cold model
   load). Success → `Ready`. Failure/timeout → `Unavailable` with a clear reason
   (`warmup_failed`), retried on a backoff (reuse recovery-probe).
3. **Do NOT trust self-reported tps** as the gate (unreliable); the gate is an
   actual token, not a number.
4. **Interaction with Feature 3:** a provider that passes the gate but later
   regresses is caught by the circuit-breaker. Gate = proactive; breaker =
   reactive. Together they cover admission + runtime.

**Config (SPEC-002).** `pool.warmup_gate_enabled` (default true),
`pool.warmup_gate_timeout_s` (default 90), `pool.warmup_gate_max_tokens`
(default 2). Make `warmupFallback` config-driven while here.

**Acceptance.**
- A provider that cannot produce a token within the gate timeout never reaches
  `Ready` / never receives buyer traffic; logged with `warmup_failed`.
- A healthy provider (incl. one with a slow cold-load under the timeout) passes
  and serves.
- Gate is skippable via config for trusted/pinned providers if needed.

**Tests.** `internal/ws/server_test.go`: provider that never returns a token →
stays out of pool; provider that returns within timeout → Ready. Fault double
in `internal/testfaults/` for "accepts inference but never produces a token."

**Touch points.** `internal/ws/server.go` (`handleConn` admission, new
capability-probe flow, `warmupFallback`), `internal/pool/provider.go` (state),
`internal/config/config.go` (keys), SPEC-002 admission section. Possibly
`internal/buyer/`/`internal/ws/relay.go` to drive the self-test inference.

**Risk.** Medium-high. Adds an admission-time inference round-trip; cold-load
timing must be generous or it false-rejects slow-but-working providers. New
provider state interacts with routing, drain, heartbeat monitor, and failover —
needs careful testing. This is why it's sequenced last.

---

## Recommended build sequence

1. **Feature 3 (circuit-breaker)** — mostly wiring existing machinery; immediate
   buyer-experience win; lowest risk. Ship + review + verify, then:
2. **Feature 1 (status semantics + console copy)** — low risk, high perceived
   polish; makes the dashboard honest.
3. **Feature 2 (warm-up gate)** — most new code + most interactions; do last
   with the breaker already as a safety net.

Each lands as its own commit + independent review pass, verified against a
healthy remote provider (NOT the operator's local Mac).

## Deferred (not this build)

- **v1.2.5 `beginActivity` no-sleep assertion** (client half of P1.1 "Both") —
  per P1.3, no partner update now. Roadmap item for when provider liquidity
  warrants a binary release.
