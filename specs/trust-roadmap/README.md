# Trust-Minimized Benchmark & Catalog — Roadmap Pieces

Each file in this directory is **one independently shippable piece** of work,
written to stand alone as a GitHub issue. They came out of the audit in
[`RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md`](RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md)
(the analysis and evidence live there; the pieces live here).

**Re-verified 2026-07-28** against `origin/main` @ `51a60c23` (17 commits past the
`8a39c636` base the roadmap was built on) — see
[VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). No piece is obsolete;
A2 shrank (its SPEC-032 item shipped in #769), A8 widened to 3 rows, A4/B4
changed shape, and line refs were refreshed.

**Implementation status updated 2026-07-29** against `origin/main` @
`fa163090`. Plane A is complete. G0 has live Pearl DB findings recorded in
[G0-measure-demand.md](G0-measure-demand.md). Plane C is partially complete:
B1, B2, B5, B6, and B10 are implemented; B3, B4, B7, B8, and B9 remain
deferred.

Why split: four review rounds never drove the single bundled roadmap to zero
findings because the *bundle* was the defect — it coupled cheap independent
fixes with a large speculative trust subsystem resting on buyer-traffic volume
nobody has measured. These pieces are the fix: each rests only on what already
exists, has an explicit boundary, and is auditable on its own.

## Ship-now pieces (commit to these; each its own issue/PR)

| Piece | Title | Size | Status |
|---|---|---|---|
| [A1](A1-overclaim-remediation.md) | Overclaim remediation (README + SDK doc) | S | Complete: `01e1585d` |
| [A2](A2-spec-doc-drift.md) | Spec/doc drift reconciliation | S | Complete: `c5b65673` |
| [A3](A3-coordinator-swap-veto.md) | Coordinator-side swap veto | S | Complete: PR #801, `66fec87f` |
| [A4](A4-inband-signed-provenance.md) | In-band signed catalog provenance | S | Complete: PR #807, `acd2a0b6` |
| [A5](A5-ceiling-drift-detection.md) | Ceiling-drift detection (observe-mode) | M | Complete: PR #803, `cbecaa37` |
| [A6](A6-transcript-label-honesty.md) | Transcript / stats-label honesty | S-M | Complete: PR #805, `ff5471c7` |
| [A7](A7-bind-signed-model-hash.md) | Bind the already-signed model hash | S | Complete: PR #806, `1fdf68d8` |
| [A8](A8-spec023-catalog-reconcile.md) | Reconcile SPEC-023 vs live signed catalog | S | Complete: `2dac46fb` |

A2/A4/A8 were coordinated through the SPEC-023 update stream and are now
complete.

## The gate

| Gate | Title | Status |
|---|---|---|
| [G0](G0-measure-demand.md) | Measure buyer demand per (provider, model, bucket) | Complete: `c9749d00` |

G0 was run against the live Pearl coordinator DB. It was positive for aggregate
live-network demand, but negative for broad per-bucket observed-performance
authority at current demand. Result: keep B3/B4/B8 deferred for broad routing
or promotion authority; narrow high-fill buckets may support observe-mode
analysis only.

## Deferred design briefs (each a FUTURE separate SPEC + its own audit loop)

Not commitments — analysis of the shape each future SPEC must take. Do not
build any until it has passed its own three-lane SPEC-audit loop.

| Brief | Title | Status |
|---|---|---|
| [B1](B1-persist-ttft-decode-columns.md) | Persist per-request TTFT/decode columns | Complete: PR #809, `6a493c8b` |
| [B2](B2-ceiling-enforcement.md) | Ceiling enforcement (routing exclusion) | Complete: PR #810, `af3064e6` |
| [B3](B3-observed-throughput-routing.md) | Rank routing on observed throughput | Deferred: B1 complete, but G0 says broad per-bucket authority is still too thin |
| [B4](B4-probationary-admission.md) | Probationary admission | Deferred: G0 broad-negative plus pricing/settlement design still unresolved |
| [B5](B5-hello-gate-sandbox.md) | Hello-gate-on, no-buyer-traffic sandbox | Complete: PR #811, `436642b8` |
| [B6](B6-registration-wash.md) | Close the identity re-registration wash | Complete: PR #812, `2cd5bd7f` |
| [B7](B7-gate-rederivation.md) | Catalog gate re-derivation tooling | Deferred: needs ≥3 verified providers / #584 hardware |
| [B8](B8-observed-drift.md) | Observed data into drift detection | Deferred: B1 complete, but G0 says broad per-bucket authority is still too thin |
| [B9](B9-compute-integrity.md) | SPEC-036 compute-integrity (observe) | Deferred: post-beta |
| [B10](B10-sign-rate-card.md) | Sign the rate card | Complete: PR #813, `00f22860`; status note at `fa163090` |

## The committed minimum, if nothing else ships (~12-20 operator hours)

Complete: **A1** + **A5** + **G0** have shipped or been recorded. The remaining
speculative observed-performance work waits on higher per-bucket demand or a
narrow observe-only design.
