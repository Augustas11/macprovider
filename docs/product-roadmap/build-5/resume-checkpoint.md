# Product Build 5 resumption checkpoint

Date: 2026-09-11

Checkpoint revision: `build5-checkpoint-r3`

Branch: `codex/product-build-5-assessment`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Scope and state

Product Build 5 remains assessment-only. No runtime, scheduler, package,
configuration, conformance, deployment, release, or production-enablement code
changed. No hardware was purchased or provisioned, and no model, prompt,
credential, private data, or operator secret was transmitted.

The first independent GPT-5.6 Sol review of R2 failed with 0 Critical, 4 High,
5 Medium, and 0 Low findings. R3 corrects every finding and records its
disposition. R3 is still a review candidate: only a fresh independent
GPT-5.6 Sol gate against the exact R3 commit/digests can approve it. Do not
label this assessment passed until that reviewer reports zero Critical, High,
and Medium findings.

## R3 candidate artifacts and pre-commit digests

| Artifact | Revision | SHA-256 |
|---|---|---|
| `current-state-evidence.md` | `build5-evidence-r3` | `11a0039bb8201f434e6c20f3fdf043e2209b38a5171813ff60ccfc12d24cb77a` |
| `feasibility-assessment.md` | `build5-assessment-r3` | `4c9f2e3a9562603efa26a3dfff3a4ce6cd9cdc123099bd441e4ee5ae578e2eeb` |
| `test-benchmark-spec.md` | `build5-benchmark-r3` | `bd2c6f3044960671de19a7033422239c6b2691dae71aa52a16cb0e99f7fc0c96` |
| `evidence/real-mlx-3b-exploratory-r3.log` | fresh exploratory real MLX | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |
| `reviews/assessment-r2-sol.md` | failed independent R2 gate | `9c7a211bce4dffd64a821fab94b6203b0faa6708aa1c7e188d112686bc2684af` |
| `reviews/assessment-r2-dispositions-r3.md` | R3 corrections | `a87cab5340c22fe03d96934ceaf7d9825b55411399b658ab8977f04cd3bcf8d6` |

The independent R3 reviewer must recompute all hashes from the committed tree.
If any digest differs, this table is superseded by the committed values and the
review must cite those exact values.

## R3 corrections

- Replaced illegal M5/M4-Max four-row qualification with a hardware-conditioned
  matrix. Current live-shaped M5 work is one row, Max work is at most two,
  and frozen MSB-02/03 use an Ultra >=128 GiB with a same-host MSB-01 baseline.
- Added the single generation-scoped resident-model execution arbiter and its
  serial/batch/drain/failure/warm-swap contracts and no-overlap tests.
- Restored the exact MSB executor/workload mapping, preserving native two-
  iterator versus pinned-oMLX as MSB-05.
- Made memory admission and pressure evidence executable through the versioned
  manifest, non-duplicating formulas, process/MLX metrics, 100 ms sampling,
  explicit abort states, and recovery bounds.
- Added the complete SPEC-039 pending-conformance prerequisite.
- Captured an exact-byte 3B snapshot/runtime/metallib/harness/log manifest while
  keeping the run exploratory because the source selector and dummy descriptor
  are not authoritative.
- Closed workload/statistics, MoE exact-parity, and protected release-toolchain
  plus dual-artifact byte-identity requirements.

Detailed one-to-one dispositions are in
`reviews/assessment-r2-dispositions-r3.md`.

## Fresh command evidence

```text
cd phase3-binary
swift test --filter 'PagedKVEngineTests|ContinuousBatchSchedulerTests|PagedKVParityTests'
```

Earlier R2 inspection: exit 0; 73 executable tests passed and three selected
real-model tests skipped. The skips are not passing evidence.

```text
cd phase3-binary
MACPROVIDER_RUN_PAGED_PARITY=1 swift test --skip-build \
  --filter PagedKVParityTests/testAC1_DenseLlama_3_2_3B_ParityWithRealGather
```

Fresh R3 run: exit 0; 1/1 selected test passed in 5.944 seconds with 40/40
greedy tokens, 2,240 gather calls, four maximum logical blocks, and a non-
identity permutation. The committed log and exact byte manifest are recorded
above. This remains exploratory development evidence because the existing test
selects the first snapshot directory and creates a descriptor with zero model
and metallib hashes. It is not shared-forward, packaging, memory, throughput,
MoE, representative-hardware, or production evidence.

`git diff --check` passed after restoring the SwiftPM-mutated
`phase3-binary/Package.resolved` to the branch version.

## Required next action

1. Commit this R3 correction with the repository Lore protocol.
2. Spawn a fresh read-only GPT-5.6 Sol verifier against the exact commit and
   recomputed artifact digests.
3. Require structured severity, evidence, consequence, and correction fields.
4. Revise and repeat until Critical, High, and Medium counts are all zero.
5. Keep implementation, activation, release, and hardware operations outside
   this Build 5 assessment.

Qualification blockers remain: no merged runtime bridge/shared MLX forward;
no serial/batch arbiter; pending SPEC-038 and SPEC-039 conformance; no legal
four-row representative host or verified large artifact; no clean sustained-
load window; current non-authoritative 3B harness; and no protected-toolchain
release candidate with final standalone/Malibu byte identity and updater proof.
