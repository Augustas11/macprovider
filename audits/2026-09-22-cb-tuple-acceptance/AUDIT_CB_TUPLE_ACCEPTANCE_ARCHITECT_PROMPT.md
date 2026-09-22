# Shared context — CB per-tuple acceptance coverage (FR-CB10 conformance)

Repo: macprovider. Worktree: `/Users/augstar/macprovider-cb-tuple-acceptance`,
branch `fix/cb-tuple-acceptance-coverage`, based on `origin/main` at `a912e039`.

Review the FULL diff as it will land: `git diff` in that worktree (6 files,
567 insertions / 25 deletions). This is the complete fix, not a follow-up slice.

## Problem being fixed

SPEC-038 FR-CB10 defines continuous-batching support for a tuple as **descriptor
membership (FR-PKV11 / FR-CB8) PLUS acceptance coverage for that tuple**. The
implementation only enforced descriptor membership. The single acceptance-shaped
gate was `ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable = true`
— a global compiled constant inherited by every Mac running the binary.

Neither `phase4-coordinator` nor `phase5-gateway` references `continuous_batching`
or `paged_kv` anywhere, so the operational boundaries in use today ("Studio only",
"slots 4", "canary not on", "do not fleet-promote") are enforced by nothing but
operator discipline plus the accident that other fleet Macs still run an older
binary (1.8.123) that predates this code.

## What the change does

Adds a fail-closed, operator-declared per-tuple acceptance gate:

- `ContinuousBatchingAcceptedTuple` (MacProviderCore/Config.swift): 6 evidence
  identity fields — model id, model SHA-256, cache class, KV dtype, requiresMoE,
  hardware class.
- `ContinuousBatchingAcceptanceCoverage` (macprovider-cli/ContinuousBatching.swift):
  exact 6-field match; `.empty` (fail-closed) and `.unrestrictedForTests`.
- New reason code `tuple_acceptance_coverage_unavailable`, apiCode
  `continuous_batching_tuple_acceptance_coverage_unavailable`, HTTP 400.
- The gate runs inside `makeCapability`'s `.attached` branch, AFTER descriptor
  admission and BEFORE the AC-23 MoE gate. The MoE constant is intentionally
  left in place; the two gates are independent conjuncts.
- `acceptanceCoverage` is an UNDEFAULTED parameter on `capability(...)` and
  `makeCapability(...)` so no future call site can silently skip it.
- YAML key `continuous_batching_accepted_tuples`; absent key yields `[]`
  (fail-closed); malformed entry is a hard `ConfigError.invalidValue`.
- `.github/CODEOWNERS` gains the CB/paged-KV source files, which had no
  mandatory reviewer at all.

## Known, deliberate operational consequence

`ModelRuntime`'s production init defaults coverage to `.empty`. A provider that
upgrades to a build containing this change and has `continuous_batching: canary`
set will stop batching — reason-coded, serial-routed — until its operator adds
the tuple to `continuous_batching_accepted_tuples`. Strict `.on` fails at
startup. This is intended fail-closed behavior. Judge whether it is correctly
and safely implemented, and whether the blast radius is acceptable and
adequately signalled.

## Verification already run

- `swift build` → exit 0.
- `swift test --filter 'macprovider_cliTests.(ServingKnobsConfigTests|ContinuousBatchSchedulerTests|PagedKVRuntimeBridgeTests)'`
  → 183 tests, 19 skipped, 0 failures.
- Full `swift test` aborts in `mlx-stage-spikeTests` on a local-env
  `Failed to load the default metallib`; not claimed as a pass.

## Output format

Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line, a
concrete failure scenario, and a suggested fix. The gate for this change is
**0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none.
Do not propose SPEC edits: this is conformance to existing FR-CB10.

## Your lane: ARCHITECTURE REVIEW

- Is per-tuple acceptance coverage the right shape for FR-CB10, or does the
  conjunction belong elsewhere (descriptor, scheduler admission, coordinator)?
- Is keying coverage on 6 evidence fields — while leaving metallibSHA256,
  kernelIdentifier, parityLabel, poolEpoch to the descriptor — the right
  split, or does it let a materially different runtime inherit coverage?
- The change is CLI-side only. Assess honestly whether an operator-declared
  local allowlist is real enforcement, given the operator is also the person
  who would mistakenly fleet-promote. What would coordinator-side enforcement
  require, and is its absence a MEDIUM+ finding or correctly deferred?
- Does leaving `productionMoEPromotionEvidenceAvailable` as a global compiled
  constant alongside a per-tuple gate create an incoherent two-gate model?
- Is the fail-closed upgrade behavior the right default, versus a one-release
  warn-then-enforce migration?
