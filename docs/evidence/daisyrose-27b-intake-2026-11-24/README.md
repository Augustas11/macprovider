# DaisyRose-27B catalog intake (2026-11-24)

Related: #2465

Catalog key `radixark/daisyrose-27b`. Artifact `mlx-community/DaisyRose-27B-4bit`
at revision `895983ea8d4244e855f6fbde2c3fa8261af202ef`, snapshot-manifest.v1
hash `996b96eef24ee8f7923fabc4fb1b9da5772c0d6bc3234536d1cdace81b7ba23f` (16 files,
16,074,323,781 bytes). The hash was recomputed from the Hugging Face tree API
with `scripts/catalog-hash-sweep.py`'s algorithm. The same code reproduces the
`qwen/qwen3.8-27b` row's signed hash `8a8786e9…`.

The row is listed at the Qwen3.8-27B placement and price. Native MTP is
admitted as a SPEC-048 MTP-13 same-architecture variant of `qwen/qwen3.8-27b`
that binds its own R012 fit evidence (SPEC-048 0.1.124, see below).

## Measurements

The incumbent `qwen/qwen3.8-27b` ran back to back with DaisyRose on one Mac
Studio M3 Ultra (256 GB), in two windows on two builds:

- parity, reference and quality: provider build `38bc402`, before #2472 and
  #2473;
- native-MTP runs: build `16f49548e`.

This is a same-engine intake. Both models run on our engine, and the speed
check under AGENTS.md rule 15 compares DaisyRose with Qwen3.8-27B on that
engine. DaisyRose is not a port: it reuses the Qwen3.8-27B `qwen3_5` code path
and changes no engine code.

| Check | DaisyRose-27B | Qwen3.8-27B | Source |
|---|---|---|---|
| 4-row batched vs serial parity, 256 tokens | PASS (4/4 rows) | PASS | `verdict.json` `models.*.parity` |
| Reference top-1 vs mlx-lm, 1K / 8K / 32K | 16/16, 16/16, 16/16 | 16/16, 16/16, 16/16 | `verdict.json` `models.*.ref` |
| Greedy tokens vs mlx-lm, 1K / 8K / 32K | 256/256 each | 256/256 each | same |
| Single-row decode tok/s, 1K / 8K / 32K | 34.4 / 33.0 / 30.1 | 34.4 / 33.1 / 30.2 | same, `decode_tps` |
| Coding-agent quality rubric | 1/9 | 1/9 | `quality-*-score.json` |
| Native-MTP acceptance, pooled over the 4 common s1 cells | 0.815 (6011/7375) | 0.819 (5996/7321) | `verdict.json` `acceptance_pooled` |

Quality is equal, but the rubric does not discriminate: both models pass 1 of
9 cases, and most failures are `finish_length` at the case token caps. It
shows no regression. It does not show an improvement.

`verdict.json` reports the overall verdict `FAIL` only for the reason
`candidate native MTP analyzer FAIL`. That FAIL blocks native MTP, not the
ordinary row.

## Native MTP: admitted as an MTP-13 variant

DaisyRose's own R015 run (`mtp-daisy-analysis.json`, Qwen3.8-27B MTP head
`25d2e7e3…`, policy `mtp-daisy-policy.json` `cbe1cae1…`) passes every s1 cell
and the s2 gated cell. It fails the s4 gated cell `s4-p1536-o512`:

- TTFT p95 upper bound 0.0667 against the 0.05 limit;
- TPOT p95 upper bound 0.0756 against the 0.05 limit.

In DaisyRose's run, the native row's prefill takes about 1.2 s longer under
staggered arrivals, which points to the prefill schedule under the native hold
rather than MTP drafting work. That cause was not tested against the donor on
the same build; it is measured in #2478.

The row is admitted through the SPEC-048 MTP-13 same-architecture variant
route with donor `qwen/qwen3.8-27b`, so it inherits the donor's qualified
tuple class. Preconditions:

| Precondition | Result |
|---|---|
| Same `mtp_family_adapter` as the donor | met: same architecture, so `qwen3_5_mtp_v1`, with the donor's head artifact `mlx-community/Qwen3.8-27B-MTP-4bit` (the DaisyRose build has no MTP tensors) |
| Same `quantization.kind` | met: `mlx_affine`, 4-bit, group 64. The config's quantization block equals the donor's, and the recomputed representation manifest equals the donor's signed `7deae874…`. |
| Same tuple class | met: same architecture and head (`hybrid_stageable_rewindable`, 1 head, depth 1) |
| R012: served `.safetensors` bytes no more than the donor's, else own fit evidence | met through own fit evidence: DaisyRose is 250 bytes larger (16,054,541,599 vs 16,054,541,349; shard deltas +90, −30, +190, from safetensors header lengths). The variant block binds `mtp-daisy-policy.json` and `mtp-daisy-analysis.json` by SHA-256 under `fit_evidence`. The policy names DaisyRose's artifact hash `996b96ee…`, and all 8 cells, including the 32K-prompt s1 cell and the s4 sustained cell, record no memory failures. |
| Snapshot manifests committed under `snapshot-manifests/` | met: `996b96ee….manifest` and the donor's `8a8786e9….manifest` |

Open risk: no MTP-16 `self_check_record` exists for DaisyRose yet, so the bank
carries the donor's expected output for the tuple. The R033 coordinator
canary compares that output; if DaisyRose's trunk produces different tokens,
the canary disables the native tuple (ordinary serving continues) until the
record is bound. `scripts/lab/2465/selfcheck.sh` captures it in a Studio
window, and `catalog-release.py bind-native-mtp-self-check-record --model-key
radixark/daisyrose-27b --source <selfcheck-record.json>` binds it; the
release is then regenerated and re-signed.

## Files

- `verdict.json`: merged intake verdict for both models (parity, reference,
  MTP cells, quality, pooled acceptance).
- `quality-daisy-score.json` and `quality-qwen38-score.json`: rubric scores.
- `mtp-daisy-policy.json`: R015 policy the analysis ran under (schema
  `macprovider.native-mtp-r015-policy.v1`).
- `mtp-daisy-analysis.json`: DaisyRose R015 analysis (schema
  `macprovider.native-mtp-r015-analysis.v1`).
