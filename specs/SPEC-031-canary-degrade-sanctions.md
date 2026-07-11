# SPEC-031 — Canary Probe, Degrade & Sanction Lifecycle

**Status:** v0.1-draft
**Date:** 2026-07-11
**Depends on:** SPEC-002 (coordinator provider state machine: FR-P5 routing eligibility, FR-P8a admission warm-up, FR-P11a circuit-breaker), SPEC-006 §17.2 (buyer 404/503), SPEC-018/019 (buyer error envelope + `retryable`), SPEC-030 (losslessness probe, which rides the canary transport)
**Companion baselines (separate specs):** SPEC-009-class proof-of-weights / OPoI semantics and the autotune hello-gate are their own normative baseline (runbook item 9); this spec defines only the canary *mechanism* those features build on.

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
each connected provider. The probe is simultaneously:

1. a **liveness** check (does the provider answer at all), and
2. a **model-identity** check (does the provider's served model echo a fresh
   random nonce exactly, proving it is running the model it advertises and has
   not silently downgraded quantization or swapped a cheaper model).

On repeated failure the coordinator **sanctions** the provider — removing it from
buyer routing (degrade) or evicting it (provisional ban) — and later **recovers**
it when a probe passes again. Because a sanction on the sole provider for a model
converts every buyer request into an HTTP 503, the canary subsystem is a
money-path and availability-path control, not merely a health check.

This spec defines the probe construction, the complete failure taxonomy, the
latency-gate policy, the degrade/ban/recovery state machine, sanction
persistence across coordinator restarts, the buyer-visible availability contract
during degrade, **last-provider protection**, the config/hot-reload contract, and
the observability surface — with the goal that the subsystem can be **safely
re-enabled in production** (it is currently disabled on Pearl; see §16).

## 2. Scope

**In scope**

- The `canary` probe profile: scheduling, body construction, transport, and
  validation.
- The normative failure-reason taxonomy (six constants).
- The latency-gate policy (`observe` vs `enforce`) and cold-start grace.
- The consecutive-failure → sanction → recovery state machine for both the
  **provisional** and **pinned** provider tiers.
- Sanction persistence and reapplication across coordinator restart.
- The buyer availability contract while a provider is canary-degraded
  (503 `no_provider_available`, `retryable`, `Retry-After`).
- **Last-provider protection**: which sanction classes may empty a model's
  eligible pool and which may not.
- The canary config surface and its reload/restart contract.
- The observability contract (`/poolz` fields, `canary_fail_reason` logging).
- The interaction with SPEC-002's provider state machine and the FR-P8a warm-up
  and FR-P11a circuit-breaker holds.

**Out of scope**

- The **semantics** of proof-of-weights / OPoI (what a `model_class_challenges`
  pass *proves* about weight integrity, drift windows, telemetry-drift scoring)
  — the canary carries the OPoI probe as a payload, but the integrity claims are
  runbook item 9's separate spec. This spec defines only that model-class
  challenges are matched and that a pass/fail flag is emitted.
- SPEC-030 losslessness probe **semantics** — it rides the same canary transport
  but has its own normative document.
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
| **Challenge** | A `{prompt, expected}` template (both MUST contain `{nonce}`), optionally carrying per-challenge latency SLOs. |
| **Correctness/identity failure** | A probe that proves the provider answered *wrongly* or *incompletely* — `nonce_mismatch`, `incomplete`. |
| **Infra/liveness failure** | A probe that could not complete — `relay_error`. |
| **Latency failure** | A probe that answered correctly but breached a wall-time SLO — `ttft_breach`, `tps_breach`. |
| **Sanction** | A coordinator-owned state change removing a provider from routing: **degrade** (pinned) or **ban** (provisional). |
| **Recovery hold** | A coordinator-owned lock that prevents a degraded provider from self-reporting its way back to `ready`; only a passing canary or an operator clear releases it. |
| **Sole provider** | The only routing-eligible provider for a given model at a given instant. |

Provider **tiers** are defined by SPEC-020: `provisional` (bearer-validated or
tokenless, self-onboarded) vs `pinned` (operator-configured). The canary
lifecycle differs by tier (§7).

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

**FR-CAN2 — Probe body determinism.** Each probe MUST:

- draw fresh random bytes and derive a nonce that is substituted into **both**
  the challenge `prompt` and its `expected` value. Configuration validation MUST
  reject any challenge whose `prompt` or `expected` does not contain `{nonce}`.
- select the challenge deterministically from the applicable bank (per-model
  `model_class_challenges` if the provider's model matches, else the global
  `canary_challenges`);
- issue the request with **`temperature: 0`** and **`stream: false`**, and
  `max_tokens = pool.canary_max_tokens`. **The temperature pin is a normative
  correctness invariant**, not an optimization: without it, low-bit models
  (measured on 4-bit qwen3-coder-30b) transform the nonce and fail the identity
  gate spuriously (incident #533). An implementation MUST pin temperature to 0
  (or the provider's most-deterministic equivalent) on every canary probe.

**FR-CAN3 — `max_tokens` sizing.** `pool.canary_max_tokens` MUST be greater than
or equal to the token length of the longest `expected` answer across all active
challenges, plus headroom for any short model preamble. Truncating the nonce echo
produces a spurious `incomplete` failure that can evict a healthy sole provider
(incident #528/#531; the prod default was raised 16→32 for exactly this reason).
Configuration validation SHOULD warn when `canary_max_tokens` is below a
challenge's expected length.

**FR-CAN4 — Transport.** WS-tunneled providers MUST be probed over the existing
WS relay using the SPEC-001 `inference_request` path; HTTP-forwarding providers
MUST be probed via `POST {endpoint}/v1/chat/completions`. WS-tunneled providers
MUST NOT receive HTTP probes and vice-versa (consistent with SPEC-002 FR-P8a).
Every probe MUST run under a `pool.canary_timeout_s` deadline.

**FR-CAN5 — Probe model id.** The probe MUST target the provider's currently
**admitted** model key (the autotune-ceiling `MaxAdmittedModelKey` when set, else
the provider's advertised `ModelID`), so the probe exercises the exact model
buyers are routed to and cannot pass by serving a smaller model than admitted.

**FR-CAN6 — Validation order.** Given the provider's output, the coordinator MUST
evaluate the identity gate **first**, then latency gates:

1. **Identity gate (ALWAYS enforced).** The extracted assistant content MUST
   satisfy `TrimSpace(output) == expected` — an **exact** match of the echoed
   nonce (leading/trailing whitespace trimmed; the comparison is otherwise
   byte-exact and case-sensitive). A mismatch is `nonce_mismatch`.
2. **Latency gates (conditional).** Evaluated only when latency enforcement is
   active for this probe (§6): `ttft_breach` if measured TTFT > the challenge's
   `max_ttft_ms`; `tps_breach` if sustained TPS < `min_sustained_tps` (or the
   metric is NaN/Inf).

A probe that cannot run at all (build error, dispatch error, warm-up-excluded
tier-2) is a **skip** and MUST be **neutral** — it does not count as a pass or a
failure and does not touch the consecutive-failure counter.

## 5. Failure-reason taxonomy (normative)

Every non-passing, non-skipped probe MUST be classified into exactly one of the
following reasons. These string constants are **normative** and MUST appear
verbatim in the `canary_fail_reason` log field (§12) and any operator surface:

| `canary_fail_reason` | Class | Trigger |
|----------------------|-------|---------|
| *(empty)* | pass | identity gate passed; latency gate passed or not enforced |
| `nonce_mismatch` | **correctness/identity** | `TrimSpace(output) != expected` |
| `incomplete` | **correctness/liveness** | WS relay `inference_response_end.status != "complete"` (e.g. truncated at `max_tokens` before the nonce) |
| `relay_error` | **infra/liveness** | WS relay error / context cancel; HTTP transport error, non-200, or body-read error |
| `ttft_breach` | latency/SLO | measured TTFT exceeds `max_ttft_ms` (only when enforcing) |
| `tps_breach` | latency/SLO | sustained TPS below `min_sustained_tps`, or non-finite (only when enforcing) |

The classifier MUST check `nonce_mismatch` before the latency reasons, and
`ttft_breach` before `tps_breach`, so a single most-specific reason is recorded.
`canary_fail_reason` MUST be present on **every** failure log line — its absence
during the 2026-07-09 incident is why operators could not diagnose *why* probes
were failing (the field was added by PR #513).

## 6. Latency-gate policy: observe vs enforce

**FR-CAN7 — Observe is the required default.** `pool.canary_latency_enforcement`
takes values `observe` (default; empty string means `observe`) or `enforce`. In
`observe` mode a latency breach MUST be logged and MUST NOT fail the probe: a
nonce-correct probe always passes regardless of TTFT/TPS. Only `enforce` mode
lets `ttft_breach`/`tps_breach` count as failures toward a sanction.

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

Until those hold, latency SLO enforcement MUST live on the streaming buyer path
and telemetry-drift scoring, not on the canary sanction path. `observe` remains
the normative production posture. (This codifies PR #513 and the operator's live
choice to run latency `observe`-only.)

**FR-CAN9 — Cold-start grace.** `pool.canary_cold_start_grace_s` (default 0 =
disabled) waives **latency** gates for `grace` seconds after a provider's
`ConnectedAt`. Grace MUST NOT waive the identity gate. A graced probe is neutral
for the counter and MUST force the *next* probe to be latency-enforced, so a
chronically slow provider cannot hide behind repeated reconnects. Grace is
irrelevant in `observe` mode (latency never sanctions there).

## 7. Sanction / degrade / recovery lifecycle

**FR-CAN10 — Consecutive-failure threshold.** The coordinator MUST maintain a
per-provider consecutive-failure counter. A **pass** resets it to 0. A **failure**
increments it and stamps `CanaryLastFailedAt`. A sub-threshold failure
(`count < pool.canary_failure_threshold`, default 3) **MUST NOT change routing
state** — a single transient failure never degrades a provider. This invariant is
stated explicitly because the 2026-07-10 incident memo initially (wrongly)
hypothesized sub-threshold failures were removing the provider; they are not.

**FR-CAN11 — At-threshold sanction (tier-dependent).** When the counter reaches
`canary_failure_threshold` and the sanction is permitted by last-provider
protection (§10):

- **Provisional tier** → the provider transitions to `unavailable`
  (`CanaryTripUnavailable`), the coordinator rejects it from admission and closes
  the session (`CloseBanned`, reason `canary_failed`). This sanction is **not
  persisted** across restart.
- **Pinned tier** → the provider transitions to `degraded`
  (`CanaryTripDegraded`), a **canary recovery hold** is installed, and the
  sanction is **persisted** to durable storage (§8).

**FR-CAN12 — Degrade window is probe-bounded, not time-bounded.** Unlike the
FR-P11a circuit-breaker (which recovers after `pool.degraded_backoff_s`), a
canary degrade has **no time-based auto-clear**. It persists until either (a) a
subsequent canary probe **passes**, or (b) an operator clears it (§13). The
coordinator MUST continue probing a canary-degraded provider at the normal
jittered cadence (a degraded-with-canary-hold provider remains probe-eligible
when it has free slots and is not warm-up-pending), so the maximum time to a
recovery *attempt* is bounded by the sweep cadence even though the window itself
is open-ended. An implementation SHOULD expose the effective per-provider probe
cadence so operators can reason about worst-case recovery latency.

**FR-CAN13 — Automatic recovery.** A canary-degraded pinned provider that returns
a **passing** probe MUST be restored: the failure counter is zeroed, the
persisted sanction is deleted, the recovery hold is released, and the provider
transitions to `ready`. Recovery requires an actual passing probe — the
coordinator MUST NOT auto-clear a canary sanction on a timer alone, because the
sanction encodes an unproven-identity condition, not a cooldown.

**FR-CAN14 — Hold integrity (aligns with SPEC-002 FR-P11a).** While a canary
recovery hold is live, the provider's own heartbeat/state-update MUST only be
permitted to re-affirm `degraded` — it MUST NOT let the provider self-launder
back to `ready`. The generic recovery path (`MarkRecovered`, used for
breaker/timeout recovery) MUST refuse to clear a canary hold; only a passing
canary probe or an operator clear releases it. This is the canary analog of
SPEC-002 FR-P11a's breaker-hold rule and closes the same self-report escape.

## 8. Sanction persistence and reconnect

**FR-CAN15 — Durable pinned sanctions.** A pinned canary sanction MUST be
persisted (provider id, fail count, last-checked/last-failed timestamps) so it
survives a coordinator restart. On boot the coordinator MUST load persisted
sanctions with a positive fail count and repopulate its in-memory state.

**FR-CAN16 — Reapplication on reconnect.** When a provider **with a persisted
pinned sanction** reconnects, the coordinator MUST reapply the sanction: restore
the fail count, set `degraded`, and install a fresh canary recovery hold — so a
provider that failed the identity proof cannot obtain a clean slate merely by
reconnecting or by riding through a coordinator restart. The reapplied provider
is non-routable until it passes a canary. Cold-start grace (§9) still applies to
*latency* gates on the fresh session but never waives the identity gate that the
provider must pass to recover.

**FR-CAN17 — Provisional bans are not persisted.** A provisional canary ban is
runtime-only. After a coordinator restart a previously-banned provisional
provider may reconnect and re-enter the normal admission → warm-up → canary
cycle. This asymmetry with pinned sanctions is **intentional**: pinned providers
are operator-vouched identities whose failure is durable evidence, while
provisional providers are re-proven from scratch on every connection anyway. §13
defines the operator un-ban path for the in-session case.

## 9. Buyer availability contract during degrade

**FR-CAN18 — Routing eligibility is binary.** A provider is routing-eligible iff
`state == ready` and it has free slots (SPEC-002 FR-P5). A canary-degraded or
canary-banned provider is **not** routing-eligible. There is no partial or soft
canary degrade.

**FR-CAN19 — Sole-provider degrade → retryable 503.** When a canary sanction
leaves a model with no routing-eligible provider, buyer requests for that model
MUST return **HTTP 503 `no_provider_available`**. Per SPEC-018/019 this code MUST
carry **`retryable: true`** (fixed in PR #548; before it, the code defaulted to
`retryable: false`, telling buyers not to retry a transient degrade window —
incident #2). A canary degrade is a transient condition from the buyer's
perspective, so the retryable classification is mandatory, not advisory.

**FR-CAN20 — `Retry-After` guidance.** The 503 response for a canary-degrade
window SHOULD carry a `Retry-After` hint bounded by the effective probe cadence
(so a client's retry lands at or after the next recovery-probe opportunity). The
gateway retryable/`Retry-After` tables (SPEC-018) are the single source of the
concrete value; this spec requires only that `no_provider_available` remain
retryable and that any `Retry-After` be consistent with the probe cadence, never
shorter than the minimum sweep interval.

**FR-CAN21 — 404 vs 503 boundary.** A canary sanction MUST NOT convert a
served/known model into a 404. `404 model_not_found` is reserved for models that
no provider serves or has recently seen (SPEC-006 §17.2, SPEC-010 R-3.3.4). A
model whose only provider is canary-degraded is **known but temporarily
unavailable** → 503, not 404.

## 10. Last-provider protection (new invariant)

**FR-CAN22 — Sanction classes split on trustworthiness.** Whether a sanction may
empty a model's eligible pool depends on the failure class:

- **Correctness/identity failures** (`nonce_mismatch`, `incomplete`) MAY remove
  the sole provider for a model. Serving output from a provider that provably
  runs the wrong or a downgraded model — or that truncates — is worse than
  returning a retryable 503; the buyer contract in §9 covers the resulting
  outage. This preserves the anti-downgrade guarantee that is the canary's whole
  point.
- **Latency failures** (`ttft_breach`, `tps_breach`) **MUST NOT** be allowed to
  remove the sole routing-eligible provider for a model. The metric is
  unreliable (§8) and a false latency sanction on a single-provider pool is a
  total, self-inflicted outage (incidents #1 and #2). In `observe` mode this is
  automatically satisfied (latency never sanctions); in any future `enforce`
  mode it is a hard precondition (FR-CAN8).
- **Infra/liveness failures** (`relay_error`) MAY remove the sole provider — a
  provider the coordinator genuinely cannot reach is already not serving buyers;
  removing it and returning a clean retryable 503 is correct.

**FR-CAN23 — Provisional last-provider softening.** A provisional provider that
is the sole provider for its model MUST NOT be hard-banned/session-closed on a
**latency** failure. Correctness/identity/infra bans still apply per FR-CAN22.
(This bounds the blast radius of the unreliable latency metric on the common
single-provider production topology.)

> **Conformance note.** Last-provider protection as an explicit guard is **not
> yet implemented** — today a sole provider can be latency-sanctioned in
> `enforce` mode (this is precisely what incidents #1/#2 exercised). The current
> code satisfies FR-CAN22/23 *only because* production runs `observe` (latency
> never sanctions). Making the guard explicit — so the invariant holds even if an
> operator sets `enforce` — is the follow-up IMPL this spec authorizes. See §14.

## 11. Config surface and reload contract

**FR-CAN24 — Config surface.** The canary subsystem is configured under `pool.*`:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `canary_enabled` | bool | `false` | Master switch. |
| `canary_interval_s` | int | `300` | Base per-provider probe interval (jittered 0.5×–1.5×); drives sweep cadence `interval/10`. |
| `canary_timeout_s` | int | `30` | Per-probe deadline. |
| `canary_max_tokens` | int | `32` | Probe completion budget; MUST satisfy FR-CAN3. |
| `canary_failure_threshold` | int | `3` | Consecutive failures to sanction. |
| `canary_cold_start_grace_s` | int | `0` | Latency-gate waiver window after connect (0 = off). |
| `canary_latency_enforcement` | enum | `observe` | `observe` \| `enforce`; see §6. Validation MUST reject other values. |
| `canary_challenges` | list | — | Global challenge bank; each `{prompt, expected}` MUST contain `{nonce}`; optional `max_ttft_ms`, `min_sustained_tps`. MUST be non-empty when enabled. |
| `model_class_challenges` | map | — | Per-model banks matched by model id (exact, then case-insensitive); feed the OPoI pass flag and telemetry-drift (semantics: item 9's spec). |

**FR-CAN25 — Enable requires a validated bank.** When `canary_enabled` is true,
configuration validation MUST fail closed unless at least one challenge bank is
non-empty and every challenge satisfies the `{nonce}` and (SHOULD) `max_tokens`
constraints. An implementation MUST NOT enable canary sanctioning against an
empty or unvalidated bank (the 2026-07-10 deadlock, decision-log Entry 125, was
an unvalidated production bank false-sanctioning the sole provider).

**FR-CAN26 — Reload without restart (required; currently a gap).** Canary is a
money-path/security gate, yet its config lives in the `pool` block which is
**startup-only** (not SIGHUP-reloadable; only tier-2/billing reload today).
Changing `canary_max_tokens` on the single-provider prod pool required a full
coordinator restart, which cascaded into the ~5 h outage of 2026-07-10 (incident
#3). This spec **requires** that the canary tuning parameters
(`canary_enabled`, `canary_interval_s`, `canary_timeout_s`, `canary_max_tokens`,
`canary_failure_threshold`, `canary_cold_start_grace_s`,
`canary_latency_enforcement`, and the challenge banks) be operator-mutable
**without a coordinator restart** — either by extending SIGHUP reload to this
subset or via an authenticated out-of-band operator tuning path. Until then,
operators MUST treat any canary config change on a single-provider pool as a
planned-maintenance event, and SHOULD prefer disabling canary
(`canary_enabled: false`, if that itself is reloadable) over a restart. This is
tracked as a conformance gap in §14.

## 12. Observability contract

**FR-CAN27 — Failure logging.** Every failed probe MUST emit a structured log
line carrying at minimum: `provider_id`, `assigned_id`, `canary_fail_reason`
(from the §5 taxonomy, verbatim), the probe outcome (`pass`/`fail`/`skip`), and —
when latency is evaluated — the measured `canary_ttft_ms` and
`canary_sustained_tps`. A `skip` SHOULD log its reason but MUST be
counter-neutral.

**FR-CAN28 — `/poolz` fields.** The operator `/poolz` surface MUST expose, per
provider: `routing_eligible` (bool), `canary_fail_count` (int),
`canary_last_checked_at` and `canary_last_failed_at` (RFC3339 UTC or null), and
the `Tripped` reason when degraded/unavailable. These are the minimum fields an
operator needs to distinguish a canary sanction from a breaker/warm-up sanction
and to decide whether to clear it.

**FR-CAN29 — Model-class pass flag.** When a probe uses a `model_class_challenges`
bank, the coordinator MUST emit the per-model OPoI pass/fail flag and record the
model-class canary result for telemetry-drift. The *meaning* of that flag is
item 9's spec; SPEC-031 requires only that the mechanism fire and be observable.

## 13. Tier asymmetry and operator recovery

**FR-CAN30 — Documented asymmetry.** The provisional-ban (evict, not persisted)
vs pinned-degrade (persist, reapply) split of FR-CAN11/15/16/17 is the intended
policy: provisional providers are re-proven every connection; pinned providers
carry durable operator trust whose violation is durable evidence.

**FR-CAN31 — Operator clear (pinned).** The coordinator MUST expose an
authenticated, idempotent operator action to clear a pinned canary sanction. It
MUST delete the persisted sanction and zero the runtime counter; if a live
recovery hold exists it MUST be converted to an operator-clear hold (not silently
dropped) so the session stays non-routable until a fresh reconnect + warm-up
re-proves it. In-flight probes MUST be fenced (epoch-guarded) so a probe result
computed against pre-clear state cannot resurrect a just-cleared sanction.

**FR-CAN32 — Operator un-ban (provisional).** The coordinator MUST expose an
authenticated, idempotent operator action to clear a provisional canary ban and
its admission rejection (the existing `DELETE /admin/reject/{provider_id}`,
decision-log Entry 125), symmetric to FR-CAN31, so a false provisional ban on the
sole provider is operator-recoverable without waiting for the provider to churn
its own session.

## 14. Conformance status (honesty table)

Per repo status-header discipline, this table states what the **current code**
does versus what this spec **requires**. "Implemented" = shipped and conformant;
"Tightens" = shipped but this spec narrows/mandates a currently-optional posture;
"Gap" = required here but not yet implemented (authorized follow-up IMPL).

| FR | Status | Note |
|----|--------|------|
| FR-CAN1 scheduling/jitter/shuffle | Implemented | `runCanaryLoop`, `shuffledProviders`, `jitteredCanaryInterval`. |
| FR-CAN2 determinism (temp 0, nonce) | Implemented | PR #533 pinned temperature; `{nonce}` validated. |
| FR-CAN3 `max_tokens` sizing | **Tightens** | Prod default raised 16→32 (#531); the ≥-expected-length rule + validation warning is newly normative. |
| FR-CAN4/5 transport, admitted model | Implemented | WS vs HTTP split; `MaxAdmittedModelKey`. |
| FR-CAN6 validation order + skip-neutral | Implemented | `evaluateCanaryProbe`; skip is counter-neutral. |
| FR-CAN7/9 observe default, grace | Implemented | Default `observe` (#513); cold-start grace (#512). |
| FR-CAN8 enforce preconditions (stream/percentile/≥2) | **Gap** | `enforce` is reachable today with a single-shot non-streaming metric and no ≥2-provider guard; this spec forbids that. |
| FR-CAN10 sub-threshold no-op | Implemented | `RecordCanaryResult` returns below threshold. |
| FR-CAN11–17 sanction/recovery/persistence | Implemented | `RecordCanaryResult`, `canary_store`, `applyCanarySanctionLocked`. |
| FR-CAN18/19 binary eligibility, retryable 503 | Implemented | `RoutingEligible`; `no_provider_available` → `retryable:true` (#548). |
| FR-CAN20 `Retry-After` bounded by cadence | **Gap** | `no_provider_available` retryable is set; a cadence-bounded `Retry-After` is not yet wired. |
| FR-CAN21 404/503 boundary | Implemented | Aligns with SPEC-006 §17.2 / SPEC-010 R-3.3.4 (#555). |
| FR-CAN22/23 last-provider protection | **Gap** | No explicit guard; satisfied today only because prod runs `observe`. Authorized follow-up. |
| FR-CAN24/25 config surface + validated bank | Implemented | `PoolConfig` + validation (#478); Entry 125 hardened empty-bank. |
| FR-CAN26 reload without restart | **Gap** | Pool block is startup-only; this is the direct cause of incident #3. Authorized follow-up. |
| FR-CAN27/28/29 observability | Implemented | `canary_fail_reason` (#513); `/poolz` fields; model-class flag (#491). |
| FR-CAN30/31/32 operator recovery | Implemented | Operator clear + `DELETE /admin/reject/{id}` (Entry 125). |

The four **Gap** rows (FR-CAN8, FR-CAN20, FR-CAN22/23, FR-CAN26) are the
implementation backlog this baseline authorizes. None is a regression; each is a
hardening the incidents motivate. Re-enabling canary in production SHOULD be
gated on at least FR-CAN22/23 (last-provider protection) and FR-CAN26 (no-restart
tuning), the two whose absence caused the outages.

## 15. Acceptance criteria

- **AC-1.** With `canary_enabled` and a valid bank, a provider serving the
  admitted model and echoing the nonce exactly passes; `canary_fail_count`
  stays 0 and `routing_eligible` stays true.
- **AC-2.** A provider that returns a transformed nonce fails `nonce_mismatch`;
  after `canary_failure_threshold` consecutive such failures it is
  degraded (pinned) or banned (provisional). A single failure does **not**
  change routing state (FR-CAN10).
- **AC-3.** A probe truncated before the nonce (undersized `max_tokens`) is
  classified `incomplete`, not `nonce_mismatch`.
- **AC-4.** In `observe` mode, a nonce-correct probe with an arbitrarily high
  measured TTFT passes; `canary_fail_count` does not increment.
- **AC-5.** A canary-degraded pinned provider that later passes one probe is
  automatically restored to `ready`; the persisted sanction row is deleted.
- **AC-6.** A pinned provider with a persisted sanction, after a coordinator
  restart + reconnect, comes back `degraded` and non-routable until it passes a
  probe (FR-CAN16).
- **AC-7.** While a canary recovery hold is live, a provider heartbeat reporting
  `ready` (or `draining`→`ready`) does **not** clear the hold (FR-CAN14).
- **AC-8.** When the only provider for a model is canary-sanctioned, a buyer
  request returns 503 `no_provider_available` with `retryable: true` (FR-CAN19);
  the model does not 404 (FR-CAN21).
- **AC-9.** A latency (`ttft_breach`/`tps_breach`) failure does not remove the
  sole routing-eligible provider for a model (FR-CAN22); a correctness
  (`nonce_mismatch`/`incomplete`) failure may.
- **AC-10.** Every failed probe emits a log line with a non-empty
  `canary_fail_reason` drawn from the §5 taxonomy (FR-CAN27).
- **AC-11.** Enabling `canary_enabled` with an empty or `{nonce}`-less challenge
  bank fails configuration validation (FR-CAN25).
- **AC-12.** *(Gap-tracking, forward AC.)* Latency `enforce` is refused unless
  the probe is streaming, the decision is percentile-over-N, and the model has
  ≥2 routing-eligible providers (FR-CAN8). Canary tuning parameters can be
  changed without a coordinator restart (FR-CAN26). These ACs are expected to
  fail against the current build; they define the follow-up IMPL's done bar.

## 16. Production posture (as of 2026-07-11)

Canary is **disabled in production** (`canary_enabled: false` in the Pearl
overlay). After the three incidents the operator chose to disable it rather than
run it flapping; warm-up (SPEC-002 FR-P8a) plus buyer-path inference plus the
external buyer canary (decision-log Entries 124–126) are the live liveness gates.
Model-integrity (`model_class_challenges`) validation is being revalidated in
staging before re-enable (Entry 125). This spec's purpose is to define the
contract under which internal canary can be **safely re-enabled**; the §14 Gap
rows FR-CAN22/23 and FR-CAN26 are the recommended pre-re-enable bar.

## 17. Cross-references

- **SPEC-002** — provider state machine (`ready/busy/degraded/draining/
  unavailable`), FR-P5 routing eligibility, FR-P8a admission warm-up gate,
  FR-P11a circuit-breaker and hold-integrity rules. Canary degrade reuses the
  same `degraded` state and the same anti-self-launder hold discipline; canary
  degrade differs from FR-P11a in being probe-bounded rather than
  `degraded_backoff_s`-bounded (FR-CAN12).
- **SPEC-006 §17.2 / SPEC-010 R-3.3.4** — 404 (unknown model) vs 503
  (known-but-unavailable) boundary that FR-CAN21 preserves.
- **SPEC-018 / SPEC-019** — buyer error envelope, the `retryable` classification
  and `Retry-After` tables that FR-CAN19/20 depend on.
- **SPEC-020** — provider trust tiers (provisional vs pinned) that drive the
  FR-CAN11 sanction asymmetry.
- **SPEC-030** — losslessness probe, a separate probe profile carried over the
  same canary transport.
- **Proof-of-weights / OPoI + autotune hello-gate** — runbook item 9's separate
  baseline; owns the *semantics* of `model_class_challenges` and the second-
  provider admission gate that interacts with canary fragility (incident #2).

## 18. Changelog

- **v0.1-draft (2026-07-11):** Initial reconstructed baseline (runbook item 8,
  Wave C). Sources: `internal/ws/canary_probe.go`, `internal/ws/canary_store.go`,
  `internal/ws/server.go`, `internal/pool/provider.go`, `internal/config/config.go`,
  `internal/buyer/server.go`, and the live Pearl posture probe of 2026-07-11.
  Incident provenance: 2026-07-09 latency-gate flapping, 2026-07-10
  transient-degrade 503s, 2026-07-10 restart outage. Codifies PRs #478, #491,
  #512, #513, #524, #528, #531, #533, #538 and decision-log Entries 124–126.
