# Product Build 3 — Planning Checkpoint Revision 3

Checkpoint: `build3-checkpoint-v3`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Branch/worktree: `codex/product-build-3` at `/Users/augstar/.codex/worktrees/macprovider/product-build-3`
Date: 2026-09-11

## State

Independent GPT-5.6 Sol review of revision 2 failed with 0 Critical, 5 High, 3 Medium, and 0 Low findings. Revision 3 addresses all eight findings without starting implementation, collecting physical calibration evidence, enabling enforcement/economics, or weakening acceptance. `reviews/plan-v2-findings-disposition-r3.md` maps each correction. Approval remains pending a new independent gate.

## Revision 3 decisions

- Authority is an acyclic profile → protocol → evidence records → evidence bundle → post-build release candidate → candidate-bound nonpositive qualification results → final qualification chain with Gate A0, Gate B, and Gate C.
- The observation-only calibration method and numeric pass/fail thresholds are frozen before data. It cannot support SPEC-036 warn/enforce, settlement verification, or production reward eligibility.
- Covered routing uses a mandatory unique session-instance and generation tuple, single-use route token, SQLite capture, post-commit WS claim, and session-actor send fence. Nil generation is nonpositive.
- A non-restored fsynced PREPARE exists before SQLite commit. Crash/restore ambiguity remains unavailable and cannot erase an acknowledged money-path suffix.
- The exact external-journal/SQLite/fsync design must pass fixed latency, throughput, storage, bootstrap, queue, disk-full, and one-year retention gates before implementation.
- Running MLX probes must synchronize and quiesce before buyer Metal work. A 2-second miss drains routing until quiescence; late callbacks are fenced.
- Reward inputs, reasons, precedence, actions, secondary ordering, and cross-client vectors are closed and total.
- SPEC-022 settlement observe/enforce and SPEC-036 observation are separate fields. Qualification shadow accrual is absent from production binaries and cannot touch production ledgers.

## Remaining gates and blockers

1. Record the exact R3 plan/test/disposition digests and commit.
2. Run a fresh independent GPT-5.6 Sol high-reasoning review on that commit and those digests.
3. Revise until zero Critical, High, and Medium findings.
4. After approval, perform only hook feasibility and author exact antecedent manifests; Gate A0 must approve them before any physical reference/cohort measurement.
5. Produce reference/calibration/capacity/migration evidence and pass Gate B before Slices 1–7.
6. After implementation, build/sign and pass Gate C before any positive qualification state.

Current qualification blockers include: unproven exact post-sampler hook; no Gate-A0-approved exact class/profile/protocol; no precommitted physical cohort run; no two qualifying independent reference sources; no exact hot-path capacity evidence; no Build 3 MLX/physical/Xcode/browser trace; no built release qualification; and no production qualification. Enforcement, economic activation, payment execution, epochs, deployment, procurement, release publication, and operator-secret changes remain out of scope.

Exact R3 gate inputs:

- `prd-implementation-plan-v3.md` SHA-256: `3cde3d3c1396bb552a69cfcb5ea5daeb910445b5814880421322d3bf6a681efc`
- `test-spec-v3.md` SHA-256: `d6b8ecb7b5af6e5b00c32668a15c9da20e44ab3e30a6cee8a6d7ef2019ffeaaf`
- `reviews/plan-v2-findings-disposition-r3.md` SHA-256: `43c9a1144eddad2e8b606a872b7dacef9345a153e87cce1b5e42f55e20b4c9bf`
- source failed review SHA-256: `a87f6a418c7e9009160abf80f1ba62d2a4ee5a942a92e6a853d193c21bb60a22`

The independent reviewer must recompute these values from the committed tree.
