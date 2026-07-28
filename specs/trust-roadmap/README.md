# Trust-Minimized Benchmark & Catalog — Roadmap Pieces

Each file in this directory is **one independently shippable piece** of work,
written to stand alone as a GitHub issue. They came out of the audit in
[`../RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md`](../RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md)
(the analysis and evidence live there; the pieces live here).

**Re-verified 2026-07-28** against `origin/main` @ `51a60c23` (17 commits past the
`8a39c636` base the roadmap was built on) — see
[VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). No piece is obsolete;
A2 shrank (its SPEC-032 item shipped in #769), A8 widened to 3 rows, A4/B4
changed shape, and line refs were refreshed.

Why split: four review rounds never drove the single bundled roadmap to zero
findings because the *bundle* was the defect — it coupled cheap independent
fixes with a large speculative trust subsystem resting on buyer-traffic volume
nobody has measured. These pieces are the fix: each rests only on what already
exists, has an explicit boundary, and is auditable on its own.

## Ship-now pieces (commit to these; each its own issue/PR)

| Piece | Title | Size | Depends on |
|---|---|---|---|
| [A1](A1-overclaim-remediation.md) | Overclaim remediation (README + SDK doc) | S | — |
| [A2](A2-spec-doc-drift.md) | Spec/doc drift reconciliation | S | — |
| [A3](A3-coordinator-swap-veto.md) | Coordinator-side swap veto | S | — |
| [A4](A4-inband-signed-provenance.md) | In-band signed catalog provenance | S | — |
| [A5](A5-ceiling-drift-detection.md) | Ceiling-drift detection (observe-mode) | M | — |
| [A6](A6-transcript-label-honesty.md) | Transcript / stats-label honesty | S-M | — |
| [A7](A7-bind-signed-model-hash.md) | Bind the already-signed model hash | S | — |
| [A8](A8-spec023-catalog-reconcile.md) | Reconcile SPEC-023 vs live signed catalog | S | — |

A2/A4/A8 all edit the LOCKED `SPEC-023` — coordinate those PRs (one unlock/version bump).

## The gate

| Gate | Title | Size |
|---|---|---|
| [G0](G0-measure-demand.md) | Measure buyer demand per (provider, model, bucket) | XS |

G0 produces the one number that decides whether the observed-performance work
(B3/B4/B8) is executable at all. **If G0 comes back thin**: shelve B3/B4/B8,
keep operator-approved identity + the A-piece hardening as the trust basis,
hold model upgrades to the operator-grant path, revisit at higher demand.

## Deferred design briefs (each a FUTURE separate SPEC + its own audit loop)

Not commitments — analysis of the shape each future SPEC must take. Do not
build any until it has passed its own three-lane SPEC-audit loop.

| Brief | Title | Gated on |
|---|---|---|
| [B1](B1-persist-ttft-decode-columns.md) | Persist per-request TTFT/decode columns | SPEC-002 amendment |
| [B2](B2-ceiling-enforcement.md) | Ceiling enforcement (routing exclusion) | its own SPEC |
| [B3](B3-observed-throughput-routing.md) | Rank routing on observed throughput | G0 + B1 |
| [B4](B4-probationary-admission.md) | Probationary admission | G0 + a pricing/settlement design |
| [B5](B5-hello-gate-sandbox.md) | Hello-gate-on, no-buyer-traffic sandbox | B2 |
| [B6](B6-registration-wash.md) | Close the identity re-registration wash | a registration-policy decision |
| [B7](B7-gate-rederivation.md) | Catalog gate re-derivation tooling | ≥3 verified providers / #584 |
| [B8](B8-observed-drift.md) | Observed data into drift detection | G0 + B1 |
| [B9](B9-compute-integrity.md) | SPEC-036 compute-integrity (observe) | post-beta |
| [B10](B10-sign-rate-card.md) | Sign the rate card | a signing-mechanism choice |

## The committed minimum, if nothing else ships (~12-20 operator hours)

**A1** (fixes a live buyer-facing normative violation) + **A5** (surfaces the one
genuine near-term hazard) + **G0** (the decision unlock). Everything speculative
waits on G0's number.
