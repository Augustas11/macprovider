# Phase 7 Hardening Plan

**Date:** 2026-05-29
**Status:** PLAN — not scoped/approved/built. Decision-ready for next session.
**Author context:** Derived from the 2026-05-29 deploy session (see
`beta/DECISION_CRITERIA.md` Entry 30 + `specs/PHASE3_BINARY_KEEPALIVE_ROOT_CAUSE.md`).
**Guiding principle:** Harden the live system before adding new spec surface.
North Star = a stranger hitting `console.streamvc.live` gets a fast, reliable
completion *every time*. Today proved the system works end-to-end but is
operationally fragile; this plan stabilizes it.

---

## Why hardening, not new specs

Today's work didn't reveal missing features — it revealed that what's built is
**live but brittle**:

- A liveness regression slipped past the Phase 6 audit (35s heartbeat-miss kill).
- Config drifted between coordinator (`request_timeout_s: 300`) and gateway
  (`coordinator_request_seconds: 120`).
- Idle provider Macs sleep → pool flaps → buyers intermittently see
  "down" / "no provider available".
- An underpowered provider (8GB / Llama-3B @ 0.6 tps) reports `ready` but
  produces zero tokens in 290s.
- The front-door web app sat built-but-undeployed until today.
- A pre-existing flaky test (`TestProviderTokenAuthFlow`).

That is the signature of a base to stabilize, not extend. New spec surface on a
flapping base just multiplies debugging at 0.6 tps.

---

## P1 — Buyer-facing reliability (the credibility issue)

### P1.1 Provider availability — idle Macs sleep and flap

**Problem.** Idle, unattended provider Macs go to system sleep, freezing the
binary; it stops sending all frames, the coordinator reaps it at the 90s
liveness threshold, and it reconnects on wake. Pool oscillates; buyers see
intermittent unavailability.

**Evidence (today).** `air8gb` cycled connect → clean 30s heartbeats →
abrupt total silence → reap (gap ~90s) → reconnect, repeatedly (8.5 min, 4 min
gaps). `air5` napped mid-test. `augustass` only stayed up because the operator
was actively using it. Disproves the original NAT-idle theory: it's machine
sleep.

**Candidate approaches (NOT yet chosen — see Open Questions):**
- **(A) Keep providers awake (client v1.2.5):** binary holds
  `ProcessInfo.processInfo.beginActivity([.idleSystemSleepDisabled,
  .automaticTerminationDisabled], reason: …)` for the lifetime of the
  coordinator session; disable App Nap. **Caveat:** `.idleSystemSleepDisabled`
  does *not* prevent **clamshell (lid-closed)** sleep — a closed-lid MacBook
  still sleeps regardless. Full coverage needs AC power + lid open, or
  `caffeinate`/`pmset`. So this helps lid-open idle machines, not closed ones.
- **(B) Operational stopgap (no code):** run the provider under
  `caffeinate -is`, or `pmset -c sleep 0 disablesleep 1` on AC machines. Wrap
  in the launchd plist. Zero partner-binary change.
- **(C) Make the *buyer experience* sleep-tolerant instead (server-side):** treat
  napping as normal — never surface "down" when any provider for the requested
  model is awake; route only to awake providers; show a clear per-model
  availability state. This accepts that hobby providers come and go and makes
  the marketplace degrade gracefully rather than forcing machines awake.

**Scope/risk.** (A) = a real v1.2.5 build + partner update (bundle ALL client
changes into one update). (B) = docs + plist edit. (C) = SPEC-002/SPEC-006
routing + status-semantics change, no client update.

**Acceptance.** A buyer requesting a model with ≥1 awake provider never sees
"down"; and/or an AC-powered lid-open provider stays connected indefinitely.

### P1.2 Provider fitness — "ready" but can't actually serve

**Problem.** A provider can report `ready` yet be unable to generate (cold-load
/ swap on undersized RAM). The coordinator routes buyer traffic to it; the buyer
waits out the timeout → 503.

**Evidence (today).** `augustass` (8GB, Llama-3B @ 0.59 tps) produced **0 tokens
in 290s** while its WS stayed healthy. The coordinator correctly didn't reap it
(it was heartbeating) but it also shouldn't have been eligible for buyer routing.

**Candidate approaches:**
- **Warm-up gate:** require a provider to pass a self-test (produce a token
  within N s) before it's `ready` for buyer routing. The `warm_up` message
  already exists; extend it to a capability proof.
- **Circuit-breaker / rolling health:** track per-provider success + first-token
  latency; auto-`degraded` a provider that repeatedly 0-tokens or times out;
  recover on a successful probe (degraded/backoff machinery already exists).
- **Hardware/throughput floor:** providers below an X-tps floor for their model
  size are tier-weighted down or excluded from buyer routing (still usable for
  their own direct traffic).

**Scope/risk.** SPEC-002 (admission/routing) change; coordinator code; no client
update for the circuit-breaker variant. Marketplace-policy implications (see
Open Questions).

**Acceptance.** A provider that can't produce a first token within N seconds is
marked `degraded` and receives no buyer traffic until it proves healthy.

---

## P2 — Operability (stop flying blind)

**Problem.** Every diagnosis today required hand-SSHing Pearl journals. No
alerting, no historical metrics, no flap detection.

**Candidate approaches (keep lightweight; no new vendors per Bδ):**
- **Synthetic canary:** periodic tiny completion against a known-good provider;
  alert on failure or latency blowout.
- **Threshold alerts:** notify on `pool ready == 0`, coordinator unreachable,
  money-path probe failing, or high provider-flap rate.
- **Metrics surface:** a `/metrics` (Prometheus-style) or structured-log ship for
  history; `/poolz` + `/v1/status` already give point-in-time state.
- Delivery via cron-on-Pearl + push notification / email.

**Acceptance.** Operator is notified within minutes of pool-empty or money-path
failure without watching logs. (This also lets us *verify* P1 fixes actually
hold.)

---

## P3 — Housekeeping (fast, low-risk)

- **DECISION_CRITERIA Entry 31:** record the `console.streamvc.live` go-live
  (built in Entry 28; deployed 2026-05-29 — DNS + LE cert + nginx + static).
- **`frontdoor/console/dist/deploy-console.sh`:** idempotent deploy script
  mirroring `phase4-coordinator/dist/deploy-pearl-vps.sh` (stub → certbot →
  full vhost → static copy), so the console deploy is reproducible, not the
  manual steps run inline today.
- **Flaky `TestProviderTokenAuthFlow`:** close-frame-vs-EOF race (fails ~2/8 on
  clean HEAD). Already spawned as a separate task.

---

## Process hardening (cheap, high-leverage)

- **Audit checklist gap:** the Phase 6 audit verified the heartbeat-close worked
  *as coded* but never asked whether 35s was viable for real MLX latencies. Add
  an **"operational-threshold realism"** check to the audit template: for every
  timeout/threshold, does it hold against the slowest realistic provider/workload?
- **Config-drift guard:** coordinator `request_timeout_s` and gateway
  `coordinator_request_seconds` must stay aligned; the live values had drifted.
  Consider a deploy-time assertion or a single source of truth.

---

## Deferred — new spec/feature surface (revisit after P1)

Billing/settlement, provider payouts, reputation/trust scoring, multi-region
coordinator, richer buyer onboarding beyond the demo. None are blocked by a
*missing* capability today; all are premature until P1 reliability holds.

---

## Suggested sequence

1. **P3 housekeeping** — clears the deck (hours, not days).
2. **P2 canary + pool-empty alert** — minimal, so we can *see* reliability.
3. **P1.2 provider fitness** (server-side, no client update) — stops the worst
   buyer experience (routing to a box that can't serve).
4. **P1.1 availability** — decide approach (C server-side graceful vs A+B keep-awake)
   first; if a client change is chosen, batch it into a single v1.2.5.

(Sequence is a recommendation, not a mandate — reorder to taste.)

---

## Open questions for the operator (decide before building)

1. **P1.1 philosophy:** force provider Macs to stay awake (power cost; partial —
   no help for closed lids), or make the marketplace gracefully tolerate
   providers coming and going (server-side, no client update)? Recommendation:
   lean (C) graceful-tolerance as the primary fix, with `caffeinate` guidance
   for operators who want their machine always available.
2. **P1.2 policy:** hard-exclude underpowered providers from buyer routing, or
   soft de-rank them? Affects provider earning in the marketplace model.
3. **v1.2.5:** is there appetite for *any* partner binary update right now? If
   yes, batch every desired client change into one. If no, prefer server-side
   options (C, circuit-breaker) that need no update.
4. **Observability delivery:** where should alerts go (push, email, a channel)?
