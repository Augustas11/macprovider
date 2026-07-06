# Architect Audit - Rate-card v4 Pivot PR 1

Scope note: `git diff origin/main...HEAD` is empty in this worktree; the requested branch state is represented by uncommitted working-tree changes in `beta/DECISION_CRITERIA.md` and `phase4-coordinator/dist/coordinator.yaml`, so this audit evaluated `git diff` for the current working tree.

## Findings

### MEDIUM

1. `phase4-coordinator/internal/config/config_env_test.go:159` still encodes the superseded Entry 111 Nemotron rates (`117500` prompt, `29375` cache-hit, `235000` completion). The PR 1 YAML now correctly applies Entry 114's RESEARCH_227 broad-fleet rate at `phase4-coordinator/dist/coordinator.yaml:175` through `phase4-coordinator/dist/coordinator.yaml:178` (`80000` prompt, `20000` cache-hit, `160000` completion), but the stale config test causes `go test ./internal/config` to fail:

   ```text
   --- FAIL: TestDeployCoordinatorYAMLLoadsWithStatsEnv
       config_env_test.go:162: unexpected nemotron rate-card row: {PromptCreditsPerMtok:80000 PromptCacheHitCreditsPerMtok:20000 CompletionCreditsPerMtok:160000 promptCacheHitRateSet:true}
   ```

   This is merge-blocking verification drift, not a runtime design flaw: the production YAML and Entry 114 align, but CI will continue to reject the intended config until the test expectation is updated to the new contract.

### LOW

None.

### INFO

1. `specs/AUDIT_BUILD_SPEC_RATE_CARD_V4_PIVOT_PR1_IMPL_ARCHITECT_PROMPT.md:6` references `specs/BUILD_SPEC_RATE_CARD_V4_PIVOT_PROMPT.md` §3 PR 1, but that build-spec file is not present in this checkout. I completed the audit from the architect prompt's embedded expected contract plus the required source files. This did not block the concrete contract checks, but it weakens traceability for future auditors.

## Contract Checks

- Entry 114 exists at `beta/DECISION_CRITERIA.md:423` and locks the pivot before engine/harness changes land in PRs 2-3.
- Entry 114 explicitly supersedes PR #419 starter-tier engine work in follow-up PR 2 without deleting starter code in this PR (`beta/DECISION_CRITERIA.md:423`).
- Nemotron is corrected from Entry 111's Qwen3-Coder parity lane to RESEARCH_227 broad-fleet pricing: `phase4-coordinator/dist/coordinator.yaml:175` through `phase4-coordinator/dist/coordinator.yaml:178`.
- Prompt/cache-hit ratios match the required pattern: `80000` prompt is 50% of `160000` completion, and `20000` cache-hit is 25% of prompt.
- Other visible v3 rate-card rows are unchanged in the working-tree diff.
- Billing key remains the normalized coordinator key `nemotron-3-nano-30b-a3b` at `phase4-coordinator/dist/coordinator.yaml:175`; existing `RateFor` normalization covers raw, namespaced, and MLX artifact aliases in `phase4-coordinator/internal/billing/formula.go:40` and `phase4-coordinator/internal/billing/formula.go:65`.

## Verification

- `ruby -e 'require "yaml"; ...'` over `phase4-coordinator/dist/coordinator.yaml` confirmed the Nemotron row is exactly `{80000, 20000, 160000}`.
- `go test ./internal/billing ./internal/config` from `phase4-coordinator/` passed `internal/billing` and failed `internal/config` only on the stale Nemotron rate assertion above.
- `git diff --check` passed.

STATUS: ARCH lane — CRITICAL=0 HIGH=0 MEDIUM=1 LOW=0 INFO=1
