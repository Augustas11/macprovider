# CODE AUDIT — Rate-card v4 pivot PR 1 R1

Scope: current working tree on `fix/rate-card-v4-pr1`, compared against `origin/main`.

Note: `git diff origin/main...HEAD` is empty because the PR 1 implementation is currently uncommitted. Per the task instruction, this audit reviewed the working tree diff against `origin/main`.

Reviewed in-scope files:

- `beta/DECISION_CRITERIA.md`
- `phase4-coordinator/dist/coordinator.yaml`

Anti-scope check:

- No working-tree diff under `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- No working-tree diff under `test/network-harness/**`
- No working-tree diff under `specs/SPEC-023-installer-autotune-recommend.md`
- No working-tree diff under billing formula, gateway, buyer, coordinator auth, or request-log paths

Validation evidence:

- `git diff --name-status origin/main --` shows only `beta/DECISION_CRITERIA.md` and `phase4-coordinator/dist/coordinator.yaml`.
- `git diff --check origin/main -- beta/DECISION_CRITERIA.md phase4-coordinator/dist/coordinator.yaml` passed with no whitespace/errors.
- Parsed `phase4-coordinator/dist/coordinator.yaml` with PyYAML and verified `rewards.rate_card["nemotron-3-nano-30b-a3b"]` equals:
  - `prompt_credits_per_mtok: 80000`
  - `prompt_cache_hit_credits_per_mtok: 20000`
  - `completion_credits_per_mtok: 160000`

## Findings

No findings.

## Contract Trace

- `beta/DECISION_CRITERIA.md:423` documents the old hourly-net model, the 2026-07-06 sku-econ harness finding, the pivot to per-token payout recommendation semantics, nemotron `$0.235/M -> $0.160/M`, and PR #419 starter-tier supersession in follow-up PR 2.
- `phase4-coordinator/dist/coordinator.yaml:175` keeps the normalized nemotron billing key.
- `phase4-coordinator/dist/coordinator.yaml:176` sets prompt credits to `80000`.
- `phase4-coordinator/dist/coordinator.yaml:177` sets prompt-cache-hit credits to `20000`.
- `phase4-coordinator/dist/coordinator.yaml:178` sets completion credits to `160000`.

STATUS: CODE lane — CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0
