# SPEC-023 v0.4 Round 1 Audit

Date: 2026-07-06
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md` (v0.4)
Scope: post-implementation convergence audit for the rate-card v4 pivot (PR #429). Three-lane Codex prompts were not re-fired for the combined PR 2–3 engine/harness diff; this record captures operator verification against the locked v0.4 contract.

## Result

Round 1 passed for the shipped v0.4 amendment scope.

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 0 | 0 | Ready (operator verified) |
| security | 0 | 0 | 0 | 0 | Ready (PR1 lane artifacts) |
| architect | 0 | 0 | 0 | 0 | Ready (PR1 lane artifacts) |

## Closure evidence

Code / contract:

- SPEC-023 v0.4 changelog matches `AutotuneRecommendEngine` scoring: `demand_weight × completion_rate_per_mtok × sustained_tps`; no `paidThreshold`, starter tier, hourly fields, or electricity/utilization inputs in JSON output.
- PR #429 merged to `main` at `c837491`; Swift autotune tests pass in CI.
- Live sku-econ harness (`11_sku_earn_viability-20260706T112145Z`): all 9 I5 invariants passed under `at_least_one_eligible_row` / `donor_only_by_ram`.
- Pearl deploy verified nemotron `completion_rate_per_mtok=160000`.

Security / architecture (carried from PR1 three-lane audits):

- `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PR1_r1_code-audit.md` — PASS
- `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PR1_r1_security-audit.md` — PASS
- `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PR1_r2_architect-audit.md` — PASS

## Open follow-up (not v0.4 audit blockers)

- M-Base-lite (8 GB / 16 GB) Macs receive `no_eligible_model` because catalog `min_ram_gb` floors exceed `ram_gb - 4`; tracked under Entry 116 catalog expansion, not a v0.4 scoring regression.
