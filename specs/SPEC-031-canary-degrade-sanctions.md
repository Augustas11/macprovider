# SPEC-031 — Canary Probe, Degrade & Sanction Lifecycle

**Status:** v0.1-draft
**Date:** 2026-07-11
**Depends on:** SPEC-002 (coordinator provider state machine: FR-P5 routing eligibility, FR-P8a admission warm-up, FR-P11a circuit-breaker; F-2 amendment defines provisional/pinned admission), SPEC-003 (open provider onboarding, tier semantics), SPEC-006 §5.2 / §17.2 (buyer error contract, 404/503), SPEC-008 (attestation — owns model/weight identity claims), SPEC-018/019 (buyer error envelope + `retryable`)
**Related infrastructure:** SPEC-030 (losslessness probe) is a *distinct* probe subsystem; SPEC-031 does not govern it. Per SPEC-030 FR-1 the two **MAY** share generic scheduling/jitter/persistence infrastructure but **MUST** keep separate carriers, frames, verdicts, state, and sanction paths (see §17).
**Companion baseline (separate spec):** proof-of-weights / OPoI semantics + the autotune hello-gate are runbook item 9's normative baseline; this spec defines only the canary *mechanism* those features build on, and explicitly does **not** make weight-integrity claims (see §1, §2, and the CRITICAL reframing in the changelog).

**Numbering note.** Assigned canonical **SPEC-031** on 2026-07-11 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 8). Highest prior canonical
spec was SPEC-030. This subsystem shipped incrementally across PRs #478, #491,
#512, #513, #524, #528, #531, #533, #538 and produced three production incidents
in 48 hours (2026-07-09/10) with **zero governing spec** — `SPEC-002-coordinator.md`
mentions the word "canary" exactly once and does not define the probe body, the
failure taxonomy, the sanction lifecycle, or the buyer contract during degrade.
This document is the reconstructed normative baseline; where it *tightens* or
*adds to* the shipped code, the conformance table in §14 says so explicitly.

---

## 1. Purpose

The coordinator periodically issues a small, deterministic **canary probe** to
each connected provider. The probe is a **liveness + instruction-following +
freshness** check. It proves that the provider's inference endpoint is:

1. **reachable and answering** within a deadline (liveness),
2. **following a trivial instruction** — echoing a fresh random nonce exactly
   (instruction-following / not returning garbage or a truncated response), and
3. **producing a fresh per-request response** — each probe carries a newly
   drawn random nonce, so a passing echo is not a stale cached answer. This is
   *probabilistic* freshness, not a uniqueness or replay-resistance guarantee:
   the shipped nonce is a 32-bit random draw with no replay cache (collisions
   become likely after ~10⁴–10⁵ probes), so the spec does not claim non-replay
   as a proven property (see FR-CAN2 for the freshness bound and the hardening
   option).

**What the canary is NOT.** The nonce is transmitted in the clear inside an
ordinary, fingerprintable inference request; any model — including a cheaper or
substituted one — or even a canary-aware string handler can extract the visible
nonce and echo it **without running the admitted weights**. The canary is
therefore **not** proof of model identity, quantization level, or weight
integrity, and a probe pass is **not** an anti-downgrade guarantee. Model/weight
identity is owned by **SPEC-008** (attestation) and by runbook item 9's future
proof-of-weights / OPoI baseline, which must supply a weight-bound statistical or
cryptographically attested test before any payment-integrity claim is made. This
boundary is consistent with SPEC-008 §3/§5.1 (which deny model-identity and
malicious-provider resistance for un-bound probes) and SPEC-030 §4 (which treats
overt probe results as self-attested implementation-health evidence only).

On repeated failure the coordinator **sanctions** the provider — removing it from
buyer routing (degrade) or evicting it (provisional ban) — and later **recovers**
it when a probe passes again. Because a sanction on the sole provider for a model
converts every buyer request into an HTTP 503, the canary subsystem is a
money-path and availability-path control. This spec defines the probe, the
failure taxonomy, the latency policy, the degrade/ban/recovery state machine
(including its composition with the FR-P11a breaker), sanction persistence,
last-provider protection against correlated coordinator-config faults, the buyer
availability contract, the config/hot-reload contract, and the observability
surface — so the subsystem can be **safely re-enabled in production** (it is
currently disabled on Pearl; see §16).

## 2. Scope

**In scope**

- The `canary` probe profile: scheduling, deterministic body construction,
  transport, and echo/latency validation.
- The normative failure-reason taxonomy (six constants) and its sub-classes.
- The latency-gate policy (`observe` vs `enforce`) and cold-start grace.
- The consecutive-failure → sanction → recovery state machine for both the
  **provisional** and **pinned** tiers, **and its composition with the FR-P11a
  circuit-breaker and other coordinator-owned degrade causes**.
- Sanction persistence and reapplication across coordinator restart, including
  the fail-closed requirements.
- The buyer availability contract while a provider is canary-degraded
  (503 `no_provider_available`, `retryable`, `Retry-After`).
- **Last-provider protection** against correlated coordinator-configuration
  faults (undersized `max_tokens`, a bad shared challenge bank).
- The canary config surface and its reload/restart contract.
- The observability contract (`/poolz` fields, `canary_fail_reason` logging).
- The mechanism (not semantics) of `model_class_challenges` and the OPoI
  pass/fail flag emission.

**Out of scope**

- The **semantics** of proof-of-weights / OPoI and any weight-integrity or
  anti-downgrade claim — runbook item 9's separate spec, building on SPEC-008.
  The canary carries the model-class probe as a payload and emits a pass/fail
  flag; what that flag *proves* is item 9's to define.
- SPEC-030 losslessness probe **in its entirety** — a distinct subsystem with its
  own carrier/frames, verdict, and in-memory state (SPEC-030 FR-1/3/4). SPEC-031
  neither governs it nor shares any canary-specific dispatch, verdict, or sanction
  path with it. Per SPEC-030 FR-1 the two MAY share generic coordinator
  infrastructure (the `Server`, pool snapshots, session lookup, timing/config,
  scheduling/jitter/persistence); SPEC-031 does not require SPEC-030 to run a
  separate scheduler.
- Any buyer-visible `/v1/chat/completions` request or response field. The canary
  is coordinator↔provider only; buyers observe it solely through routing
  eligibility (i.e. whether a 503 is returned).
- SPEC-001 wire-protocol changes. WS-tunneled canary probing reuses the existing
  `inference_request` / `inference_response_chunk` / `inference_response_end`
  frames; no phase3-binary change is required.

## 3. Terminology and roles

| Term | Meaning |
|------|---------|
| **Probe** | One canary request/response round to one provider session. |
| **Sweep** | One pass over the pool that dispatches probes to all providers whose per-provider due time has elapsed. |
| **Nonce** | A fresh per-probe random token substituted into both the prompt and the expected answer. |
| **Challenge** | A `{prompt, expected}` template (both MUST contain `{nonce}`), optionally carrying per-challenge latency SLOs (model-class banks only; see §6). |
| **Correctness failure** | A probe that proves the provider did not return the expected fresh echo — `nonce_mismatch`, `incomplete`. This is a **liveness/instruction-following** failure, **not** evidence of wrong weights. |
| **Infra/liveness failure** | A probe that could not complete — `relay_error`, split into *hard* (transport/session dead) and *soft* (deadline expiry) sub-classes (§5). |
| **Latency failure** | A probe that echoed correctly but breached a wall-time SLO — `ttft_breach`, `tps_breach`. |
| **Sanction** | A coordinator-owned state change removing a provider from routing: **degrade** (pinned) or **admission-reject/ban** (provisional). |
| **Recovery hold** | A coordinator-owned lock preventing a degraded provider from self-reporting its way back to `ready`. Reasons are enumerated (breaker, canary, provider-failure, warm-up, operator-clear); see §7 for composition. |
| **Sole provider** | The only routing-eligible provider for a given model at a given instant. |

Provider **tiers** — `provisional` (self-onboarded, bearer-validated or tokenless)
vs `pinned` (operator-configured) — are defined by SPEC-002's F-2 amendment and
SPEC-003's open-onboarding requirements. SPEC-020 consumes these tiers in its
autoupdate trust table but does not define them. The canary lifecycle differs by
tier (§7).

## 4. Probe mechanism

**FR-CAN1 — Scheduling.** When `pool.canary_enabled` is true, the coordinator
runs a canary loop that performs one immediate sweep at startup, then sweeps on a
ticker at `clamp(canary_interval_s / 10, 1s, 30s)`. Each sweep MUST:

- snapshot the pool and iterate providers in a **cryptographically shuffled**
  order (uniform Fisher-Yates), so probe ordering leaks no schedule a provider
  could game;
- probe each provider at most once concurrently (a per-session in-flight guard);
- schedule each provider's next probe at a **jittered** interval of
  `canary_interval_s/2 + rand[0, canary_interval_s)` (i.e. 0.5×–1.5× the
  configured interval), so probes are unpredictable in time.

**FR-CAN2 — Probe body.** Each probe MUST:

- draw fresh cryptographic random bytes and derive a nonce that is substituted
  into **both** the challenge `prompt` and its `expected` value. Configuration
  validation MUST reject any challenge whose `prompt` or `expected` does not
  contain `{nonce}`. The nonce substitution is deterministic given the drawn
  bytes. The nonce is a **32-bit random draw** (shipped: the first 4 of 5 drawn
  bytes, rendered uppercase-hex); this gives probabilistic freshness only, and an
  implementation that needs true replay resistance SHOULD widen the nonce to
  ≥128 bits and add duplicate rejection.
- select the applicable bank: the per-model `model_class_challenges` bank if the
  provider's admitted model id matches (exact, then case-insensitive), else the
  global `canary_challenges` bank;
- select the challenge from that bank by **fresh random draw**. The shipped
  selector is `challenges[randbyte % len(bank)]` — consecutive probes to the same
  provider may use different challenges, so an implementer MUST NOT assume stable
  per-provider selection. Note this modulo selection is **biased** unless the bank
  size divides 256, and — critically — for a bank **larger than 256 entries the
  entries beyond index 255 are unreachable and never probed**. Validation MUST
  therefore reject banks larger than 256 entries (or the selector MUST use
  rejection sampling / `crypto/rand.Int` for unbiased, fully-covering selection);
  until then, operators MUST keep every bank ≤256 entries. This selection-coverage
  guard is a conformance gap (§14).
- issue the request with **`temperature: 0`** and `max_tokens =
  pool.canary_max_tokens`. **The temperature pin is a normative correctness
  invariant**: without it, low-bit models (measured on 4-bit qwen3-coder-30b)
  transform the nonce and fail the echo gate spuriously (incident #533). An
  implementation MUST pin temperature to 0 (or the provider's most-deterministic
  equivalent) on every canary probe.
- set the **stream mode by probe purpose**: `stream: false` for the current
  echo/liveness probe and any `observe`-mode probe (the shipped default); `stream:
  true` is REQUIRED when — and only when — latency `enforce` is active, because
  FR-CAN8 forbids latency enforcement on a non-streaming metric. FR-CAN2 and
  FR-CAN8 are thus consistent: the shipped `stream:false` is correct for
  today's echo/observe posture, and the streaming probe is a precondition of the
  (currently-Gap) enforce path, not a contradiction of it.

**FR-CAN3 — `max_tokens` sizing.** `pool.canary_max_tokens` MUST be greater than
or equal to the token length of the longest `expected` answer across all active
challenges, plus headroom for any short model preamble. A too-small budget
truncates the nonce echo and produces a spurious `incomplete` failure that is a
**coordinator-configuration fault, not a provider fault** — it can evict a
healthy sole provider (incident #528/#531; the prod default was raised 16→32 for
exactly this reason). Configuration validation SHOULD warn or reject when
`canary_max_tokens` is below a challenge's expected length. Because such
truncation is coordinator-attributable, `incomplete` failures are subject to
last-provider protection (§10).

**FR-CAN4 — Transport.** WS-tunneled providers MUST be probed over the existing
WS relay using the SPEC-001 `inference_request` path; HTTP-forwarding providers
MUST be probed via `POST {endpoint}/v1/chat/completions`. WS-tunneled providers
MUST NOT receive HTTP probes and vice-versa (consistent with SPEC-002 FR-P8a).
Every probe MUST run under a `pool.canary_timeout_s` deadline. (This canary
transport is distinct from and MUST NOT be conflated with SPEC-030's dedicated
losslessness carrier; see §17.)

**FR-CAN5 — Probe model id.** The probe MUST target the provider's currently
**admitted** model key (the autotune-ceiling `MaxAdmittedModelKey` when set, else
the provider's advertised `ModelID`), so the probe at least exercises the model
key buyers are routed to. This **reduces but does not close** the "advertise big,
serve small" gap: a provider that serves the smaller model to the canary too
still passes (see §1 — this is not a cryptographic identity binding).

**FR-CAN6 — Validation order.** Given the provider's output, the coordinator MUST
evaluate the **echo gate first**, then latency gates:

1. **Echo gate (ALWAYS enforced).** The extracted assistant content MUST satisfy
   `TrimSpace(output) == expected` — an **exact** match of the echoed nonce
   (leading/trailing whitespace trimmed; the comparison is otherwise byte-exact
   and case-sensitive). A mismatch is `nonce_mismatch`.
2. **Latency gates (conditional).** Evaluated only when latency enforcement is
   active for this probe (§6): `ttft_breach` if measured TTFT > the challenge's
   `max_ttft_ms`; `tps_breach` if sustained TPS < `min_sustained_tps` (or the
   metric is NaN/Inf).

A probe that cannot run at all (build error, dispatch error, warm-up-excluded
tier-2, or an **empty applicable bank**) is a **skip** and MUST be **neutral** —
it does not count as a pass or a failure and does not touch the consecutive-
failure counter. A skip MUST also be neutral for the OPoI model-class pass flag
(see §12 FR-CAN29 — the current code records `pass=false` on a model-class
dispatch skip, which is a conformance gap).

## 5. Failure-reason taxonomy (normative)

Every non-passing, non-skipped probe MUST be classified into exactly one of the
following reasons. These string constants are **normative** and MUST appear
verbatim in the `canary_fail_reason` log field (§12) and any operator surface:

| `canary_fail_reason` | Class | Sub-class | Trigger |
|----------------------|-------|-----------|---------|
| *(empty)* | pass | — | echo gate passed; latency gate passed or not enforced |
| `nonce_mismatch` | correctness (liveness/instruction) | — | `TrimSpace(output) != expected` |
| `incomplete` | correctness (liveness) | coordinator-attributable when caused by `max_tokens` truncation | WS relay `inference_response_end.status != "complete"` |
| `relay_error` | infra/liveness | **hard** (transport) | WS relay error *after dispatch* (relay dies mid-inference); HTTP transport error or body-read error |
| `relay_error` | infra/liveness | **status** (endpoint-level) | HTTP non-200 from the provider endpoint — a canary-specific status, which does **not** by itself prove the buyer path is unreachable (§10) |
| `relay_error` | infra/liveness | **soft** (deadline) | probe exceeded `canary_timeout_s` with no hard transport failure |
| *(skip — no fail reason)* | neutral | — | WS **pre-dispatch** failure (`DispatchInference` error: session unavailable / closed / dead) — counter-neutral, NOT a `relay_error` (see §4 skip rule) |
| `ttft_breach` | latency/SLO | — | measured TTFT exceeds `max_ttft_ms` (only when enforcing) |
| `tps_breach` | latency/SLO | — | sustained TPS below `min_sustained_tps`, or non-finite (only when enforcing) |

The classifier MUST check `nonce_mismatch` before the latency reasons, and
`ttft_breach` before `tps_breach`. `canary_fail_reason` MUST be present on
**every** failure log line — its absence during the 2026-07-09 incident is why
operators could not diagnose *why* probes were failing (the field was added by
PR #513).

> **Sub-class conformance note.** The shipped code emits a single `relay_error`
> constant for the hard/status/soft sub-classes above; it does **not**
> distinguish canary-endpoint deadline expiry (`canary_timeout_s`, default 30 s,
> far below the buyer request timeout of 280 s) or a canary-specific HTTP non-200
> from a genuine transport death. Distinguishing them — so a merely-slow sole
> provider that still serves buyers, or one that returns a canary-only non-200,
> is not evicted (§10 FR-CAN22/23) — is a conformance gap (§14). One nuance the
> spec relies on: a WS **pre-dispatch** failure (the session is already dead /
> unavailable) is a counter-neutral **skip**, not a `relay_error`, so a genuinely
> dead WS sole provider is never *canary*-sanctioned; it is the FR-P11a
> buyer-path breaker, not the canary, that removes it. Likewise `incomplete` does
> not currently carry a coordinator-attribution flag.

## 6. Latency-gate policy: observe vs enforce

**FR-CAN7 — Observe is the required default; latency SLOs are model-class-only.**
`pool.canary_latency_enforcement` takes values `observe` (default; empty string
means `observe`) or `enforce`. In `observe` mode a latency breach MUST be logged
and MUST NOT fail the probe. Only `enforce` mode lets `ttft_breach`/`tps_breach`
count toward a sanction.

Per-challenge latency SLO fields (`max_ttft_ms`, `min_sustained_tps`) are
meaningful **only on model-class banks**. Configuration validation **MUST** reject
these fields on a **global** `canary_challenges` entry, because the global bank
is a pure liveness/echo probe. **Beware the shipped asymmetry:** in *observe*
mode the coordinator only *logs* latency breaches for model-class banks, so a
global-bank latency field is silently un-logged; but in *enforce* mode
`evaluateCanaryProbe` applies the TTFT/TPS thresholds **regardless of bank type**,
so a global-bank latency field *can* sanction. Accept-and-partially-honor is
exactly the trap an operator falls into — the clean resolution is to **reject**
latency fields on global banks at validation. Both the missing observe-log and
the un-rejected global latency field are conformance gaps (§14).

**FR-CAN8 — Why `enforce` is gated.** The current probe is `stream: false`, so
the coordinator has no true first-token boundary and derives TTFT/TPS from
wall-time over a single server-buffered response. This metric is **structurally
unreliable**: the same healthy provider measured `canary_ttft_ms` swinging
125 ms – 7000 ms and `canary_sustained_tps` 7 – 27000 across consecutive probes
(2026-07-09 flapping incident). Calibrating `max_ttft_ms` off a *streaming*
buyer-probe TTFT and applying it to the *non-streaming* canary caused
three-in-a-row `ttft_breach` → sanction → `pool_ready: 0` → buyer-503 flapping.

Therefore an implementation **MUST NOT** enable latency `enforce` unless ALL of:

1. the probe is issued **`stream: true`** so TTFT/TPS are measured against real
   token boundaries; **and**
2. the sanction decision is taken over a **percentile of N recent probes**
   (e.g. p95 over the last ≥5 probes), never a single-shot measurement; **and**
3. **last-provider protection** (§10) holds — the model has ≥2 routing-eligible
   providers, so a latency sanction cannot empty the pool.

Concrete sub-timeout QoS enforcement — sanctioning a provider that is correct but
persistently slower than an SLO yet faster than the request timeout — is **not
defined by this spec and does not currently exist** (buyer-path TTFT handling is
observe-only and default-off; telemetry-drift only alerts and does not change
routing). Whether such enforcement should penalize scoring, trip the breaker, or
affect payout is deferred to runbook item 9's baseline / a future SLO spec with a
named owner. Until then, `observe` remains the normative production posture.

**Precise scope of the observe-mode "no sanction" claim.** Observe mode disables
only the `ttft_breach`/`tps_breach` **sub-timeout SLO** gates. It does **not**
disable the `canary_timeout_s` **soft-deadline** failure: a probe that exceeds the
30 s canary deadline still records a `relay_error` and counts toward a sanction
even in observe mode. Because last-provider protection (§10) shields only the
*sole* provider from soft-deadline removal, a correct-but-slow provider in a
**multi-provider** pool can still be canary-sanctioned by repeated deadline
expiry. The accurate claim is therefore: *sub-timeout SLO breaches never sanction
in observe mode, and no non-sole provider is protected from a soft-deadline
sanction.* Widening `canary_timeout_s` toward the buyer request timeout, or
treating the soft-deadline as latency for all providers, is the follow-up (§14).

**FR-CAN9 — Cold-start grace.** `pool.canary_cold_start_grace_s` (default 0 =
disabled) waives **latency** gates for `grace` seconds after a provider's
`ConnectedAt`. Grace MUST NOT waive the echo gate. A graced probe is neutral for
the counter and MUST force the *next* probe to be latency-enforced, so a
chronically slow provider cannot hide behind repeated reconnects. Grace is
irrelevant in `observe` mode (latency never sanctions there).

## 7. Sanction / degrade / recovery lifecycle

**FR-CAN10 — Consecutive-failure threshold.** The coordinator MUST maintain a
per-provider consecutive-failure counter. A **pass** resets it to 0. A **failure**
increments it and stamps `CanaryLastFailedAt`. A sub-threshold failure
(`count < pool.canary_failure_threshold`, default 3) **MUST NOT change routing
state** — a single transient failure never degrades a provider.

**FR-CAN11 — At-threshold sanction (tier-dependent).** When the counter reaches
`canary_failure_threshold` and the sanction is permitted by last-provider
protection (§10):

- **Provisional tier** → the provider transitions to `unavailable`
  (`CanaryTripUnavailable`); the coordinator **rejects it from admission** and
  closes the session (`CloseBanned`, reason `canary_failed`). See FR-CAN17 for
  the persistence semantics of that admission rejection.
- **Pinned tier** → the provider transitions to `degraded`
  (`CanaryTripDegraded`), a **canary recovery hold** is installed, and the
  canary-sanction record is **persisted** to durable storage (§8).

**FR-CAN12 — Degrade window is probe-bounded, not time-bounded.** Unlike the
FR-P11a circuit-breaker (which recovers after `pool.degraded_backoff_s`), a
canary degrade has **no time-based auto-clear**. It persists until either (a) a
subsequent canary probe **passes**, or (b) an operator clears it (§13). The
coordinator MUST continue probing a canary-degraded provider so recovery is
attempted. Two distinct bounds matter and MUST NOT be conflated:

```
next-dispatch bound   ≤  1.5 × canary_interval_s  +  canary_sweep_cadence  +  dispatch delay
recovery-ready bound  =  next-dispatch bound  +  eligibility wait  +  probe-completion time
```

The **next-dispatch bound** (~480 s with defaults: `canary_interval_s = 300`,
sweep cadence 30 s) bounds only when the *next probe is scheduled and picked up* —
and only for a provider that is immediately probe-eligible. Actual **recovery
readiness** additionally requires the provider to be dispatch-eligible (free slot,
no warm-up hold) at that moment and the up-to-`canary_timeout_s` probe to complete
and its passing result to be applied. The eligibility wait has **no finite hard
bound** (a provider with no free slot may never become probe-eligible), so
recovery readiness is **not** hard-bounded. Consequently the `Retry-After`
guidance (FR-CAN20) is exactly that — *guidance* derived from the next-dispatch
bound — not a guaranteed recovery deadline, and MUST NOT be shorter than the
minimum sweep interval.

**FR-CAN13 — Automatic recovery, gated on no other degrade cause.** A canary-
degraded pinned provider that returns a **passing** probe MUST have its canary
cause cleared: the failure counter is zeroed and the persisted canary sanction is
deleted. It transitions to `ready` **only if no other coordinator-owned degrade
cause remains** (see FR-CAN14). Recovery requires an actual passing probe — the
coordinator MUST NOT auto-clear a canary sanction on a timer alone, because the
sanction encodes an unproven-liveness/echo condition, not a cooldown.

**FR-CAN14 — Composition of degrade causes (hold integrity).** Provider
degradation MUST be modeled as a **set of coordinator-owned causes** —
`breaker` (FR-P11a), `canary`, `provider_failure`, `warmup`, `operator_clear` —
each with an independent lifecycle. A provider returns to `ready` only when
**every** cause has been cleared by its own recovery path. Specifically:

- Clearing the **canary** cause (a passing probe) MUST NOT clear a concurrent
  **breaker** hold, and vice-versa.
- The generic recovery path (`MarkRecovered`, used for breaker/timeout recovery)
  MUST NOT clear a **canary** or **operator-clear** hold; only a passing canary
  probe (canary cause) or a fresh reconnect + warm-up (operator-clear cause)
  releases those.
- While any hold is live, the provider's own heartbeat/state-update MUST only be
  permitted to re-affirm `degraded` (the canary analog of SPEC-002 FR-P11a).

> **Conformance gap (§14).** The shipped registry keeps a **single**
> `recoveryHolds[providerID]` slot with one `reason`. A canary threshold-failure
> that lands while a breaker hold is live **overwrites** the breaker hold with a
> canary hold; a later passing canary then clears the only hold and restores
> `ready` even though breaker recovery never succeeded. Additionally
> `MarkRecovered` refuses only `RecoveryReasonCanary`, so it will clear an
> `operator_clear` hold and restore the same session, bypassing FR-CAN31's
> required reconnect + warm-up. Implementing the multi-cause set with strict
> per-cause clearing is the authorized follow-up; until then a provider that is
> simultaneously breaker- and canary-degraded has undefined recovery precedence.

## 8. Sanction persistence and reconnect

**FR-CAN15 — Durable pinned sanctions; load is independent of `canary_enabled`.**
A pinned canary sanction MUST be persisted (provider id, fail count,
last-checked/last-failed timestamps) so it survives a coordinator restart. On
boot the coordinator MUST **always** load and reapply persisted sanctions with a
positive fail count. Sanction *persistence and reapplication* MUST be independent
of `pool.canary_enabled` — that flag controls only whether new probes are
*scheduled*.

> **Conformance gap (§14).** The shipped code gates `LoadCanarySanctions` on
> `cfg.Pool.CanaryEnabled` (`main.go:959`). Consequently disabling canary and
> restarting — the exact incident-response path §16 describes — **launders** any
> existing durable pinned sanction. This MUST be fixed before disabling canary is
> a safe operational lever; see §16.

**FR-CAN16 — Reapplication on reconnect.** When a provider **with a persisted
pinned sanction** reconnects, the coordinator MUST reapply the sanction: restore
the fail count, set `degraded`, and install a fresh canary recovery hold — so a
provider that failed the echo proof cannot obtain a clean slate merely by
reconnecting or by riding through a coordinator restart. The reapplied provider
is non-routable until it passes a canary. Cold-start grace (FR-CAN9) still applies
to *latency* gates on the fresh session but never waives the echo gate.

**FR-CAN17 — Provisional bans: record runtime-only, admission rejection durable
(best-effort in shipped code).** The canary-sanction *record* (in
`provider_canary_sanctions`) is **not** written for a provisional trip. Instead
the provisional trip calls `AdmissionManager.Reject`, and that **admission
rejection is intended to be durable** — persisted and reloaded across restart,
with its own retention TTL and operator-clear path (FR-CAN32). So a banned
provisional provider **is meant to stay admission-rejected across a restart**
until an operator un-ban (FR-CAN32) or retention pruning clears it, not get a
clean readmission cycle (Decision-log Entry 125 records exactly this). **However,
the shipped durability is best-effort, not crash-consistent:** `Reject` returns no
error and calls best-effort persistence (`persistLocked` only *reports* a save
failure through a callback), and admission-store **load** failure at startup is
fail-open. A failed write or a corrupt/absent store followed by a restart can
therefore silently drop a provisional ban. This asymmetry — pinned degrade
persists as a canary sanction, provisional ban as an admission rejection — is
intentional, but both are currently best-effort and MUST be hardened per FR-CAN18.
(Conformance gap, §14 — marked Partial, not clean.)

**FR-CAN18 — Crash-consistent, fail-closed persistence.** Sanction persistence —
for **both** pinned canary sanctions and provisional admission rejections — MUST
be crash-consistent, not best-effort. "Keep the provider degraded in memory and
log the error" is **insufficient**, because that runtime state is exactly what a
restart discards (the laundering FR-CAN15 identifies). Precisely:

- **Fail-closed on write, backed by a durable record.** A **durable** write-ahead
  pending-sanction record (or outbox entry) MUST exist before the sanction is
  relied upon; an in-memory-only non-routable quarantine is **insufficient**,
  because a crash before the primary write's acknowledgement would discard the
  RAM quarantine and let a clean store load on restart (laundering the sanction —
  the exact case AC-F10(c) forbids). Concretely: the coordinator MUST durably
  record the pending sanction *before or atomically with* making it effective,
  hold the provider **non-routable** until the durable record is confirmed, and
  replay the outbox until the canonical sanction write succeeds; the failure MUST
  propagate, never be swallowed by the asynchronous canary loop. A bare
  "wait for the primary write to be acknowledged, quarantine in RAM meanwhile"
  path is NOT conformant on its own.
- **Fail-loud on load.** A sanction-store (or admission-store) **load failure or
  corruption at startup** MUST fail coordinator startup / readiness rather than
  boot fail-open with no sanctions (today provisional admission load is fail-open,
  FR-CAN17) — booting blind would silently launder every persisted sanction.
- **Atomic combined clears.** Operator operations that touch two durable records —
  e.g. `recoverProvider`, which deletes the pinned sanction and then persists the
  admission `Unreject` — MUST be **all-or-nothing or compensating**: today the
  second write can fail after the first commits, leaving a half-applied clear and
  a 500.

(Conformance gap, §14; the load-failure, write-failure, crash-before-ack,
recovery-deletion, and combined-clear cases are covered by AC-F10.)

## 9. Buyer availability contract during degrade

**FR-CAN19 — Routing eligibility is a conjunction, not just state.** A provider is
routing-eligible only when its `Provider.RoutingEligible()` predicate holds:
`state == ready` **and** free slots **and** every independent authentication /
publication precondition (not `AuthBearerlessDuplicate`, not `AuthSelfMinted`, no
pending receipt public key, …). A canary sanction makes the predicate false by
driving `state` away from `ready`; it is one input among several, and this spec
does not weaken the other preconditions. There is no partial or soft canary
degrade — eligibility is binary.

**FR-CAN20 — Sole-provider degrade → retryable 503.** When a canary sanction
leaves a model with no routing-eligible provider, buyer requests for that model
MUST return **HTTP 503 `no_provider_available`** with **`retryable: true`**. The
general buyer retryability/`Retry-After` contract is owned by **SPEC-006 §5.2**
(SPEC-018/019 own only the tool-calling error subset); the concrete `Retry-After`
value is emitted by the gateway. A canary degrade is transient from the buyer's
perspective, so the retryable classification is mandatory. Any `Retry-After` hint
MUST be consistent with the FR-CAN12 recovery-attempt bound and MUST NOT be
shorter than the minimum sweep interval. (The gateway currently attaches a
generic 1 s hint to retryable 503/504, which is shorter than the sweep and thus
nonconformant — a conformance gap, §14.)

**FR-CAN21 — 404 vs 503 boundary.** A canary sanction MUST NOT convert a
known model into a 404. `404 model_not_found` is reserved for models where
**`ModelKnown(model) == false`** under the **authoritative SPEC-010 R-3.3.4**
definition — the union of every live provider's `ModelID`, every live provider's
declared `SupportedModels`, and retained recently-seen history. A model that is
*declared-but-cold* (in some provider's `SupportedModels` but not currently
served) is therefore **known**, and a model whose only provider is canary-degraded
is **known but temporarily unavailable** → both are **503**, not 404. (SPEC-010
R-3.3.4's `MUST` is authoritative on this exact question; the older SPEC-002
R-3.X.6 `MAY` and SPEC-006 §17.2 "served or recently seen" wording are a carried
cross-spec inconsistency — runbook item 22 — not re-litigated here.)

## 10. Last-provider protection (new invariant)

**FR-CAN22 — The sole provider is never removed by a canary-only signal.** When a
provider is the **only** routing-eligible provider for a model, **no canary
signal alone may remove it** — not `nonce_mismatch`, not `incomplete`, not a
latency or soft-deadline `relay_error`, and not a canary-specific HTTP non-200
(`status` sub-class). The reason is the corrected threat model (§1): a canary
probe is a fingerprintable synthetic request, so a failed echo, a rejected
synthetic request, or a canary-endpoint status does **not** prove that ordinary
buyer workloads are failing, and with a fleet of one there is no independent
sample to distinguish a genuine provider fault from a coordinator-config fault
(bad challenge, undersized `max_tokens`). Removing the last provider on such a
signal is exactly the self-inflicted total outage of incidents #1/#2.

The sole provider may be removed **only** on evidence that is independent of the
canary's synthetic probe:

- a genuine **buyer-path failure** driving the FR-P11a circuit-breaker (real
  requests are failing), or
- a **confirmed transport/session death** that the buyer path would equally hit
  — note a dead WS session is a counter-neutral *skip* (§5), so this is the
  breaker's job, not the canary's — or
- **item 9's weight-bound / attested test** returning a confirmed integrity
  failure.

A canary sanction on the sole provider therefore degrades it toward the buyer
503 + `retryable:true` contract (§9) **only** once one of the above corroborates;
until then the sole provider stays routing-eligible even while it accrues canary
failures, and the operator is alerted (§12) to investigate.

**FR-CAN23 — Multi-provider correctness sanctions + correlated-fault
containment.** With **≥2** routing-eligible providers, a `nonce_mismatch` or a
non-`max_tokens`-attributable `incomplete` MAY remove a provider (it is not
producing usable responses — *not* because the canary proved wrong weights, §1),
always **subject to the FR-CAN22 last-provider floor** (the pool never drops below
one routing-eligible provider on a canary-only signal) and to correlated-fault
containment:

- **A correlated-majority verdict produces only ephemeral, self-limiting effects —
  it never creates persistent containment state a malicious set of providers could
  weaponize.** This is the load-bearing Sybil-safety invariant, scoped precisely:
  no *correlated-majority verdict* (and no provider behavior of any trust level —
  SPEC-008 `attested` proves device identity, not independent ownership, and one
  operator can hold several attested/pinned IDs) may automatically trigger a bank
  rollback, a config-fault attribution, a **persistent** fingerprint suspension, or
  any other durable *containment* state. The only automatic responses to
  correlation are *within* the current epoch (discard its results) plus a
  fire-and-forget operator alert. (This invariant governs the *correlated-fault*
  path only; it does **not** override ordinary per-provider sanctioning — a
  non-correlated committed failure still updates that provider's counter and, at
  the FR-CAN11 threshold, produces the normal durable FR-CAN11/15 sanction. The
  Sybil concern is exclusively the fleet-wide *containment* actions a majority
  could weaponize, not the per-provider sanction of a genuinely-broken provider.)
- **Detection with staged results.** The coordinator **MUST**, whenever canary
  sanctioning is enabled for a multi-provider model, run a **correlation epoch**
  over a **fixed pre-sweep snapshot** (denominator `N ≥ 2`, atomic): it actively
  re-dispatches the **same** challenge fingerprint to every snapshot member
  (random per-probe selection would never guarantee shared exposure), keyed by
  challenge fingerprint + bank generation, bounded by the FR-CAN12 next-dispatch
  window (`1.5 × canary_interval_s + sweep cadence`). **All epoch results MUST be
  staged — unapplied, no counter increment, no sanction — until the epoch
  resolves**, so a shared bad challenge cannot sanction the first responders
  before the correlated verdict forms.
- **Resolve the epoch:** if a strict majority (`> N/2`, and ≥ 2) failed the shared
  fingerprint → **suspicion**: the coordinator MUST **discard the staged results
  entirely** (no sanction, no counter increment — honest providers are unharmed),
  preserve the FR-CAN22 last-provider floor, and **alert the operator** (§12), and
  do **nothing else**. Otherwise → **commit** the staged results **atomically**
  with respect to the last-provider guard: committed failures update their
  providers' counters and produce a sanction only at the FR-CAN11 threshold (the
  ordinary per-provider path, FR-CAN11/15); two providers can't both be removed
  below the floor.
- **All persistent containment is an authenticated operator action, never
  automatic.** Benching a suspect fingerprint from sanctioning, rolling back a
  challenge bank, or attributing a coordinator-config fault are operator decisions
  taken after the alert — because any *persistent* automatic response that a
  provider majority can trigger is itself weaponizable (a Sybil majority failing
  successive epochs could otherwise suspend every fingerprint one by one and
  silently disable the canary). The ephemeral discard-and-alert response has no
  such accumulation: the worst a malicious majority achieves per epoch is
  discarding its own failures (which cannot harm honest providers) and raising an
  alert; nothing persists. (A Sybil *majority of the whole pool* is out of the
  canary's threat model — it is an admission/attestation problem, since such an
  attacker already owns buyer routing; the canary defends against a *minority* bad
  provider, which by definition cannot form a correlated majority and so is
  committed and sanctioned normally.) A future version MAY add automatic bank
  rollback only behind an authenticated, single-flight, cooldown-bounded,
  generation-fenced control whose **deterministic challenge-semantic** failure
  (never a transport/timeout/status failure) is the sole authorization — deferred,
  not specified here.
- Coordinator-attributable failures (an `incomplete` from undersized
  `max_tokens`, FR-CAN3) are **neutral** regardless of fleet size.
- A **provisional** sole provider MUST additionally never be
  hard-banned/session-closed on a latency or soft-deadline failure.

> **Conformance gap (§14).** Sole-provider protection, coordinator-attribution of
> `incomplete`, the status/soft/hard `relay_error` split, the correlation epoch
> with **staged results** (pre-sweep snapshot + shared-fingerprint re-dispatch +
> bank-generation fencing + discard-on-suspicion), and atomic last-provider
> evaluation are **not yet implemented** — `RecordCanaryResult` receives only a
> pass/fail boolean with no failure class, no attribution, no snapshot, no
> staging, and no eligible-count guard. Today a sole provider CAN be removed by a
> coordinator-config fault (incidents #1/#2). Production is safe only because it
> runs `observe` and canary is disabled entirely; making these guards explicit is
> the primary pre-re-enable requirement (§16).

## 11. Config surface and reload contract

**FR-CAN24 — Config surface.** The canary subsystem is configured under `pool.*`:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `canary_enabled` | bool | `false` | Master switch for probe *scheduling* (not sanction persistence; see FR-CAN15). |
| `canary_interval_s` | int | `300` | Base per-provider probe interval (jittered 0.5×–1.5×); drives sweep cadence `interval/10`. |
| `canary_timeout_s` | int | `30` | Per-probe deadline (soft `relay_error` on expiry). |
| `canary_max_tokens` | int | `32` | Probe completion budget; MUST satisfy FR-CAN3. |
| `canary_failure_threshold` | int | `3` | Consecutive failures to sanction. |
| `canary_cold_start_grace_s` | int | `0` | Latency-gate waiver window after connect (0 = off). |
| `canary_latency_enforcement` | enum | `observe` | `observe` \| `enforce`; see §6. Validation MUST reject other values. |
| `canary_challenges` | list | — | Global liveness/echo bank; each `{prompt, expected}` MUST contain `{nonce}`; latency SLO fields MUST be rejected here (§6). |
| `model_class_challenges` | map | — | Per-model banks matched by model id (exact, then case-insensitive); may carry latency SLOs; feed the OPoI pass flag (semantics: item 9's spec). |

**FR-CAN25 — Enable requires a validated, covering bank.** When `canary_enabled`
is true, configuration validation MUST fail closed unless there is at least one
**non-empty effective** bank for every admissible model — i.e. either a non-empty
global fallback, or a non-empty per-model bank for each model plus coverage of
unmatched models. Validation MUST reject an **empty per-model list**
(`{model-a: []}` currently passes — a conformance gap) and MUST reject or
case-fold **duplicate model keys**. An implementation MUST NOT enable canary
against a bank that leaves any admissible model with no usable challenge (which
would make its probe a permanent neutral skip, so the model is never actually
checked while `canary_enabled` appears active). This hardens the 2026-07-10
deadlock class (decision-log Entry 125).

**FR-CAN26 — Reload without restart (required; currently a gap).** Canary is a
money-path/availability gate, yet its config lives in the `pool` block which is
**startup-only** (SIGHUP reload today updates only tier-2/billing/routing
surfaces, not the pool canary config). Changing `canary_max_tokens` on the
single-provider prod pool required a full coordinator restart, which cascaded
into the ~5 h outage of 2026-07-10 (incident #3). This spec **requires** that the
canary tuning parameters (all keys in FR-CAN24) be operator-mutable **without a
coordinator restart** — either by extending SIGHUP reload to this subset or via
an authenticated out-of-band operator tuning path. Until then, operators MUST
treat any canary config change on a single-provider pool as a planned-maintenance
event. (Note the interaction with FR-CAN15: making `canary_enabled` reloadable is
only safe once sanction load is decoupled from it.)

**Config-generation contract.** Because a probe spans time (dispatch → up to
`canary_timeout_s` → evaluate → sanction), a reload MUST NOT let a probe be
*built* under one configuration and *evaluated or sanctioned* under another. The
reload MUST: (a) **validate the complete candidate configuration** before it takes
effect (a partial/invalid reload is rejected wholesale, not partially applied);
(b) publish it as **one monotonically-versioned immutable snapshot** covering
**every FR-CAN24 key** — the challenge banks, `canary_max_tokens`,
`canary_timeout_s`, `canary_interval_s`, `canary_cold_start_grace_s`,
`canary_latency_enforcement`, `canary_failure_threshold`, `canary_enabled`, and
the FR-CAN22/23 attribution rules together (each affects deadline classification,
grace neutrality, the correlation window, or whether a probe should run at all, so
none may drift mid-probe); the generation counter MUST increment on **any** canary
change; and (c) bind each in-flight probe to the generation it was **dispatched**
under, so it is evaluated entirely against that captured snapshot or **discarded**
if the generation changed (the same fencing FR-CAN23 requires for the correlation
epoch). Disabling canary mid-flight (`canary_enabled: false`) MUST discard
already-dispatched results — a stale in-flight probe MUST NOT sanction after
canary is turned off. Conformance gap, §14; reload-during-probe behavior is
covered by AC-F14.

## 12. Observability contract

**FR-CAN27 — Failure logging.** Every failed probe MUST emit a structured log
line carrying at minimum: `provider_id`, `assigned_id`, `canary_fail_reason`
(from the §5 taxonomy, verbatim), the probe outcome (`pass`/`fail`/`skip`), and —
when latency is evaluated — the measured `canary_ttft_ms` and
`canary_sustained_tps` for **both** global and model-class banks.

> **Conformance gap (§14).** The shipped failure logger emits `provider_id`,
> fail count, threshold, and reason, but **not** `assigned_id` or the explicit
> outcome, and emits latency metrics **only for model-class banks**. These
> additions are the authorized follow-up.

**FR-CAN28 — `/poolz` fields.** The operator `/poolz` surface MUST expose, per
provider: `routing_eligible` (bool), `canary_fail_count` (int),
`canary_last_checked_at` and `canary_last_failed_at` (RFC3339 UTC, emitted as
explicit `null` when unset — **not** omitted), and a stable **trip/hold reason**
that distinguishes a canary hold from a breaker, warm-up, or operator-clear hold.
These are the minimum fields an operator needs to distinguish a canary sanction
from other degrade causes and to decide whether to clear it.

> **Conformance gap (§14).** `/poolz` currently exposes only `routing_eligible`
> and `canary_fail_count`; the timestamps use `omitempty` (absent, not `null`)
> and there is no exposed trip/hold reason (`CanaryResult.Tripped` is transient
> and never retained). Adding the nullable timestamps and a persisted trip/hold
> reason is the authorized follow-up.

**FR-CAN29 — Model-class pass flag.** When a probe uses a `model_class_challenges`
bank, the coordinator MUST emit the per-model OPoI pass/fail flag and record the
model-class canary result for telemetry-drift. A **skip** MUST be neutral for
this flag (the current code records `pass=false` on a model-class dispatch skip
before the skip-neutral return — a conformance gap). The *meaning* of the flag is
item 9's spec; SPEC-031 requires only that the mechanism fire, be observable, and
be skip-neutral.

**FR-CAN29a — Correlated-fault operator alert.** The FR-CAN23 suspicion alert MUST
be emitted as a distinct, operator-visible event (page/log) carrying at minimum:
the `model_id`, the suspected challenge **fingerprint** and **bank generation**,
the snapshot denominator `N` and the failing count, and the fact that the epoch's
results were **discarded** (no sanction taken). This is the signal the operator
acts on to bench the fingerprint or roll back the bank (FR-CAN23 permits no
automatic persistent containment, so the alert is the sole trigger for the
operator's authenticated response). Absence of this event on a correlated
suspicion is a conformance gap (§14). *(Numbered `29a` to avoid renumbering the
§13 recovery FRs CAN30–32; it belongs to the §12 observability contract.)*

## 13. Tier asymmetry and operator recovery

**FR-CAN30 — Documented asymmetry.** The provisional-ban (admission reject,
persisted in the admission store per FR-CAN17) vs pinned-degrade (canary sanction,
persisted in `provider_canary_sanctions`) split is the intended policy; both are
**intended** to survive restart, by different mechanisms — though both are
currently best-effort and MUST be hardened to crash-consistent per FR-CAN18.

**FR-CAN31 — Operator clear (pinned).** The coordinator MUST expose an
authenticated, idempotent operator action to clear a pinned canary sanction. It
MUST delete the persisted sanction and zero the runtime counter; if a live
recovery hold exists it MUST be converted to an `operator_clear` hold (not
silently dropped) so the session stays non-routable until a fresh reconnect +
warm-up re-proves it. In-flight probes MUST be fenced (epoch-guarded) so a probe
result computed against pre-clear state cannot resurrect a just-cleared sanction.
Per FR-CAN14, the generic `MarkRecovered` path MUST NOT release an
`operator_clear` hold (current code does — a gap).

**FR-CAN32 — Operator un-ban (provisional).** The coordinator MUST expose an
authenticated, idempotent operator action to clear a provisional canary ban and
its **durable admission rejection** (the existing `DELETE /admin/reject/
{provider_id}`, decision-log Entry 125), symmetric to FR-CAN31, so a false
provisional ban on the sole provider is operator-recoverable without waiting for
retention pruning.

## 14. Conformance status (honesty table)

Per repo status-header discipline, this table states what the **current code**
does versus what this spec **requires**. "Implemented" = shipped and conformant;
"Tightens" = shipped but this spec narrows/mandates a currently-optional posture;
"Partial" = partly shipped; "Gap" = required here but not yet implemented
(authorized follow-up IMPL).

| FR | Status | Note |
|----|--------|------|
| FR-CAN1 scheduling/jitter/shuffle | Implemented | `runCanaryLoop`, `shuffledProviders`, `jitteredCanaryInterval`. |
| FR-CAN2 body (temp 0, nonce, random challenge) | **Partial** | Temp pinned (#533), nonce validated. Selection is byte-modulo (biased; entries >255 unreachable) not uniform; nonce is 32-bit (probabilistic freshness, no replay cache). Spec recommends ≤256-entry banks + rejection-sampling / ≥128-bit nonce beyond shipped. |
| FR-CAN3 `max_tokens` sizing + attribution | **Tightens/Gap** | Prod default 16→32 (#531); ≥-expected-length validation and the coordinator-attribution of `incomplete` are new. |
| FR-CAN4/5 transport, admitted model | Implemented | WS vs HTTP split; `MaxAdmittedModelKey`. FR-CAN5 explicitly not an identity binding. |
| FR-CAN6 echo-first, skip-neutral | **Partial** | Order + counter skip-neutral implemented; OPoI skip-neutrality is a gap (see FR-CAN29). |
| FR-CAN7 observe default; global-latency reject | **Partial** | Default `observe` (#513). Global-bank latency is un-logged in observe but **applied in enforce** (not rejected at validation) — accept-and-partially-honor (gap). |
| FR-CAN8 enforce preconditions + buyer-path QoS owner | **Gap** | `enforce` reachable today single-shot/non-streaming/unguarded; no concrete sub-timeout QoS enforcement exists. |
| FR-CAN9 cold-start grace | Implemented | #512. |
| FR-CAN10 sub-threshold no-op | Implemented | `RecordCanaryResult` returns below threshold. |
| FR-CAN11 tier sanction | Implemented | Provisional ban / pinned degrade+persist. |
| FR-CAN12 probe-bounded window + next-dispatch bound | Implemented | Behavior shipped; the ~1.5×interval figure is the *next-dispatch* bound (a doc correction of the earlier sweep-cadence claim), NOT a recovery-readiness guarantee — recovery readiness has no finite bound (eligibility wait). The cadence-derived `Retry-After` gap belongs to FR-CAN20. |
| FR-CAN13/14 composition of degrade causes | **Gap** | Single `recoveryHolds` slot: canary overwrites breaker hold; `MarkRecovered` clears operator-clear hold. Multi-cause set not implemented. |
| FR-CAN15 durable load independent of `canary_enabled` | **Gap** | `LoadCanarySanctions` gated on `CanaryEnabled` — disable+restart launders sanctions. |
| FR-CAN16 reapply on reconnect | Implemented | `applyCanarySanctionLocked` (pinned). |
| FR-CAN17 provisional admission-reject durable | **Partial** | Admission store persists, but best-effort: `Reject` swallows save errors and startup load is fail-open, so a failed write + restart drops the ban. |
| FR-CAN18 crash-consistent fail-closed persistence | **Gap** | Upsert failure log-only; runtime sanction installed before persistence; `recoverProvider` two-step is non-atomic. Applies to pinned + provisional. |
| FR-CAN19 conjunctive eligibility | Implemented | `RoutingEligible()` enforces auth/publication + state + slots. |
| FR-CAN20 retryable 503 + cadence Retry-After | **Partial** | `no_provider_available` retryable (#548); ownership is SPEC-006 §5.2; gateway 1 s hint is shorter than the sweep (gap). |
| FR-CAN21 404/503 boundary | Implemented | Follows SPEC-010 R-3.3.4 `ModelKnown()` union (#555, authoritative); SPEC-002 R-3.X.6 `MAY` / SPEC-006 §17.2 wording is the carried item-22 cross-spec inconsistency, not claimed as fully aligned. |
| FR-CAN22/23 sole-provider protection + Sybil-proof correlated-fault | **Gap** | `RecordCanaryResult` gets only a pass/fail bool: no failure-class, no attribution, no last-provider floor, no correlation epoch with staged results (snapshot + shared-fingerprint re-dispatch + bank-generation + discard-on-suspicion), no atomic evaluation. (v0.1 correlation produces only ephemeral discard + alert — no correlated-majority verdict creates persistent containment state; ordinary per-provider FR-CAN11/15 sanctions still apply; all persistent containment is operator-only — see FR-CAN23.) |
| FR-CAN24/25 config surface + covering bank | **Partial** | Surface + basic validation shipped (#478, Entry 125); empty per-model lists and duplicate keys pass (gap). |
| FR-CAN26 reload without restart + generation contract | **Gap** | Pool block startup-only (direct cause of incident #3); no validated-candidate, atomically-versioned config-generation snapshot for in-flight probes. |
| FR-CAN27 failure logging | **Partial** | `canary_fail_reason` (#513); missing `assigned_id`/outcome and global-bank latency (gap). |
| FR-CAN28 `/poolz` fields | **Partial** | Exposes `routing_eligible` + `canary_fail_count`; timestamps serialize when present via `omitempty` (not explicit `null` when unset), and there is no stable trip/hold reason. |
| FR-CAN29 model-class pass flag skip-neutral | **Partial** | Flag emitted (#491); skip records `pass=false` (gap). |
| FR-CAN30 documented asymmetry | Implemented | Both durable, different stores. |
| FR-CAN31 operator clear (pinned) | **Partial** | Clear + epoch fencing + hold conversion shipped; `MarkRecovered` still clears the operator hold (gap, ties to FR-CAN14). |
| FR-CAN32 operator un-ban (provisional) | Implemented | `DELETE /admin/reject/{id}` (Entry 125). |

**Re-enable bar.** The Gap rows are the implementation backlog this baseline
authorizes; none is a regression. The **single normative re-enable requirement**
is the `MUST NOT re-enable until` list in **§16** — that list (not this paragraph)
is authoritative; it enumerates FR-CAN22/23, FR-CAN15, FR-CAN18, FR-CAN14,
FR-CAN26, and the `observe`-until-FR-CAN8 condition. This section only classifies
each FR's shipped status; §16 states the gate.

## 15. Acceptance criteria

Testable against the current build (happy paths against the shipped code):

- **AC-1.** With `canary_enabled` and a valid covering bank, a provider echoing
  the nonce exactly passes; `canary_fail_count` stays 0 and `routing_eligible`
  stays true.
- **AC-2.** A provider that returns a transformed nonce fails `nonce_mismatch`;
  after `canary_failure_threshold` consecutive such failures it is degraded
  (pinned) or admission-rejected (provisional). A single failure does **not**
  change routing state (FR-CAN10).
- **AC-3 (WS path).** A WS probe truncated before the nonce (undersized
  `max_tokens`) is classified `incomplete`, not `nonce_mismatch`. *(HTTP probes
  do not inspect `finish_reason` and classify a truncated body as
  `nonce_mismatch`; HTTP truncation classification is forward AC-F8.)*
- **AC-4.** In `observe` mode, a nonce-correct probe with an arbitrarily high
  measured *sub-timeout* TTFT passes; `canary_fail_count` does not increment.
  (A probe exceeding `canary_timeout_s` still fails — that is the soft-deadline
  `relay_error`, not a sub-timeout SLO breach; see FR-CAN8.)
- **AC-5.** A canary-degraded pinned provider that later passes one probe (with
  no other degrade cause) is restored to `ready`; the persisted sanction row is
  deleted.
- **AC-6.** A pinned provider with a persisted sanction, after a coordinator
  restart (**with `canary_enabled` true**, store intact) + reconnect, comes back
  `degraded` and non-routable until it passes a probe (FR-CAN16).
- **AC-7.** While a canary recovery hold is live, a provider heartbeat reporting
  `ready` (or `draining`→`ready`) does **not** clear the hold (FR-CAN14).
- **AC-8.** When the only provider for a model is canary-sanctioned *and buyer
  requests are also failing*, a buyer request returns 503 `no_provider_available`
  with `retryable: true` (FR-CAN20); the model does not 404 (FR-CAN21).
- **AC-9.** Every failed probe emits a log line with a non-empty
  `canary_fail_reason` drawn from the §5 taxonomy (FR-CAN27).
- **AC-10.** A provisional provider banned by canary remains admission-rejected
  after a coordinator restart (store intact) until an operator un-ban
  (FR-CAN17/FR-CAN32).

Forward criteria (expected to FAIL against the current build; each corresponds to
a §14 Partial/Gap row and defines part of the follow-up IMPL's done bar):

- **AC-F1 (FR-CAN8).** Latency `enforce` is refused unless the probe is
  streaming, the decision is percentile-over-N, and the model has ≥2
  routing-eligible providers.
- **AC-F2 (FR-CAN14).** A provider concurrently breaker- and canary-degraded is
  restored to `ready` only after **both** causes clear; a passing canary while a
  breaker hold is live does not restore routing; `MarkRecovered` does not release
  an `operator_clear` hold.
- **AC-F3 (FR-CAN15).** With `canary_enabled: false`, a durable pinned sanction
  is still loaded and reapplied on restart.
- **AC-F4 (FR-CAN22).** The **sole** provider for a model is not removed by any
  canary-only signal — `nonce_mismatch`, `incomplete`, latency, soft-deadline
  `relay_error`, or a canary-specific HTTP non-200 — absent an independent
  buyer-path failure, confirmed transport death, or item-9 weight evidence.
- **AC-F5 (FR-CAN23).** Correlated-fault containment is ephemeral and Sybil-proof:
  (a) **no correlated-majority verdict** — from one provider, a strict majority,
  an all-attested set, multiple IDs under one operator, or a set that fails
  **successive** epochs on **different** fingerprints — automatically creates any
  persistent **containment** state (no rollback, no config-fault attribution, no
  persistent fingerprint suspension); the only automatic correlated-fault effects
  are per-epoch. (Ordinary per-provider FR-CAN11/15 sanctioning of a
  non-correlated failure is unaffected — see (d).) (b) A correlation epoch **stages** all
  its results; on a strict-majority (>N/2, ≥2) shared-fingerprint failure the
  staged results are **discarded** (no sanction, no counter increment) + operator
  alert + FR-CAN22 floor, and nothing persists; a sequential multi-fingerprint
  Sybil campaign therefore only produces repeated discards + alerts, never a
  disabled canary. (c) With **honest** providers at threshold−1, a shared bad
  fingerprint does **not** sanction the first responders before the verdict forms
  (staged, then discarded). (d) A non-correlated minority failure **commits** and
  sanctions that provider normally. (e) A stale-generation result (bank reloaded
  mid-epoch) is discarded; per-provider commits are atomic w.r.t. the
  last-provider guard (two providers can't both be removed). (f) A
  `max_tokens`-attributable `incomplete` is neutral at any fleet size.
- **AC-F6 (FR-CAN26).** Canary tuning parameters can be changed without a
  coordinator restart.
- **AC-F7 (FR-CAN20).** The 503 `Retry-After` is derived from the FR-CAN12
  next-dispatch bound (guidance) and is never shorter than the minimum sweep
  interval.
- **AC-F8 (FR-CAN6, HTTP path).** An HTTP probe truncated by `max_tokens` is
  classified `incomplete` (via `finish_reason:"length"`), not `nonce_mismatch`.
- **AC-F9 (FR-CAN25).** A config with an empty per-model bank (`{model-a: []}`),
  a global bank carrying a latency SLO field, a duplicate model key, or a bank of
  >256 entries fails validation.
- **AC-F10 (FR-CAN18).** Persistence is crash-consistent: (a) a sanction/ban whose
  durable write fails holds the provider **non-routable** (quarantine) until ack —
  never routable-with-a-logged-error — and does not become effective-then-lost
  across restart; (b) a sanction-store or admission-store **load failure/
  corruption at startup fails coordinator readiness**, not fail-open; (c) a crash
  before write-ack does not launder the sanction; (d) automatic recovery deletion
  and `recoverProvider`'s two durable writes are all-or-nothing.
- **AC-F11 (FR-CAN27/28).** Failure logs carry `assigned_id` + outcome and
  latency metrics for both bank types; `/poolz` exposes explicit-`null` canary
  timestamps and a stable trip/hold reason.
- **AC-F12 (FR-CAN29).** A model-class dispatch skip is neutral for the OPoI
  pass flag (does not record `pass=false`).
- **AC-F13 (FR-CAN31).** After an operator clear, the session is non-routable
  until a fresh reconnect + warm-up; a concurrent in-flight probe cannot
  resurrect the cleared sanction (epoch fencing).
- **AC-F14 (FR-CAN26).** A config reload during an in-flight probe does not let the
  probe be dispatched under one generation and evaluated/sanctioned under another:
  an invalid candidate config is rejected wholesale; a valid one swaps atomically
  as one versioned snapshot covering **every** FR-CAN24 key; a probe whose
  generation changed mid-flight is evaluated against its captured snapshot or
  discarded. Specifically exercised: reloads of `canary_timeout_s`,
  `canary_cold_start_grace_s`, `canary_interval_s`, `canary_max_tokens`,
  `canary_latency_enforcement`, and **`canary_enabled: false` mid-flight discards
  the already-dispatched result** (no post-disable sanction).

## 16. Production posture (as of 2026-07-11)

Canary is **disabled in production** (`canary_enabled: false` in the Pearl
overlay). After the three incidents the operator chose to disable it rather than
run it flapping; warm-up (SPEC-002 FR-P8a) plus buyer-path inference plus the
external buyer canary (decision-log Entries 124–126) are the live liveness gates.
Model-class (`model_class_challenges`) validation is being revalidated in staging
before re-enable (Entry 125).

**Operational caveat (ties to FR-CAN15).** Because the shipped code gates durable
sanction load on `canary_enabled`, disabling canary and restarting currently
**launders** any existing pinned sanction. Until FR-CAN15 is fixed, disabling
canary is not a clean sanction-preserving lever; operators SHOULD prefer clearing
a specific false sanction (FR-CAN31/32) over a broad disable+restart when the
intent is to keep other sanctions in force.

This spec's purpose is to define the contract under which internal canary can be
**safely re-enabled**. This is the **single authoritative re-enable requirement**
(§14 classifies per-FR status but defers the gate to this list) — operators
**MUST NOT** re-enable canary sanctioning until every item holds:

1. **FR-CAN22/23** — sole-provider protection + Sybil-proof correlated-fault
   containment (a canary-only signal never empties the pool for the last provider;
   a shared bad challenge is contained by ephemeral discard + operator alert, with
   no correlated-majority verdict creating persistent containment state — ordinary
   per-provider FR-CAN11/15 sanctions still apply).
2. **FR-CAN15** — durable sanction load decoupled from `canary_enabled` (disabling
   canary does not launder sanctions).
3. **FR-CAN18** — crash-consistent, fail-closed persistence for pinned sanctions
   *and* provisional admission rejections (best-effort writes do not survive a
   restart, so a sanction can be laundered without this).
4. **FR-CAN14** — degrade-cause composition (breaker and canary coexist without a
   canary pass laundering a breaker hold).
5. **FR-CAN26** — canary config tunable without a coordinator restart.
6. **`observe` mode MUST remain in force until FR-CAN8** (streaming +
   percentile-over-N + ≥2-provider preconditions) is conformant — latency
   `enforce` on the current non-streaming single-shot metric is unsafe.

FR-CAN22/23, FR-CAN15, FR-CAN18, and FR-CAN26 are the outage-preventing guards;
FR-CAN14 is required before the breaker and canary coexist under load.

## 17. Cross-references

- **SPEC-002** — provider state machine (`ready/busy/degraded/draining/
  unavailable`), FR-P5 routing eligibility, FR-P8a admission warm-up gate,
  FR-P11a circuit-breaker and hold-integrity rules, F-2 provisional/pinned
  admission. Canary degrade reuses the `degraded` state and the anti-self-launder
  hold discipline; it differs from FR-P11a in being probe-bounded rather than
  `degraded_backoff_s`-bounded (FR-CAN12) and MUST compose with the breaker as a
  distinct cause (FR-CAN14).
- **SPEC-003** — open provider onboarding; co-owns the tier definitions.
- **SPEC-006 §5.2 / §17.2 / SPEC-010 R-3.3.4** — buyer retryability contract and
  the 404 (unknown model) vs 503 (known-but-unavailable) boundary (FR-CAN20/21).
- **SPEC-008** — attestation; owns model/weight identity claims that the canary
  explicitly does NOT make (§1).
- **SPEC-018 / SPEC-019** — the tool-calling error subset of the buyer envelope
  and the `retryable`/`Retry-After` field mechanics.
- **SPEC-020** — provider autoupdate trust table; *consumes* the provisional/
  pinned tiers (does not define them).
- **SPEC-030** — losslessness probe. The two are distinct probe families. To stay
  consistent with SPEC-030 FR-1 (which *permits* SPEC-030 to reuse the canary
  scheduling / jitter / persistence infrastructure), SPEC-031 states the boundary
  as a permission plus a hard separation: SPEC-030 **MAY** share the generic
  scheduling/jitter/persistence infrastructure, but **MUST** keep its own
  **authenticated carrier, frames, verdict, state, and sanction path** separate
  from the canary's (HTTP fallback excluded, Tier-2 dedicated carrier per SPEC-030
  FR-1/3/4). SPEC-031 does not require SPEC-030 to run a separate scheduler (the
  current implementation happens to), and SPEC-031's `inference_request`/HTTP
  transport (FR-CAN4) MUST NOT carry losslessness probes, and vice-versa.
- **Proof-of-weights / OPoI + autotune hello-gate** — runbook item 9's separate
  baseline (SPEC-032); owns the *semantics* of `model_class_challenges` and the
  autotune hello-gate. Per SPEC-032 FR-PW1/PW3, OPoI as implemented is **not** a real
  anti-downgrade guarantee (it is the same plaintext-nonce echo); a genuine
  weight-integrity test (statistical/attested) is a forward requirement there, not yet
  a shipped guarantee. FR-CAN8/22 consume the hello-gate's live eligible-provider
  count (incident #2).

## 18. Changelog

- **v0.1-draft (2026-07-11):** Initial reconstructed baseline (runbook item 8,
  Wave C), then **R1 codex three-lane audit absorbed** (code / security /
  architect; each returned 1 CRITICAL + HIGH/MEDIUM). Key absorptions:
  - **CRITICAL (all three lanes):** recast the nonce echo as a **liveness /
    instruction-following / freshness** signal — it is NOT model-identity or
    anti-downgrade proof (a cheaper/substituted model can echo a plaintext
    nonce). Removed the identity/anti-downgrade language throughout (§1/§3/§4/§7/
    §10); deferred weight-integrity to SPEC-008 + item 9. Consistent with
    SPEC-008 §3/§5.1 and SPEC-030 §4.
  - **HIGH:** provisional bans are durable via the admission store, not
    runtime-only (FR-CAN17); routing eligibility is conjunctive with auth/
    publication predicates (FR-CAN19); canary/breaker degrade must compose as a
    multi-cause set — the single `recoveryHolds` slot lets a canary pass launder a
    breaker hold and `MarkRecovered` clears an operator hold (FR-CAN14); durable
    sanction load must not be gated on `canary_enabled`, else disable+restart
    launders sanctions (FR-CAN15); observe-mode latency logging is model-class-only
    and global-bank latency should be rejected (FR-CAN7); empty per-model banks
    pass validation (FR-CAN25); SPEC-030 transport must not be conflated (§17);
    the observability "Implemented" claims were overstated (FR-CAN27/28/29).
  - **MEDIUM:** the recovery-attempt bound is ~1.5×interval+cadence (~480 s), not
    one sweep (FR-CAN12/20); retryability ownership is SPEC-006 §5.2 not SPEC-018;
    the AC set is split into testable-now vs forward (§15); AC-3 qualified WS-only.
  - **LOW:** tier ownership attributed to SPEC-002/003 (SPEC-020 only consumes).
  Sources: `internal/ws/canary_probe.go`, `internal/ws/canary_store.go`,
  `internal/ws/server.go`, `internal/ws/admission*.go`, `internal/pool/provider.go`,
  `internal/config/config.go`, `internal/buyer/server.go`, `cmd/coordinator/main.go`,
  and the live Pearl posture probe of 2026-07-11. Incident provenance:
  2026-07-09 latency-gate flapping, 2026-07-10 transient-degrade 503s, 2026-07-10
  restart outage. Codifies PRs #478/#491/#512/#513/#524/#528/#531/#533/#538 and
  decision-log Entries 124–126.
  - **R2 codex three-lane audit absorbed** (0 CRITICAL; code 3H/3M, security
    2H/3M/1L, architect 1H/3M/1L — all refinements of the R1 corrections):
    - **Sole-provider protection rewritten (FR-CAN22/23).** The R1 "correctness
      may empty the pool" rule contradicted the R1 CRITICAL for a singleton. Now:
      the **sole** provider is *never* removed by a canary-only signal (echo,
      latency, soft-deadline, or canary HTTP non-200) — removal requires
      independent corroboration (buyer-path breaker, confirmed transport death,
      or item-9 weight evidence). Correctness sanctions apply only with ≥2
      providers, under correlated-fault containment defined over a pre-sweep
      snapshot with challenge fingerprint + bank generation + quorum + atomic
      eligible-count evaluation.
    - **Nonce/selection stated precisely (FR-CAN2, §1).** 32-bit nonce =
      probabilistic freshness, not uniqueness/replay proof; `randbyte % len`
      selection is biased and leaves banks >256 entries partly unreachable →
      require ≤256-entry banks or unbiased sampling. Row demoted to Partial.
    - **Persistence hardened (FR-CAN17/18).** Provisional durability is
      best-effort (swallowed save errors, fail-open load) → Partial; FR-CAN18 now
      requires crash-consistent, fail-closed writes for pinned + provisional and
      all-or-nothing combined operator clears; added to the re-enable bar.
    - **FR-CAN7 corrected:** global-bank latency is un-logged in observe but
      *applied* in enforce (not merely ignored) → reject at validation.
    - **FR-CAN8/§5:** observe-mode "no sanction" narrowed to sub-timeout SLO
      breaches (soft-deadline still sanctions non-sole providers); WS pre-dispatch
      session-death is a neutral *skip*, not a `relay_error`; HTTP non-200 split
      into a `status` sub-class.
    - **FR-CAN12/20:** split next-dispatch bound from recovery-ready bound
      (unbounded eligibility wait) → `Retry-After` is guidance, not a deadline.
    - **§17:** SPEC-030 is fully independent (own loop/carrier/state), not an
      infrastructure re-user. **§14/§15:** FR-CAN2/17/28 → Partial; AC set
      renumbered with validation/HTTP-truncation/persistence/observability/
      skip-neutral/operator-hold moved to forward AC-F8..F13. Two canary_probe.go
      comments reframed off "identity/anti-downgrade" (comment-only).
  - **R3 codex three-lane audit absorbed** (0 CRITICAL; code 0H/0M/1L PASS,
    security 2H/3M, architect 4M — final convergence refinements):
    - **FR-CAN23 quorum made exact + Sybil-resistant** (arch + security HIGH): the
      `⌈N/2⌉` quorum was attacker-triggerable (one Sybil provider = quorum at
      N=2). Now requires a strict majority (`>N/2`) AND ≥2 providers, a
      `canary_interval_s` observation window, and — the key add — automatic bank
      rollback requires Sybil-resistant corroboration (≥2 operator-trusted
      identities or a known-good control); a provisional/Sybil-only majority is
      *suspicion + alert*, not attribution. AC-F5 extended with N=2 / hostile /
      Sybil cases.
    - **Single canonical re-enable bar** (arch + security HIGH): §16 now reproduces
      the full §14 list including FR-CAN18 and the observe-until-FR-CAN8 rule.
    - **FR-CAN18 "fail closed" fully defined** (security): non-routable quarantine
      until write-ack; fail startup/readiness on sanction/admission-store load
      failure or corruption; atomic combined clears. AC-F10 extended.
    - **FR-CAN26 config-generation contract** (security): validate the whole
      candidate config, swap one monotonically-versioned immutable snapshot,
      bind each in-flight probe to its dispatch generation or discard. New AC-F14.
    - **Global-bank latency `SHOULD`→`MUST` reject** (security) in FR-CAN7 +
      FR-CAN24, aligning with AC-F9's MUST.
    - **FR-CAN12 §14 row** relabeled Implemented + "next-dispatch bound" (not a
      recovery guarantee) (arch + code LOW). **SPEC-030** header/§2 softened from
      "shares no code path" to "no shared canary-specific dispatch/verdict/sanction
      path" — they do share the generic `Server`/pool/session infrastructure (arch).
  - **R4 codex two-lane audit absorbed** (0 CRITICAL; security 3H/2M, architect
    1H/4M — both lanes converged on one redesign, and the code lane was not
    re-fired as it had already PASSED at R3):
    - **FR-CAN23 correlated-fault redesigned to be Sybil-proof by construction**
      (both lanes HIGH). The R3 "≥2 operator-trusted (pinned/attested) identities
      corroborate" rule was still exploitable — SPEC-008 `attested` proves device
      identity, not independent ownership, so one operator with two attested/pinned
      IDs met the bar and could force a bank rollback. Replaced the trusted-provider
      quorum entirely: **provider correlation is now a suspicion signal only, and
      the sole thing that authorizes an automatic challenge-bank rollback is a
      coordinator-controlled known-good control failing** — no set of providers, of
      any trust level, can force it. Absent a control, suspicion = operator alert +
      the FR-CAN22 last-provider floor. Also fixed the window/scheduling
      contradiction: an explicit **correlation epoch** actively re-dispatches the
      same fingerprint to the snapshot (random per-probe selection never guaranteed
      shared exposure), bounded by the FR-CAN12 next-dispatch window.
    - **FR-CAN18 crash-launderable path closed** (security HIGH): the bare
      "wait-for-ack + RAM quarantine" alternative loses the sanction on a crash
      before ack; now a **durable write-ahead/outbox record MUST exist before the
      sanction is relied upon**.
    - **§14/§16 de-duplicated** (both lanes HIGH): §16 is now the single normative
      `MUST NOT re-enable` list; §14 defers to it (was a contradictory `SHOULD`/
      five-item list omitting observe-until-FR-CAN8).
    - **FR-CAN26 generation snapshot** now covers **every** FR-CAN24 key
      (added `canary_timeout_s`/`_interval_s`/`_cold_start_grace_s`/`_enabled`) and
      defines disable-mid-flight = discard (security MED). **SPEC-030** §17 aligned
      with SPEC-030 FR-1: MAY share generic scheduling/persistence infra, MUST keep
      carrier/verdict/state/sanction separate (arch MED). AC-F5/F14 extended.
  - **R5 codex two-lane audit absorbed** (0 CRITICAL; security 1H/1M, architect
    1H/3M — both lanes confirmed the R4 redesign textually closed; remaining
    items were the last mile of that redesign + one internal contradiction):
    - **Automatic bank rollback removed from v0.1 entirely (both lanes HIGH →
      decisive scope call).** R4's "coordinator known-good control failing
      authorizes rollback" was still a **rollback oracle**: Sybils repeatedly trip
      the control and eventually ride a *transient* control failure (timeout /
      transport / unavailable) into rolling back a valid bank. Rather than pile on
      taxonomy/single-flight/cooldown epicycles, v0.1 refuses the automatic path:
      correlated suspicion now **suspends sanctioning on the one suspect challenge
      fingerprint** (+ operator alert + FR-CAN22 floor) — bounded and Sybil-safe
      (worst case = one challenge benched from sanctioning, never an outage or
      rollback). Full rollback is an operator action; an automatic path is deferred
      to a future version behind an authenticated, single-flight, generation-fenced
      control whose *deterministic challenge-semantic* failure alone could
      authorize it.
    - **FR-CAN2/FR-CAN8 contradiction fixed (arch HIGH):** FR-CAN2 mandated
      `stream:false` unconditionally while FR-CAN8 requires `stream:true` for
      latency enforce — the enforce path was unimplementable. FR-CAN2 is now
      mode-conditional (`stream:false` echo/observe; `stream:true` iff enforce).
    - **Correlation detection SHOULD→MUST** (both lanes MED) so it matches the §16
      re-enable gate. **SPEC-030 header/§2** finally aligned with §17 (dropped the
      leftover "own dispatch loop" claim) (arch MED).
  - **R6 codex two-lane audit absorbed** (0 CRITICAL; security 1H/1M, architect
    0H/2M — both lanes confirmed R5 closed; the last item was the fixed point of
    the correlated-fault design):
    - **Correlated-fault made ephemeral / persistent-state-free (both lanes HIGH+
      MED — the terminating invariant).** R5's fingerprint-*suspend* was itself
      persistent provider-triggerable state: a Sybil majority failing successive
      epochs on different fingerprints could suspend the whole bank and silently
      disable the canary. Root cause: *any* persistent automatic response a
      provider majority can trigger is weaponizable. Final design: a correlation
      epoch **stages** all results; a strict-majority shared-fingerprint failure
      **discards** them (no sanction, no counter) + operator alert + FR-CAN22 floor
      and **nothing persists**; otherwise results **commit** atomically. All
      persistent containment (bench a fingerprint, roll back a bank) is an
      **authenticated operator action**. Also fixes security MED (staged results
      never sanction honest providers at threshold−1 before the verdict forms).
      This is the fixed point — there is no persistent automatic state left to
      weaponize.
    - **FR-CAN21 404 rule deferred to SPEC-010 `ModelKnown()`** (arch MED): 404 iff
      `ModelKnown()==false` over the union of live `ModelID` + live
      `SupportedModels` + seen history; declared-but-cold → 503. The SPEC-002
      `MAY` / SPEC-006 wording is the carried item-22 inconsistency (§14 no longer
      claims full three-way alignment).
  - **R7 codex two-lane audit** — **architect PASS (0 C/H/M, 2 LOW)**; security
    0C/0H/1M/1L with both R6 items confirmed closed. Absorbed:
    - **Sybil-safety invariant narrowed** (security MED): the R6 wording ("no
      provider behavior may cause any durable state change") was too absolute — it
      also forbade the *legitimate* per-provider FR-CAN11/15 sanction. Re-scoped to
      "no **correlated-majority verdict** may automatically create persistent
      **containment** state"; a non-correlated committed failure still updates its
      counter and sanctions at the FR-CAN11 threshold. No design change — the
      ephemeral correlated-fault path is unchanged.
    - **LOW hygiene:** deleted a duplicated `incomplete`-neutrality bullet; added
      **FR-CAN29a** defining the correlated-fault operator-alert event in §12 (the
      §12 cross-reference now has a concrete home).
