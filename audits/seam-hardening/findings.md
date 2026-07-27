# Seam-Hardening Findings & Remediation

Verdicts against the eight seams. `file:line` are in our own repo. Tripwire tests (where
built) live in `harness/` and are named `TestSeam*`.

## Scorecard

| Seam | Verdict | One-line |
|---|---|---|
| 1 · settlement / deadline | **FAIL** | one flat request wall-clock; two money-integrity gaps |
| 2 · cache-tenant-isolation | **PASS by construction** | server-authored account-HMAC scope; KV in-memory only |
| 3 · backend-rollout-safety | **PASS (1 gap)** | strong flags/canary/self-update; perf telemetry not backend-segmented |
| 4 · attestation-honesty | **FAIL (client-facing)** | prose honest, but stat surfaces over-claim hardware trust |
| 5 · fleet-version-floor | **PASS (2 gaps)** | blocks incompatible/known-bad builds; capacity trusted blindly |

Fundamentals are strong (cache isolation, rollout discipline, signed-catalog admission,
honest prose). Exposure concentrates in two client-facing FAILs (settlement flat-wall,
attestation schema) plus a shared observability gap (capacity/backend telemetry).

---

## Findings by severity

### P0 — before enrolling on OpenRouter

**P0-1 · Attestation surfaces report hardware trust that a software key satisfies** — `credibility`
Two machine-readable surfaces — `nodes_hardware_attested` (public network-stats) and the
`/v1/models` `hardware_attestation` state — are computed from `AttestationStatus == "attested"`,
which a self-signed software P-256 key satisfies (`phase4-coordinator/.../poolsnapshot.go:77-78`,
`internal/buyer/server.go:898-925`). The `hardware` tier is never emitted, and the hardware-rooted
controls are gated off in prod. A client trusting the field over-trusts the fleet.
**Fix:** gate both surfaces on `AttestationTier == "hardware"` (never true today) or rename to
key-custody (e.g. `nodes_key_attested`). Buyer prose already says "no hardware attestation" — bring
the schema up to the prose. *Tripwire: none yet (add a pool-snapshot unit test).*

**P0-2 · Single request wall-clock kills healthy long generations** — `ranking` — test `TestSeamH1`
**FIXED gateway-side (issue #760).** `upCtx = context.WithTimeout(r.Context(), CoordinatorTimeout())`
(`phase5-gateway/.../chat_proxy.go:122`, default 300s) spanned the whole request; it was enforced on a
mid-stream generation via the transport closing the body on `upCtx` expiry (the read loop is on
`r.Context()`+the idle timer). A legitimate long stream that kept emitting was cut at the wall → 5xx
against our public error rate. The wall had a second, hidden copy in `http.Client.Timeout`
(`cmd/gateway/main.go`), which also covers body reads.
**Fix (shipped):** one cancel funnel (`context.WithCancelCause`) with per-phase budgets in
`phase5-gateway/internal/router/request_deadlines.go` — `admission` (120s) → `first_token` (120s) →
a never-re-armed `stream_ceiling` = clamp(60s + `max_tokens`×250ms, ≥ `coordinator_request_seconds`,
≤ 900s) — plus the decode-idle timer converted from "any byte" to CONTENT progress, `Client.Timeout`
dropped to 0 with the connect budget moved to dial/TLS, and the concurrency lease scaled to the
effective ceiling. Non-streaming keeps a flat wall (`non_stream_request_seconds`, 300s, unchanged).
`TestSeamH1` flipped to `ProgressingStreamSurvivesLegacyWall` (PASS = certifies the fix).
**Residual (not fixed here):** the coordinator has the same flat-wall shape one hop up
(`phase4-coordinator/internal/buyer/server.go` attempt ctx, `routing.request_timeout_s` 280s;
`providerhttp/client.go` 300s), so buyer-visible improvement past ~280s needs the prod overlay raised
to ≥ the gateway ceiling and `check-deploy-config.sh` C2/C2b retargeted at the streaming ceiling.
Structured-output streams also keep a hard 300s sub-ceiling: SPEC-019 v0.2.4 §AC-V2-9 pins that
number, and raising it is a contract change requiring a spec amendment.

**P0-3 · Provider health struck on buyer/gateway cancellation** — `supply` — test `TestSeamH3`
The `ErrRelayTimeout` branch (`phase4-coordinator/internal/buyer/server.go:2994-2996`) calls
`recordBreakerFault` unconditionally; its `ErrRelayClosed` sibling (`:2997-3002`) guards on
`r.Context().Err() != nil`. A buyer cancel racing a relay timeout strikes the provider; two strikes
in 120s degrade it (`pool/provider.go:1574`) → dropped from routing.
**Fix:** add the `r.Context().Err()` guard to the `ErrRelayTimeout` branch; twin fix on the streaming
path (`forwardWSStreamingBuffered:3299`).

### P1 — before real volume

**P1-1 · Retry double-bill without a stable request id** — `money` — test `TestSeamH5a` · issue #200
An id-less buyer retry (which OpenRouter does) mints a fresh request_id (`server.go:240-244`) → a new
reservation → billed again. **Fix:** gateway-native `Idempotency-Key` dedupe (tracked in #200).

**P1-2 · Settlement not crash-durable** — `money` — test `TestSeamH7`
On the streaming after-commit path, if `SettleReservation` and the `EnsureUsageEvent` fallback both
fail (`phase5-gateway/.../chat_proxy.go:1974-1993`), the gateway logs, refunds, and drops the usage
row — the buyer already got a committed 200. Tokens delivered, nobody billed, no durable record.
**Fix:** append-only settlement journal keyed by (account, request_id)+effect, written before dispatch,
sealed on terminal, with a startup recovery scan. Reservation-before-dispatch already exists.

**P1-3 · Capacity trusted blindly; no clamp, no tripwire** — `ranking`/`supply` (closes a slice-3 + slice-5 gap)
Provider-reported `max_concurrency` is granted verbatim (`phase4-coordinator/internal/ws/server.go:2249`,
`:4196`, `relay.go:423`); the only drift signal is observe-only + default-off (`pow/drift.go:218`,
`config.go:104`). A stale/over-claiming build serves silently. **Fix:** `min(hello, ceiling)` capacity
clamp + a permanent over-claim tripwire counter on the heartbeat path, and segment TTFT/TPS rollups by
`binary_version`/backend (`stats/handlers.go:78`). Keep the verified-benchmark baseline (`drift.go:151`).

**P1-4 · Runtime perf gate fails open on absent benchmark** — `ranking`
`pow/drift.go` skips the TPS/hash check when `!hasBenchmark` — un-benchmarked providers are silently
un-gated. **Fix:** treat "no verified benchmark" as quarantine-until-proven (absence = suspect).

### P2 — debt

**P2-1 · Single-terminal-wins request arbiter** — `money` — H4 (blocked)
No arbiter joins the billing terminal (`billing_recorder.go:220`) and the buyer-504 terminal
(`server.go:2996`); billing can complete while the buyer is told it timed out. **Fix:** a terminal
latch/actor. Not unit-testable until it exists (see `harness/` H4).

**P2-2 · Version floor unset in prod + client can't parse the rejection** — `supply`
`required_binary_version` is set nowhere in prod config, and the Swift client has no `case 4004`
(`phase3-binary/.../CoordinatorClient.swift:1460-1499`) → a below-floor close is a silent reconnect
loop, not an upgrade directive. **Fix:** set the floor in the prod overlay, add a `4004` handler + an
upgrade directive, add a `doctor` subcommand.

**P2-3 · No per-model version floor** — `supply`
Only a per-model *hardware-tier* gate exists; an old-but-hardware-eligible build can serve a model that
needs a newer engine. **Fix:** add a per-model minimum-version floor to the routing gate.

**P2-4 · Hygiene: hello-gate spec vs prod config; same-account timing risk** — `hygiene`
`SPEC-032` claims the hello-gate is prod-on; committed prod config does not set it (also confirm
`canary_enabled`/`warmup_gate_enabled` are ON in the live overlay — Go zero-value OFF). And if sticky
routing is enabled for multi-tenant traffic, document acceptance of the residual same-account TTFT
timing side-channel. **Fix:** reconcile spec vs overlay; write the risk-acceptance note.

---

## Verified strengths — do not regress

- **Cache-tenant isolation (seam 2):** conversation/cache scope = `HMAC(secret, scope‖accountID‖tag)`
  server-side (`phase5-gateway/.../chat_proxy.go:2061`); KV cache in-memory only. No cross-tenant oracle.
- **Rollout discipline (seam 3):** default-OFF engine flags + kill switches; signed compatibility-set
  floor with mandatory rollback set; correctness canary; verified-predecessor self-update + quarantine.
- **Admission (seam 5):** compat-set + signed-catalog + model-hash, enforced at connect **and** reconnect,
  ON in prod. Blocks incompatible/known-bad builds cleanly.
- **Honest buyer prose (seam 4):** copy that says "no hardware attestation" + a MUST-NOT-claim list.

## Cheapest-first sequence

1. **P0-1** + **P0-3** — two-line changes, highest stakes-per-character.
2. **P0-2** — the flat-wall decomposition.
3. **P1-3** — one clamp+tripwire closes the seam-3 and seam-5 gaps together.
4. **P1-1 / P1-2** — money integrity before real buyer volume.
5. P2 as debt burn-down.
