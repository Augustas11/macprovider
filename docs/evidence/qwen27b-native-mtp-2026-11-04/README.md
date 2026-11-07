# Qwen3.6-27B and Qwen3.8-27B native-MTP qualification records (#2222)

These are the committed records of the #2222 lab windows. A Qwen 27B
native-MTP admission tuple binds them. Native MTP runs at proposal depth 1,
with one native row and four qualified slots, on `apple-m3-ultra` with
256 GiB RAM. No admission entry is published yet. See "Not admissible against
CLI 1.8.281" below.

## Files

| File | SHA-256 | Tuple field it binds |
| --- | --- | --- |
| `qwen36/r015-policy.json` | `a65eddea7b5778fe1174919bb63a6201e3e5b0b21b52f53716fe6ac7173da373` | `benchmark_policy_sha256` |
| `qwen36/r015-analysis.json` | `4070c4129656949f9c1cc2a7fe9e5123a696985510bc6572fd1b8d88e5acf337` | `performance_`, `fit_`, `quality_evidence_sha256`, `ordinary_baseline.measurement_sha256` |
| `qwen36/bank-entry.json` | `892ea6d80fe9aad4532df9917355538d595b21b34edb722d34e6df3d155ed48a` | the self-test bank entry `native-mtp-selftest-qwen36-27b-0001` |
| `qwen38/r015-policy.json` | `64c17208cf58f02da1e1adac6bd58eebaf346e2d2018f876746f903f531d1b3a` | `benchmark_policy_sha256` |
| `qwen38/r015-analysis.json` | `b3f0934e72335e58dee7ea044f9473dddaadb68621911392a14c5f7e65cb5287` | `performance_`, `fit_`, `quality_evidence_sha256`, `ordinary_baseline.measurement_sha256` |
| `qwen38/bank-entry.json` | `e8987cd3f6d96497af473892aabd5828d6cbd68e6afc1da3f9d9d8741bdeb5db` | the self-test bank entry `native-mtp-selftest-qwen38-27b-0001` |

The files are byte-identical to the lab outputs. The raw R015 JSONL and the
R005 acceptance results stay off-repo, as for earlier tuples. Their digests are
the commitments:

| Record | SHA-256 |
| --- | --- |
| Qwen3.6 R015 JSONL (window `20261104T011543Z`) | `45f7ebdcf3e2b034e5b383eea6d3fa7897824b77d91e04a6d5bcbe953b0b9f03` |
| Qwen3.8 R015 JSONL (window `20261104T031308Z`) | `b81f9aa2b5652d6204655b45801248c7abcc98bd3166494f51e50f16cab70d75` |
| Qwen3.6 R005 `acceptance.json` (window `20261104T103139Z`) | `7085347a761caa334fa93f5849f4700201e12dc983ef2a766ea3d216b6f25765` |
| Qwen3.8 R005 `acceptance.json` (window `20261104T103139Z`) | `bd741fd667573e73686b8489a925a31c53b037a627ef06d9a33d1a76166b5cd2` |

## Identity

| | Qwen3.6-27B | Qwen3.8-27B |
| --- | --- | --- |
| `model_key` / `artifact_id` | `qwen/qwen3.6-27b` / `mlx-4bit` | `qwen/qwen3.8-27b` / `mlx-4bit` |
| `artifact_hash` (artifact-feed member) | `518ef47c…` | `8a8786e9…` |
| drafter (`mtp`) | `mlx-community/Qwen3.6-27B-MTP-4bit` @ `83795d54…`, snapshot `88b6d3e0…` | `mlx-community/Qwen3.8-27B-MTP-4bit` @ `b643c01b…` |
| `mtp_manifest_sha256` (drafter `config.json`) | `64c2cf17…` | `16094efa…` |
| `tokenizer_sha256` | `87a7830d…` | `06b95093…` |
| family adapter | `qwen3_5_mtp_v1`, `hybrid_stageable_rewindable` | same |

## Results

- **R015** (harness `2033feab5`, release `mlx.metallib` `3d9b4a74…`,
  decode-path digest `5d0ea217…`, mlx-swift-lm `ae6aa782…`). Both analyzers
  report `overall_status` PASS on all six cells, and the 1,800 s sustained
  phase passed.
  - Qwen3.6 decode ratios: 1.487, 1.422, 1.405, 1.337, 1.16, 1.064.
  - Qwen3.8 decode ratios: 1.444, 1.375, 1.383, 1.282, 1.131, 1.056.
  - The cells are s1-p1536-o128, s1-p1536-o512, s1-p4096-o128,
    s1-p4096-o512, s2-p1536-o512 and s4-p1536-o512.
  - At the tuple's 4 slots (s4-p1536-o512), the throughput median is
    +6.36% for Qwen3.6 and +5.64% for Qwen3.8. The ordinary aggregate is
    40.01 and 39.01 tok/s.
- **R005** (harness `b609a589d`, same decode-path digest). Both models
  passed 200/200 cases with no failed checks.
  - Qwen3.6 accepted 7953 and rejected 4353.
  - Qwen3.8 accepted 7350 and rejected 5513.
- **Bank.** Candidate 0 was recorded on the release metallib.
  - Qwen3.6: speedup 1.463, 31 accepted, 1 rejected.
  - Qwen3.8: speedup 1.459, 31 accepted, 1 rejected.

## Decode path since this evidence (AGENTS.md rule 2)

The decode-path digest is `5d0ea217…` at harness `2033feab5`, at R005 harness
`b609a589d` and at the #2222 merge `1381c0c5e`. Signed CLI 1.8.281
(`8898508c1`) embeds `dbadff54…`. Two decode-path changes landed in between:

- #2224 (`b78b005e8`): fork `.24` adds the `minimax_m3` models, and the
  provider adds `PagedMiniMaxM3Cache.swift` with scheduler and runtime
  routing for MiniMax M3 rows. The only fork change shared with Qwen is that
  `loadWeights` drops its weight dictionary after `model.update`. It holds
  references, not values.
- #2225 (`c0289376f`): fork `.25` windows the GLM-5.3 MTP head prefill. The
  provider adds `nativeMTPDrafterPromptWindow`, which only the GLM backend
  sets. The on-device self-check bar moves from `>= 1.15` to `> 1.0`.

Neither change touches the `qwen3_5_mtp_v1` forward or the Qwen scheduling
path. The release metallib is unchanged. So binding these records to the
1.8.281 decode path is an identity rebind (MTP-13), not a requalification,
and the bank entries keep their tokens, counters and committed state.

## Not admissible against CLI 1.8.281

1. **Release scope.** `scripts/native_mtp_release_match.py`
   (`native_mtp_release_match_gate` in `scripts/ops/catalog-activate.sh`)
   requires every admission entry's `model_key`, `artifact_hash`,
   `hardware_class`, `ram_bytes` and `qualified_slots` to match an entry of
   the admission set embedded in the signed release payload. The 1.8.281
   tarball embeds release
   `published-2026-11-02-glm53-flash-abliterated-cached-turns-v280`, which
   has only the GLM, GLM-abliterated and Qwen3.6-35B-A3B entries. With the
   1.8.281 identity bound, a Qwen 27B entry is refused:

   ```text
   model_key: qwen/qwen3.6-27b differs from signed release scope
   model_key: qwen/qwen3.8-27b differs from signed release scope
   ```

   A release that carries these entries is native-bound, so the gate blocks
   the whole release at `next --run`. The entries have to be in the catalog
   that the next CLI cut embeds. The post-cut catalog release then binds them
   to that cut's identity.
2. **Evidence not recorded.** The bank journey lists
   `step-02-capability-negatives` and `step-03-artifact-security-negatives`
   as pending. It did not execute `step-05-cache-state-boundary` or
   `step-07-08-mixed-multirow-capacity`. So no record exists yet for
   `security_negative_evidence_sha256`, `state_rollback_evidence_sha256` or
   `batch_evidence_sha256`. GLM got these from its journey record
   (steps 04-10) and from a `security-negatives.json` test run on the served
   snapshot. These are CPU suites plus a journey run on the lab harness, not
   an R005 or R015 rerun.
3. **Tuple sizing.** The lab admission used the lab stand-ins
   `complete_window_bytes_by_depth` `[1048576, 2097152]` and placeholder
   thresholds. The production tuple needs the derived window bound and the
   policy thresholds (400000, 700000, 2500), as the Qwen3.6-35B-A3B entry
   has them. Its `quantization` block must also be recomputed by
   `NativeMTPArtifactObserver` from the served snapshot.

Related: #2222, #2199
