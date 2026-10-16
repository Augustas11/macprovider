# GLM-5.3-Flash T2 reference bench (epic #2029)

Reference lanes for the native-engine campaign. These numbers are reference
only: no catalog gate (`min_ram_gb`, `min_sustained_tps`) may be set from them
(SPEC-023 §16, oMLX-seeded rows are not activated). Catalog gates come from the
native Swift engine.

## Identity

| Item | Value |
| --- | --- |
| Artifact | `Jundot/GLM-5.3-Flash-oQ4e-mtp` @ `36defc5042d92a992a7948e83d6f110b8df69329` (MIT) |
| Artifact files | 46 files, 186 GB; per-file SHA-256 in `artifact-files.sha256`; SHA-256 of that list `38b810d3f59c1a539eb814c9a7adbd65d894aff938b6cb59043a8a144ca6d647` |
| Format | MLX affine, group 64, base 4-bit with per-layer 5/6/8-bit overrides; MTP layer under `language_model.mtp.0`; vision tower present (dropped by the text path) |
| Tensor layout | mlx-vlm PR #2030 layout (separate q/k/v and forget-gate projections). Stock mlx-vlm 0.7.8 cannot load it: its sanitize fuses KDA projections that this artifact quantizes at different widths. |
| Hardware | Mac Studio M3 Ultra, 60-core GPU, 256 GB, macOS 27.0.1 (26A434), `iogpu.wired_limit_mb` 0 (default) |
| oMLX lane | oMLX 0.7.1rc1 (`7a5a3d75ce7463300bdfa5fedccd34348f60ff46`), mlx 0.32.4, mlx-vlm 0.7.8, mlx-lm 0.31.4.dev132+g94cdcae13. Installed from source without precompiled custom kernels (no Metal toolchain on the host); its GLM decode kernels are runtime-compiled `mx.fast.metal_kernel`. Served through oMLX's `vlm` engine (not its batched engine). |
| Reference lane | the same venv: mlx-vlm 0.7.8 with oMLX's vendored `glm5_next` (mlx-vlm PR #2030, merge `fa27a9a692770c39fdf57b9a985fad084a90aec2`), script `scripts/lab/cb-studio/glm53_bench_vlm.py` |
| Windows | live provider paused and drained (0 in flight) for both: 11:19:36–11:43:54Z and 11:46:22–12:29:09Z |

## oMLX lane (`omlx-sweep.jsonl`, `scripts/lab/cb-studio/depth_sweep.py`, streaming, no prompt cache)

Prompt filler is sized for the Qwen tokenizer, so GLM prompts ran ~8% long
(target 8192 → ~8861 tokens, 65536 → ~70975).

| Cell | Concurrency | Aggregate tok/s | Decode tok/s p50 | TTFT p50 |
| --- | --- | --- | --- | --- |
| 1024 prompt / 256 out | 1 | 34.4 | 55.2 | 2.69 s |
| 1024 / 256 | 4 | 30.8 | 9.6 | 6.45 s |
| 1024 / 256 | 8 | 35.8 | 5.8 | 16.8 s |
| ~8.9k / 256 | 1 | 8.5 | 49.5 | 23.4 s |
| ~71k / 256 | 1 | not measured | not measured | > 240 s (no request finished in the window) |

oMLX does not batch this model (vlm engine): concurrency 4 and 8 do not raise
aggregate throughput. These rows show oMLX's serving behavior for this model,
not the model's batching ceiling.

## Reference lane (`reference-lane-speed.json`)

| Prompt tokens | Prefill tok/s | TTFT | Peak memory |
| --- | --- | --- | --- |
| 1024 | 301 | 3.4 s | 186.5 GB |
| 8192 | 355 | 23.1 s | 189.4 GB |
| 65536 | 170 | 385.9 s | 209.1 GB |

Decode tok/s from this harness is invalid (0.37–0.40 tok/s): a bare
per-token loop without the runtime's decode setup. It is excluded; the oMLX
lane is the decode reference.

**Memory:** one 64k-context stream peaks at 209 GB. With SPEC-048-R012's 10%
free-memory floor (~26 GB on 256 GB), long-context continuous batching on this
box is memory-bound well before it is compute-bound. The native `min_ram_gb` and
CB slot count must be set from native measurements that include KV growth.

## Parity oracle (kept on the bench host, not committed)

Greedy (argmax, batch 1, no prompt cache) 256-token continuations plus top-16
logits for the first 16 decode steps, on a deterministic code corpus. Decoded
text is coherent at all three lengths.

| File | SHA-256 |
| --- | --- |
| `oracle_1024.npz` | `749d044333f0b74a3e97db340cab0f6eef8c337018e54dbf126796ce2f8598bc` |
| `oracle_8192.npz` | `5b9da6f0ed40a730f7041ad3b8b9a9941b226b86b6b62f7c54363e673f279358` |
| `oracle_65536.npz` | `9b334b75ff32b84fd31346871b21f9e12fb0728420a6f522776d64f1403ea98e` |

The T3 Swift port must reproduce these greedy tokens on the same artifact.
