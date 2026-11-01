# Abliterated GLM-5.3-Flash CB and native-MTP qualification (#2189)

One lab window on 2026-11-01 (UTC 21:24 to 00:29). The live provider was paused and drained.
The lab serve ran no-join on its own loopback port, with its own home and config. Paths are
written as `<lab>` and `<models>`.

- Artifact: `grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit` @
  `cbf4e8bd80e9227aa0a60c19b550bef6b390c04c`, snapshot-manifest `d47ec628…`, catalog key
  `zai-org/glm-5.3-flash-abliterated`.
  - Same `glm5_next` architecture, layer layout and tokenizer as the live GLM-5.3-Flash
    (`7299b6a7…`). It also has the same set of quantization-override modules and the MTP layer.
  - Different: the weights, some per-module bit widths, and the chat template
    (`5448db3c…`; live `6138d780…`).
- Binary: the signed provider CLI 1.8.277 (source `11c4107744116ac426b0eab4cd37a20c511526a9`,
  sha256 `5ef947b5…`, CDHash `736ebf35…`, metallib `3d9b4a74…`, decode-path digest
  `27d5e3e2…`), so the evidence binds the binary that serves.
- 1.8.277's SPEC-039 FR-PKV12 allowlist has no entry for the abliterated key. The window
  therefore served these weights under `zai-org/glm-5.3-flash`. This PR adds the key (SPEC-039
  v0.1.27). The provider change ships in the next CLI cut; for this entry that cut is an
  identity rebind only.

## Continuous batching

| Check | Result |
| --- | --- |
| Paged attach probe (serve) | established: 11 sparse layers, 36 forwards, 792 of 792 gather calls, non-identity block permutation |
| MoE expert-dispatch isolation (serve) | batched rows equal serial rows on first decode and on rejoin |
| Scheduler leftovers, rows 4 (`leftovers.json`) | isolation, replay, drain and 48-token parity all `pass=true` |
| Serial warm vs cold, rows 1 and 4 | every turn equals its cold run, and the warm run reuses the prior prefix |
| FR-CB10 self-check, AC-26 cached-turn batching | not run: the signed binary batches only a tuple its signed policy authorizes, and none exists for this sha yet. The self-check runs at load once the entry is signed. |

`msb-throughput`, paged engine, block 256, 1,024 prompt and 128 decode tokens per row, 3 runs
(`msb-rows{1,2,4}.json`):

| Rows | Aggregate tok/s p50 | Paged single row | Aggregate / production serial | GLM-5.3-Flash T4 record | Peak footprint |
| --- | --- | --- | --- | --- | --- |
| 1 | 40.33 | 40.33 | 0.96 | 0.97 | 181.2 GB |
| 2 | 58.93 | 40.62 | 1.40 | 1.40 | 181.6 GB |
| 4 | 66.37 | 40.39 | 1.58 | 1.70 | 181.8 GB |

## Native MTP (SPEC-048)

R005: 200-case bank, max 1 native row, max prompt 4,096, policy `acceptance-policy.json`.

| | Abliterated | Live GLM-5.3-Flash on 1.8.277 |
| --- | --- | --- |
| Status | pass, all 10 checks | pass |
| Accepted / rejected | 4,628 / 1,290 | 4,071 / 1,095 |
| Acceptance | 78.2% | 78.8% |
| Compared positions (near-tied) | 10,592 (152) | 9,304 (107) |

R015: `bench-policy.json`, the same cells as the live tuple. The analysis is
`bench-analysis.json`; overall PASS, gate set `tpot_chunk_gap_v2`.

| Cell | Status | Acceptance | Native decode tok/s | Ordinary CB decode tok/s | Ratio | TTFT p95 native / ordinary s |
| --- | --- | --- | --- | --- | --- | --- |
| s1-p1536-o128 | PASS | 0.820 | 48.12 | 39.40 | 1.221 | 4.281 / 4.180 |
| s1-p1536-o512 | PASS | 0.809 | 47.87 | 38.72 | 1.236 | 4.279 / 4.179 |
| s1-p4096-o128 | PASS | 0.802 | 45.36 | 37.15 | 1.221 | 12.820 / 12.297 |
| s1-p4096-o512 | PASS | 0.799 | 45.50 | 37.24 | 1.222 | 12.821 / 12.305 |
| s2-p1536-o512 | PASS | n/a | 46.04 | 46.08 | 0.999 | 6.418 / 6.285 |
| s4-p1536-o512 | PASS | n/a | 47.01 | 47.04 | 0.999 | 10.922 / 10.815 |

Notes on the table:
- s2 and s4 run ordinary CB. The native row cap is 1, so the native path stays at depth zero
  there, exactly as in the live tuple.
- The s4 cell also ran the sustained phase: 1,820 s, 38 runs, minimum available memory 23.6%.
- No cell has a hard failure, which includes token parity.
- The live 1.8.277 ratios are 1.193, 1.217, 1.224, 1.221, 0.999 and 1.000.

## Files

- `bench-analysis.json`, `bench-policy.json`, `acceptance-policy.json`: the exact bytes whose
  SHA-256 values the drafted tuple entry carries.
- `msb-rows{1,2,4}.json`, `leftovers.json`: local paths are replaced by `<models>` and `<lab>`.
- The acceptance result (`589c433e…`, 5.1 MB) and the R015 records (`bench.jsonl`, `a1664b5f…`,
  7.9 MB) are kept with the operator's qualification records.
