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
pass criterion are byte-identical. The resulting `ModelClassOPoIPass` flag has
**no routing/tiering/degrade/payout reader** (it is exported for operator
observability on `/poolz` but never gates anything), and a low OPoI pass-rate or a
telemetry-drift breach does **nothing but emit a `WARN` log**. This spec therefore
**refuses to let "proof-of-weights" imply a guarantee the code does not deliver**:
it labels OPoI **non-binding / liveness-derived**, defines what a *real*
proof-of-weights test would require, and pins the current signals' guarantee ceiling
at **observability-only**. The substantive, live normative content of this spec is
the **hello-gate admission policy** (Part A).

## 2. Scope

**In scope**

- **Part A — Autotune hello-gate:** the admission mechanism, the hardware-evidence
  requirement and freshness (TTL), the capacity-ceiling comparison (enforced on every
  model transition, FR-HG7), the complete close-reason taxonomy and its
  evidence-absent / no-passing-benchmark / policy-unverifiable classification, and the
  **pool-redundancy policy** — a below-two operator alert plus operator levers, with
  **no** automatic probationary admission in v0.1 (FR-HG5).
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
  note: the shipped constant is `hardware-verifier.v2:verified_trusted_hardware`; the
  runbook item-10 anchor was corrected from `v1` to `v2` — item 10 pins the
  authoritative string; this spec
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
| **Hardware evidence** | A verified `hardware_evidence.autotune.v1` envelope: autotune benchmark results bound to a chip/RAM tuple, ingested under bearer-token auth and accepted by the item-10 verifier with `decision_reason = hardware-verifier.v2:verified_trusted_hardware` after trust/chip-profile/value-binding checks. **The benchmark result itself is NOT cryptographically signed** — the *catalog* it is checked against is signed, but the provider-submitted benchmark is authenticated + trust-bound, not signature-verified (do not overstate its trust basis). |
| **Capacity ceiling** | `ResolveMaxAdmission` — the highest-RAM catalog row whose benchmark passes the gate; a provider may be admitted only for a model whose `MinRAMGB` ≤ this ceiling. |
| **OPoI** | "Overt Proof of Inference" — a model-class canary observation. Per this spec, **liveness-derived and non-binding**; not a weight proof. |
| **Telemetry-drift** | Heartbeat-time heuristics (TPS below the *verified* benchmark baseline; model-hash status; artifact drift) — alert-only. |
| **Evidence-absent close** | A hello-gate rejection curable by submitting evidence (no verified evidence in-window — never submitted or expired). |
| **No-passing-benchmark close** | `autotune_evidence_invalid` — evidence present but no benchmark passes the *current* gate. This is **either** a genuine affirmative shortfall (thermal/TPS/TTFT) **or** policy staleness (catalog/model/artifact-SHA mismatch after a catalog rotation); see FR-HG4. |
| **Affirmative-shortfall close** | A rejection where the evidence *proves* the provider cannot serve the tier: `cap_exceeded` and the hardware sub-cases of `evidence_invalid`. |
| **Policy-unverifiable / coordinator-side close** | The coordinator cannot evaluate the claim (`uncatalogued`), or is itself not wired/erroring (`gate_unavailable`, a coordinator fault). |

## Part A — Autotune hardware-evidence admission gate

**FR-HG1 — Gate activation.** The hello-gate is a no-op unless
`proof_of_weights.require_autotune_hello_gate` is true (default false; **true in the
Pearl production overlay**). When active, it MUST run at provider hello for **both**
the composed-auth (v2) and legacy admission paths, for **both** provisional and
pinned tiers, **before** the provider is recorded in the pool
(`recordProviderAdmission` / `checkOrRecordAdmission`). On the **composed-auth (v2)
path** the gate MUST be checked **twice** — once *before* issuing the auth challenge
and again *after* proof, immediately before durable admission — so that evidence that
disappears or expires during the challenge round-trip cannot slip a provider through
(a TOCTOU protection the shipped regression test pins; an implementation MUST preserve
both checks). Because the gate runs pre-admission, a rejected provider never enters the
pool, and SPEC-031's last-provider protection (which guards already-admitted providers
from sanctioning) **cannot** apply to a gate rejection — see FR-HG5.

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

**FR-HG4 — Close-reason taxonomy (normative), classified by evidence stance.**
Every gate rejection MUST use exactly one of the following close reasons (all on WS
close code `4001`). **In v0.1 every one hard-closes** (there is no probationary
admission, FR-HG5); the classification is normative because it governs operator
response and the *deferred* future probation, which — if ever built — could apply
**only** to the evidence-absent-from-expiry case:

| Close reason | Class | Meaning | v0.1 |
|--------------|-------|---------|------|
| `autotune_gate_unavailable` | **coordinator-fault** | catalog/evidence store not wired, **or any evidence lookup/decode/binding error** (DB/query failure, malformed envelope, immutable-binding mismatch) | rejects (operator must fix) |
| `autotune_evidence_required` | **evidence-absent** | no verified evidence in-window (never submitted, or **expired**) | rejects |
| `autotune_evidence_invalid` | **no-passing-benchmark** (affirmative shortfall **or** catalog staleness) | evidence present but **no benchmark passes the *current* gate** — a genuine hardware shortfall (thermal throttle, TPS below gate, TTFT above gate) **or** a policy-staleness case (catalog-SHA / model-id / artifact-SHA mismatch after a catalog rotation) | rejects |
| `autotune_model_uncatalogued` | **policy-unverifiable** | claimed model not in the catalog — the coordinator cannot *evaluate* the claim (not proof of shortfall) | rejects |
| `autotune_model_cap_exceeded` | **affirmative shortfall** | claimed model's `MinRAMGB` > verified capacity ceiling | rejects |

The load-bearing distinction is between **evidence-absent** (we have *no information*
about the provider's capability — recoverable by submitting evidence), a **genuine
affirmative shortfall** (the evidence *proves* the provider cannot serve the tier —
`cap_exceeded`, and the hardware sub-cases of `evidence_invalid`), and
**policy-unverifiable / coordinator-side** conditions (`uncatalogued` = the coordinator
cannot evaluate the claim; `gate_unavailable` = the coordinator is not wired or is
erroring — an operator fault, not the provider's). One nuance for operator response:
`evidence_invalid` is **not uniformly** a hardware shortfall — a **catalog rotation**
can flip a previously-good provider into `evidence_invalid` via a catalog-SHA/artifact
mismatch, which is policy staleness, not incapability; the hard-close remains correct
(the coordinator cannot currently verify capability), but the operator should check
catalog freshness, not assume bad hardware. Regardless of sub-case, `evidence_invalid`
never becomes probation-eligible — only the evidence-absent-from-expiry case could (and
even that is deferred, FR-HG5). Conflating "no evidence" with "no passing benchmark" was
the draft's original error.

**FR-HG5 — Redundancy alert and operator levers (NO automatic probationary admission
in v0.1).** The hello-gate as shipped is **pool-size-blind**: it hard-closes any
rejection, so a rejection of the intended second provider for a model can leave
`pool_size = 1` with no redundancy — the 2026-07-10 incident (#2) and the live
production posture (`pool_size: 1`) as of this writing.

**v0.1 does NOT introduce automatic probationary admission**, and this is a
deliberate scope decision, not an omission. An automatic "admit-anyway when the pool
would be a singleton" mechanism is a **capability-gate bypass oracle**: every
constraint it needs — re-evaluating stale evidence against the *current* catalog to
avoid laundering an affirmative failure into an expiry close, a hard grace clock
anchored at evidence expiry and durable across reconnect/restart, a budget bound to
the *hardware* identity so it cannot be chained across freshly-registered provider
IDs (Sybil), a ceiling recomputed under the current catalog, and a mid-session
redundancy count that excludes the expiring provider itself — is a place a malicious
or merely-unlucky provider can be routed to buyers on stale or self-declared
capacity. Rather than ship that surface, v0.1 keeps the gate strict and gives the
**operator** the levers:

- **All rejections hard-close, regardless of redundancy** — no-passing-benchmark
  (`autotune_evidence_invalid`, whether a hardware shortfall or catalog staleness),
  affirmative shortfall (`autotune_model_cap_exceeded`), policy-unverifiable /
  coordinator-side (`autotune_model_uncatalogued`, `autotune_gate_unavailable`), and
  evidence-absent (`autotune_evidence_required`, whether never-submitted or expired)
  alike. The coordinator never routes buyers to a provider it cannot currently verify
  can serve the tier.
- **Below-two operator alert (MUST).** Whenever a gate action leaves a model's
  **already-admitted routing-eligible** provider count **below two** (a structural
  count, independent of momentary slot availability), the coordinator MUST emit a
  distinct operator redundancy alert. This covers **both** (i) a gate-driven
  *eligibility loss* — a hard close, or a move to non-routable via mid-session expiry
  (FR-HG6) or config re-evaluation (FR-CFG2) — that drops the count below two, **and**
  (ii) a **rejection of an intended additional provider while the model is already at
  or below one** — the crucial incident-#2 case, where rejecting the second provider
  causes no downward *transition* but sustains a below-two *state* that MUST still
  alert. To keep this signal meaningful against a **provider-controlled `model_id`**
  (a hostile provider could otherwise flood alerts with random model claims), the
  alert MUST: (a) fire only for a **catalogued, demand-bearing** model (one buyers
  actually request), (b) be keyed by **normalized model id** and **deduplicated per
  redundancy episode** — one alert while a model remains below two, re-armed only after
  it recovers to ≥2, not per rejected attempt — and (c) be **cooldown-bounded** per key.
- **Emergency lever = the hot-reloadable gate (FR-CFG2).** An operator facing a
  redundancy emergency can **disable the gate** (`require_autotune_hello_gate: false`)
  or **temporarily raise `autotune_evidence_ttl_days`** to admit older-but-verified
  evidence — **without a coordinator restart** — the safe, auditable, human-in-the-loop
  path, rather than the coordinator auto-admitting an unverified provider. (Note the
  direction: the evidence cutoff is `now − ttl`, so **raising** the TTL *relaxes* the
  gate and **lowering** it *tightens*. Any such relaxation MUST be recorded as an
  explicit, time-boxed trust relaxation, and the gate re-tightened once redundancy
  recovers.)

The recorded incident-#2 `air5` case confirms this is the right scope: `air5` was
**never verified** and a smaller (7B) box, so no admission-policy exemption could have
safely given it 30B redundancy — the actual remedy is operational (acquire and verify
a second provider for the tier), which the below-two alert surfaces.

> **Deferred: automatic expiry-grace probation (a future version only).** A future
> version MAY add a narrow automatic exemption for the **evidence-expiry** case of a
> **previously-verified** provider, but ONLY if it satisfies **every** constraint
> above: (1) it re-evaluates the last-verified envelope against the **current**
> catalog and admits only if it still passes all non-TTL predicates (no laundering an
> affirmative failure through expiry); (2) it routes only up to the ceiling
> **recomputed under the current catalog** (never self-declared); (3) the grace is a
> single, hard-bounded window anchored at **evidence expiry**, durable across
> reconnect/restart, non-renewable, with the budget keyed to the evidence's
> **hardware identity** (not the provider ID) to prevent Sybil chaining; (4) the
> redundancy count **excludes the expiring provider itself**; (5) the provider stays
> canary/degrade-governed and non-tier-promoted throughout. Absent all five, the
> exemption is unsafe and MUST NOT ship.

> **Conformance note (§14).** The below-two operator alert is the one new normative
> requirement here and is **not implemented** (the shipped gate is pool-size-blind and
> emits no redundancy alert). The "no automatic probation" posture matches the shipped
> hard-close behavior; the redundancy levers (alert + FR-CFG2 hot-reload) are the Gap.

**FR-HG6 — Evidence freshness and bounded mid-session expiry.** Admission uses a
30-day TTL (`autotune_evidence_ttl_days`) while the item-10 verifier applies a 7-day
`maxEvidenceAge` at verification time; this asymmetry is intentional (verification is
stricter than admission-reuse). Because the gate runs only at hello, a
continuously-connected provider could otherwise serve **indefinitely on expired
evidence** — the spec closes that window. It requires: (a) the coordinator MUST
perform a **session-time freshness recheck** bounded by a **defined maximum** (a config
value, e.g. `autotune_evidence_recheck_interval_s`, or — as a conservative default —
the provider heartbeat interval, so the recheck happens at least once per heartbeat):
when an admitted provider's evidence crosses the TTL mid-session it MUST be re-gated
within that bound and, since v0.1 has no automatic probation (FR-HG5), moved
**non-routable** (with the FR-HG5 below-two operator alert) — it MUST NOT continue
serving at its pre-expiry ceiling past that bound; (b) a provider whose evidence
expires MUST NOT be silently hard-killed mid-request; and (c) the coordinator SHOULD
define a proactive re-verification cadence so evidence refreshes before the TTL lapses
rather than at an expiry boundary.

**FR-HG7 — Capacity ceiling enforced on every model transition (not just hello).**
The capacity ceiling (FR-HG3) MUST constrain routing eligibility on **every** model
the provider serves, evaluated whenever the provider's served model changes (via a
heartbeat that carries the model id) — not only the model claimed in the hello frame.
A provider MUST NOT be routing-eligible for a served model that is **either** (a)
**not in the catalog**, **or** (b) catalogued with a `MinRAMGB` that **exceeds its
verified ceiling** — regardless of whether that model was set at hello or by a later
heartbeat. Both branches matter: an *uncatalogued* transition target has no
`MinRAMGB` to compare and MUST NOT be treated as passing by default — routing to an
uncatalogued model buyers requested is exactly the capability-gate bypass this FR
closes.

> **Conformance gap (§14) — this is a live capability-gate bypass.** As shipped, the
> gate runs **only at admission**; a heartbeat can then replace `Provider.ModelID`
> (with a larger *or uncatalogued* model) without re-consulting the ceiling, and buyer
> routing uses that mutable model id (uncatalogued Tier-2 status stays routable unless
> strict hash verification is on). The computed `MaxAdmittedModelKey/ID` ceiling has
> **no routing consumer** — its only reader selects the warm-up/canary probe model. So
> a provider can pass hello on a small model, heartbeat-switch to a large or
> uncatalogued one, and serve buyers for a tier it never proved. Wiring the ceiling
> (catalogued **and** `MinRAMGB` ≤ ceiling) into the routing-eligibility predicate and
> re-evaluating it on model change is a **CRITICAL-severity** Gap and a required part
> of making the hello-gate meaningful; it is on the §14 re-enable/hardening bar.

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
(`internal/pow/drift.go`) has two distinct entry points with different evidence
preconditions: (1) `EvaluateHeartbeat`, at heartbeat time, computes a
**TPS-below-baseline** signal (measured sustained TPS below `tps_ratio_threshold` ×
the *verified autotune benchmark* baseline, with an absolute floor and a minimum request
window), a **model-`hash_status`** signal (statuses in `hash_alert_on_status`), and a
**benchmark-artifact drift** signal — this path early-returns when fresh verified
evidence is absent, so **all three** require verified evidence; and
(2) `RecordModelClassCanary`, at canary completion, computes the OPoI **pass-rate**
signal (Part B) — this path performs **no** evidence lookup, so an OPoI pass-rate alert
can fire without verified evidence. **The `pow.Evaluator`'s own response to any of
these is alert-only**: it emits a structured `WARN`
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
| `autotune_evidence_ttl_days` | int | `30` | Admission-reuse freshness window (cutoff = `now − ttl`; **raising** relaxes, **lowering** tightens); `>0` required when gate or drift enabled. |
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
allowlist extension or an authenticated operator tuning path).

**Enabling or tightening the gate MUST re-evaluate already-admitted sessions —
atomically and fail-closed.** A runtime change that turns the gate on, or narrows its
evidence requirement, MUST cause sessions admitted while the gate was disabled or
looser to be re-gated (and moved non-routable / closed if they no longer pass), not
merely apply to new connects — otherwise a hot-enable leaves the exact
capability-mismatched providers the gate exists to exclude serving buyers indefinitely.
The re-evaluation MUST be **race-free and fail-closed**: the coordinator MUST publish
the new config under a **monotonic config generation** and, at or before that
publication, **quarantine (move non-routable) every affected session** so no session
admitted under the old policy receives new buyer work during the scan; the scan MUST
complete within a **bounded interval**, MUST **fail closed** (leave a session
non-routable) on any evidence-lookup error, and MUST restore to routable only the
sessions that pass under the new generation. A snapshot-then-scan that lets old-policy
sessions keep serving during an unbounded scan does not satisfy this. Conformance gap
(§14).

## Conformance status (§14)

| FR | Status | Note |
|----|--------|------|
| FR-HG1 gate activation/ordering | Implemented | `checkAutotuneHelloGate`; both paths; pre-admission; v2 two-phase (pre-challenge + post-proof) recheck. |
| FR-HG2 evidence lookup | **Partial** | `LatestVerified(providerID, ttl)` + TTL + grants ship. Binds evidence to the provider **credential/ID**, not live session hardware (hello carries no chip/identity hash) — a limitation (item-10's to strengthen). The benchmark result is authenticated + trust-bound, **not cryptographically signed** (only the catalog is signed). |
| FR-HG3 capacity ceiling (resolution) | Implemented | `ResolveMaxAdmission` / `benchmarkPassesGate` resolve the ceiling correctly at hello. (Enforcement on the *served* model is FR-HG7.) |
| FR-HG4 close-reason taxonomy + classification | **Tightens** | The five reasons ship; the evidence-absent / no-passing-benchmark (affirmative-shortfall **or** catalog-staleness) / policy-unverifiable classification is new (esp. `evidence_invalid` and `uncatalogued` as NOT probation-eligible). |
| FR-HG5 redundancy alert; no auto-probation | **Gap (alert)** | The below-two operator redundancy alert is new/unimplemented. "No automatic probationary admission in v0.1" matches the shipped hard-close behavior (deliberate scope decision, not a Gap); auto-probation is deferred with its full constraint set. |
| FR-HG6 bounded mid-session expiry recheck | **Gap** | Gate runs only at hello — no bounded session-time freshness recheck; a continuously-connected provider can serve indefinitely on expired evidence. On recheck v0.1 moves the provider non-routable (no auto-probation). |
| **FR-HG7 ceiling enforced on model transition** | **Gap (CRITICAL-class)** | The ceiling has **no routing consumer**; a heartbeat model-swap to a larger **or uncatalogued** tier bypasses the gate entirely. Required to make the hello-gate meaningful. |
| FR-PW1 OPoI non-binding labeling | **Tightens** | Go source already says liveness-only; this makes it a normative repo-wide prohibition on weight-claims. Reconciled in this change: the `server.go` OPoI comment and the `proof-of-weights-implementation.md` runbook's "anti-downgrade" claims (both docs/comment-only). |
| FR-PW2 OPoI flag observability-only | Implemented | Zero routing/tiering/degrade/payout readers **and** already exposed as `model_class_opoi_pass` on the operator-auth `/poolz` surface. Not dead state. |
| FR-PW3 real proof-of-weights definition | **Gap (forward)** | No weight-binding test exists; deferred. |
| FR-TD1 pow-heuristic alert-only + preserve SPEC-008 hash routing | Implemented | pow.Evaluator is WARN-only. `EvaluateHeartbeat` (TPS, `hash_status`, artifact drift) requires verified evidence; `RecordModelClassCanary` (OPoI pass-rate) needs **no** evidence lookup. The pow WARN is distinct from SPEC-008's `hash_mismatch`/`hash_invalid` routing exclusion, which is independent and enforced by buyer routing. |
| FR-TD2 OPoI↔canary coupling | Implemented | `opoi_pass_rate_window>0` requires `canary_enabled`, validated when `telemetry_drift.enabled`. |
| FR-CFG1 config surface | Implemented | `ProofOfWeightsConfig` + validation. |
| FR-CFG2 reload without restart + existing-session re-eval | **Gap** | `proof_of_weights.*` startup-only; SIGHUP reloads Tier-2/billing/settlement/USD/routing-classes but not this block, and there is no re-evaluation of existing sessions on gate enable/tighten. |

**Re-enable / hardening bar.** The priority is **FR-HG7** — a **CRITICAL-severity** live
bypass: the ceiling is not wired into routing, so a heartbeat model-swap (to a larger
**or uncatalogued** model) defeats the whole gate, meaning the live gate does not
actually protect buyers from a capability-mismatched *served* model. Then the
redundancy levers — **FR-HG5** below-two alert + **FR-CFG2** (no-restart tuning *and*
existing-session re-eval, so an operator can safely relax the gate in an emergency
without a restart and re-gate stale sessions when tightening it) — and **FR-HG6**
(bounded expiry recheck). v0.1 deliberately ships **no** automatic probationary
admission; that mechanism is deferred behind the full constraint set in FR-HG5. OPoI /
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
- **AC-3b.** Evidence that is present but fails a gate predicate — a benchmark below
  the TPS gate / above the TTFT gate / thermally throttled, **or** a catalog/model/
  artifact-SHA mismatch under the current catalog — closes `autotune_evidence_invalid`
  (both the hardware-shortfall and catalog-staleness sub-cases map to this reason).
- **AC-4.** With the catalog/evidence store unwired **or any evidence lookup/decode
  error**, the gate closes `autotune_gate_unavailable` (fails closed).
- **AC-5.** A low OPoI pass-rate emits a `pow_telemetry_drift_detected` WARN (via
  `RecordModelClassCanary`, which needs **no** evidence lookup) and causes **no**
  routing/sanction/degrade change.
- **AC-6.** A TPS-below-baseline, `hash_status`, or artifact-drift signal (via
  `EvaluateHeartbeat`) emits a WARN only, and **only when fresh verified evidence is
  present** (no evidence → the heartbeat path early-returns, no alert).
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
- **AC-F2 (FR-HG7, CRITICAL — uncatalogued).** A provider that heartbeat-switches to an
  **uncatalogued** model is **not** routing-eligible for that model (an uncatalogued
  target does not pass by default for lack of a `MinRAMGB` to compare).
- **AC-F3 (FR-HG5).** A gate action that leaves a model's admitted routing-eligible
  count below two emits a distinct operator redundancy alert — covering **both** an
  eligibility loss that drops below two **and** rejecting a second provider while the
  model is already at or below one (a sustained below-two *state*, not only a downward
  transition) — **only** for a catalogued demand-bearing model, **deduplicated per
  episode** (one alert while below two, re-armed on recovery to ≥2) **and
  cooldown-bounded** (a provider spamming random `model_id` claims cannot flood it); and
  no rejection of any class — including `autotune_gate_unavailable` — is auto-admitted
  (v0.1 has no probationary path).
- **AC-F4 (FR-HG6).** An admitted provider whose evidence crosses the TTL mid-session is
  re-gated within the defined bound (`autotune_evidence_recheck_interval_s` / heartbeat
  interval) and moved non-routable (v0.1), and does not serve past that bound on expired
  evidence; it is not hard-killed mid-request.
- **AC-F5 (FR-CFG2).** `require_autotune_hello_gate`, **`autotune_evidence_ttl_days`**,
  and the `telemetry_drift.*` keys can be changed without a coordinator restart. The TTL
  direction is correct: **raising** `autotune_evidence_ttl_days` admits older-but-verified
  evidence (relaxes the gate) and **lowering** it rejects more evidence (tightens) — a
  test MUST assert this direction so an inverted `now − ttl` comparison fails. And
  enabling/tightening the gate re-gates already-admitted sessions **atomically and
  fail-closed** — affected sessions are quarantined non-routable at/before the new
  config generation is published, the scan completes within a bound, an evidence-lookup
  error leaves a session non-routable, and only passers are restored — not merely
  applied to new connects.
- **AC-F6 (FR-PW3).** A mechanism is labeled "proof-of-weights" only if it binds output
  to the admitted weights (statistical/distributional or cryptographic attestation);
  the current nonce-echo OPoI does not qualify and is not so labeled.

## Production posture (as of 2026-07-11)

Read-only Pearl check (`/etc/macprovider/coordinator.pearl-overlays.yaml`):

- **Hello-gate: ENABLED** (`require_autotune_hello_gate: true`, `autotune_evidence_ttl_days: 30`).
  This is the live, load-bearing element; it is what closed the intended second
  provider in incident #2. Prod is **`pool_size: 1`** right now — the single-provider
  fragility is a **live** condition, not hypothetical.
- **OPoI/canary: DISABLED** (`canary_enabled: false`, `opoi_pass_rate_window: 0`) — OPoI
  is dormant; Part B/C are specced-but-inactive.
- The `telemetry_drift` block is present in the overlay; with the OPoI window at 0 and
  canary disabled, the OPoI pass-rate path is inactive (TPS/hash drift may evaluate at
  heartbeat but is alert-only regardless — FR-TD1).

The highest-value follow-up is **FR-HG7** (wire the ceiling into routing — closes the
live capability-gate bypass). The single-provider fragility's remedy is chiefly
**operational** (acquire and verify a second provider for the tier), surfaced by the
FR-HG5 below-two alert and made safely tunable by FR-CFG2; it is **not** solved by
auto-admitting an unverified provider (the recorded `air5` was never-verified and a
smaller box), which is why v0.1 ships no automatic probation.

## Cross-references

- **SPEC-031** — canary probe mechanism (OPoI reuses it verbatim), degrade/sanction
  state machine, last-provider protection (which cannot apply to a *pre-admission*
  gate rejection — FR-HG1/HG5), and the FR-CAN29 OPoI skip-neutrality gap.
- **item 10 (hardware-verifier)** — owns the `hardware-verifier.v2` verdict, evidence
  schema, and trust/chip matching consumed as inputs here (FR-HG2). (The runbook
  item-10 anchor was corrected `v1`→`v2` in this change to match the shipped constant.)
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
  - **R2 codex three-lane audit** (code 0C/0H/2M/1L, security 1C/2H/2M/1L, architect
    0C/2H/1M/1L — R1 CRITICALs confirmed closed). Decisive scope call: **automatic
    probationary admission removed from v0.1 entirely.** Both lanes' HIGHs (and
    security's laundering/chaining findings) were all probation-state-machine holes —
    expiry laundering a current-catalog affirmative failure into a redundancy pass, an
    unbounded/reconnect-chainable grace clock (Sybil across provider IDs), and a
    mid-session redundancy count that couldn't decide whether to count the expiring
    provider. Any automatic "admit-anyway on singleton" mechanism is a capability-gate
    bypass oracle; rather than pin all five constraints and keep finding edge cases,
    v0.1 keeps the gate strict and gives the operator the levers: the **below-two
    redundancy alert** + the **hot-reloadable gate** (FR-CFG2). Auto-probation is
    deferred with its full constraint set documented so nobody builds the unsafe
    version. Also absorbed:
    - **CRITICAL (security):** FR-HG7 left **uncatalogued** post-hello transitions
      routable (it only compared `MinRAMGB`, which an uncatalogued model lacks). Now
      requires the transition target to be **catalogued AND** ceiling-valid; added an
      uncatalogued-transition negative AC.
    - **MEDIUM (security):** FR-CFG2 now requires enabling/tightening the gate to
      **re-evaluate already-admitted sessions**, not just new connects.
    - **MEDIUM (code+security):** FR-TD1 corrected — the OPoI pass-rate path
      (`RecordModelClassCanary`) needs **no** evidence lookup; only the heartbeat
      TPS/artifact path requires verified evidence. **LOW:** §1 no longer calls the OPoI
      flag "write-only" (it has a `/poolz` consumer); FR-HG7 says "heartbeat" (the
      `StateUpdate` frame carries no model); softened the "FR-HG5 = direct incident-#2
      fix" language (the remedy is operational — `air5` was never-verified).
  - **R3 codex three-lane audit** (code 0C/1H/5M, security 0C/0H/4M, architect
    0C/0H/4M/1L — R2 CRITICAL + both probation HIGHs confirmed closed). Absorbed:
    - **HIGH (code):** dropped the false "signed autotune benchmark" claim — the
      benchmark result is bearer-authenticated + trust-bound, **not** cryptographically
      signed (only the *catalog* is signed); corrected §3 terminology and FR-TD1.
    - **MEDIUM (all 3):** the emergency TTL lever was **inverted** — the cutoff is
      `now − ttl`, so **raising** the TTL relaxes the gate and lowering it tightens;
      corrected FR-HG5 + AC-F5 + the config table.
    - **MEDIUM (arch+security):** the below-two alert now fires on **any** gate-driven
      eligibility loss (close or non-routable move), is restricted to catalogued
      demand-bearing models, and is dedup/cooldown-bounded (a provider-controlled
      `model_id` can't flood it).
    - **MEDIUM (security):** FR-CFG2 existing-session re-eval must be **atomic +
      fail-closed** (monotonic config generation, quarantine-before-publish, bounded
      scan, fail-closed on lookup error).
    - **MEDIUM (arch):** FR-HG6 recheck bound pinned to a config value
      (`autotune_evidence_recheck_interval_s`, proposed) / heartbeat interval.
    - **MEDIUM (arch+code):** FR-HG4 refined — `evidence_invalid` is **not uniformly**
      a hardware shortfall (a catalog rotation can flip a good provider via SHA
      mismatch = policy staleness); `gate_unavailable` kept distinct as a
      coordinator-fault; pruned the dangling `transient/permanent` §3 terms.
    - **MEDIUM (code):** FR-HG1 now records the v2 two-phase (pre-challenge +
      post-proof) TOCTOU recheck; §14 FR-TD1 note split by entry point.
    - **MEDIUM (code):** FR-PW1 repo-wide honesty — reconciled the
      `proof-of-weights-implementation.md` runbook's "anti-downgrade" claims
      (docs-only); fixed the stale item-10 `hardware-verifier.v1`→`v2` runbook anchor.
  - **R4 codex three-lane audit** (code 0C/2H/3M, security 0C/0H/3M, architect
    0C/1H/5M — all consistency residuals, several introduced by the R3 edits; no
    CRITICAL, no design change). Absorbed:
    - **HIGH (code):** a missed `signed baseline` instance in §3 → `verified`
      (completing R3's unsigned-benchmark correction).
    - **HIGH (code+architect):** adding the *proposed* `autotune_evidence_recheck_interval_s`
      to the FR-CFG1 config table made its §14 "Implemented" false; removed it from the
      shipped-surface table (it stays a proposed key under FR-HG6).
    - **MEDIUM (all 3):** finished the FR-HG4 catalog-staleness split — §3 gains a
      distinct **no-passing-benchmark** class, and §2/FR-HG5/§14 no longer group all
      `evidence_invalid` under affirmative shortfall; added AC-3b to lock it.
    - **MEDIUM (code+architect):** the item-10 `v1`-anchor-is-stale note went stale
      itself (R3 fixed the runbook) — updated §2/§17.
    - **MEDIUM (architect):** the below-two alert now fires on a sustained below-two
      *state* (rejecting the 2nd provider while already at one), not only a downward
      transition — the exact incident-#2 case; AC-F3 updated.
    - **MEDIUM (architect):** reconciled SPEC-031's residual "only real anti-downgrade
      guarantee" cross-reference with SPEC-032 FR-PW1/PW3 (SPEC-031 docs edit, bundled).
    - **MEDIUM (architect):** AC-F5 now acceptance-locks the TTL direction (raise=relax).
    - **MEDIUM (code):** FR-TD1's heartbeat path adds the `hash_status` signal (also
      evidence-gated); §14 row updated.
    - **MEDIUM (security):** the runbook's "30B-claim/8B-serve downgrade smoke via the
      nonce gate" overclaim corrected — the nonce gate cannot detect a downgrade
      (docs-only).
