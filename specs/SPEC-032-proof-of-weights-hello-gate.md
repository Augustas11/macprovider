# SPEC-032 — Autotune Hardware-Evidence Admission Gate, OPoI & Proof-of-Weights Boundary

**Status:** v0.1-draft
**Date:** 2026-07-11
**Depends on:** SPEC-002 (coordinator admission, provider state machine; F-2 defines provisional/pinned tiers), SPEC-003 (open onboarding, tiers), **SPEC-008 (Tier-2 — authoritative on the model-hash routing-exclusion predicate and attestation; this spec MUST NOT override it)**, SPEC-031 (canary probe mechanism — OPoI reuses it), and the item-10 hardware-verifier verdict spec (owns `hardware-verifier.v2`, consumed here as an input). SPEC-020 (provider *autoupdate* trust table) is only tangentially related and is **not** the tier-definition source.
**Related (distinct, cross-referenced only):** SPEC-030 (losslessness probe — a separate distributional probe family)

**Numbering note.** Assigned canonical **SPEC-032** on 2026-07-11 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 9). Highest prior canonical spec
was SPEC-031. This document is the reconstructed normative baseline for two
coordinator trust signals that ship unspecced: the **autotune hardware-evidence
admission gate** (the "hello-gate", **live in production**) and the **OPoI /
proof-of-weights / telemetry-drift** signals (specced here but **disabled in
production**). SPEC-031 explicitly deferred the *semantics* of `model_class_challenges`
and the OPoI pass flag to this baseline (SPEC-031 §2, §17); this spec owns them.

---

## 1. Purpose and the central honesty problem

The coordinator carries two trust signals beyond the SPEC-031 liveness canary:

1. **The autotune hello-gate** (`internal/autotune/gate.go`, `checkAutotuneHelloGate`
   in `internal/ws/server.go`) — an **admission** gate that, when enabled, refuses a
   provider at connect unless it presents fresh, verified **hardware evidence**
   proving it can serve the model tier it claims. This gate is **enabled in
   production** (`require_autotune_hello_gate: true` in the Pearl overlay) and is a
   money-path / availability-path control: it is the gate that closed the intended
   second provider in the 2026-07-10 transient-degrade incident (#2), leaving a
   single-provider pool.

2. **OPoI / proof-of-weights / telemetry-drift** (`internal/pow/drift.go`) — a set
   of signals intended to detect a provider that has silently downgraded or swapped
   its model. These are **disabled in production** and, critically, **as implemented
   are not proof of weights at all**.

**The central honesty problem.** "OPoI" (Overt Proof of Inference) and
"proof_of_weights" are aspirational names for a mechanism that does not yet prove
what they imply. The OPoI check is the **identical plaintext-nonce echo** that
SPEC-031 already established is *not* a model-identity or anti-downgrade proof — a
cheaper or substituted model can echo a plaintext nonce without running the admitted
weights. The `model_class_challenges` bank differs from the liveness canary bank
**only** in which YAML supplies the challenge string; the on-wire probe and the
pass criterion are byte-identical. The resulting `ModelClassOPoIPass` flag is
**write-only** (one writer, zero readers) and a low OPoI pass-rate or a
telemetry-drift breach does **nothing but emit a `WARN` log**. This spec therefore
**refuses to let "proof-of-weights" imply a guarantee the code does not deliver**:
it labels OPoI **non-binding / liveness-derived**, defines what a *real*
proof-of-weights test would require, and pins the current signals' guarantee ceiling
at **observability-only**. The substantive, live normative content of this spec is
the **hello-gate admission policy** (Part A).

## 2. Scope

**In scope**

- **Part A — Autotune hello-gate:** the admission mechanism, the hardware-evidence
  requirement and freshness (TTL), the capacity-ceiling comparison, the complete
  close-reason taxonomy, the **transient-vs-permanent classification** of those
  reasons, and the **pool-redundancy admission policy** (the incident-#2 fix).
- **Part B — OPoI / proof-of-weights honesty:** what a model-class canary pass
  proves and does not prove; the observability-only status of the
  `ModelClassOPoIPass` flag; and the normative definition of what a future
  weight-binding proof-of-weights test must provide.
- **Part C — Telemetry-drift:** the TPS-below-baseline and model-hash drift signals
  and their **alert-only guarantee ceiling**.
- The config surface and reload contract for all of the above.

**Out of scope**

- The **hardware-verifier verdict** itself — the evidence schema, trust/chip-profile
  matching, and the `hardware-verifier.v2` `Decision` reasons live in
  `internal/stats/hardwareverify/verify.go` and are **runbook item 10's** spec. This
  spec consumes the `VerifiedDecisionReason` contract and the migration-017 grants as
  **inputs** to the hello-gate; it does not re-specify the verifier. (Version-string
  note: the runbook item-10 anchor says `hardware-verifier.v1`; the shipped constant
  is `hardware-verifier.v2` — item 10 pins the authoritative string; this spec
  references v2 as shipped.)
- The **canary probe mechanism, degrade/sanction state machine, and last-provider
  protection** — SPEC-031. OPoI reuses the canary probe; this spec does not redefine
  it.
- **SPEC-030 losslessness** — a distinct distributional probe family
  (`internal/ws/losslessness.go`), imports neither `internal/pow` nor
  `internal/autotune`. Cross-referenced only.
- A **real cryptographic or statistical proof-of-weights** — defined here as a
  requirement (§Part B), not implemented; deferred to a future version.

## 3. Terminology

| Term | Meaning |
|------|---------|
| **Hello-gate** | The admission-time hardware-evidence gate (`checkAutotuneHelloGate`), runs at provider hello **before** the provider is recorded in the pool. |
| **Hardware evidence** | A verified `hardware_evidence.autotune.v1` envelope: signed autotune benchmark results bound to a chip/RAM tuple, produced by the item-10 verifier with `decision_reason = hardware-verifier.v2:verified_trusted_hardware`. |
| **Capacity ceiling** | `ResolveMaxAdmission` — the highest-RAM catalog row whose benchmark passes the gate; a provider may be admitted only for a model whose `MinRAMGB` ≤ this ceiling. |
| **OPoI** | "Overt Proof of Inference" — a model-class canary observation. Per this spec, **liveness-derived and non-binding**; not a weight proof. |
| **Telemetry-drift** | Heartbeat-time heuristics (TPS below signed baseline; model-hash status/artifact drift) — alert-only. |
| **Transient close** | A hello-gate rejection the provider can cure by submitting evidence (no verified evidence in-window). Recoverable. |
| **Permanent close** | A hello-gate rejection reflecting a genuine capability shortfall (evidence proves the provider cannot serve the claimed tier). |

## Part A — Autotune hardware-evidence admission gate

**FR-HG1 — Gate activation.** The hello-gate is a no-op unless
`proof_of_weights.require_autotune_hello_gate` is true (default false; **true in the
Pearl production overlay**). When active, it MUST run at provider hello for **both**
the composed-auth (v2) and legacy admission paths, for **both** provisional and
pinned tiers, **before** the provider is recorded in the pool
(`recordProviderAdmission` / `checkOrRecordAdmission`). Because the gate runs
pre-admission, a rejected provider never enters the pool, and SPEC-031's
last-provider protection (which guards already-admitted providers from sanctioning)
**cannot** apply to a gate rejection — see FR-HG5.

**FR-HG2 — Evidence requirement and lookup.** When active, the gate MUST require a
**verified, in-window** hardware-evidence record for the connecting provider. The
lookup is keyed by **provider ID + TTL** (`LatestVerified(providerID, ttl)`); it
selects the provider's stored hardware profile joined to a historical
`hardware_verification_jobs` row with `status = verified` and `decision_reason =
hardware-verifier.v2:verified_trusted_hardware`, matching the stored profile's
chip-normalized + unified-memory-GB tuple, and `generated_at ≥ now −
autotune_evidence_ttl_days` (default 30 days). The lookup MUST use the
least-privilege column grants of migration-017. If the catalog or evidence store is
not wired, **or the evidence lookup/decode/binding fails for any reason** (DB error,
malformed envelope, immutable-binding mismatch), the gate MUST fail closed with
`autotune_gate_unavailable` (close 4001).

> **Binding limitation (not a current-session hardware proof).** The hello frame
> carries **no** chip descriptor or hardware-identity hash (`messages.go`), and
> `LatestVerified` receives only the provider ID and TTL. The gate therefore binds
> verified evidence to the provider **credential/ID**, not to the *live hardware of
> the current WS session*: a credential holder that moves to weaker hardware can
> reuse prior evidence until the TTL lapses. Binding the gate to a
> per-session-attested hardware identity is a limitation this spec records (§14) and
> is properly the item-10 verifier's domain to strengthen.

**FR-HG3 — Capacity-ceiling comparison.** Given verified evidence, the gate MUST
resolve the **capacity ceiling** as the highest-RAM catalog row whose benchmark
passes every gate predicate (no thermal throttle, catalog-SHA match, model-id match,
**artifact-SHA256 match** to the catalog row, sustained-TPS ≥ the row's gate, TTFT ≤
the row's gate). It MUST then evaluate the provider's claimed model against that
ceiling and admit only if the claimed model is catalogued and its `MinRAMGB` does not
exceed the ceiling.

**FR-HG4 — Close-reason taxonomy (normative), classified transient vs permanent.**
Every gate rejection MUST use exactly one of the following close reasons (all on WS
close code `4001`), and each carries a **normative transient/permanent
classification** that FR-HG5 depends on:

| Close reason | Class | Meaning | Probation-eligible? (FR-HG5) |
|--------------|-------|---------|------------------------------|
| `autotune_gate_unavailable` | **coordinator-fault** | catalog/evidence store not wired, **or any evidence lookup/decode/binding error** (DB/query failure, malformed envelope, immutable-binding mismatch) | No — operator must fix |
| `autotune_evidence_required` | **evidence-absent** | no verified evidence in-window (never submitted, or **expired**) | **Only the expiry sub-case** (see FR-HG5) |
| `autotune_evidence_invalid` | **affirmative shortfall** | evidence present but **no benchmark passes** the gate — thermal throttle, catalog/model/artifact-SHA mismatch, TPS below gate, or TTFT above gate | **No — always rejects** |
| `autotune_model_uncatalogued` | **policy-unverifiable** | claimed model not in the catalog — the coordinator cannot *evaluate* the claim (not proof of shortfall) | No — always rejects |
| `autotune_model_cap_exceeded` | **affirmative shortfall** | claimed model's `MinRAMGB` > verified capacity ceiling | **No — always rejects** |

The load-bearing distinction this spec adds is between **evidence-absent** (we have
*no information* about the provider's capability — recoverable, and only-then
possibly probation-eligible) versus **affirmative shortfall** (the evidence
*affirmatively shows* the provider cannot serve the claimed tier — `evidence_invalid`
and `cap_exceeded`) versus **policy-unverifiable** (`uncatalogued` / `gate_unavailable`
— the coordinator cannot evaluate the claim). **Only evidence-absent is ever
probation-eligible, and even then only in the narrow case defined by FR-HG5.**
`evidence_invalid` is emphatically **not** transient: it includes evidence proving a
too-slow, thermally-throttled, or wrong-artifact provider, and admitting such a
provider to serve buyers is the exact trust hole this classification prevents.
Conflating "no evidence" with "evidence proves failure" was the draft's original
error; the incident-#2 fragility is a hard close on genuine *evidence-absence*, not
on a proven shortfall.

**FR-HG5 — Pool-redundancy-aware admission (the incident-#2 fix).** The hello-gate
as shipped is **pool-size-blind**: it evaluates one provider's evidence in isolation
and hard-closes on any rejection, so a **transient** `autotune_evidence_required`
close on the intended second provider for a model can leave `pool_size = 1` with no
redundancy — exactly the 2026-07-10 incident (#2), and the live production posture
(`pool_size: 1`) as of this writing.

This spec requires a **narrow, bounded** redundancy exemption that never trusts a
self-declared capability and never admits an affirmatively-failed provider:

- **Affirmative shortfall and policy-unverifiable closes always reject, regardless
  of redundancy.** `autotune_evidence_invalid`, `autotune_model_cap_exceeded`,
  `autotune_model_uncatalogued`, and `autotune_gate_unavailable` MUST hard-close even
  when doing so leaves a singleton pool — admitting a provider whose evidence
  *proves* it cannot serve the tier (too slow, wrong artifact, thermally throttled),
  or whose claim the coordinator cannot evaluate, would route buyers to a provider
  that fails their requests, which is strictly worse than a retryable 503.
- **Probation is limited to the evidence-EXPIRY sub-case, at the last-verified
  ceiling.** The *only* probation-eligible close is `autotune_evidence_required`
  arising from the **expiry of the provider's own previously-verified evidence** —
  because that provider has an *independent, coordinator-verified* (if now stale)
  capacity bound: its **last-verified capacity ceiling**. When such an expiry close
  would leave a model with **fewer than two already-admitted routing-eligible
  providers** for a tier the last-verified ceiling covers, the coordinator MUST admit
  the provider in a **probationary** state: routable **only up to its last-verified
  ceiling** (NEVER a self-declared capacity), flagged `evidence_pending`, **not**
  tier-promoted, still canary/degrade-governed (SPEC-031), and bounded by a
  **single, reconnect-stable grace window** — the deadline is tracked by provider
  identity so a reconnect does NOT reset it, and there is **no** re-extension: at the
  deadline the provider is closed `autotune_evidence_required` until it submits fresh
  verified evidence.
- **A never-verified provider gets NO probationary buyer-routing.** With no prior
  verified evidence there is no independent capacity bound to trust, so a
  never-verified provider MUST NOT be routed on a self-declared claim. It MAY be held
  in a **non-routable candidate/observe** state to submit evidence, or closed
  `autotune_evidence_required` — but it MUST NOT serve buyers. (This is why the
  incident-#2 `air5` case is not fully solved by admission policy alone: a
  never-benchmarked box cannot safely provide instant redundancy — the remedy there
  is faster evidence onboarding and acquiring a second *verified* provider for the
  tier, not trusting an unmeasured claim.)
- **Redundancy predicate.** "Fewer than two" MUST be computed over the model's
  **already-admitted routing-eligible providers** (a structural count), evaluated
  independently of momentary slot availability (a busy provider still counts toward
  redundancy). The connecting candidate is not yet admitted, so the trigger is
  "the model's current admitted-eligible count is below two AND the candidate's
  last-verified ceiling covers the model," not a "reduce below two" delta.
- **Below-two operator alert.** On any close (of any class) that leaves a model's
  admitted routing-eligible count below two, the coordinator MUST emit a distinct
  operator redundancy alert, so the operator sees the redundancy risk even when the
  close is correct.

> **Conformance note (§14).** The redundancy predicate, the expiry-only probationary
> `evidence_pending` state (last-verified-ceiling-bounded, reconnect-stable,
> non-re-extending), the never-verified non-routable path, and the below-two alert
> are **not implemented** — the shipped gate is pool-size-blind and hard-closes all
> rejections. This is the primary Gap this spec authorizes. Note it does **not**
> weaken the current gate for any affirmative-shortfall case; it only spares a
> previously-verified provider a hard close during an evidence-expiry redundancy
> emergency, at its already-proven ceiling.

**FR-HG6 — Evidence freshness and bounded mid-session expiry.** Admission uses a
30-day TTL (`autotune_evidence_ttl_days`) while the item-10 verifier applies a 7-day
`maxEvidenceAge` at verification time; this asymmetry is intentional (verification is
stricter than admission-reuse). Because the gate runs only at hello, a
continuously-connected provider could otherwise serve **indefinitely on expired
evidence** — the spec closes that window. It requires: (a) the coordinator MUST
perform a **bounded session-time freshness recheck** (not merely at reconnect): when
an admitted provider's evidence crosses the TTL mid-session it MUST be re-gated within
a bounded interval — routed only under the FR-HG5 expiry-probation rules if
redundancy demands (at its last-verified ceiling), else moved non-routable — and MUST
NOT continue serving at its pre-expiry ceiling past that bounded interval; (b) a
provider whose evidence expires MUST NOT be silently hard-killed mid-request; and
(c) the coordinator SHOULD define a proactive re-verification cadence so evidence
refreshes before the TTL lapses rather than at an expiry boundary.

**FR-HG7 — Capacity ceiling enforced on every model transition (not just hello).**
The capacity ceiling (FR-HG3) MUST constrain routing eligibility on **every** model
the provider serves, evaluated whenever the provider's served model changes — not
only the model claimed in the hello frame. A provider MUST NOT be routing-eligible
for a model whose `MinRAMGB` exceeds its verified (or, in FR-HG5 probation,
last-verified) ceiling, regardless of whether that model was set at hello or by a
later heartbeat/state-update.

> **Conformance gap (§14) — this is a live capability-gate bypass.** As shipped, the
> gate runs **only at admission**; a heartbeat can then replace `Provider.ModelID`
> with a larger model without re-consulting the ceiling, and buyer routing uses that
> mutable model id. The computed `MaxAdmittedModelKey/ID` ceiling has **no routing
> consumer** — its only reader selects the warm-up/canary probe model. So a provider
> can pass hello on a small model, heartbeat-switch to a large one, and serve buyers
> for a tier it never proved. Wiring the ceiling into the routing-eligibility
> predicate (and re-evaluating it on model change) is a **CRITICAL-severity** Gap and
> a required part of making the hello-gate meaningful; it is listed on the §14
> re-enable/hardening bar.

## Part B — OPoI / proof-of-weights honesty

**FR-PW1 — OPoI is non-binding (liveness-derived); it is NOT a proof of weights.**
An OPoI observation is a model-class canary probe (SPEC-031): a plaintext nonce is
embedded in a per-model challenge and the provider MUST echo it exactly under greedy
decoding. This proves the endpoint is **live and follows a trivial instruction on
that model's challenge bank**. It does **not** prove the provider is running the
admitted weights, quantization, or model — a cheaper or substituted model, or a
canary-aware handler, can echo the visible nonce without running the admitted
weights. SPEC-032 therefore **prohibits** any document, config, metric, or code
comment from describing OPoI as a model-identity, anti-downgrade, or weight-integrity
proof. (This is the same reframing SPEC-031 applied to the liveness canary; OPoI is
mechanically the same probe.)

**FR-PW2 — The OPoI pass flag is observability-only.** `ModelClassOPoIPass` (and the
OPoI rolling pass-rate) MUST be treated as **observability-only** telemetry. The
coordinator MUST NOT gate routing, tier promotion, degrade/sanction, or payout on the
OPoI flag or pass-rate, because doing so would act on a signal that does not prove
what its name implies (and would risk the same false-sanction flapping SPEC-031
documents for unreliable canary signals). The shipped code already conforms: the flag
has **zero** routing/tiering/degrade/payout readers (the "MUST NOT gate" half), **and**
it already has a defined operator-observability consumer — it is JSON-exported
(`model_class_opoi_pass`) on the operator-authenticated `/poolz` surface (the
proof-of-weights implementation runbook defines it as a `/poolz` export). This spec
makes that observability-only status a **deliberate guarantee ceiling** rather than an
accident; the flag is not dead state.

**FR-PW3 — What a real proof-of-weights test must provide (deferred).** A mechanism
may be called "proof-of-weights" only if it **binds the provider's output to the
admitted weights** such that a substituted/downgraded model cannot pass except with
negligible probability. This requires one of: (a) a **statistical/distributional**
test the provider cannot satisfy without running the admitted weights (e.g. a
challenge whose correct answer distribution is model-specific and not derivable from
the prompt — related to SPEC-030's losslessness TV-distance approach, or a
next-token-distribution attestation), or (b) a **cryptographic attestation** over the
loaded weights (e.g. the Merkle+VRF+statistical VeriLLM-class design in the
`zk-verifiable-inference-design` memo). Until such a test ships, the coordinator
MUST NOT advertise or rely on any anti-downgrade guarantee from this subsystem. This
FR is a **forward requirement**, not an implemented one.

## Part C — Telemetry-drift

**FR-TD1 — The `pow.Evaluator`'s own drift response is alert-only; it does NOT
override SPEC-008's authoritative hash routing.** The telemetry-drift evaluator
(`internal/pow/drift.go`) computes, at heartbeat time (and only when fresh verified
evidence is present — `EvaluateHeartbeat` returns early otherwise, so **all** drift
alerts, TPS and hash alike, require verified evidence): a **TPS-below-baseline** signal
(measured sustained TPS below `tps_ratio_threshold` × the *signed autotune benchmark*
baseline, with an absolute floor and a minimum request window), a **benchmark-artifact
drift** signal, and the OPoI **pass-rate** signal (Part B). **The `pow.Evaluator`'s own
response to any of these is alert-only**: it emits a structured `WARN`
(`pow_telemetry_drift_detected`) subject to a per-signal cooldown, and initiates **no**
routing, sanction, degrade, tiering, or payout action *of its own*.

**This alert-only ceiling applies to the `pow.Evaluator`'s reaction, NOT to the
independent SPEC-008 hash predicate.** SPEC-008 §5.5–5.6 defines an **authoritative**
model-hash routing-exclusion: a provider whose signed-catalog `HashStatus` is
`hash_mismatch` or `hash_invalid` MUST be excluded from routing — even when
`require_hash_verified` is false — and the shipped buyer routing enforces exactly that
(`internal/tier2/catalog.go`, `internal/buyer/server.go`). SPEC-032 **MUST NOT** be
read to weaken that exclusion: the `pow.Evaluator` merely *observes and alerts on* the
same hash status; the routing exclusion is SPEC-008's, remains in force, and is
authoritative. In short: signed-catalog `hash_mismatch`/`hash_invalid` → **excluded
from routing (SPEC-008)**; TPS / OPoI / benchmark-artifact drift → **alert-only
(this spec)**.

The alert-only ceiling on the *pow-heuristic* signals is **deliberate and normative**:
TPS and artifact-drift comparisons are heuristics against *benchmark metadata*, not a
weight-binding proof, and escalating an unreliable heuristic to an automatic sanction
is the exact failure mode SPEC-031 documents for the canary latency gates
(false-sanction flapping → self-inflicted outage). A future version MAY escalate a
pow-heuristic signal to a routing/sanction effect **only** once it is backed by a
weight-binding test (FR-PW3) or corroborated by an independent buyer-path signal.

**FR-TD2 — Coupling to the canary.** OPoI pass-rate tracking has no independent
measurement path — it can only observe canary outcomes — so `opoi_pass_rate_window > 0`
MUST require `pool.canary_enabled`. Validation enforces this **only when
`telemetry_drift.enabled = true`** (the validator returns before the coupling check
when drift is disabled), which is correct: the window is inert unless drift is enabled.
With canary disabled (the production posture), OPoI is dormant; the hello-gate (Part A)
is the only live element of this spec.

## Config surface and reload contract

**FR-CFG1 — Config surface.** Under `proof_of_weights.*`:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `require_autotune_hello_gate` | bool | `false` (**true in prod**) | Master switch for Part A. |
| `autotune_evidence_ttl_days` | int | `30` | Admission-reuse freshness window; `>0` required when gate or drift enabled. |
| `telemetry_drift.enabled` | bool | `false` | Master switch for Part C. |
| `telemetry_drift.tps_ratio_threshold` | float | `0.70` | (0,1]; TPS-below-baseline trigger. |
| `telemetry_drift.tps_min_absolute` | float | `5.0` | absolute TPS floor. |
| `telemetry_drift.tps_min_requests_window` | int | `2` | min requests before TPS drift evaluated. |
| `telemetry_drift.hash_alert_on_status` | []string | `[hash_mismatch, hash_invalid]` | model-hash statuses that alert. |
| `telemetry_drift.hash_alert_on_artifact_drift` | bool | `true` | alert on artifact drift. |
| `telemetry_drift.opoi_pass_rate_window` | int | `10` | OPoI rolling window; `>0` requires `canary_enabled`. |
| `telemetry_drift.opoi_pass_rate_threshold` | float | `0.80` | OPoI pass-rate alert threshold. |
| `telemetry_drift.alert_cooldown_s` | int | `900` | per-signal alert cooldown. |

**FR-CFG2 — Reload without restart (required; currently a gap).** All of Part A/B/C
config is **startup-only**. SIGHUP *does* reload a substantial surface — the Tier-2
block, rewards/billing flags, settlement config, USD-conversion config, and routing
model classes — but **not** `proof_of_weights.*`: the hello-gate wiring is fixed at
construction and the whole proof-of-weights block is read from the boot config, so it
is outside the SIGHUP allowlist. Since the hello-gate is a **live money-path/
availability gate on a single-provider-fragile pool**, changing it (e.g. to relax
evidence requirements during a redundancy emergency, or to enable/disable the gate)
currently forces a coordinator restart — the same restart-outage class that SPEC-031
FR-CAN26 addresses and that caused the 2026-07-10 ~5h outage. This spec **requires**
that `require_autotune_hello_gate`, `autotune_evidence_ttl_days`, and the
`telemetry_drift.*` keys be operator-mutable **without a coordinator restart** (SIGHUP
allowlist extension or an authenticated operator tuning path). Conformance gap (§14).

## Conformance status (§14)

| FR | Status | Note |
|----|--------|------|
| FR-HG1 gate activation/ordering | Implemented | `checkAutotuneHelloGate`; both paths; pre-admission. |
| FR-HG2 evidence lookup | **Partial** | `LatestVerified(providerID, ttl)` + TTL + grants ship. But the gate binds evidence to the provider **credential/ID**, not the live session hardware (hello carries no chip/identity hash) — the current-session-hardware binding is a limitation (item-10's to strengthen). |
| FR-HG3 capacity ceiling (resolution) | Implemented | `ResolveMaxAdmission` / `benchmarkPassesGate` resolve the ceiling correctly at hello. (Enforcement on the *served* model is FR-HG7.) |
| FR-HG4 close-reason taxonomy + classification | **Tightens** | The five reasons ship; the evidence-absent / affirmative-shortfall / policy-unverifiable classification (esp. `evidence_invalid` and `uncatalogued` as NOT probation-eligible) is new. |
| FR-HG5 narrow redundancy exemption | **Gap** | Gate is pool-size-blind; hard-closes all rejections. The expiry-only, last-verified-ceiling, reconnect-stable probation + never-verified non-routable path + below-two alert are new. |
| FR-HG6 bounded mid-session expiry recheck | **Gap** | TTL/`maxEvidenceAge` ship but the gate runs only at hello — no bounded session-time freshness recheck; a continuously-connected provider can serve indefinitely on expired evidence. |
| **FR-HG7 ceiling enforced on model transition** | **Gap (CRITICAL-class)** | The ceiling has **no routing consumer**; a heartbeat model-swap to a larger tier bypasses the gate entirely. Required to make the hello-gate meaningful. |
| FR-PW1 OPoI non-binding labeling | **Tightens** | Code comment already says liveness-only; this makes it a normative prohibition on weight-claims (one residual comment still says "identity" — comment-fixed in this change). |
| FR-PW2 OPoI flag observability-only | Implemented | Zero routing/tiering/degrade/payout readers **and** already exposed as `model_class_opoi_pass` on the operator-auth `/poolz` surface. Not dead state. |
| FR-PW3 real proof-of-weights definition | **Gap (forward)** | No weight-binding test exists; deferred. |
| FR-TD1 pow-heuristic alert-only + preserve SPEC-008 hash routing | Implemented | pow.Evaluator is WARN-only (and requires verified evidence to evaluate); SPEC-008's `hash_mismatch`/`hash_invalid` routing exclusion is independent and enforced by buyer routing. |
| FR-TD2 OPoI↔canary coupling | Implemented | `opoi_pass_rate_window>0` requires `canary_enabled`, validated when `telemetry_drift.enabled`. |
| FR-CFG1 config surface | Implemented | `ProofOfWeightsConfig` + validation. |
| FR-CFG2 reload without restart | **Gap** | `proof_of_weights.*` startup-only; SIGHUP reloads Tier-2/billing/settlement/USD/routing-classes but not this block. |

**Re-enable / hardening bar.** Two Gaps are **CRITICAL-severity** and are the priority:
**FR-HG7** (the ceiling is not wired into routing — a heartbeat model-swap bypasses the
whole gate, so the live gate does not actually protect buyers from a capability-
mismatched *served* model) and **FR-HG5** (the narrow expiry-only redundancy exemption
— the direct fix for the live single-provider fragility, which must NOT be built as the
draft's original over-broad version that would route affirmatively-failed providers).
Then **FR-HG6** (bounded expiry recheck) and **FR-CFG2** (no-restart tuning). OPoI /
telemetry-drift remain observability-only until a weight-binding test (FR-PW3) exists;
they MUST NOT be wired to routing/sanction before then, and SPEC-008's authoritative
hash routing exclusion MUST NOT be weakened (FR-TD1).

## Acceptance criteria

Testable against the current build:

- **AC-1.** With `require_autotune_hello_gate: true` and no verified in-window
  evidence, a connecting provider is closed `4001 autotune_evidence_required`.
- **AC-2.** With verified evidence whose capacity ceiling is below the claimed model's
  `MinRAMGB`, the provider is closed `autotune_model_cap_exceeded`.
- **AC-3.** A claimed model absent from the catalog closes `autotune_model_uncatalogued`.
- **AC-4.** With the catalog/evidence store unwired **or any evidence lookup/decode
  error**, the gate closes `autotune_gate_unavailable` (fails closed).
- **AC-5.** A low OPoI pass-rate (with verified evidence present) emits a
  `pow_telemetry_drift_detected` WARN and causes **no** routing/sanction/degrade change.
- **AC-6.** A TPS-below-baseline or artifact-drift signal emits a WARN only, and **only
  when fresh verified evidence is present** (no evidence → no drift evaluation/alert).
- **AC-7.** With `telemetry_drift.enabled: true`, `opoi_pass_rate_window > 0` and
  `canary_enabled: false` fails config validation. (With drift disabled, the coupling
  is not checked.)
- **AC-8.** No code path reads `ModelClassOPoIPass` to gate routing/tiering/degrade
  (grep invariant: no routing consumer), and the flag **is** JSON-exported on the
  operator-auth `/poolz` surface (observability consumer exists).
- **AC-9 (SPEC-008 preserved).** A provider whose signed-catalog `HashStatus` is
  `hash_mismatch`/`hash_invalid` is excluded from routing (SPEC-008 §5.5–5.6), even
  with `require_hash_verified: false` — SPEC-032 does not weaken this.

Forward criteria (expected to FAIL against the current build; §14 Gap rows):

- **AC-F1 (FR-HG7, CRITICAL).** A provider that passes hello on a small model and then
  heartbeat-switches to a model whose `MinRAMGB` exceeds its verified ceiling is **not**
  routing-eligible for the larger model.
- **AC-F2 (FR-HG5).** An `autotune_evidence_required` close caused by **expiry of the
  provider's own previously-verified evidence**, when the model's admitted
  routing-eligible count is below two and the last-verified ceiling covers the model,
  admits the provider probationally **at its last-verified ceiling** (flagged
  `evidence_pending`, not tier-promoted, reconnect-stable deadline, no re-extension).
- **AC-F3 (FR-HG5, negative).** `autotune_evidence_invalid`, `autotune_model_cap_exceeded`,
  and `autotune_model_uncatalogued` **always reject** even when doing so leaves a
  singleton pool; and a **never-verified** provider gets **no** probationary
  buyer-routing (non-routable candidate state or close, never served on a self-claim).
- **AC-F4 (FR-HG5).** Any close leaving a model's admitted routing-eligible count below
  two emits a distinct operator redundancy alert.
- **AC-F5 (FR-HG6).** An admitted provider whose evidence crosses the TTL mid-session is
  re-gated within a bounded interval (probationary at last-verified ceiling if
  redundancy demands, else non-routable), and does not serve past that interval on
  expired evidence; it is not hard-killed mid-request.
- **AC-F6 (FR-CFG2).** `require_autotune_hello_gate` and the `telemetry_drift.*` keys
  can be changed without a coordinator restart.
- **AC-F7 (FR-PW3).** A mechanism is labeled "proof-of-weights" only if it binds output
  to the admitted weights (statistical/distributional or cryptographic attestation);
  the current nonce-echo OPoI does not qualify and is not so labeled.

## Production posture (as of 2026-07-11)

Read-only Pearl check (`/etc/macprovider/coordinator.pearl-overlays.yaml`):

- **Hello-gate: ENABLED** (`require_autotune_hello_gate: true`, `autotune_evidence_ttl_days: 30`).
  This is the live, load-bearing element; it is what closed the intended second
  provider in incident #2. Prod is **`pool_size: 1`** right now — the single-provider
  fragility FR-HG5 targets is a **live** condition, not hypothetical.
- **OPoI/canary: DISABLED** (`canary_enabled: false`, `opoi_pass_rate_window: 0`) — OPoI
  is dormant; Part B/C are specced-but-inactive.
- The `telemetry_drift` block is present in the overlay; with the OPoI window at 0 and
  canary disabled, the OPoI pass-rate path is inactive (TPS/hash drift may evaluate at
  heartbeat but is alert-only regardless — FR-TD1).

The highest-value follow-up is **FR-HG5** (redundancy-aware admission), which directly
addresses the live fragility.

## Cross-references

- **SPEC-031** — canary probe mechanism (OPoI reuses it verbatim), degrade/sanction
  state machine, last-provider protection (which cannot apply to a *pre-admission*
  gate rejection — FR-HG1/HG5), and the FR-CAN29 OPoI skip-neutrality gap.
- **item 10 (hardware-verifier)** — owns the `hardware-verifier.v2` verdict, evidence
  schema, and trust/chip matching consumed as inputs here (FR-HG2). Reconcile the
  runbook's `v1` anchor with the shipped `v2`.
- **SPEC-020 / SPEC-002 F-2 / SPEC-003** — provider trust tiers and auth admission; the
  hello-gate is orthogonal (capacity, not trust) and sequenced before them.
- **SPEC-030** — losslessness/quantization-fidelity distributional probe; a distinct
  family. Its TV-distance approach is one candidate substrate for a future real
  proof-of-weights (FR-PW3), but SPEC-030 is not itself proof-of-weights.
- **`zk-verifiable-inference-design`** memo — the VeriLLM-class Merkle+VRF+statistical
  design is the other candidate substrate for FR-PW3.

## Changelog

- **v0.1-draft (2026-07-11):** Initial reconstructed baseline (runbook item 9, Wave C).
  Verify-before-design read-only Pearl check established that the **hello-gate is live
  in production** (`require_autotune_hello_gate: true`, `pool_size: 1`) while
  OPoI/canary are disabled — reshaping the spec so the live hello-gate admission policy
  (Part A, incl. the FR-HG5 redundancy fix) is the substantive core and OPoI is
  honestly labeled non-binding (Part B). Sources: `internal/pow/drift.go`,
  `internal/autotune/{gate,evidence,catalog,evidence_pg}.go`,
  `internal/stats/hardwareverify/verify.go`, `internal/ws/server.go`,
  `internal/ws/canary_probe.go`, `internal/config/config.go`, migration-017, and the
  live Pearl overlay. Incident provenance: 2026-07-10 transient-degrade (#2).
  Then **R1 codex three-lane audit absorbed** (code 1C/2H/3M, security 2C/3H/1L,
  architect 1C/2H/2M). Key absorptions:
  - **CRITICAL (all 3 lanes):** the draft's FR-HG5 would probationally route
    `autotune_evidence_invalid` providers — but that reason is an **affirmative
    capability shortfall** (evidence present, no benchmark passes: thermal/hash/TPS/
    TTFT). Reclassified: probation is now limited to the **evidence-EXPIRY sub-case of
    a previously-verified provider, at its last-verified ceiling**, reconnect-stable and
    non-re-extending; `evidence_invalid`/`cap_exceeded`/`uncatalogued` always reject; a
    never-verified provider gets no probationary buyer-routing.
  - **CRITICAL (security):** the ceiling was not enforced post-hello — a heartbeat
    model-swap bypasses the gate (`MaxAdmittedModelKey` has no routing consumer). Added
    **FR-HG7** requiring the ceiling to constrain routing on every model transition;
    marked the shipped bypass a CRITICAL-class Gap.
  - **HIGH (all 3):** FR-TD1's blanket "alert-only" contradicted **SPEC-008**'s
    authoritative `hash_mismatch`/`hash_invalid` routing exclusion. Scoped alert-only to
    the pow.Evaluator's own TPS/OPoI/artifact-drift response; preserved SPEC-008 hash
    routing; fixed the dependency header (added SPEC-008; SPEC-020 is not the tier
    source).
  - **HIGH (code+security):** the OPoI flag is **not** dead state — it is exported on the
    operator-auth `/poolz` surface; FR-PW2/§14 corrected to Implemented.
  - **HIGH (security):** FR-HG2 overstated current-hardware binding (lookup is by
    provider-ID, not live session hardware) and FR-HG6 permitted unbounded serving after
    expiry — corrected FR-HG2 (credential-bound limitation) and FR-HG6 (bounded
    session-time recheck).
  - **MEDIUM:** `uncatalogued` reclassified policy-unverifiable; `gate_unavailable`
    broadened to any lookup/decode error; AC-6/AC-7 given their evidence/enabled
    preconditions; FR-CFG2 corrected (SIGHUP reloads more than Tier-2). **LOW:** fixed a
    residual `server.go` comment calling OPoI an "identity" record (comment-only).
