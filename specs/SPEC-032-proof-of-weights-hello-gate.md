# SPEC-032 — Autotune Hardware-Evidence Admission Gate, OPoI & Proof-of-Weights Boundary

**Status:** v0.2.5-draft
**Date:** 2026-08-02
**Depends on:** SPEC-002 (coordinator admission, provider state machine; F-2 defines provisional/pinned tiers), SPEC-003 (open onboarding, tiers), **SPEC-008 (Tier-2 — authoritative on the model-hash routing-exclusion predicate and attestation; this spec MUST NOT override it)**, SPEC-031 (canary probe mechanism — OPoI reuses it), and the item-10 hardware-verifier verdict spec (owns `hardware-verifier.v2`, consumed here as an input). SPEC-020 (provider *autoupdate* trust table) is only tangentially related and is **not** the tier-definition source.
**Related (distinct, cross-referenced only):** SPEC-030 (losslessness probe — a separate distributional probe family)

**Numbering note.** Assigned canonical **SPEC-032** on 2026-07-11 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 9). Highest prior canonical spec
was SPEC-031. This document is the reconstructed normative baseline for two
coordinator trust signals that ship unspecced: the **autotune hardware-evidence
admission gate** (the "hello-gate", enabled in prod at the 2026-07-11 baseline,
**explicitly disabled in the live Pearl overlay as of 2026-07-27** — see the
production-posture section) and the **OPoI / proof-of-weights /
telemetry-drift** signals (drift observe-mode **enabled live** since the
2026-07-22 overlay revision; the rest disabled). SPEC-031 explicitly deferred the *semantics* of `model_class_challenges`
and the OPoI pass flag to this baseline (SPEC-031 §2, §17); this spec owns them.

---

## 1. Purpose and the central honesty problem

The coordinator carries two trust signals beyond the SPEC-031 liveness canary:

1. **The autotune hello-gate** (`internal/autotune/gate.go`, `checkAutotuneHelloGate`
   in `internal/ws/server.go`) — an **admission** gate that, when enabled, refuses a
   provider at connect unless it presents fresh, verified **hardware evidence**
   proving it can serve the model tier it claims. This gate was enabled in production at this spec's 2026-07-11 baseline but is **explicitly disabled
   in the live Pearl overlay as of 2026-07-27** (`require_autotune_hello_gate: false`, overlay
   revised 2026-07-22 — verified against the running process, epic #770 / #769; see the
   production-posture section). It remains a money-path / availability-path control: it is the gate that closed the intended
   second provider in the 2026-07-10 transient-degrade incident (#2), leaving a
   single-provider pool.

2. **OPoI / proof-of-weights / telemetry-drift** (`internal/pow/drift.go`) — a set
   of signals intended to detect a provider that has silently downgraded or swapped
   its model. Telemetry-drift observe mode is **enabled in the live overlay as of
   2026-07-27** (`telemetry_drift.enabled: true`; the OPoI canary and every enforcement remain
   off) and, critically, these signals **as implemented are not proof of weights at all**.

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
at **observability-only**. The substantive normative content of this spec is
the **hello-gate admission policy** (Part A) — currently disabled in the live overlay (see the
production-posture section).

## 2. Scope

**In scope**

- **Part A — Autotune hello-gate:** the admission mechanism, the hardware-evidence
  requirement and freshness (TTL), the capacity-ceiling comparison (enforced on every
  model transition, FR-HG7), the complete close-reason taxonomy and its
  evidence-absent / no-passing-benchmark / policy-unverifiable classification, and the
  **pool-redundancy policy** — a below-two operator alert plus operator levers, with
  **no** automatic buyer-routable probationary admission in v0.2.2 (FR-HG5).
- **Part B — OPoI / proof-of-weights honesty:** what a model-class canary pass
  proves and does not prove; the observability-only status of the
  `ModelClassOPoIPass` flag; and the normative definition of what a future
  weight-binding proof-of-weights test must provide.
- **Part C — Telemetry-drift:** the heartbeat signals (TPS-below-baseline, model-hash
  status, benchmark-artifact drift) **and** the canary-completion OPoI pass-rate signal
  (`RecordModelClassCanary`), across both `pow.Evaluator` entry points, and their
  **alert-only guarantee ceiling**.
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
| **Hardware evidence** | A verified `hardware_evidence.autotune.v2` envelope: autotune benchmark results bound to a chip/RAM tuple, the signed catalog row identity, the `spec-023-harmony-stream.v2` probe protocol, and the submitting executable SHA-256; it is ingested under bearer-token auth and accepted by the item-10 verifier with `decision_reason = hardware-verifier.v2:verified_trusted_hardware` after trust/chip-profile/value-binding checks. **The benchmark result itself is NOT cryptographically signed** — the *catalog* it is checked against is signed, but the provider-submitted benchmark is authenticated + trust-bound, not signature-verified (do not overstate its trust basis). |
| **Capacity ceiling** | `ResolveMaxAdmission` — the highest-RAM catalog row whose benchmark passes the gate; a provider may be admitted only for a model whose `MinRAMGB` ≤ this ceiling. |
| **OPoI** | "Overt Proof of Inference" — a model-class canary observation. Per this spec, **liveness-derived and non-binding**; not a weight proof. |
| **Telemetry-drift** | `pow.Evaluator` heuristics — heartbeat-time (TPS below the *verified* benchmark baseline; model-hash status; artifact drift) **and** the canary-completion OPoI pass-rate (`RecordModelClassCanary`, no evidence lookup) — all alert-only (FR-TD1). |
| **Evidence-absent sandbox** | A strict hello-gate admission with no verified evidence in-window (never submitted or expired). The provider may connect only as `admission_sandboxed`: operator-visible / internal-probe eligible, but never routing-eligible or buyer-serving, and without receiving newly minted durable provider credentials. It still consumes normal provisional admission/session limits. |
| **No-passing-benchmark close** | `autotune_evidence_invalid` — evidence present but no benchmark passes the *current* gate. Cause is one of: a genuine affirmative shortfall (**thermal throttle only** — the advisory `bench_gate` TPS/TTFT never reject, #687), policy staleness (catalog/model/artifact-SHA mismatch after a catalog rotation), **or** provider semantic misbinding (a submitted binding — `model_key`, model-id, artifact-SHA, or catalog-SHA — that the verifier accepts syntactically but the gate value-checks against the current signed catalog and rejects); see FR-HG4. |
| **Affirmative-shortfall close** | A rejection where the evidence *proves* the provider cannot serve the tier: `cap_exceeded` and the hardware sub-cases of `evidence_invalid`. |
| **Policy-unverifiable / coordinator-side close** | The coordinator cannot evaluate the claim (`uncatalogued`), or is itself not wired/erroring (`gate_unavailable`, a coordinator fault). |

## Part A — Autotune hardware-evidence admission gate

**FR-HG1 — Gate activation.** The hello-gate is a no-op unless
`proof_of_weights.require_autotune_hello_gate` is true (default false; **explicitly
false in the live Pearl overlay as of 2026-07-27; see §1**). When active, it MUST run at provider hello for **both**
the composed-auth (v2) and legacy admission paths, for **both** provisional and
pinned tiers, **before** the provider is recorded in the pool
(`recordProviderAdmission` / `checkOrRecordAdmission`). On the **composed-auth (v2)
path** the gate MUST be checked **twice** — once *before* issuing the auth challenge
and again *after* proof, immediately before durable admission — so that evidence that
disappears or expires during the challenge round-trip cannot slip a provider through
(a TOCTOU protection the shipped regression test pins; an implementation MUST preserve
both checks). Providers that fail an affirmative gate check never enter the pool.
Providers that only lack verified evidence enter the pool as `admission_sandboxed`,
which is non-routable and not buyer-serving but remains operator-visible for internal
probing. SPEC-031's last-provider protection (which guards already-admitted providers
from sanctioning) **cannot** make a sandboxed or rejected provider buyer-routable —
see FR-HG5.

**FR-HG2 — Evidence requirement and lookup.** When active, buyer-routable admission
MUST require a **verified, in-window** hardware-evidence record for the connecting provider. The
lookup is keyed by **provider ID + TTL** (`LatestVerified(providerID, ttl)`); it
selects the provider's stored hardware profile joined to a historical
`hardware_verification_jobs` row with `status = verified` and `decision_reason =
hardware-verifier.v2:verified_trusted_hardware`, matching the stored profile's
chip-normalized + unified-memory-GB tuple, and `generated_at ≥ now −
autotune_evidence_ttl_days` (default 30 days). The lookup MUST use the
least-privilege column grants of migration-017. If the catalog or evidence store is
not wired, **or the evidence lookup/decode/binding fails for any reason** (DB error,
malformed envelope, immutable-binding mismatch), the gate MUST fail closed with
`autotune_gate_unavailable` (close 4001). If the lookup succeeds but returns no
verified in-window evidence, the gate MUST admit the provider only as
`admission_sandboxed`: connected, visible to operators, and eligible only for
synthetic/internal probes, never buyer traffic, routing eligibility, buyer-serving
capacity, or newly minted durable provider credentials. The sandbox is still subject
to normal provisional admission/session limits. This provider-session rule does not apply to v2 credential-bootstrap
mint-only sockets: those sockets may mint a first credential without hardware evidence
only on the narrow bootstrap path, but they register no pool provider and create no
buyer-routable session.

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
**artifact-SHA256 match** to the catalog row). It MUST then evaluate the provider's
claimed model against that ceiling and admit only if the claimed model is catalogued
and its `MinRAMGB` does not exceed the ceiling.

**[amended #687 — advisory bench_gate is never an admission veto].** The hello-gate
MUST NOT include the advisory `bench_gate.min_sustained_tps` or
`bench_gate.max_4k_ttft_ms` fields (SPEC-023 §5 / §12 defines these as advisory drift
targets, never a veto) as ceiling-resolution or admission predicates. A catalog row's
`bench_gate` MAY be `omlx_seeded` — seeded from unattested oMLX community data — and
per the #687 trust invariant unattested oMLX data MUST NEVER hard-block a provider or
set/hold a recommendable or admission gate. The ceiling therefore resolves from
hardware/identity predicates (no thermal throttle, catalog-SHA / model-id /
artifact-SHA256 match) and `MinRAMGB` only; a provider MUST NOT be excluded from the
ceiling because its submitted sustained-TPS is below, or its TTFT above, the advisory
`bench_gate`. If a future hard **performance** admission gate is wanted, it MUST be a
**separate catalog field** backed by trusted-provider (verified-provider-matrix)
evidence, distinct from the advisory `bench_gate`; that separate-field mechanism is
deferred to a later stage.

**[normative — admission identity MUST exclude advisory `bench_gate` (#687
Stage-2 prerequisite)].** The hello-gate's **admission identity** — the key set the
gate uses to match a provider against verified hardware evidence and resolve its
ceiling — MUST NOT include the advisory `bench_gate.min_sustained_tps` /
`max_4k_ttft_ms`, `bench_gate.provenance`, or `bench_gate.gate_seed`. Those fields are
advisory (SPEC-023 §5) and may be `omlx_seeded` from unattested community data;
including any of them in the admission identity or evidence-match would let unattested
oMLX data influence a hard admission decision, violating the #687 trust invariant.
When the SPEC-023 oMLX schema activates (SPEC-023 §12.2 activation gate, condition
(b)(i)), the Stage-2 implementation MUST provide this **separate admission identity**
that reads only the hardware/identity predicates (thermal, catalog-policy digest /
model-id / artifact-SHA256) and `MinRAMGB`. This is a normative requirement on the
Stage-2 implementation; it is not implemented by this docs-only amendment and touches
no code.

**[normative — admission matches the catalog admission-policy digest, NOT the full
catalog SHA (#687 r5)].** Wherever this spec refers to a "catalog-SHA" match as an
admission or ceiling-resolution predicate (FR-HG3 above, FR-HG4 policy-staleness),
the match MUST be against SPEC-023 §3.6's **`admission_policy_sha256`** — the digest
computed over the catalog with the advisory `bench_gate.min_sustained_tps`,
`max_4k_ttft_ms`, `provenance`, and `gate_seed` fields EXCLUDED — and MUST NOT be the
full `candidate_catalog_sha256` (which SPEC-023 hashes over the entire catalog
including those advisory/oMLX fields, and which SPEC-023 reserves for cache/update
integrity only). Matching admission on the full catalog SHA would (a) drag unattested
oMLX advisory values into the hard admission decision, contradicting the exclusion
above, and (b) spuriously invalidate a provider's verified admission whenever any
advisory-only catalog field changes. This is the spec-level resolution of that
self-contradiction; the digest computation is SPEC-023 §12.2(b)(i) Stage-2 work.

**FR-HG4 — Gate outcome taxonomy (normative), classified by evidence stance.**
Every gate non-admission or sandboxing outcome MUST use exactly one of the following
reasons. Hard closes use WS close code `4001`; missing evidence uses the
`autotune_evidence_required` operator event and `admission_sandboxed` provider flag,
not a buyer-routable probation. The classification is normative because it governs
operator response and the *deferred* future probation, which — if ever built — could
apply **only** to the evidence-absent-from-expiry case:

| Reason | Class | Meaning | v0.2.2 |
|--------|-------|---------|--------|
| `autotune_gate_unavailable` | **coordinator-fault** | catalog/evidence store not wired, **or any evidence lookup/decode/binding error** (DB/query failure, malformed envelope, immutable-binding mismatch) | rejects (operator must fix) |
| `autotune_evidence_required` | **evidence-absent** | no verified evidence in-window (never submitted, or **expired**) | sandbox-connects, never buyer-routable |
| `autotune_evidence_invalid` | **no-passing-benchmark** (affirmative shortfall, catalog staleness, **or** provider semantic misbinding) | evidence present but **no benchmark passes the *current* gate** — a genuine hardware shortfall (**thermal throttle only**; the advisory `bench_gate.min_sustained_tps`/`max_4k_ttft_ms` are NEVER a rejection cause, #687); a policy-staleness case (catalog-SHA / model-id / artifact-SHA mismatch after a catalog rotation); **or** a provider-submitted **semantic misbinding** — the verifier accepts evidence on *syntactic*/trust bindings (e.g. `model_key` non-empty/unique, `candidate_catalog_sha256` well-formed) but does **not** value-check those bindings against the signed catalog, so the *gate* is where a mismatched **`model_key`, model-id, artifact-SHA, or a provider-misbound catalog-SHA** (distinct from a genuine catalog rotation) is caught | rejects |
| `autotune_model_uncatalogued` | **policy-unverifiable** | claimed model not in the catalog — the coordinator cannot *evaluate* the claim (not proof of shortfall) | rejects |
| `autotune_model_cap_exceeded` | **affirmative shortfall** | claimed model's `MinRAMGB` > verified capacity ceiling | rejects |

**[amended #687 — `evidence_invalid` MUST NOT be raised on advisory bench_gate
TPS/TTFT].** The "genuine hardware shortfall" sub-case of `autotune_evidence_invalid`
is limited to a **thermal-throttle** shortfall and the catalog-SHA / model-id /
artifact-SHA policy-staleness and semantic-misbinding sub-cases. The gate MUST NOT
close `autotune_evidence_invalid` (nor otherwise reject or non-admit a provider)
because the provider's submitted sustained-TPS is below, or its TTFT above, the
advisory `bench_gate.min_sustained_tps` / `bench_gate.max_4k_ttft_ms`. Those fields
are advisory drift targets (SPEC-023 §5 / §12), the source row may be `omlx_seeded`
from unattested oMLX data, and the #687 trust invariant forbids unattested oMLX data
from hard-blocking a provider. A hard **performance** admission gate, if ever wanted,
MUST be a separate catalog field backed by trusted-provider (verified-provider-matrix)
evidence, not the advisory `bench_gate`; that mechanism is deferred to a later stage.

The load-bearing distinction is between **evidence-absent** (we have *no information*
about the provider's capability — recoverable by submitting evidence), a **genuine
affirmative shortfall** (the evidence *proves* the provider cannot serve the tier —
`cap_exceeded`, and the hardware sub-cases of `evidence_invalid`), and
**policy-unverifiable / coordinator-side** conditions (`uncatalogued` = the coordinator
cannot evaluate the claim; `gate_unavailable` = the coordinator is not wired or is
erroring — an operator fault, not the provider's). One nuance for operator response:
`evidence_invalid` is **not uniformly** a hardware shortfall — a **catalog rotation**
can flip a previously-good provider into `evidence_invalid` via a catalog-SHA/artifact
mismatch, which is policy staleness, not incapability; or the provider may have
submitted evidence whose **`model_key` / model-id / artifact-SHA / catalog-SHA** values
are misbound (the verifier trusts syntactic/hardware bindings but does not value-check
them against the signed catalog —
that check is the gate's). The hard-close remains correct in every sub-case (the
coordinator cannot currently verify capability); the operator's diagnosis differs
(check hardware vs. catalog freshness vs. the provider's submitted model/artifact ids).
Regardless of sub-case, `evidence_invalid` never becomes probation-eligible — only the
evidence-absent-from-expiry case could (and even that is deferred, FR-HG5). The
current evidence-absent sandbox is not probation because it is not buyer-routable.
Conflating "no evidence" with "no passing benchmark" was the draft's original error.

**FR-HG5 — Redundancy alert and operator levers (NO automatic buyer-routable
probationary admission).** The hello-gate is **pool-size-blind** for buyer traffic:
it rejects affirmative failures and parks evidence-absent providers in a non-buyer
sandbox, so the intended second provider for a model can still leave `pool_size = 1`
with no buyer-serving redundancy — the 2026-07-10 incident (#2) and the live
production posture (`pool_size: 1`) as of this writing.

**v0.2.2 does NOT introduce automatic buyer-routable probationary admission**, and this is a
deliberate scope decision, not an omission. An automatic "admit-anyway when the pool
would be a singleton" mechanism is a **capability-gate bypass oracle**: every
constraint it needs — re-evaluating stale evidence against the *current* catalog to
avoid laundering an affirmative failure into an expiry close, a hard grace clock
anchored at evidence expiry and durable across reconnect/restart, a budget bound to
the *hardware* identity so it cannot be chained across freshly-registered provider
IDs (Sybil), a ceiling recomputed under the current catalog, and a mid-session
redundancy count that excludes the expiring provider itself — is a place a malicious
or merely-unlucky provider can be routed to buyers on stale or self-declared
capacity. Rather than ship that surface, v0.2.2 keeps the gate strict for buyer routing and gives the
**operator** the levers and sandbox visibility:

- **No buyer-routable admission without verified evidence, regardless of redundancy** —
  no-passing-benchmark
  (`autotune_evidence_invalid`, whether a hardware shortfall, catalog staleness, or
  semantic misbinding),
  affirmative shortfall (`autotune_model_cap_exceeded`), policy-unverifiable /
  coordinator-side (`autotune_model_uncatalogued`, `autotune_gate_unavailable`) hard-close;
  evidence-absent (`autotune_evidence_required`, whether never-submitted or expired)
  connects only as `admission_sandboxed`. The coordinator never routes buyers to a
  provider it cannot currently verify can serve the tier.
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
> emits no redundancy alert). The "no automatic buyer-routable probation" posture
> matches the shipped sandbox / hard-close behavior; the below-two alert remains the Gap.

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
within that bound and, since v0.2.2 has no automatic buyer-routable probation (FR-HG5), moved
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

> **Conformance gap (§14) — a capability-gate bypass live in the shipped code (moot at runtime while the gate is disabled in the overlay, but it defeats the gate whenever enabled).** As shipped, the
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
With canary disabled (the production posture), OPoI is dormant. As of 2026-07-27 the
hello-gate (Part A) is ALSO disabled in the live overlay, and telemetry-drift observe mode is
the only live element of this spec.

## Config surface and reload contract

**FR-CFG1 — Config surface.** Under `proof_of_weights.*`:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `require_autotune_hello_gate` | bool | `false` (**explicitly false in the live overlay as of 2026-07-27; see §1**) | Master switch for Part A. |
| `autotune_evidence_ttl_days` | int | `30` | Admission-reuse freshness window (cutoff = `now − ttl`; **raising** relaxes, **lowering** tightens); `>0` required when gate or drift enabled. |
| `telemetry_drift.enabled` | bool | `false` | Master switch for Part C. |
| `telemetry_drift.tps_ratio_threshold` | float | `0.70` | (0,1]; TPS-below-baseline trigger. |
| `telemetry_drift.tps_min_absolute` | float | `5.0` | absolute TPS floor. |
| `telemetry_drift.tps_min_requests_window` | int | `2` | min requests before TPS drift evaluated. |
| `telemetry_drift.hash_alert_on_status` | []string | `[hash_mismatch, hash_invalid]` | model-hash statuses that alert. |
| `telemetry_drift.hash_alert_on_artifact_drift` | bool | `true` | alert on artifact drift. |
| `telemetry_drift.opoi_pass_rate_window` | int | `10` | OPoI rolling window; `>0` requires `canary_enabled` **when `telemetry_drift.enabled`** (the coupling is validated only then — the shipped default of drift-disabled + window 10 + canary-disabled is valid). |
| `telemetry_drift.opoi_pass_rate_threshold` | float | `0.80` | OPoI pass-rate alert threshold. |
| `telemetry_drift.alert_cooldown_s` | int | `900` | per-signal alert cooldown. |

**FR-CFG2 — Reload without restart.** All of Part A/B/C config MUST be operator-mutable
**without a coordinator restart** (SIGHUP allowlist extension or an authenticated
operator tuning path). SIGHUP reloads MUST cover `require_autotune_hello_gate`,
`autotune_evidence_ttl_days`, and the `telemetry_drift.*` keys alongside the existing
Tier-2, rewards/billing flags, settlement config, USD-conversion config, and routing
model-class reload surface. A reload that would enable the hello-gate or telemetry
drift without the required autotune catalog/evidence-store dependencies MUST be
rejected without publishing partial state. Since the hello-gate is a
**money-path/availability gate on a single-provider-fragile pool whenever enabled**
(disabled in the live overlay as of 2026-07-27), changing it (e.g. to relax evidence
requirements during a redundancy emergency, or to enable/disable the gate) MUST NOT
force the restart-outage class that SPEC-031 FR-CAN26 addresses and that caused the
2026-07-10 ~5h outage.

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
sessions keep serving during an unbounded scan does not satisfy this. The current
implementation satisfies this with a monotonic proof-of-weights generation,
pre-publication route quarantine, bounded revalidation, sandboxing for sessions that
lack an admitted verified tuple, fail-closed stale-evidence handling on lookup errors,
and a runtime telemetry-drift evaluator swap.

## Conformance status (§14)

| FR | Status | Note |
|----|--------|------|
| FR-HG1 gate activation/ordering | Implemented | `checkAutotuneHelloGate`; both paths; pre-admission; v2 two-phase (pre-challenge + post-proof) recheck. |
| FR-HG2 evidence lookup | **Partial** | `LatestVerified(providerID, ttl)` + TTL + grants ship. Binds evidence to the provider **credential/ID**, not live session hardware (hello carries no chip/identity hash) — a limitation (item-10's to strengthen). The benchmark result is authenticated + trust-bound, **not cryptographically signed** (only the catalog is signed). |
| FR-HG3 capacity ceiling (resolution) | Implemented | `ResolveMaxAdmission` / `benchmarkPassesGate` resolve the ceiling correctly at hello. (Enforcement on the *served* model is FR-HG7.) |
| FR-HG4 close-reason taxonomy + classification | **Tightens** | The five reasons ship; the evidence-absent / no-passing-benchmark (affirmative-shortfall, catalog-staleness, **or** semantic-misbinding) / policy-unverifiable classification is new (esp. `evidence_invalid` and `uncatalogued` as NOT probation-eligible). |
| FR-HG5 redundancy alert; no auto-probation | **Gap (alert)** | The below-two operator redundancy alert is unimplemented. No automatic buyer-routable probation ships: evidence-absent providers may connect only as `AdmissionSandboxed`, which is not routing-eligible / serving-capable and does not mint a new durable provider credential; it remains subject to provisional admission/session limits. Auto-probation is deferred with its full constraint set. |
| FR-HG6 bounded mid-session expiry recheck | **Partial** | When `require_autotune_hello_gate:true`, the 30s trust-revalidation sweep now re-checks live autotune evidence TTL for admitted sessions with observed caps and route-excludes stale / tuple-mismatched / invalid rechecks. Proactive refresh remains forward work; config hot-reload re-gating is covered by FR-CFG2. |
| **FR-HG7 ceiling enforced on model transition** | Implemented | When `require_autotune_hello_gate:true`, `Provider.AdmissionCeilingExcluded` is set on heartbeat from the signed admission catalog verdict and is consumed by `RoutingEligible` / `ServingCapable`, including over-ceiling and uncatalogued heartbeat targets. Gate-off deployments remain observe-only. |
| FR-PW1 OPoI non-binding labeling | **Tightens** | Go source already says liveness-only; this makes it a normative repo-wide prohibition on weight-claims. Reconciled in this change: the `server.go` OPoI comment and the `proof-of-weights-implementation.md` runbook's "anti-downgrade" claims (both docs/comment-only). |
| FR-PW2 OPoI flag observability-only | Implemented | Zero routing/tiering/degrade/payout readers **and** already exposed as `model_class_opoi_pass` on the operator-auth `/poolz` surface. Not dead state. |
| FR-PW3 real proof-of-weights definition | **Gap (forward)** | No weight-binding test exists; deferred. |
| FR-TD1 pow-heuristic alert-only + preserve SPEC-008 hash routing | Implemented | pow.Evaluator is WARN-only. `EvaluateHeartbeat` (TPS, `hash_status`, artifact drift) requires verified evidence; `RecordModelClassCanary` (OPoI pass-rate) needs **no** evidence lookup. The pow WARN is distinct from SPEC-008's `hash_mismatch`/`hash_invalid` routing exclusion, which is independent and enforced by buyer routing. |
| FR-TD2 OPoI↔canary coupling | Implemented | `opoi_pass_rate_window>0` requires `canary_enabled`, validated when `telemetry_drift.enabled`. |
| FR-CFG1 config surface | Implemented | `ProofOfWeightsConfig` + validation. |
| FR-CFG2 reload without restart + existing-session re-eval | Implemented | SIGHUP reloads `proof_of_weights.*` with dependency validation, monotonic proof generation, telemetry-drift evaluator swap, pre-publication route quarantine, bounded revalidation, sandboxing for unverified live sessions, fail-closed stale-evidence handling, and clearing of gate exclusions on disable for sessions that have credential authority. Sandbox-only/no-credential sessions are not auto-promoted by gate-disable reload. |

**Re-enable / hardening bar.** FR-HG7's model-transition bypass is closed in
v0.2.1 and FR-CFG2's no-restart tuning / existing-session re-eval is closed in
v0.2.2. Remaining hardening priorities are the redundancy levers — **FR-HG5**
below-two alert — and the remaining **FR-HG6** proactive refresh pieces.
v0.2.2 deliberately ships **no** automatic buyer-routable probationary admission;
that mechanism is deferred behind the full
constraint set in FR-HG5. OPoI / telemetry-drift remain observability-only until
a weight-binding test (FR-PW3) exists; they MUST NOT be wired to routing/sanction
before then, and SPEC-008's authoritative hash routing exclusion MUST NOT be
weakened (FR-TD1).

## Acceptance criteria

Testable against the current build:

- **AC-1.** With `require_autotune_hello_gate: true` and no verified in-window
  evidence, a connecting provider receives admission only as `admission_sandboxed`;
  it is not routing-eligible, not serving-capable, and cannot receive buyer traffic.
- **AC-1a (gate no-op).** With `require_autotune_hello_gate: false`, a provider with no
  evidence is admitted (the gate is a no-op).
- **AC-1b (both paths).** The gate is enforced on **both** the composed-auth (v2) and
  legacy admission paths, for provisional and pinned tiers.
- **AC-1c (v2 TOCTOU).** On the composed-auth path, evidence that is valid at the
  pre-challenge check but disappears/expires before the post-proof check causes the
  provider to be admitted only as `admission_sandboxed` — both checks are enforced,
  and the post-proof result determines buyer routing authority.
- **AC-2.** With verified evidence whose capacity ceiling is below the claimed model's
  `MinRAMGB`, the provider is closed `autotune_model_cap_exceeded`.
- **AC-3.** A claimed model absent from the catalog closes `autotune_model_uncatalogued`.
- **AC-3b.** Evidence that is present but for which **no benchmark passes** the current
  gate — every benchmark thermally throttled, **or** a catalog/model/artifact-SHA
  mismatch under the current catalog — closes `autotune_evidence_invalid`
  (hardware-shortfall, catalog-staleness, and semantic-misbinding sub-cases all map to
  this reason). Per AC-10 (#687), a benchmark below the advisory
  `bench_gate.min_sustained_tps` or above `bench_gate.max_4k_ttft_ms` does **not** by
  itself make the gate fail — the advisory `bench_gate` is not an admission veto. A
  single *passing* benchmark prevents
  `evidence_invalid` — it establishes a ceiling — but admission may **still** be refused
  as `autotune_model_cap_exceeded` or `autotune_model_uncatalogued` if the *claimed*
  model exceeds that ceiling or is uncatalogued.
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
- **AC-10 (#687 — advisory bench_gate is not an admission veto).** With
  `require_autotune_hello_gate: true`, a provider whose submitted benchmark is below
  the catalog row's advisory `bench_gate.min_sustained_tps` or above its
  `bench_gate.max_4k_ttft_ms` (including when that row is `omlx_seeded`) is **not**
  closed `autotune_evidence_invalid` on that basis and is **not** excluded from the
  capacity ceiling on that basis; the ceiling and admission decision use only
  hardware/identity predicates (thermal, catalog-SHA / model-id / artifact-SHA match)
  and `MinRAMGB`. Only a thermal-throttle, policy-staleness (SHA/model/artifact
  mismatch), semantic-misbinding, `cap_exceeded`, or `uncatalogued` condition drives a
  non-admission — never an advisory TPS/TTFT shortfall.

Implemented hardening criteria:

- **AC-F1 (FR-HG7, CRITICAL).** With `require_autotune_hello_gate:true`, a provider that passes hello on a small model and then
  heartbeat-switches to a model whose `MinRAMGB` exceeds its verified ceiling is **not**
  routing-eligible for the larger model.
- **AC-F2 (FR-HG7, CRITICAL — uncatalogued).** With `require_autotune_hello_gate:true`, a provider that heartbeat-switches to an
  **uncatalogued** model is **not** routing-eligible for that model (an uncatalogued
  target does not pass by default for lack of a `MinRAMGB` to compare).
- **AC-F4 (FR-HG6).** With `require_autotune_hello_gate:true`, an admitted provider whose evidence crosses the TTL mid-session is
  re-gated within the defined bound (the 30s trust-revalidation sweep) and moved
  non-routable, and does not serve past that bound on expired evidence; it
  is not hard-killed mid-request. This criterion now passes for stale /
  tuple-mismatched evidence revalidation and for config hot-reload interactions;
  proactive refresh remains forward work.
- **AC-F5 (FR-CFG2).** `require_autotune_hello_gate`, **`autotune_evidence_ttl_days`**,
  and the `telemetry_drift.*` keys can be changed without a coordinator restart. The TTL
  direction is correct: **raising** `autotune_evidence_ttl_days` admits older-but-verified
  evidence (relaxes the gate) and **lowering** it rejects more evidence (tightens). Enabling
  the gate re-gates already-admitted sessions **atomically and fail-closed** — affected
  sessions are quarantined non-routable at/before the new config generation is published,
  the scan completes within a bound, an evidence-lookup error leaves a session
  non-routable, unverified live sessions are parked as `AdmissionSandboxed`, and only
  passers are restored. Disabling the gate clears proof-of-weights gate exclusions
  for sessions that have credential authority; sandbox-only/no-credential
  sessions remain sandboxed until reconnect or verified re-gating.

Remaining forward criteria (expected to FAIL against the current build; §14 Gap rows):
- **AC-F3 (FR-HG5).** A gate action that leaves a model's admitted routing-eligible
  count below two emits a distinct operator redundancy alert — covering **both** an
  eligibility loss that drops below two **and** rejecting a second provider while the
  model is already at or below one (a sustained below-two *state*, not only a downward
  transition) — **only** for a catalogued demand-bearing model, **deduplicated per
  episode** (one alert while below two, re-armed on recovery to ≥2) **and
  cooldown-bounded** (a provider spamming random `model_id` claims cannot flood it); and
  no rejection of any class — including `autotune_gate_unavailable` — is auto-admitted
  to buyer routing (v0.2.2 has no buyer-routable probationary path).
- **AC-F6 (FR-PW3).** A mechanism is labeled "proof-of-weights" only if it binds output
  to the admitted weights (statistical/distributional or cryptographic attestation);
  the current nonce-echo OPoI does not qualify and is not so labeled.

## Production posture (2026-07-11 baseline; superseded — see 2026-07-27 below)

Read-only Pearl check at the 2026-07-11 baseline
(`/etc/macprovider/coordinator.pearl-overlays.yaml`):

- **Hello-gate: ENABLED at that time** (`require_autotune_hello_gate: true`,
  `autotune_evidence_ttl_days: 30`). It is what closed the intended second
  provider in incident #2. Prod was **`pool_size: 1`** — the single-provider
  fragility was a **live** condition, not hypothetical.

**2026-07-27 posture (#769, verified against the running process):** the same
overlay now sets `require_autotune_hello_gate: false` (flipped by the
2026-07-22 overlay revision), `pool.canary_enabled: false` explicitly, and
`telemetry_drift.enabled: true` (observe mode — so the #764/#765
`missing_benchmark` observe alerts ARE live; the #765 quarantine stays dormant
behind the absent `quarantine_missing_benchmark`). Full snapshot + drift notes:
`ops/runbooks/seam-769-gate-posture-2026-07-27.md`.
- **OPoI/canary: DISABLED** (`canary_enabled: false`, `opoi_pass_rate_window: 0`) — OPoI
  is dormant; Part B (OPoI/canary) is specced-but-inactive, and Part C
  telemetry-drift is live in OBSERVE mode only (heartbeat TPS/hash alerts;
  no enforcement).
- The `telemetry_drift` block is present in the overlay; with the OPoI window at 0 and
  canary disabled, the OPoI pass-rate path is inactive (TPS/hash drift may evaluate at
  heartbeat but is alert-only regardless — FR-TD1).

FR-HG7's ceiling predicate now exists but is dormant in the 2026-07-27
gate-off production posture; re-enabling the hello gate makes it load-bearing.
The remaining highest-value follow-ups are FR-HG5 and the rest of FR-HG6. The
single-provider fragility's remedy is chiefly
**operational** (acquire and verify a second provider for the tier), surfaced by the
FR-HG5 below-two alert and made safely tunable by FR-CFG2; it is **not** solved by
auto-admitting an unverified provider (the recorded `air5` was never-verified and a
smaller box), which is why v0.2.2 ships no automatic buyer-routable probation.

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

- **v0.2.5-draft (2026-08-02, #687 r5)** — Admission matches the catalog
  admission-policy digest, not the full catalog SHA. Added a normative FR-HG3
  requirement that every "catalog-SHA" admission / ceiling-resolution / FR-HG4
  policy-staleness match uses SPEC-023 §3.6 `admission_policy_sha256` (which
  excludes advisory `bench_gate.min_sustained_tps`/`max_4k_ttft_ms`/`provenance`/
  `gate_seed`), NOT the full `candidate_catalog_sha256`. Resolves the
  self-contradiction between the r4 "admission identity excludes advisory bench_gate"
  rule and admission matching on the full catalog hash; also stops non-oMLX advisory
  edits from invalidating verified admission. Docs-only; digest computation is
  SPEC-023 §12.2(b)(i) Stage-2 work.

- **v0.2.4-draft (2026-08-02, #687 r4)** — Separate admission identity (Stage-2
  prerequisite). Added a normative requirement to FR-HG3 that the hello-gate's
  admission identity / verified-evidence match MUST NOT include the advisory
  `bench_gate.min_sustained_tps` / `max_4k_ttft_ms`, `bench_gate.provenance`, or
  `bench_gate.gate_seed`; when the SPEC-023 oMLX schema activates (SPEC-023 §12.2
  activation gate, condition (b)(i)) the Stage-2 implementation MUST provide a separate
  admission identity reading only hardware/identity predicates and `MinRAMGB`.
  Docs-only; no code touched.

- **v0.2.3-draft (2026-08-02, #687)** — Advisory bench_gate is never an admission
  veto. Amended FR-HG3 and FR-HG4 so the hello-gate MUST NOT resolve the capacity
  ceiling on, reject on, or close `autotune_evidence_invalid` on the advisory
  `bench_gate.min_sustained_tps` / `bench_gate.max_4k_ttft_ms`. SPEC-023 §5/§12 defines
  those fields as advisory drift targets (never a veto); a catalog row's `bench_gate`
  may be `omlx_seeded` from unattested oMLX community data, and the #687 trust invariant
  forbids unattested oMLX data from hard-blocking a provider or setting/holding an
  admission gate. The ceiling now resolves from hardware/identity predicates (no
  thermal throttle, catalog-SHA / model-id / artifact-SHA match) and `MinRAMGB` only.
  Any hard **performance** admission gate MUST be a separate catalog field backed by
  trusted-provider (verified-provider-matrix) evidence, distinct from the advisory
  `bench_gate`; that separate-field mechanism is deferred to a later stage. Added AC-10.

- **v0.2.2-draft (2026-07-29, B5)** — Hello-gate sandbox and reload implementation
  reconciliation. When `require_autotune_hello_gate:true`, missing verified
  evidence now connects the provider only as `AdmissionSandboxed`: visible for
  operators and internal/synthetic probes, but excluded from buyer routing and
  buyer-serving capacity or durable credential minting, while still consuming normal
  provisional admission/session limits. Affirmative invalid evidence, uncatalogued models,
  capacity exceedance, and dependency/lookup failures still hard-close. SIGHUP
  now reloads `proof_of_weights.*` with dependency validation, a monotonic proof
  generation, pre-publication route quarantine, bounded revalidation, fail-closed
  stale-evidence handling, telemetry-drift evaluator swap, clearing of gate
  exclusions for credential-authorized sessions when the gate is disabled,
  and no auto-promotion of sandbox-only/no-credential sessions. Remaining gaps:
  FR-HG5 below-two operator
  alert, FR-HG6 proactive refresh, and future real proof-of-weights.

- **v0.2.1-draft (2026-07-29, B2)** — Ceiling enforcement implementation
  reconciliation. When `require_autotune_hello_gate:true`, heartbeat model
  transitions now route-exclude providers whose current served model is
  uncatalogued or whose catalog `MinRAMGB` exceeds the admitted verified
  ceiling. Gate-off deployments remain observe-only. The flag is consumed by both buyer routing
  eligibility and buyer-serving capacity so a sole provider cannot be kept
  routable by the canary floor. The 30s trust-revalidation sweep also checks
  autotune evidence TTL and tuple binding for capped sessions and route-excludes
  stale or mismatched evidence without hard-killing mid-request. Remaining gaps:
  FR-HG5 below-two operator alert, FR-CFG2 hot reload / atomic re-gating, and
  future real proof-of-weights.

- **v0.2-draft (2026-07-27, epic #770 / #769)** — Prod-posture reconciliation.
  Corrected the "true in the Pearl production overlay" claims (five sites: §1
  prose, numbering note, FR-HG1, config table, production-posture section):
  the RUNNING process loads `--config-overlay
  /etc/macprovider/coordinator.pearl-overlays.yaml`, and that overlay
  EXPLICITLY sets `require_autotune_hello_gate: false` (revised 2026-07-22;
  the v0.1 claim was accurate at its 2026-07-11 baseline and drifted since).
  Related live posture recorded the same day: `pool.canary_enabled: false`
  explicit in the overlay AND the canary-buyer timer inactive with the
  DISABLED sentinel (the accepted P0 #584 exception);
  `telemetry_drift.enabled: true` live (observe mode — #764/#765
  missing_benchmark observe alerts fire; quarantine stays dormant);
  `warmup_gate_enabled` false live vs true committed Pearl template at capture
  time; #784 aligned the checked-in Pearl deploy templates to match Pearl's
  false posture while leaving the generic SPEC-002/code default unchanged, with
  the original capture preserved in
  `ops/runbooks/seam-769-gate-posture-2026-07-27.md`.
  Sticky routing IS enabled live; the same-account timing-side-channel
  risk-acceptance note required by #769 lives in the same runbook.

- **v0.1-draft (2026-07-11):** Initial reconstructed baseline (runbook item 9, Wave C).
  Verify-before-design read-only Pearl check established that the **hello-gate was live at the 2026-07-11 baseline (flipped off by the 2026-07-22 overlay revision — see v0.2)
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
  - **R5 codex three-lane audit** — **security PASS (0 C/H/M)**; code 0C/0H/3M,
    architect 0C/1H/3M (all docs/consistency, no design change). Absorbed:
    - **HIGH (architect) — money-path:** the `opoi-challenge-implementation.md` runbook
      still called itself the "interim normative source" and directed a **credit/payout
      multiplier** off OPoI pass-streaks — a direct violation of FR-PW2 (OPoI must never
      gate payout). Marked the runbook **superseded by SPEC-032** and the multiplier
      phase **deferred/void** until an FR-PW3 weight-bound signal exists. Also superseded
      `proof-of-weights-implementation.md` (stale close-reason names) with a banner.
    - **MEDIUM (code):** FR-HG4 gained a **third** `evidence_invalid` cause — provider
      **semantic misbinding** (the verifier trusts syntactic/hardware bindings but does
      not value-check model-id/artifact against the signed catalog; the gate does).
    - **MEDIUM (code):** AC-3b corrected — `evidence_invalid` requires **no** benchmark
      to pass (a single passing benchmark still establishes a ceiling and admits).
    - **MEDIUM (code):** FR-PW1 repo-wide honesty — fixed the staging overlay comment
      (`coordinator.opoi-v0-staging.yaml`) that claimed nonce challenges "prove the
      provider is running the declared model".
    - **MEDIUM (architect):** FR-CFG1 opoi/canary coupling cell qualified with "when
      `telemetry_drift.enabled`"; FR-HG1 gained acceptance locks (AC-1a no-op, AC-1b
      both paths, AC-1c v2 two-phase TOCTOU).
  - **R6 codex two-lane audit** (security already PASS; code 0C/0H/2M, architect
    0C/0H/1M — pure consistency, no design/behavior change). Absorbed: propagated the
    third `evidence_invalid` cause (**semantic misbinding**) to the three summaries that
    still listed only two (§3 terminology, FR-HG5 inventory, §14 row); and corrected
    AC-3b — a single passing benchmark prevents `evidence_invalid` but admission can
    **still** be refused as `cap_exceeded`/`uncatalogued` if the *claimed* model exceeds
    the ceiling.
  - **R7 codex two-lane audit** (code 0C/0H/1M, architect 0C/0H/1M — terminology
    precision only). Broadened the semantic-misbinding description to any
    provider-submitted binding the gate value-checks against the signed catalog
    (`model_key`, model-id, artifact-SHA, catalog-SHA — distinct from a genuine catalog
    rotation), in §3/FR-HG4/prose; and widened the Part C / telemetry-drift scope
    summaries (§2/§3) to include the OPoI pass-rate `RecordModelClassCanary` entry point
    alongside the heartbeat TPS/hash/artifact signals.
