# Product Build 5 resumption checkpoint

Date: 2026-09-11

Branch: `codex/product-build-5-assessment`

Initial and assessed base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Scope and state

Product Build 5 remains assessment-only. No runtime, scheduler, package,
configuration, conformance, deployment, or production-enablement code changed.
No hardware was purchased or provisioned, and no model, prompt, credential, or
private material was transmitted.

The lead requested an independent GPT-5.6 Sol adversarial gate. This worker
could not spawn it because all seven native agent slots were occupied. The root
lead will run that gate after this worker ends. Therefore the current documents
are review candidates, not an adversarially approved assessment. Record every
finding and revision in a later review artifact; do not label the gate passed
until a verifier reports zero Critical, High, and Medium findings against exact
document digests.

## Candidate artifacts and digests

| Artifact | Revision | SHA-256 |
|---|---|---|
| `current-state-evidence.md` | evidence at assessed base | `72b7eb53f8f70c2e8c70522ebac776bae659d838d7af2ea4e3ccfb56dd0d5d1b` |
| `feasibility-assessment.md` | `build5-assessment-r2` | `a58a1468bec8c17a1ca9ddca7d6057f331e547eba6465b542dd401b88928edd2` |
| `test-benchmark-spec.md` | `build5-benchmark-r2` | `b02f8012c8d1c260de051b2aacb693895dbb4b2af8b83e5adf8913ace4daddb2` |

## Fresh command evidence

```text
git rev-parse HEAD
git rev-parse origin/main
```

Both returned `1d2c930bad81704dd0acc0322226725d8b64aceb` before the documentation
commit.

```text
cd phase3-binary
swift test --filter 'PagedKVEngineTests|ContinuousBatchSchedulerTests|PagedKVParityTests'
```

Exit 0. Seventy-three executable tests passed (43 scheduler, 30 engine). Three
selected real parity tests were skipped by their explicit environment gates.
They are recorded as skipped, not passed.

```text
cd phase3-binary
MACPROVIDER_RUN_PAGED_PARITY=1 swift test \
  --filter PagedKVParityTests/testAC1_DenseLlama_3_2_3B_ParityWithRealGather
```

Exit 1 before completion: `Failed to load the default metallib`. This is a
fresh failed attempt and proof that ordinary worktree SwiftPM output is not a
packaged-runtime result.

```text
cd phase3-binary
./scripts/build-mlx-metallib.sh \
  .build/arm64-apple-macosx/debug/phase3-binaryPackageTests.xctest/Contents/MacOS
MACPROVIDER_RUN_PAGED_PARITY=1 swift test --skip-build \
  --filter PagedKVParityTests/testAC1_DenseLlama_3_2_3B_ParityWithRealGather
```

Exit 0. One of one test passed in 5.682 seconds: 40/40 greedy-token parity,
2,240 gather calls, maximum four logical blocks, and a non-identity physical
permutation. This is narrow real-MLX 3B gather parity on the recorded 32 GB
host, not a scheduler, throughput, packaging, or large-hardware result.

Other fresh inspection commands included `git log`, `git merge-base
--is-ancestor`, targeted `rg`/`sed` over the runtime, paged engine, tests,
SPEC-038/039, conformance manifest, benchmarks/runbooks, and `gh pr view 894`.
The current-state artifact records their material conclusions.

## Required next action

1. Spawn a read-only independent GPT-5.6 Sol verifier against the exact commit
   and candidate digests.
2. Require structured severity/evidence/consequence/correction findings.
3. Revise and repeat until Critical, High, and Medium counts are all zero.
4. Persist each round and final approved digests under this directory.
5. Keep all implementation and enablement out of Product Build 5.

Current qualification blockers remain the absent merged runtime bridge,
pending SPEC-038 conformance, conflicting/failed-governance draft PR #894, no
64 GB+ representative Mac or verified large artifact, no clean sustained-load
maintenance window, and no release-candidate integration result.
