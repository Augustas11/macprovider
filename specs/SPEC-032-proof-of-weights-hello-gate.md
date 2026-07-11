# SPEC-032 — Autotune Hardware-Evidence Admission Gate, OPoI & Proof-of-Weights Boundary

**Status:** v0.1-draft
**Date:** 2026-07-11
**Depends on:** SPEC-002 (coordinator admission, provider state machine), SPEC-003 (open onboarding, tiers), SPEC-020 (provider trust tiers), SPEC-031 (canary probe mechanism — OPoI reuses it), and the item-10 hardware-verifier verdict spec (owns `hardware-verifier.v2`, consumed here as an input)
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
**verified, in-window** hardware-evidence record for the connecting provider, looked
up by the exact **chip-normalized + unified-memory-GB tuple**, with the verifier's
`status = verified` and `decision_reason = hardware-verifier.v2:verified_trusted_hardware`,
and `generated_at ≥ now − autotune_evidence_ttl_days` (default 30 days). The lookup
MUST use the least-privilege column grants of migration-017 (`provider_id,
chip_normalized, unified_memory_gb, verified` on `provider_hardware_profiles`;
`chip_normalized, unified_memory_gb` on `hardware_verification_jobs`). If the
catalog or evidence store is not wired, the gate MUST fail closed with
`autotune_gate_unavailable` (close 4001).

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

| Close reason | Class | Meaning | Curable by the provider? |
|--------------|-------|---------|--------------------------|
| `autotune_gate_unavailable` | **coordinator-fault** | catalog/evidence store not wired | No — operator must fix wiring |
| `autotune_evidence_required` | **transient** | no verified evidence in-window (never submitted, or expired) | **Yes** — submit/refresh evidence |
| `autotune_evidence_invalid` | **transient** | evidence present but no benchmark passes the gate | Yes — re-run benchmark |
| `autotune_model_uncatalogued` | **permanent** | claimed model not in the catalog | No (until the catalog adds it) |
| `autotune_model_cap_exceeded` | **permanent** | claimed model's `MinRAMGB` > verified capacity ceiling | No — genuine capability shortfall |

The classification is the load-bearing distinction this spec adds: a **transient**
close means the provider is *probably capable* but has not proven it yet; a
**permanent** close means the evidence *affirmatively shows* the provider cannot
serve the claimed tier. Conflating the two is the incident-#2 fragility.

**FR-HG5 — Pool-redundancy-aware admission (the incident-#2 fix).** The hello-gate
as shipped is **pool-size-blind**: it evaluates one provider's evidence in isolation
and hard-closes on any rejection, so a **transient** `autotune_evidence_required`
close on the intended second provider for a model can leave `pool_size = 1` with no
redundancy — exactly the 2026-07-10 incident (#2), and the live production posture
(`pool_size: 1`) as of this writing.

This spec requires the gate to be **redundancy-aware for transient closes only**:

- A **permanent** close (`autotune_model_cap_exceeded`, `autotune_model_uncatalogued`)
  MUST always reject — admitting a provider that provably cannot serve the tier would
  route buyers to a provider that fails their requests, which is worse than a
  retryable 503. Redundancy never overrides a proven capability shortfall.
- A **transient** close (`autotune_evidence_required`, `autotune_evidence_invalid`)
  that would leave a model with **fewer than two** routing-eligible providers MUST
  NOT hard-close the provider. Instead the coordinator MUST admit it in a
  **probationary** state: routable for the model tiers its *last known* or
  *self-declared-and-plausibility-checked* capacity supports, flagged
  `evidence_pending`, **not** counted toward any trust-tier promotion, and subject to
  an evidence-submission deadline after which it is re-gated. The probationary
  provider MUST still be canary/degrade-governed by SPEC-031 (it is not exempt from
  liveness). This trades a bounded, flagged trust reduction for pool redundancy in
  exactly the case where a hard close causes a self-inflicted outage.
- The gate MUST emit a distinct operator alert whenever a close (of any class) would
  reduce a model's routing-eligible count below two, so the operator can act on the
  redundancy risk even when the close is correct (permanent).

> **Conformance note (§14).** Pool-redundancy awareness, the probationary
> `evidence_pending` admission state, and the below-two alert are **not implemented**
> — the shipped gate is pool-size-blind and hard-closes all rejections. This is the
> primary Gap this spec authorizes and the direct remediation for the live
> single-provider fragility.

**FR-HG6 — Evidence freshness and mid-session expiry.** Admission uses a 30-day TTL
(`autotune_evidence_ttl_days`) while the item-10 verifier applies a 7-day
`maxEvidenceAge` at verification time; this asymmetry is intentional (verification is
stricter than admission-reuse). This spec requires: (a) a provider whose evidence
**expires mid-session** MUST NOT be silently dropped — it MUST be treated like a
transient close at its next re-gate/reconnect (probationary if redundancy demands,
else re-gate), never hard-killed mid-serving; and (b) the coordinator SHOULD define a
re-verification cadence so evidence is refreshed before the TTL lapses rather than at
a reconnect boundary.

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
documents for unreliable canary signals). The shipped code already satisfies the
"MUST NOT gate" half (the flag is write-only); this spec makes that a deliberate
guarantee ceiling, not an accident, and requires the flag either to gain a defined
observability consumer (an operator dashboard field) or to be removed as dead state —
it MUST NOT be silently retained as if it were load-bearing.

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

**FR-TD1 — Drift signals and their alert-only ceiling.** The telemetry-drift
evaluator (`internal/pow/drift.go`) computes, at heartbeat time: a **TPS-below-baseline**
signal (measured sustained TPS below `tps_ratio_threshold` × the *signed autotune
benchmark* baseline, with an absolute floor and a minimum request window) and a
**model-hash** signal (hash status in `hash_alert_on_status`, or artifact drift). It
also computes the OPoI **pass-rate** signal (Part B). Every one of these MUST be
**alert-only**: on breach the coordinator emits a structured `WARN`
(`pow_telemetry_drift_detected`) subject to a per-signal cooldown, and takes **no**
routing, sanction, degrade, tiering, or payout action.

This alert-only ceiling is **deliberate and normative**, not a missing feature: the
TPS baseline and hash comparisons are heuristics against *benchmark metadata*, not a
weight-binding proof, and escalating an unreliable heuristic to an automatic sanction
is the exact failure mode SPEC-031 documents for the canary latency gates
(false-sanction flapping → self-inflicted outage). A future version MAY escalate a
drift signal to a routing/sanction effect **only** once it is backed by a
weight-binding test (FR-PW3) or corroborated by an independent buyer-path signal.

**FR-TD2 — Coupling to the canary.** OPoI pass-rate tracking has no independent
measurement path — it can only observe canary outcomes — so `opoi_pass_rate_window > 0`
MUST require `pool.canary_enabled` (as validation already enforces). With canary
disabled (the production posture), OPoI is dormant; the hello-gate (Part A) is the
only live element of this spec.

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
config is **startup-only** — the SIGHUP handler reloads only the Tier-2 block; the
hello-gate wiring is fixed at construction and `proof_of_weights.*` is read from the
boot config. Since the hello-gate is a **live money-path/availability gate on a
single-provider-fragile pool**, changing it (e.g. to relax evidence requirements
during a redundancy emergency, or to enable/disable the gate) currently forces a
coordinator restart — the same restart-outage class that SPEC-031 FR-CAN26 addresses
and that caused the 2026-07-10 ~5h outage. This spec **requires** that
`require_autotune_hello_gate`, `autotune_evidence_ttl_days`, and the
`telemetry_drift.*` keys be operator-mutable **without a coordinator restart** (SIGHUP
allowlist extension or an authenticated operator tuning path). Conformance gap (§14).

## Conformance status (§14)

| FR | Status | Note |
|----|--------|------|
| FR-HG1 gate activation/ordering | Implemented | `checkAutotuneHelloGate`; both paths; pre-admission. |
| FR-HG2 evidence requirement/lookup | Implemented | `LatestVerified`, TTL, migration-017 grants, `autotune_gate_unavailable`. |
| FR-HG3 capacity ceiling | Implemented | `ResolveMaxAdmission` / `benchmarkPassesGate`. |
| FR-HG4 close-reason taxonomy | **Tightens** | The five reasons ship; the normative transient/permanent classification is new. |
| FR-HG5 redundancy-aware admission | **Gap** | Gate is pool-size-blind; hard-closes all rejections. Primary incident-#2 remediation. |
| FR-HG6 freshness + mid-session expiry | **Partial** | TTL/maxEvidenceAge ship; probationary re-gate on mid-session expiry + re-verify cadence are new. |
| FR-PW1 OPoI non-binding labeling | **Tightens** | Code comment already says liveness-only; this makes it a normative prohibition on weight-claims. |
| FR-PW2 OPoI flag observability-only | **Partial** | Flag is write-only (satisfies "MUST NOT gate"); it lacks a defined consumer / is dead state. |
| FR-PW3 real proof-of-weights definition | **Gap (forward)** | No weight-binding test exists; deferred. |
| FR-TD1 drift alert-only ceiling | Implemented | `logTelemetryDriftAlerts` WARN-only; this makes the ceiling normative/deliberate. |
| FR-TD2 OPoI↔canary coupling | Implemented | Validation requires `canary_enabled` when window>0. |
| FR-CFG1 config surface | Implemented | `ProofOfWeightsConfig` + validation. |
| FR-CFG2 reload without restart | **Gap** | Startup-only; SIGHUP reloads Tier-2 only. |

**Re-enable / hardening bar.** The live gate (Part A) already protects buyers from
capability-mismatched providers; the priority Gap is **FR-HG5** (redundancy-aware
admission) — it is the direct fix for the live single-provider fragility — followed by
**FR-CFG2** (no-restart tuning, so the gate can be adjusted during a redundancy
emergency without triggering the restart-outage class). OPoI/telemetry-drift remain
observability-only until a weight-binding test (FR-PW3) exists; they MUST NOT be wired
to routing/sanction before then.

## Acceptance criteria

Testable against the current build:

- **AC-1.** With `require_autotune_hello_gate: true` and no verified in-window
  evidence, a connecting provider is closed `4001 autotune_evidence_required`.
- **AC-2.** With verified evidence whose capacity ceiling is below the claimed model's
  `MinRAMGB`, the provider is closed `autotune_model_cap_exceeded`.
- **AC-3.** A claimed model absent from the catalog closes `autotune_model_uncatalogued`.
- **AC-4.** With the catalog/evidence store unwired, the gate closes
  `autotune_gate_unavailable` (fails closed).
- **AC-5.** A low OPoI pass-rate emits a `pow_telemetry_drift_detected` WARN and
  causes **no** routing/sanction/degrade change (alert-only).
- **AC-6.** A TPS-below-baseline or hash-status drift emits a WARN only.
- **AC-7.** `opoi_pass_rate_window > 0` with `canary_enabled: false` fails config
  validation.
- **AC-8.** No code path reads `ModelClassOPoIPass` to gate routing/tiering/degrade
  (grep-level invariant: the flag has no routing consumer).

Forward criteria (expected to FAIL against the current build; §14 Gap rows):

- **AC-F1 (FR-HG5).** A **transient** close (`autotune_evidence_required`) that would
  leave a model with fewer than two routing-eligible providers admits the provider in
  a probationary `evidence_pending` state (routable for supported tiers, not
  tier-promoted, deadline-bounded) instead of hard-closing; a **permanent** close
  (`autotune_model_cap_exceeded`) still rejects regardless of redundancy.
- **AC-F2 (FR-HG5).** Any close reducing a model's routing-eligible count below two
  emits a distinct operator redundancy alert.
- **AC-F3 (FR-HG6).** A provider whose evidence expires mid-session is re-gated
  (probationary if redundancy demands) at its next reconnect, not hard-killed
  mid-serving.
- **AC-F4 (FR-CFG2).** `require_autotune_hello_gate` and the `telemetry_drift.*` keys
  can be changed without a coordinator restart.
- **AC-F5 (FR-PW2).** `ModelClassOPoIPass` is either exposed on a defined operator
  observability surface or removed — not silently retained as dead state.
- **AC-F6 (FR-PW3).** A mechanism is labeled "proof-of-weights" only if it binds
  output to the admitted weights (statistical/distributional or cryptographic
  attestation); the current nonce-echo OPoI does not qualify and is not so labeled.

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
