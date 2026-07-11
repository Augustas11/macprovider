# SPEC-031 — Canary Probe, Degrade & Sanction Lifecycle

**Status:** v0.1-draft
**Date:** 2026-07-11
**Depends on:** SPEC-002 (coordinator provider state machine: FR-P5 routing eligibility, FR-P8a admission warm-up, FR-P11a circuit-breaker; F-2 amendment defines provisional/pinned admission), SPEC-003 (open provider onboarding, tier semantics), SPEC-006 §5.2 / §17.2 (buyer error contract, 404/503), SPEC-008 (attestation — owns model/weight identity claims), SPEC-018/019 (buyer error envelope + `retryable`)
**Related infrastructure:** SPEC-030 (losslessness probe) reuses the canary *scheduling/jitter/persistence* infrastructure but owns its own dedicated authenticated carrier and state (see §17).
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
3. **producing fresh, non-replayed output** (the nonce is unique per probe).

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
- SPEC-030 losslessness probe **semantics and transport** — it reuses only the
  canary scheduling/jitter/persistence infrastructure; its carrier, encryption,
  and state are its own (SPEC-030 FR-1/3/4).
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
  bytes; the **challenge selection is uniformly random** over the applicable
  bank (`challenges[randbyte % len(bank)]`) — consecutive probes to the same
  provider may use different challenges. (An implementer MUST NOT assume stable
  per-provider challenge selection.)
- select the applicable bank: the per-model `model_class_challenges` bank if the
  provider's admitted model id matches (exact, then case-insensitive), else the
  global `canary_challenges` bank;
- issue the request with **`temperature: 0`** and **`stream: false`**, and
  `max_tokens = pool.canary_max_tokens`. **The temperature pin is a normative
  correctness invariant**: without it, low-bit models (measured on 4-bit
  qwen3-coder-30b) transform the nonce and fail the echo gate spuriously
  (incident #533). An implementation MUST pin temperature to 0 (or the
  provider's most-deterministic equivalent) on every canary probe.

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
| `relay_error` | infra/liveness | **hard** (transport/session) | WS relay error / session dead; HTTP transport error, non-200, or body-read error |
| `relay_error` | infra/liveness | **soft** (deadline) | probe exceeded `canary_timeout_s` with no hard transport failure |
| `ttft_breach` | latency/SLO | — | measured TTFT exceeds `max_ttft_ms` (only when enforcing) |
| `tps_breach` | latency/SLO | — | sustained TPS below `min_sustained_tps`, or non-finite (only when enforcing) |

The classifier MUST check `nonce_mismatch` before the latency reasons, and
`ttft_breach` before `tps_breach`. `canary_fail_reason` MUST be present on
**every** failure log line — its absence during the 2026-07-09 incident is why
operators could not diagnose *why* probes were failing (the field was added by
PR #513).

> **Sub-class conformance note.** The shipped code emits a single `relay_error`
> constant for both hard transport failure and soft deadline expiry
> (`canary_timeout_s`, default 30 s, is far below the buyer request timeout of
> 280 s). Distinguishing the two — so a merely-slow sole provider that still
> serves buyers is not evicted by a canary deadline (§10 FR-CAN23) — is a
> conformance gap (§14). Likewise `incomplete` does not currently carry a
> coordinator-attribution flag.

## 6. Latency-gate policy: observe vs enforce

**FR-CAN7 — Observe is the required default; latency SLOs are model-class-only.**
`pool.canary_latency_enforcement` takes values `observe` (default; empty string
means `observe`) or `enforce`. In `observe` mode a latency breach MUST be logged
and MUST NOT fail the probe. Only `enforce` mode lets `ttft_breach`/`tps_breach`
count toward a sanction.

Per-challenge latency SLO fields (`max_ttft_ms`, `min_sustained_tps`) are
meaningful **only on model-class banks**. Configuration validation SHOULD reject
these fields on a **global** `canary_challenges` entry, because the global bank
is a pure liveness/echo probe. (The shipped code only *logs* observe-mode
latency breaches for model-class banks; a global-bank latency field is silently
ignored — a conformance gap, §14. The clean resolution is to reject them at
validation rather than accept-and-ignore.)

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
named owner. Until then, `observe` remains the normative production posture and a
correct-but-slow provider is **not** sanctioned by the canary path. This is
recorded as an open item, not an implemented guarantee (§14).

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
attempted; because the next probe is scheduled at the **jittered per-provider
interval** and then observed on a later sweep, the worst-case time to a recovery
*attempt* is approximately:

```
recovery-attempt bound  ≤  1.5 × canary_interval_s  +  canary_sweep_cadence  +  dispatch delay
```

With defaults (`canary_interval_s = 300`, sweep cadence 30 s) this is ~480 s, not
one sweep. `Retry-After` guidance (§9 FR-CAN20) MUST be derived from this same
bound, never from the raw sweep cadence.

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
is non-routable until it passes a canary. Cold-start grace (§9) still applies to
*latency* gates on the fresh session but never waives the echo gate.

**FR-CAN17 — Provisional bans: record runtime-only, admission rejection durable.**
The canary-sanction *record* (in `provider_canary_sanctions`) is **not** written
for a provisional trip. However, the provisional trip calls
`AdmissionManager.Reject`, and that **admission rejection IS durable** — it is
persisted and reloaded across restart, with its own retention TTL and operator-
clear path (FR-CAN32). Therefore a banned provisional provider **remains
admission-rejected across a coordinator restart** until an operator un-ban
(FR-CAN32) or retention pruning clears it; it does **not** get a clean readmission
cycle on restart. (Decision-log Entry 125 records exactly this: a provisional
false positive became a durable admission rejection that only an authenticated
un-ban could clear.) This asymmetry — pinned degrade persists as a canary
sanction, provisional ban persists as an admission rejection — is intentional;
both survive restart, by different mechanisms.

**FR-CAN18 — Fail-closed persistence.** Sanction persistence MUST NOT be
best-effort. The shipped path installs the runtime sanction first and only logs
an upsert failure (`provider.go`), so a storage failure followed by a restart
silently drops the sanction. An implementation MUST make persistence failure
either fail-closed (keep the provider degraded and surface the error) or reliably
retried via an outbox. (Conformance gap, §14.)

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
served/known model into a 404. `404 model_not_found` is reserved for models that
no provider serves or has recently seen (SPEC-006 §17.2, SPEC-010 R-3.3.4). A
model whose only provider is canary-degraded is **known but temporarily
unavailable** → 503, not 404.

## 10. Last-provider protection (new invariant)

**FR-CAN22 — Sole-provider removal requires independent, non-coordinator-
attributable evidence.** Whether a sanction may empty a model's eligible pool
depends on whether the failure is **independent of the coordinator's own
configuration** and corroborated as a genuine provider fault — *not* on the raw
reason label:

- **Coordinator-attributable failures MUST NOT empty the pool.** An `incomplete`
  caused by an undersized `pool.canary_max_tokens` (FR-CAN3), or any failure
  attributable to the coordinator's challenge bank or prompt, is a coordinator
  fault. It MUST be treated as neutral or last-provider-protected for the sole
  provider.
- **Latency failures MUST NOT empty the pool** — including the **soft**
  `relay_error` sub-class (canary deadline expiry, §5), because a provider that
  exceeds the 30 s canary deadline may still be serving buyers within the 280 s
  request timeout. The metric is unreliable (§8) and a false sanction on a
  single-provider pool is a total, self-inflicted outage (incidents #1 and #2).
- **Hard infra failures** (`relay_error` hard sub-class: WS/session dead, non-200)
  MAY remove the sole provider — a provider the coordinator genuinely cannot
  reach is already not serving buyers, and the buyer path returns a clean
  retryable 503.
- **Correctness failures** (`nonce_mismatch`, or `incomplete` NOT attributable to
  `max_tokens`) MAY remove the sole provider **only** when the failure is not
  part of a correlated fleet-wide pattern (FR-CAN23) — i.e. when it is plausibly
  a genuine single-provider fault (dead/garbage/instruction-not-followed), not a
  bad shared challenge. Removal is justified because the provider is not producing
  usable responses, **not** because the canary proved wrong weights (§1).

**FR-CAN23 — Correlated-fault containment.** If **all** (or a quorum of)
routing-eligible providers for a model fail the **same** challenge or fail
concurrently in the same way, the coordinator MUST suspect its own configuration
(challenge bank, prompt, `max_tokens`) rather than the fleet, and MUST NOT
sequentially remove every provider. In that case it MUST (a) circuit-break /
roll back the offending challenge bank, and (b) protect the last known-serving
provider, until stronger independent evidence (a buyer-path failure, or item 9's
weight-bound test) corroborates a genuine provider fault. A provisional sole
provider MUST additionally never be hard-banned/session-closed on a **latency**
or **soft-deadline** failure.

> **Conformance gap (§14).** Last-provider protection, coordinator-attribution of
> `incomplete`, the soft/hard `relay_error` split, and correlated-fault
> containment are **not yet implemented** — `RecordCanaryResult` receives only a
> pass/fail boolean with no failure class, no attribution, and no eligible-count
> guard. Today a sole provider CAN be removed by a coordinator-config fault
> (incidents #1/#2). Production is safe only because it runs `observe` (latency
> never sanctions) and canary is disabled entirely; making these guards explicit
> is the primary pre-re-enable requirement (§16).

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
| `canary_challenges` | list | — | Global liveness/echo bank; each `{prompt, expected}` MUST contain `{nonce}`; latency SLO fields SHOULD be rejected here (§6). |
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
only safe once sanction load is decoupled from it.) Conformance gap, §14.

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

## 13. Tier asymmetry and operator recovery

**FR-CAN30 — Documented asymmetry.** The provisional-ban (admission reject,
durable via the admission store per FR-CAN17) vs pinned-degrade (canary sanction,
durable via `provider_canary_sanctions`) split is the intended policy; both
survive restart, by different mechanisms.

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
| FR-CAN2 body (temp 0, nonce, random challenge) | Implemented | Temperature pinned (#533); nonce validated; challenge selection is random (spec now says so). |
| FR-CAN3 `max_tokens` sizing + attribution | **Tightens/Gap** | Prod default 16→32 (#531); ≥-expected-length validation and the coordinator-attribution of `incomplete` are new. |
| FR-CAN4/5 transport, admitted model | Implemented | WS vs HTTP split; `MaxAdmittedModelKey`. FR-CAN5 explicitly not an identity binding. |
| FR-CAN6 echo-first, skip-neutral | **Partial** | Order + counter skip-neutral implemented; OPoI skip-neutrality is a gap (see FR-CAN29). |
| FR-CAN7 observe default; global-latency reject | **Partial** | Default `observe` (#513); global-bank latency fields are accept-and-ignored, not rejected (gap). |
| FR-CAN8 enforce preconditions + buyer-path QoS owner | **Gap** | `enforce` reachable today single-shot/non-streaming/unguarded; no concrete sub-timeout QoS enforcement exists. |
| FR-CAN9 cold-start grace | Implemented | #512. |
| FR-CAN10 sub-threshold no-op | Implemented | `RecordCanaryResult` returns below threshold. |
| FR-CAN11 tier sanction | Implemented | Provisional ban / pinned degrade+persist. |
| FR-CAN12 probe-bounded window + recovery bound | **Tightens** | Behavior shipped; the ~1.5×interval recovery-bound formula is a spec correction (was mis-stated as sweep cadence). |
| FR-CAN13/14 composition of degrade causes | **Gap** | Single `recoveryHolds` slot: canary overwrites breaker hold; `MarkRecovered` clears operator-clear hold. Multi-cause set not implemented. |
| FR-CAN15 durable load independent of `canary_enabled` | **Gap** | `LoadCanarySanctions` gated on `CanaryEnabled` — disable+restart launders sanctions. |
| FR-CAN16 reapply on reconnect | Implemented | `applyCanarySanctionLocked` (pinned). |
| FR-CAN17 provisional admission-reject durable | **Tightens** | Behavior shipped (admission store persists); the spec now describes it accurately (was wrongly "runtime-only"). |
| FR-CAN18 fail-closed persistence | **Gap** | Upsert failure is log-only; runtime sanction installed before persistence. |
| FR-CAN19 conjunctive eligibility | Implemented | `RoutingEligible()` enforces auth/publication + state + slots. |
| FR-CAN20 retryable 503 + cadence Retry-After | **Partial** | `no_provider_available` retryable (#548); ownership is SPEC-006 §5.2; gateway 1 s hint is shorter than the sweep (gap). |
| FR-CAN21 404/503 boundary | Implemented | Aligns with SPEC-006 §17.2 / SPEC-010 R-3.3.4 (#555). |
| FR-CAN22/23 last-provider protection + correlated-fault | **Gap** | No failure-class, no attribution, no eligible-count guard, no correlated-fault containment. |
| FR-CAN24/25 config surface + covering bank | **Partial** | Surface + basic validation shipped (#478, Entry 125); empty per-model lists and duplicate keys pass (gap). |
| FR-CAN26 reload without restart | **Gap** | Pool block startup-only; direct cause of incident #3. |
| FR-CAN27 failure logging | **Partial** | `canary_fail_reason` (#513); missing `assigned_id`/outcome and global-bank latency (gap). |
| FR-CAN28 `/poolz` fields | **Gap** | Only `routing_eligible` + `canary_fail_count`; no nullable timestamps, no trip/hold reason. |
| FR-CAN29 model-class pass flag skip-neutral | **Partial** | Flag emitted (#491); skip records `pass=false` (gap). |
| FR-CAN30 documented asymmetry | Implemented | Both durable, different stores. |
| FR-CAN31 operator clear (pinned) | **Partial** | Clear + epoch fencing + hold conversion shipped; `MarkRecovered` still clears the operator hold (gap, ties to FR-CAN14). |
| FR-CAN32 operator un-ban (provisional) | Implemented | `DELETE /admin/reject/{id}` (Entry 125). |

**Re-enable bar.** The Gap rows are the implementation backlog this baseline
authorizes; none is a regression. Re-enabling canary in production SHOULD be
gated on at least **FR-CAN22/23** (last-provider protection + correlated-fault
containment), **FR-CAN15** (sanction load decoupled from `canary_enabled`), and
**FR-CAN26** (no-restart tuning) — the guards whose absence caused the outages —
plus **FR-CAN14** (degrade-cause composition) before the breaker and canary can
safely coexist under load.

## 15. Acceptance criteria

Testable against the current build:

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
  `nonce_mismatch`; HTTP truncation classification is a forward gap, AC-13.)*
- **AC-4.** In `observe` mode, a nonce-correct probe with an arbitrarily high
  measured TTFT passes; `canary_fail_count` does not increment.
- **AC-5.** A canary-degraded pinned provider that later passes one probe (with
  no other degrade cause) is restored to `ready`; the persisted sanction row is
  deleted.
- **AC-6.** A pinned provider with a persisted sanction, after a coordinator
  restart (**with `canary_enabled` true**) + reconnect, comes back `degraded` and
  non-routable until it passes a probe (FR-CAN16).
- **AC-7.** While a canary recovery hold is live, a provider heartbeat reporting
  `ready` (or `draining`→`ready`) does **not** clear the hold (FR-CAN14).
- **AC-8.** When the only provider for a model is canary-sanctioned, a buyer
  request returns 503 `no_provider_available` with `retryable: true` (FR-CAN20);
  the model does not 404 (FR-CAN21).
- **AC-9.** A configuration with an empty per-model bank (`{model-a: []}`) or a
  global bank containing a latency SLO field fails validation (FR-CAN25/FR-CAN7).
- **AC-10.** Every failed probe emits a log line with a non-empty
  `canary_fail_reason` drawn from the §5 taxonomy (FR-CAN27).
- **AC-11.** A provisional provider banned by canary remains admission-rejected
  after a coordinator restart until an operator un-ban (FR-CAN17/FR-CAN32).

Forward criteria (expected to FAIL against the current build; they define the
follow-up IMPL's done bar and correspond to the §14 Gap rows):

- **AC-F1 (FR-CAN8).** Latency `enforce` is refused unless the probe is
  streaming, the decision is percentile-over-N, and the model has ≥2
  routing-eligible providers.
- **AC-F2 (FR-CAN14).** A provider concurrently breaker- and canary-degraded is
  restored to `ready` only after **both** causes clear; a passing canary while a
  breaker hold is live does not restore routing.
- **AC-F3 (FR-CAN15).** With `canary_enabled: false`, a durable pinned sanction
  is still loaded and reapplied on restart.
- **AC-F4 (FR-CAN22/23).** A latency, soft-deadline, or `max_tokens`-attributable
  `incomplete` failure does not remove the sole provider; a correlated fleet-wide
  failure circuit-breaks the challenge bank instead of emptying the pool.
- **AC-F5 (FR-CAN26).** Canary tuning parameters can be changed without a
  coordinator restart.
- **AC-F6 (FR-CAN20).** The 503 `Retry-After` is derived from the FR-CAN12
  recovery bound and is never shorter than the minimum sweep interval.
- **AC-F7 (FR-CAN28).** `/poolz` exposes nullable canary timestamps and a stable
  trip/hold reason distinguishing canary from breaker/warm-up/operator-clear.
- **AC-13 (HTTP truncation).** An HTTP probe truncated by `max_tokens` is
  classified `incomplete` (via `finish_reason:"length"`), not `nonce_mismatch`.

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
**safely re-enabled**; the §14 re-enable bar (FR-CAN22/23, FR-CAN15, FR-CAN26,
FR-CAN14) is the recommended gate.

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
- **SPEC-030** — losslessness probe. It **reuses only** the canary scheduling/
  jitter/persistence infrastructure; it owns its own dedicated **authenticated WS
  provider-control carrier** and separate state (HTTP fallback excluded, Tier-2
  dedicated carrier). SPEC-031's `inference_request`/HTTP transport (FR-CAN4)
  MUST NOT be used to tunnel losslessness probes.
- **Proof-of-weights / OPoI + autotune hello-gate** — runbook item 9's separate
  baseline; owns the *semantics* of `model_class_challenges` (and thus the only
  real anti-downgrade guarantee) and the second-provider admission gate that
  interacts with canary fragility (incident #2). FR-CAN8/22 consume the resulting
  live eligible-provider count.

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
