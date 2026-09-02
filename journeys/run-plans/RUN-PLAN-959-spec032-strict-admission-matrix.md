# RUN-PLAN-959 — SPEC-032 strict admission-gate evidence matrix

Issue: https://github.com/Augustas11/macprovider/issues/959
Journey: JOURNEY-PROVIDER-PREBETA-ADMISSION
Requirements covered: SPEC-032-R001, SPEC-032-R002, SPEC-032-R003
Authority domain: hardware-evidence-admission (`requires_signed_journey_result: true`)
Status: **DRAFT run plan — satisfies AC #1; awaiting operator review + approval before any strict-gate activation**
Author: prepared for @Augustas11 review

> **Safety boundary (from the issue, restated as binding):** do NOT enable
> strict gates on Pearl production (`coordinator.malibu.tech`) or mutate an
> active production provider cohort. This run executes only against a dedicated
> **isolated canary coordinator** with its own database, host/port, and signing
> material, using a **consenting canary provider cohort**. Nothing in this plan
> is authorized to run until the operator approves this document and explicitly
> authorizes strict-gate activation on the named canary.

---

## 1. Objective and non-goals

**Objective.** Produce a redacted, recomputable evidence artifact that
independently exercises the three default-off strict admission-gate behaviors
and proves they route-exclude/sandbox only the offending provider while healthy
providers retain capacity and routing. Then, via the protected acceptance
workflow, promote **only the requirement subset that actually passed** from
`pending` to `conformant` in `specs/CONFORMANCE.json`.

**In scope:** R001 over-ceiling/uncatalogued route-exclusion; R002 stale /
tuple-mismatched evidence session-time revalidation route-exclusion; R003
evidence-absent sandbox + fail-closed config reload/revalidation.

**Non-goals (do not attempt in this run):** enabling strict gates on Pearl
production; changing the shipped production default of
`require_autotune_hello_gate` (stays `false` in prod after this run); buyer
money-path / payout / settlement proofs; catalog re-derivation; proactive
re-verification cadence (SPEC-032 §350 Gap, tracked separately).

---

## 2. Behavior under test (grounded in SPEC-032 + implementation)

| Req | Behavior | Non-admission code | Key implementation |
|---|---|---|---|
| **R001** | A heartbeat model transition to an **over-ceiling** (`MinRAMGB` > verified capacity ceiling) or **uncatalogued** model makes that provider **route-excluded** while capacity/routing state of valid providers is untouched; a heartbeat back into an in-ceiling catalogued model clears the exclusion. | `autotune_model_cap_exceeded` (over-ceiling); uncatalogued transition | `applyAdmissionCeilingRouteExclusion`, `admissionCeilingRouteVerdict`, `SetAdmissionCeilingExcluded`, `RoutingEligible`/`ServingCapable`; warmup skip via `TestWarmupGateSkipsAdmissionCeilingExcludedProvider` |
| **R002** | Session-time revalidation (**30s sweep**) route-excludes a provider whose admitted evidence has crossed the **TTL** (`autotune_evidence_ttl_days`, cutoff `now − ttl`) or no longer **tuple-matches** the admitted (`model_key`/model-id/artifact-SHA/catalog-SHA); missing admitted tuple also route-excludes. | evidence expiry; tuple mismatch; missing admitted tuple | `runAdmissionEvidenceRevalidationSweep`, `admissionEvidenceStaleVerdict`, `verifiedEvidenceMatchesAdmittedTuple`, `SetAdmissionEvidenceStale` |
| **R003** | An **evidence-absent** strict hello-gate provider connects only as `admission_sandboxed` — operator-visible/internal-probe eligible, **never routing-eligible or buyer-serving**, no newly minted durable credentials — and a **proof-of-weights config reload / revalidation** re-gates existing unverified sessions **fail-closed**. | `autotune_evidence_required` | `SetAdmissionSandboxed`, `QuarantineForProofOfWeightsReload`, `SetProofOfWeightsConfig`, `revalidateProofOfWeightsAdmissions`, `checkAutotuneHelloGateWithCatalog`, `reloadCoordinatorConfig`, `telemetryDriftEvaluatorForReload` |

The advisory `bench_gate.min_sustained_tps` / `max_4k_ttft_ms` are **never** a
rejection or ceiling-resolution input (SPEC-032 FR-HG5 / #687). The ceiling
resolves from `ResolveMaxAdmission` excluding the advisory targets. Assertions
below must confirm no exclusion is attributed to an advisory-gate value.

---

## 3. Environment

- **Coordinator:** a dedicated **isolated canary coordinator** built from the
  current release tag (git-describe clean; see release-verification runbook),
  its own Postgres/sqlite state, its own host/port, its own signing keys — **not
  `coordinator.malibu.tech`, not the Pearl production DB**. Confirm isolation by
  checking the canary reports a distinct coordinator identity and an empty/seed
  provider pool before the run.
- **Provider cohort (consenting canary Macs):**
  - `P_subject` — the provider driven through each failing transition (the
    `redastare` canary Air 8GB / macOS 26.5 is a suitable subject; see the
    canary-access memory for connection).
  - `P_control` — a **healthy** provider that submits valid in-window evidence
    for an in-ceiling catalogued model and is **left untouched** across all
    three scenarios. Its continued routing-eligibility is the AC #3 proof.
  - Optionally `P_subject2` for R002 tuple-mismatch vs. R002 expiry, to keep the
    two R002 sub-cases on distinct sessions.
- **Buyer smoke probe:** an authenticated buyer request path used only to prove
  that `P_control` still serves and `P_subject` does not, after each transition.
- **TTL for R002:** set `autotune_evidence_ttl_days` to a **short canary value**
  (e.g. an override expressed in seconds/minutes if the build supports it, else
  the smallest supported day value) so evidence expiry is observable within the
  run window without waiting 30 days. Record the exact TTL used.

---

## 4. Flags and configuration (exact keys)

Set on the **canary coordinator only**, recorded verbatim in the evidence
artifact:

| Config path | Run value | Prod default | Purpose |
|---|---|---|---|
| `autotune.require_autotune_hello_gate` | `true` | `false` | **The default-off strict gate under test.** Enabling it is the strict-gate activation this plan gates on. |
| `autotune.enforce_provider_admission` | `true` | `true` | Shared strict-mode switch (already default-on). |
| `autotune.autotune_evidence_ttl_days` | short canary value (record exact) | 30 | R002 TTL expiry observability. |
| `proof_of_weights.*` | strict/enabled per current schema | per prod | R003 reload/revalidation path. |

No other admission/routing/rate-card/pricing config is changed. The exact
`proof_of_weights` sub-keys are confirmed against the release build at run time
and recorded; do not infer them from this table.

---

## 5. Caps

- Blast radius capped to the isolated canary: **max provider pool = the named
  cohort** (`P_subject[, P_subject2]` + `P_control`); no other providers may
  join the canary during the run.
- Buyer probes are operator-authenticated smoke requests only; **no paid buyer
  traffic**, no money-path.
- Wall-clock cap on the run window; if exceeded, stop and roll back (§8/§9).

---

## 6. Scenarios (each requirement exercised independently)

Every scenario captures **before** and **after** state for: (a) pool membership
+ per-provider `RoutingEligible`/`ServingCapable`, (b) admission state + the
exact non-admission code, (c) verifier / evidence state (`LatestVerified`
verdict, admitted tuple, TTL window), (d) buyer-routing outcome for both
`P_subject` and `P_control`. `P_control` MUST remain routing-eligible and
buyer-serving in **every** scenario (AC #3).

### S1 — R001 over-ceiling / uncatalogued route-exclusion
1. Admit `P_subject` and `P_control` with valid in-window evidence for
   in-ceiling catalogued models; confirm both routing-eligible + serving.
2. Heartbeat `P_subject` a model transition to (a) an **over-ceiling** model
   (`MinRAMGB` > ceiling) → expect `autotune_model_cap_exceeded` + route-excluded;
   then (b) an **uncatalogued** model → expect route-excluded. `P_control`
   unchanged and still serving.
3. Heartbeat `P_subject` **back** into an in-ceiling catalogued model → expect
   exclusion cleared and routing restored. Confirm exclusion reason never cites
   an advisory `bench_gate` value.

### S2 — R002 stale / tuple-mismatched evidence revalidation
1. Admit `P_subject` (and `P_subject2`) with valid evidence; confirm serving.
2. **Expiry sub-case:** let `P_subject` evidence cross the TTL mid-session (using
   the short canary TTL) → the 30s revalidation sweep must route-exclude it
   (`SetAdmissionEvidenceStale`), and it must not serve at its pre-expiry ceiling
   past that bound.
3. **Tuple-mismatch sub-case:** cause `P_subject2`'s live tuple to diverge from
   its admitted tuple (`model_key`/model-id/artifact-SHA/catalog-SHA) → sweep
   route-excludes on mismatch; also confirm a **missing admitted tuple**
   route-excludes. `P_control` (valid, in-window, matching tuple) keeps serving
   throughout.

### S3 — R003 evidence-absent sandbox + fail-closed reload
1. Connect `P_subject` with **no verified evidence in-window** under the strict
   gate → expect `autotune_evidence_required`, `admission_sandboxed`:
   operator-visible, **not** routing-eligible, **not** buyer-serving, **no**
   durable provider credentials minted. Buyer probe to `P_subject` must fail
   closed; `P_control` serves.
2. Trigger a **proof-of-weights config reload / revalidation**
   (`reloadCoordinatorConfig` → `revalidateProofOfWeightsAdmissions`) with an
   existing unverified session present → expect the unverified session is
   sandboxed/quarantined (`QuarantineForProofOfWeightsReload`) and the reload
   transition **fails closed** (no window where the unverified provider becomes
   routable). `P_control` remains routable across the reload.

---

## 7. Evidence capture and redaction (AC #4)

- Artifact schema: `macprovider.provider-prebeta-admission-evidence.v1` under
  `journeys/evidence/`, `run_id` =
  `provider-prebeta-admission-spec032-strict-<hw>-<UTC>Z`, `requirement_ids` =
  the subset actually exercised and passed.
- Record all JOURNEY-PROVIDER-PREBETA-ADMISSION required capture fields:
  journey/SPEC/requirement IDs, capture timestamp, redacted operator
  fingerprint, repo commit, candidate build identity, expiry; the exact config
  flags from §4; and per-scenario before/after state from §6.
- **Redaction:** stable **correlation fingerprints** only — no secrets, no raw
  provider IDs, no raw machine identities, no buyer IPs, no tokens/keys. Use the
  same salted-fingerprint scheme as the existing redacted artifacts so a
  reviewer can correlate a provider across steps without learning its identity.
- The artifact must be **recomputable**: assertions reference captured state, not
  screenshots or prose.

---

## 8. Rollback

1. Set `autotune.require_autotune_hello_gate` back to `false` on the canary.
2. Restore `autotune_evidence_ttl_days` and `proof_of_weights.*` to their
   pre-run canary values.
3. Drain/reset the canary provider cohort; confirm the canary pool returns to
   its pre-run seed state.
4. **Pearl production is never touched**, so production rollback is N/A by
   construction — verify prod `require_autotune_hello_gate` is still `false` and
   the prod pool is unchanged as a closing check.

---

## 9. Stop conditions (abort + roll back immediately if any hold)

- `P_control` (or any valid healthy provider) is made unroutable or
  non-serving by any scenario → **collateral-exclusion failure**, stop.
- Any exclusion/sandbox is attributed to an advisory `bench_gate` value → stop
  (violates FR-HG5 / #687).
- A sandboxed/route-excluded provider is observed buyer-routable at any instant,
  including a reload transition window → stop.
- Newly minted **durable** provider credentials are issued to a sandboxed
  provider → stop.
- Any sign the run is affecting a non-canary/production surface → stop.
- Wall-clock cap exceeded → stop.

---

## 10. Promotion (AC #5)

- Only requirements whose scenario **passed** every assertion (including the
  AC #3 healthy-provider proof) are eligible.
- Promote via the **protected acceptance workflow** (`scripts/verify-acceptance-promotion.py`
  / acceptance-candidate-v1 signing), which signs a
  `*.journey-result.signed.json` covering exactly the passing subset and flips
  those `SPEC-032-RNNN` rows `pending → conformant` in `specs/CONFORMANCE.json`,
  with the `gap.verdict` updated from `UNKNOWN` to the passing verdict and the
  evidence artifact linked. A requirement that did not fully pass **stays
  pending** and is re-run; the signed result must not over-promote.
- Signing is an **operator + protected-workflow action** (this domain is
  `requires_signed_journey_result: true`); it is out of scope for any automated
  agent and is performed by the operator.

---

## 11. Dry-run rehearsal (de-risk before the physical run)

Before the physical canary run, an **isolated in-process acceptance harness**
(`test/integration/`) exercises S1–S3 against an ephemeral strict-gated
coordinator with synthetic providers, emitting a **draft** v1 evidence artifact
marked `"result.class": "dry-run"` / not-for-promotion. This validates the
scenario logic, the assertion set, the healthy-control invariant, and the
evidence schema/redaction **without any physical Mac or production surface**. A
green dry-run is a precondition for requesting operator approval of the physical
run, but is **explicitly not** promoting evidence (a test is not the redacted
physical artifact the conformance contract requires).

---

## 12. Operator sign-off checklist (AC #1 closure)

- [ ] Environment confirmed isolated canary (identity + empty seed pool), not Pearl prod.
- [ ] Exact `proof_of_weights.*` sub-keys and canary TTL value recorded.
- [ ] Consenting canary cohort named; `P_control` designated.
- [ ] Caps, rollback, and stop conditions accepted.
- [ ] Dry-run rehearsal green.
- [ ] Strict-gate activation on the named canary explicitly authorized.
