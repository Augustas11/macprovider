# DeepSeek V4 port plan

Related: #2111 (buyer-UX gate: #2107)
Date: 2026-10-22
Fork: `Augustas11/mlx-swift-lm` at `87dc5159c87d73f4d7abd524fbdd17760cf56285`
References (read-only):
- mlx-vlm 0.7.10 (PyPI wheel): `mlx_vlm/models/deepseek_v4/*`, `mlx_vlm/models/deepseek_v41/*`,
  `mlx_vlm/speculative/drafters/deepseek_v4_{mtp,dspark}/*`
- mlx-lm `main` at `72be8c955d9a0d3099bd01865af288e0e947c3fa`: `mlx_lm/models/deepseek_v41.py`.
  There is no `deepseek_v4.py` on main. It exists only in open PRs #1195 and #1797.
- mlx-lm open PRs: #1195 "Implement DSV4" (model plus `chat_templates/deepseek_v4.py`),
  #1797 "Add DeepSeek-V4-Flash without MTP (yet)", #1337 "Add deepseek_dsml tool parser".
- HF `deepseek-ai/DeepSeek-V4-Flash-0731` (`config.json`, `model.safetensors.index.json`,
  `encoding/encoding_dsv4.py`); HF `deepseek-ai/DeepSeek-V4.1-Flash` (`config.json`, index);
  HF `TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX@d6be051` (`config.json`, file tree).

Citation prefixes:
- `F:` is the fork (`Libraries/...`).
- `V:` is mlx-vlm 0.7.10 (`mlx_vlm/...`).
- `L:` is mlx-lm main.
- `E:` is `encoding/encoding_dsv4.py`.
- `M:` is this repo (`phase3-binary/Sources/...`).

All line numbers were checked with `grep -n` against those revisions.

## 0. Facts that shape the plan

| | V4-Flash-0731 | V4.1-Flash |
|---|---|---|
| `model_type` | `deepseek_v4` (flat config) | `deepseek_v41` (`text_config` + `vision_config`) |
| layers / hidden | 43 / 4096 | 40 / 5120 |
| routed experts / top-k / shared | 256 / 6 / 1 | 384 / 6 / 1 |
| hash-routed layers | `num_hash_layers: 3` (`tid2eid` in layers 0-2) | none: layer 0 has `gate.bias`, no `tid2eid` |
| attention | 64 q heads x 512, 1 KV head of 512, `o_groups 8`, `o_lora_rank 1024`, sliding window 128 | same shape, `q_lora_rank 1280` |
| `compress_ratios` | `[0,0, 4,128 alternating ..., 4, 0,0,0]` (46 entries = 43 layers + 3 MTP/DSpark stages) | `[0,0, 2 x18, 1 x20, 0,0,0]` (43 entries) |
| indexer | 64 heads x 128, top-k 512, own compressor | 32 heads x 128, top-k 512, shared across layers (`index_source_layer_ids`), candidate blocks |
| RoPE | `rope_theta 10000` (local) + `compress_rope_theta 160000` with YaRN factor 16 | same |
| MTP weights | `mtp.0..2`: three DSpark stages; `mtp.2` has `markov_head`, `confidence_head` and `hc_head` | `mtp.0..2` DSpark; `markov_head.embed/head`; `dspark_n_routed_experts 128` |
| extra | none | engram layers 1 and 14, `kv_source_layer_ids`, vision tower (`vision.*`, `aligner.*`) |
| source checkpoint | fp8 e4m3 blocks of 128, experts fp4; index `total_size` 166.9 GB | fp8 blocks of 32, experts fp4; index `total_size` 510.3 GB |

**The 4-bit MLX artifact is MXFP4, not affine.**
- The TensorFold config has `quantization: {bits 4, group_size 32, mode "mxfp4"}` as its default, so routed experts are `mxfp4`.
- These are `mxfp8` (8 bit, group 32): every attention projection (`wq_a`, `wq_b`, `wkv`, `wo_a`, `wo_b`), `indexer.wq_b`, the shared experts and `mtp.*.main_proj`.
- These stay unquantized: `embed`, `head`, `ffn.gate`, the compressor `wkv`/`wgate`, `indexer.weights_proj` and `markov_head`.
- The file tree sums to 167.09 GB.
- The GLM fused decode kernels accept only `mode == .affine` (F:`MLXLLM/Models/GLM5Next.swift:177-195`). On this artifact every fused path returns `nil` and falls back to the op path. This is the largest performance risk (see Risks).

**Memory.**
- V4-Flash 4-bit (~167 GB) fits a 256 GB Studio and leaves about 70 GB.
- V4.1: no full-expert MLX conversion fits in about 210 GB of weights. The table below lists the low-bit candidates found on 2026-10-22 through the HF API (`/api/models?search=DeepSeek-V4.1-Flash`, MLX library filter, sizes summed from the safetensors files). V4.1 4-bit (~432 GB) qualifies only on a 512 GB provider.

  | Repo | Revision | Weights | Scheme | Note |
  |---|---|---|---|---|
  | `rapid-mlx/DeepSeek-V4.1-Flash-REAP-2bit-MLX` | `efa9ce163d0b9dd75eacbaaeb98dc556de22cf6c` | 212.9 GB | affine 2-bit, group 64 | REAP-pruned to 336 of 384 experts; the publisher's loader only; no vision or MTP. The only one near 210 GB, and it is not the full model. |
  | `mlx-community/DeepSeek-V4.1-Flash-MLX-2bit` | `e36455ec16cd95e16964d85dd3ca9cf278752d77` | 238.8 GB | affine 2-bit, group 64 | full 384 experts, 3 MTP layers |
  | `TensorFold/DeepSeek-V4.1-Flash-MLX-2bit-MTP` | `f93c0f90c09d5806d52df29f952d7080f72ac211` | 238.8 GB | affine 2-bit, group 64 | same size; norms and gates left unquantized |
  | `0xSojalSec/DeepSeek-V4.1-Flash-MLX-MAC` | `db5b35242b8986b7e6e0f8f3fae65892aecd2317` | 238.8 GB | affine 2-bit, group 64 | same layout as the TensorFold repo |
  | `pipenetwork/DeepSeek-V4.1-Flash-REAP50-MLX-mixed-4_8bit` | `65b2bc7a233ace9d57840aa02d56dc0e0ce5f8b4` | 274.7 GB | mixed 4/8-bit | 50% expert-pruned |
  | `Jundot/DeepSeek-V4.1-Flash-oQ2e-mtp` (and `mlx-community/...-1017-oQ2e-mtp`) | `d61d2e4365ded40dee51ba24a942e7ab22cbd386` | 313.3 GB | oQ2e mixed | |
  | `mlx-community/DeepSeek-V4.1-Flash-1017-oQ2.5e-mtp` | `78456115d301eecf9fadcdcc81c0cf6f8b2c8eab` | 342.7 GB | oQ2.5e mixed | |
  | `mlx-community/DeepSeek-V4.1-Flash-1017-oQ3e-mtp` | `36b7ed19d13957875cddfd9094a1d138f7bcf340` | 379.9 GB | oQ3e mixed | |
  | `gnahzhang/DeepSeek-V4.1-Flash-LSQ3-G128-MLX` | `9162be9dcd8763395ee1e19977e30abd28b18951` | 451.5 GB | LSQ 3-bit, group 128 | |

  The 2-bit full-expert conversions (238.8 GB) leave no headroom on a 256 GB box. Only the REAP-pruned 212.9 GB artifact could load there, as a smoke test, not as parity or qualification evidence. The sub-210 GB V4.1 repos found are EXL3, GGUF or partial uploads, which the MLX runtime does not load.
- KV is small. The figures below are computed from the config, not measured:
  - Ratio-4 layers keep (512 + 128)/4 = 160 elements per token, counting the attention pool plus the indexer pool.
  - Ratio-128 layers keep 4 elements per token.
  - 21 x 160 + 20 x 4 = 3440 elements, which is about 6.9 KB per token in bf16.
  - Every layer adds a fixed 128-token window: 43 x 128 x 512 x 2 B, about 5.6 MB per row.
  - A 32k row is about 230 MB. CB row count is bounded by compute, not KV.

## 1. Component map

Each component is marked REUSED (with the fork citation), NEW (with the reference citation) or ADAPT (reused with a material change).

### 1.1 MoE gather and gating
- **REUSED: expert gather.**
  - `SwitchGLU` (F:`MLXLMCommon/SwitchLayers.swift:107`) and `QuantizedSwitchLinear` (F:`MLXLMCommon/SwitchLayers.swift:471`).
  - The limited SwiGLU (F:`GLM5Next.swift:38`; reference `swiglu_limit 10.0`, V:`deepseek_v4/language.py:242`).
  - The shared-expert add (F:`GLM5Next.swift:339-350`).
- **NEW: score function.**
  - The V4 gate scores with `sqrt(softplus(logits))` (V:`deepseek_v4/language.py:71-78`, used at `:148-168`).
  - Top-k runs on `scores + e_score_correction_bias`, has no group restriction (`n_group` is absent) and renormalizes when `norm_topk_prob`.
  - Weights are multiplied by `routed_scaling_factor 1.5`.
  - The GLM gate hard-codes `sigmoid` (F:`GLM5Next.swift:267`). The change is to make the scorer a config enum (`sigmoid` | `sqrtsoftplus`) in a `DeepseekV4MoEGate`. The compiled `select` closure keeps its shape.
- **ADAPT: fused decode router.**
  - `glm5NextRouterLogits` and `glm5NextMoERouter` (F:`MLXLLM/Models/GLM5NextDecodeKernels.swift:1132`, `:1160`) bake in sigmoid and affine experts (`glm5NextMoEExperts` at `:2626`).
  - V4 needs a sqrt-softplus variant and `mxfp4` expert tiles. Until that exists, decode uses `gatherQMM` through `SwitchGLU`. That path is correct but slower.
- **Expert count 256/384:** no structural change. It is config only, but the router kernel's threadgroup sizing must handle 384 (unverified).

### 1.2 Indexer (top-k 512)
- **ADAPT from `GLM5NextIndexer`** (F:`GLM5Next.swift:679-846`). What carries over:
  - The scoring math: `relu(q.k) * softmax_scale * weights_proj(x) * n_heads^-0.5`, summed over heads, then top-k.
  - `scoreChunk` bounding (`:696`).
  - The fused one-token selector `glm5NextDSASelect` (F:`GLM5NextDecodeKernels.swift:2993`).
- **NEW deltas (V:`deepseek_v4/language.py:657-785`):**
  - V4 does not pool raw indexer keys with a `kpool` gate the way GLM does (`updatePools`/`compress`, F:`GLM5Next.swift:719-738`). It owns a full `Compressor` (ratio 4, 128-dim, overlapping windows, own `ape`, RMSNorm and compressed RoPE; `:667`).
  - It selects over **compressed pool entries**, not token positions. The returned indices address pooled KV (`_gather_pooled`, `:426-436`), not token rows.
  - There is no `always_select_tail`. The local 128-token window is always attended separately.
  - The query is `wq_b(q_residual)` with the attention RoPE applied (`:725-727`).
  - The mask honours pool causality (`pool_cache.make_mask`, `:731`).
  - HISA hierarchical selection (`:672-710`, `hisa_kernel.py:15`) is **on**. `ModelConfig` defaults `index_block 64` and `index_keep 16` (V:`deepseek_v4/config.py:46-47`), and the 0731 config overrides neither (checked 2026-10-22: `ModelConfig.from_dict` on the artifact config gives 64/16). It applies once a ratio-4 pool holds at least 1024 entries (4096 tokens): decode uses `_hisa_select`, prefill `hisa_select`. Only whole 64-entry blocks are candidates. The 8k and 32k oracles ran through it, so the port implements both HISA paths and the flat path (`:774-785`, pools of 513-1023 entries).
- **V4.1:** one indexer per `index_source_layer_ids` (8 layers) with shared keys and a coarse candidate-block filter (`candidate_source_layer_id 20`, 2048 blocks of 8). V:`deepseek_v41/language.py:183-198`, `:145` `select_candidate_blocks`; L:`deepseek_v41.py:403-478`.

### 1.3 mHC hyper-connections
- **REUSED.**
  - `GLM5NextHyperConnection` (F:`GLM5Next.swift:63-175`): `hc_mult 4`, the Sinkhorn split (`:94-113`), collapse (`:118-126`), deferred decode state `GLM5NextHCState` (`:50-61`) and `glm5NextHCExpand` (`:30`).
  - Kernels: `glm5NextHCMix`/`glm5NextHCNorm`/`glm5NextHCPre`/`glm5NextHCPost` (F:`GLM5NextDecodeKernels.swift:956`, `:976`, `:1557`, `:1589`).
  - The math is identical to V:`deepseek_v4/hyper_connection.py:311-336` (same pre/post/comb, softmax + eps and column normalization, `iters - 1` alternations) and has the same parameters (`hc_attn_fn/base/scale`, `hc_ffn_*`).
  - The change is only the weight-key remap: `hc_attn_fn` goes to `attn_hc.fn`.
- **NEW: `HyperHead`** (V:`hyper_connection.py:437-456`, weights `hc_head_fn/base/scale`).
  - It is a learned sigmoid-weighted collapse before the final norm.
  - GLM averages the streams (`h.mean(axis: 2)`, F:`GLM5Next.swift:1278`, `:1291`), so the head is about 20 lines of new code.
  - DSpark also uses it per stage (`mtp.2.hc_head_*`).

### 1.4 Compressed attention (ratios 0 / 4 / 128) and compressor state
- **NEW (V:`deepseek_v4/language.py`).** There are three attention classes, chosen by `v4_attention_factory` (`:1033-1040`):
  - ratio 0: `LocalAttention` (`:788-915`). Sliding-window-128 MQA over the raw 512-dim KV.
  - ratio 128: `CompressedAttention` (`:918-960`). The local window plus **all** pooled entries (one per 128 tokens), with no indexer.
  - ratio 4: `SparseCompressedAttention` (`:963-1030`). The local window plus pooled entries (one per 4 tokens). It attends densely while `pooled <= 512` and switches to `_sparse_pooled_attention` over the indexer top-512 beyond that (`:438`).
- **The compressor** is `Compressor` (`:598-654`):
  - `wkv`/`wgate` (unquantized) produce kv and gate.
  - `softmax(gate + ape)` pools over windows of `ratio` tokens.
  - Ratio 4 uses **overlapping** windows: `_overlap_compress_kv` (`:398-415`) mixes the previous window's first half into each window.
  - Then come RMSNorm and compressed RoPE at position `pool_base` with `freq_scale = ratio` (`:610-616`).
  - **Reference behaviour the port keeps:** `_overlap_compress_kv` borrows the previous window's half only from windows completed in the **same call**. The first window of every prefill chunk, and every window completed during decode, pools against zeros with gate `-inf`. The ratio-4 pools therefore depend on the chunk plan. Parity runs must chunk exactly like mlx-vlm `generate_step` (`min(step, remaining - 1)` while more than one prompt token is left, then the last token). Serving (slice 6) and MTP verify (slice 7) must fix one chunk plan and keep it. The upstream DeepSeek inference code carries the half across calls. Whether we follow it is a decision for slice 6, and changing it needs new oracles.
  - State is a remainder buffer of fewer than `ratio` raw kv/gate rows plus the growing pool (`PoolingCache`, V:`models/cache.py:2693`).
- **Fork cache classes.**
  - The closest existing state machine is `GLM5NextAttentionCache` (F:`MLXLMCommon/GLM5NextAttentionCache.swift:188`): pending keys/gates, folded raw keys kept for exact trim (`foldedCapacity = kpool - 1 + maxTrim`, `:214`), `takeCompleteWindows` (`:241`), `appendPooled` (`:268`) and exact `trim` (`:318`).
  - **ADAPT** it into a `DeepseekV4PoolCache(ratio:, overlap:)`. The cache keeps raw kv and gate, not keys only. For ratio 4 it also retains the previous window's raw half so overlap stays exact across trim.
  - A V4 layer cache is a triple: a rotating 128-window (`RotatingKVCache`, keep 0) for the local branch, one pool cache for attention, and, on ratio-4 layers, a second pool cache for the indexer. This matches V:`deepseek_v4/language.py:1274-1295`.
- **CB and paged KV (this repo).**
  - Paged KV recognizes cache kinds by type (M:`macprovider-cli/PagedKVRuntimeBridge.swift:551-595`).
  - The local branch can reuse the existing `.slidingWindow(windowTokens:)` (`:557`), which already accepts `RotatingKVCache` with keep 0 (`:587-593`).
  - The pools need a new `.pagedPool(ratio:, indexerPool:)` kind and a `PagedPoolCache`, modelled on `PagedMLALatentCache` (M:`macprovider-cli/PagedMLACache.swift:25`). That class already pages a pooled buffer at `blockSizeTokens / kpool` granularity and keeps row-local pending windows.
  - The batched form follows `PagedMLABatchLayerCache` (`:429`).
  - The block size must be a multiple of 128. Add `"deepseek_v4": 256` to `familyDefaultBlockSizeTokens` (M:`MacProviderCore/PagedKVConfig.swift:94`) and add the family to `recognizedModelFamilies` (M:`MacProviderCore/PagedKVEngine.swift:349`).
  - The attach probe needs a context larger than `512 x 4` tokens, because only then does the sparse branch run (cf. `attachProbePromptTokens`, M:`macprovider-cli/ModelRuntime.swift:735-741`).
- **Batched rows.** Rows sit at different offsets, so each has its own remainder phase. The reference refuses non-uniform commits (`PoolingCache requires uniform batch commit lengths`, V:`models/cache.py:2764`; `requires_uniform_batch_acceptance = True`, V:`deepseek_v4/language.py:1174`). The fork already solves this for GLM: projections run batched, then each row attends against its own cache (F:`GLM5Next.swift:917-1007`, `GLM5NextBatchedLatentCache` at F:`GLM5NextAttentionCache.swift:31`). V4 reuses that per-row loop.

### 1.5 Single 512-dim KV head with output groups
- **NEW (V:`deepseek_v4/language.py:788-915`).** The projections:
  - `q = rmsnorm(wq_b(q_norm(wq_a x)))`, giving 64 heads of 512.
  - `kv = kv_norm(wkv x)`, one head of 512, used as both **K and V**.
  - Attention sinks per head (`attn_sink`, `:820`).
- RoPE covers only the last 64 dims (`traditional=True`; nope pairs get infinite frequency, `:308-320`). The **output is inverse-rotated** (`:883`), because V carries the rotated dims.
- The output projection is grouped low-rank: reshape into 8 groups, `wo_a` (`MultiLinear`, 8 x [4096 -> 1024], `:810`), then `wo_b` [8192 -> 4096].
- **REUSED:**
  - `MultiLinear`/`QuantizedMultiLinear` (F:`MLXLLM/Models/GLM4MOELite.swift:16`; mode-aware since `toQuantized(..., mode:)` at `:43`) for `wo_a`.
  - Fused SDPA over a 512-wide head, which GLM already does on its 512-rank latent (F:`GLM5Next.swift:1040`, `:1068`).
  - SDPA with sinks, as gpt-oss does (F:`MLXLLM/Models/GPTOSS.swift:199`, `:287`).
  - Unverified: that MLX's fused SDPA kernel accepts `sinks` at head dim 512. If it does not, the op path runs.

### 1.6 Hash routing in the first layers
- **NEW (V:`deepseek_v4/language.py:195-211`, `:482`).**
  - For `layer_idx < num_hash_layers` (3), the expert ids come from a lookup, not top-k: `inds = tid2eid[input_ids]`, where `tid2eid` is [vocab, 6] int32 (`:205`).
  - The weights are still the sqrt-softplus scores at those ids.
  - The layer has no `e_score_correction_bias`.
- **Fork change.** `GLM5NextMoE` is a `UnaryLayer` called as `(mlp as! UnaryLayer)(ffnNormed)` (F:`GLM5Next.swift:1132`), so the token ids never reach the FFN. The V4 decoder layer must thread `inputs` into the MoE. MTP and DSpark verification must pass the verified token ids, not drafts' positions.
- V4.1 has no hash layers (its layer-0 gate has `bias`).

### 1.7 YaRN with two RoPE bases
- **ADAPT.**
  - `YarnRoPE` (F:`MLXLMCommon/RoPEUtils.swift:292`) and the DeepSeek-V3 correction-range helpers (F:`MLXLLM/Models/DeepseekV3.swift:68-87`) cover the frequency interpolation.
  - V4's variant (V:`deepseek_v4/language.py:258-339`) has no mscale term. It applies a frequency override with nope pairs set to `inf`, offers an `inverse` mode and divides positions by `freq_scale` for compressor pools.
- Three RoPE instances per model:
  - Local layers use base 10000 with **no** scaling (`:822-827`).
  - Compressed and sparse layers use `compress_rope_theta 160000` with YaRN (factor 16, `original_max_position_embeddings 65536`, beta 32/1; `:924-929`). The indexer query uses this one too.
  - The compressor applies the same base with `freq_scale = ratio` (`:610-616`).
- Implement this as one `DeepseekV4RoPE` built on `MLXFast.RoPE(freqs:)`, not as a `YarnRoPE` subclass, so the mscale is not applied silently.
- Batched per-row offsets use `BatchPositionedKVCache.batchOffset` (F:`MLXLMCommon/RoPEApplication.swift:13`).

### 1.8 MTP: the V4 MTP layer, DSpark (0731), V4.1 stages
- **Fork framework (REUSED):**
  - `MTPDrafterModel` (F:`MLXLMCommon/MTPDrafterModel.swift:28`); `draftBlock` returns `[B, blockSize-1]`.
  - `MTPPackedStatefulDrafterModel` (`:208`) and `StatefulMTPDrafterModel` (`:223`).
  - `SpeculativeCacheRewindModel` (`:99`).
  - `MTPSpeculativeTokenIterator` (F:`MLXLMCommon/MTPSpeculativeTokenIterator.swift:36`) and `MTPKVCacheTransaction` (F:`MLXLMCommon/MTPKVCacheTransaction.swift:288`).
  - Packed verification: `MTPPackedVerificationCache` (F:`MLXLMCommon/MTPPackedTargetVerification.swift:21`).
  - `MTPAdaptiveDepth` (F:`MLXLMCommon/MTPAdaptiveDepth.swift:24`).
  - The GLM drafter as the pattern: `GLM5NextMTPDraftModel` (F:`MLXLLM/Models/GLM5NextMTP.swift:30`), registered at `:346-348`, with target rewind capped at 7 (F:`GLM5Next.swift:1416-1421`).
- **What 0731 ships.**
  - `config.json` says `num_nextn_predict_layers: 1`, but the index has `mtp.0`, `mtp.1` and `mtp.2`.
  - `mtp.0` has `main_proj`/`main_norm`. `mtp.2` adds `markov_head.markov_w1/w2`, `confidence_head.proj`, `hc_head_*` and `norm`.
  - Together with `dspark_block_size 5`, `dspark_target_layer_ids [40,41,42]`, `dspark_markov_rank 256` and `dspark_noise_token_id 128799`, this is a **DSpark** drafter. It is not the autoregressive V4 MTP layer.
- **NEW: DSpark (V:`speculative/drafters/deepseek_v4_dspark/deepseek_v4_dspark.py`).**
  - Stages are full V4 blocks with mHC and MoE, `compress_ratios [0]`, no hash (`:83-140`).
  - Stage 0 projects the concatenated target hiddens of layers 40-42 (`main_proj`, `:112-121`) into a cross-attention input (`DSparkMLACrossAttention`, `:36`).
  - A block is drafted in **one** forward: the anchor plus mask tokens (`:223-258`), followed by a Markov head that samples the block sequentially (`VanillaMarkov`, V:`speculative/drafters/dspark/dspark.py:11`).
  - `confidence_head` is dropped (`:283`).
  - The splitter shows how the checkpoint maps (V:`deepseek_v4_dspark/split.py:41-98`).
  - The reference default runtime block is `min(2, block_size)` (V:`deepseek_v4_dspark/config.py:49-53`), meaning one proposal per round.
- **Fork deltas:**
  - (a) A target-hidden capture hook for three named layers, each the mean over HC copies (V:`deepseek_v4/language.py:1146-1151`). Today the drafter gets only the last hidden.
  - (b) Block drafting in one forward instead of chained recursion (GLM chains, F:`GLM5NextMTP.swift:21-29`).
  - (c) The Markov sampler.
  - (d) The drafter state is one rotating window per stage, which is simpler than GLM's latent cache.
  - (e) Target verification needs exact rewind of the pool caches, including the ratio-4 overlap half (§1.4).
- **The V4 MTP layer** (V:`speculative/drafters/deepseek_v4_mtp/deepseek_v4_mtp.py:44-122`): `enorm`/`hnorm`/`e_proj`/`h_proj` with one V4 block, autoregressive. It applies only to non-0731 V4-Flash checkpoints. Unverified: we did not inspect a non-0731 index. It is out of scope unless such a checkpoint is catalogued.
- **V4.1 "3 MTP layers"** are also DSpark stages (`mtp.0..2`, `markov_head.embed/head`, `dspark_n_routed_experts 128`, `dspark_num_experts_per_tok 3`).
  - mlx-vlm 0.7.10 ships **no** `deepseek_v41` DSpark drafter (grep over `speculative/` finds none).
  - L:`deepseek_v41.py:1014` drops `mtp.*`.
  - So V4.1 MTP has no reference. It is unverified and goes last.
- **Admission (this repo).** The embedded-MTP family adapter today is `glm5_next_mtp_v1`, which is greedy only and allows max 1 active row (M:`macprovider-cli/NativeMTPAdmissionSidecar.swift:518-530`). The drafter is loaded at M:`macprovider-cli/ModelRuntime.swift:11785-11825`. Add `deepseek_v4_dspark_v1` as a target-embedded adapter beside it.

### 1.9 DSML prompt, tool-call and reasoning encoding
- **NEW (E:).** The format:
  - BOS, then `<｜User｜>` / `<｜Assistant｜>` turns. The tools system block is built from `TOOLS_TEMPLATE` (E:`82-107`, `render_tools` `:201`).
  - Tool results are merged into user turns as `<tool_result>` (E:`60-61`, `merge_tool_messages` `:416`, sorted by call order `:475`).
  - Calls are encoded as `<｜DSML｜tool_calls><｜DSML｜invoke name=..><｜DSML｜parameter name=.. string="true|false">..` (E:`52-57`, `encode_arguments_to_dsml` `:151`).
  - Reasoning effort prompts are `low`/`high`/`max` (E:`66-80`).
  - Earlier-turn thinking is dropped unless tools are present (E:`521-588`).
- In thinking mode the prompt **ends with `<think>`** (E:`396-407`), so generation starts inside reasoning and never emits an opening `<think>`. Parsing is `parse_message_from_completion_text` (E:`703-760`) and `parse_tool_calls` (E:`646-700`).
- No checked-in Jinja template exists. The HF `tokenizer_config.json` has no `chat_template`, and the TensorFold tree has none either.
- Prior art for the tool parser:
  - PR #1337 adds `mlx_lm/tool_parsers/deepseek_dsml.py`, a regex parser that matches the start marker without its trailing `>` because of BPE merging.
  - PR #1195 adds `mlx_lm/chat_templates/deepseek_v4.py`.
- **Where it plugs in (this repo).** The citations below are at `origin/main`. Open PR #2109 (#2107) replaces tool-grammar selection with template-selected grammars and adds a `<think>` split with `reasoning_effort`. The DSML encoder and parser register as one more grammar on top of it rather than as a separate path.
  - **Prompt.** The tokenizer loader is `ChatTemplateCompatTokenizerLoader` (M:`macprovider-cli/ChatTemplateCompatibility.swift:137-151`; used at M:`macprovider-cli/ModelRuntime.swift:10686`). Add a `DSMLChatEncodingTokenizer` whose `applyChatTemplate` (cf. `LiteralChatTemplateTokenizer.applyChatTemplate`, `:173`) runs a Swift port of `encode_messages` when `model_type` is `deepseek_v4` or `deepseek_v41`.
  - **Tool history.** Multi-turn tool history currently 400s for non-Qwen families (M:`macprovider-cli/ToolPromptRenderer.swift:14-20`). With the encoder owning history, that guard is bypassed for DSML models, which is the #2107 D4 fix shape.
  - **Tool calls.** `ToolCallFormat.detect` matches only qwen and llama-3.3 (M:`macprovider-cli/ToolCallParser.swift:975-985`, dispatched at `:18`). Add a `.dsml` case with a parser that mirrors E:`646-700`, plus the PR #1337 marker tolerance. It keeps the SPEC-018 byte caps (`:5-7`) and schema typing for `string="false"`.
  - **Fork side.** The fork's `MiniMaxM2ToolCallParser` (F:`MLXLMCommon/Tool/ToolCallFormat.swift:157-158`) parses the same invoke/parameter grammar without the `｜DSML｜` prefix. Reuse its scanner for a fork `ToolCallFormat.dsml`, so the streaming path benefits as well.
  - **Reasoning.** Split on `</think>`, starting in the thinking state when the prompt ended with `<think>`. The existing splitter (M:`macprovider-cli/LocalResponsesAdapter.swift:239-257`) starts in the visible state and would leak reasoning. Map `reasoning_effort` to E:`66-80`, with `low` as the default.
- **#2107 gate.** DSV4 rows become recommendable only with a passing buyer-UX conformance record. That covers:
  - `tool_choice` auto, required and named;
  - streamed tool deltas and a tool round trip;
  - reasoning separation;
  - JSON mode and stop strings;
  - `/v1/messages` with `anthropic-beta` and `thinking`;
  - `/v1/responses` tools;
  - context-limit errors and `finish_reason`.
- Golden tests: byte-exact prompts against `encode_messages` and parse round-trips against `parse_message_from_completion_text` for 10 or more fixtures (tools, parallel calls, thinking/chat, multi-turn with dropped thinking).

### 1.10 V4.1 deltas (`deepseek_v41`)
References: V:`deepseek_v41/language.py`, V:`deepseek_v41/engram.py`, L:`deepseek_v41.py`.

- **Config.** 40 layers, hidden 5120, 384 experts, `rms_norm_eps 1e-20`.
  - Config parsing must unwrap `text_config` (L:`deepseek_v41.py:63-66`).
  - The vision tower is dropped on the text path. Sanitize removes `vision.`, `aligner.`, `image_` and `mtp.` (L:`deepseek_v41.py:1014`) and `gate.bias_vl` (`:1126-1128`).
- **Compress ratios 1 and 2** replace 4 and 128.
  - Ratio 1 is a plain projection with no gate (V:`deepseek_v41/language.py:700-720`).
  - Only `kv_source_layer_ids [2,8,14,20]` own a compressor. The other layers read the source layer's pooled KV (`:514-520`, `:563`). L:`deepseek_v41.py:770-816` computes the sharing layout.
- **Indexer sharing and candidate blocks** (§1.2).
- **Cache.** The reference cache is whole-model (`DeepseekV41Cache` with cross-layer handoff `index_k`, `candidates`, `compress_kv`, `topk_idxs`, V:`:953-975`; batched form `:1131`). It is not per-layer, so CB and paged KV need a model-level row state. That is new work for the paged bridge, which is per-layer today.
- **Engram, layers 1 and 14** (V:`deepseek_v41/engram.py:118` layout, `:163` n-gram hash, `:362` offloaded embedding, `:509` `Engram`).
  - The n-gram hashed embedding tables have `engram_num_embeddings` of about 384M rows each. The reference reads rows from the checkpoint on the CPU without making them resident.
  - **mlx-lm main refuses engram configs** (L:`deepseek_v41.py:68-74`). V4.1-Flash sets `engram_layer_ids [1,14]`, so mlx-vlm is the only usable V4.1 reference.
  - Table size in the 4-bit artifact: unverified.
- **MTP:** three DSpark stages with 128 experts each. No reference exists (§1.8).

## 2. Slice order
One campaign PR in the fork plus one in macprovider (AGENTS.md rules 4 and 13). Each slice is one commit. Estimates are engineer-days.

| # | Slice | Repo | Est. |
|---|---|---|---|
| 1 | **Parity oracle and harness.** One Studio window with mlx-vlm 0.7.10 on the MXFP4 artifact. Greedy oracles for prompts of 1024, 8192 and 32768 tokens: `oracle_1024.npz`, `oracle_8192.npz`, `oracle_32768.npz`, each with arrays `prompt` (int32 [N]), `greedy` (int32 [G]), `top_idx` (int32 [16,16]) and `top_logprob` (float32 [16,16], log-softmax for the first 16 decode steps). Script: `scripts/lab/dsv4/dsv4_reference_bench.py`, run as the `dsv4-reference` job of `scripts/ops/studio-lab-window.sh`. The same window records the rule-12 baseline (§3). Adds a fork test that loads an `.npz` and runs a model greedily against it. | fork | 1.5 |
| 2 | **Skeleton.** DONE 2026-10-22, fork `dsv4/2111-port` @ `fe28d000` (see §6). `DeepseekV4Configuration` (+ validation), sanitize (key remap from the MXFP4 artifact, mxfp4/mxfp8 quant map, `tid2eid` as int32), sqrt-softplus gate + hash routing (§1.1, §1.6), mHC reuse + `HyperHead` (§1.3), `DeepseekV4RoPE` x3 (§1.7), `LocalAttention` with sinks, inverse RoPE and grouped `wo_a` (§1.5). Register `deepseek_v4` in `LLMModelFactory` (F:`MLXLLM/LLMModelFactory.swift:91` pattern). | fork | 3 |
| 3 | **Compressor and pool cache.** DONE 2026-10-22 (same commit). `DeepseekV4PoolCache` with overlap and exact trim (§1.4), `CompressedAttention` (ratio 128). | fork | 3 |
| 4 | **Indexer and sparse attention.** Code DONE 2026-10-22 (same commit); real-weights gate waits for a GLM-off window. `SparseCompressedAttention` (ratio 4), dense to sparse at 512 pools. **Gate:** greedy parity on all three oracles. | fork | 3 |
| 5 | **Decode performance.** mxfp4/mxfp8 variants of the router, expert and QMV decode kernels (or a measured decision to stay on `gatherQMM`), deferred HC decode and staged eval reuse. **Gate:** 1-row decode tok/s at least equal to the reference. Research target 40-46 tok/s at 1 row (notes in §6.3). | fork | 4 |
| 6 | **CB and paged KV.** Batched per-row V4 caches (fork), `.pagedPool` cache kind + `PagedPoolCache` + attach parity probe longer than 2048 tokens, family default block 256, `deepseek_v4` family detection (M:`macprovider-cli/ModelRuntime.swift:3060-3071` pattern), resident-weights and command-buffer family entries (`:2879`, `:2918`). **Gate:** CB token parity at 1/2/4/8 rows. | both | 5 |
| 7 | **DSpark native MTP (0731).** Hidden capture, block drafter, Markov head, pool rewind for verify, `deepseek_v4_dspark_v1` adapter, SPEC-048 sidecar fields. **Gate:** the native-vs-ordinary CB R015 cells (§3). | both | 5 |
| 8 | **DSML.** Swift `encode_messages` port with golden tests, `.dsml` tool parser (fork + `ToolCallParser`), think-state splitter + `reasoning_effort`, #2107 conformance record. | both | 4 |
| 9 | **V4.1 (`deepseek_v41`).** Config unwrap, ratio 1/2 compressors with KV/index sharing, candidate blocks, engram (hash + offloaded rows), 384 experts, whole-model row cache for CB, DSpark V4.1 (no reference). Load and smoke test on the 2-bit conversion are best effort only, because it does not fit 256 GB with headroom. Parity and qualification run on the first 512 GB provider. | both | 8 |
| 10 | **Catalog and live.** V4-Flash row for 256 GB providers and V4.1-Flash row for 512 GB only, activated through `scripts/ops/catalog-activate.sh`. GLM-5.3-Flash stays the serving model on the current 256 GB Studio. | macprovider | 2 |

The total is about 38.5 engineer-days. V4-Flash serving with CB, MTP and DSML (slices 1-8 and 10) is about 30.5 days. V4.1 adds about 8 days plus the 512 GB hardware dependency.

## 3. Measurement gates (AGENTS.md rule 12)
- **Before any code (slice 1)**, measure the mlx-vlm reference on V4-Flash-0731 MXFP4 in one Studio window:
  - output tok/s at 1 and 4 rows;
  - TTFT at 4k and 32k;
  - the greedy oracles.
  
  GLM is restored afterwards. Port slices are judged against these numbers and never against a side metric.
- **Token parity (slices 4, 6 and 9):**
  - The greedy token sequence must match the oracle.
  - A divergence is allowed only at a near-tie step, where the oracle's top-2 `top_logprob` gap is under 0.05. Generation is then re-anchored on the oracle token and checked again.
  - The top-5 `top_idx` sets must match at every step.
  - CB parity: each of N rows equals its own 1-row run, for N in {1, 2, 4, 8}.
- **Throughput (slices 5 and 6):**
  - native 1-row decode tok/s at least equal to the reference 1-row figure;
  - CB aggregate output tok/s at 4 rows at least equal to the reference 4-row figure;
  - TTFT at 4k and 32k no worse than the reference by more than 10%.
- **Native MTP (slice 7):** SPEC-048 R015 cells, native DSpark against ordinary CB at the **same row count**. Each cell reports:
  - output tok/s;
  - acceptance (mean accepted per round);
  - TTFT;
  - token parity (greedy).
  
  MTP ships enabled only where tok/s beats ordinary CB in that cell (rule 11). Otherwise the adapter stays unadmitted for that row count.
- **Buyer UX (slice 8):** a #2107 conformance record for every advertised capability.
- **Done means live (rule 1):** a paid gateway request served by V4-Flash with CB, and with MTP where admitted.

## 4. Key risks
1. **MXFP4/MXFP8 kernels.**
   - Every GLM fused decode kernel is affine-only (F:`GLM5Next.swift:177-195`; `glm5NextQMVFastCovered`, F:`GLM5NextDecodeKernels.swift:2615`).
   - On the published 4-bit artifact, decode therefore falls back to generic `gatherQMM`/`quantizedMM` in mx modes. The GLM gains came from those fused kernels.
   - An affine re-quantization of the bf16 or fp8 source is the fallback artifact. It changes the identity and needs its own oracle.
2. **CB and MTP over the compressor state.**
   - Per-row remainder phases, overlapping ratio-4 windows and pool rewind on rejected drafts all have to be exact.
   - The reference sidesteps this by requiring uniform acceptance (V:`models/cache.py:2764`, V:`deepseek_v4/language.py:1174`).
   - The fork's per-row loop (F:`GLM5Next.swift:917-1007`) is the plan, but MTP with more than one row is new ground. Today's embedded adapter is capped at 1 row (M:`macprovider-cli/NativeMTPAdmissionSidecar.swift:521-523`).
3. **V4.1 has no full reference and no lab box.**
   - Engram tables, cross-layer KV and index sharing, and a whole-model cache are all present.
   - mlx-lm main refuses engram (L:`deepseek_v41.py:68-74`), and mlx-vlm has no V4.1 DSpark drafter.
   - The 4-bit (~432 GB) qualification depends on a 512 GB provider joining.
4. Smaller risks:
   - SDPA with sinks at head dim 512 (unverified fused support).
   - Hash routing needs token ids threaded through MoE and MTP verify (§1.6).
   - The DSML BPE marker split (PR #1337 note) in streaming detection.
   - Thinking-mode prompts start inside `<think>` (§1.9).

## 5. Unverified items
- The non-0731 V4-Flash MTP layout: the index was not inspected.
- V4.1 engram table byte size.
- MLX fused SDPA with `sinks` at D=512.
- Router kernel limits at 384 experts.
- The V4.1 DSpark stage semantics (no reference implementation).

## 6. Progress

### 6.1 Reference measurements and oracles (slice 1, 2026-10-22 window)
Run: mlx-vlm 0.7.10, mlx 0.32.4, macOS 27.0.1 (26A434), greedy, `prefill_step_size` 2048, no prompt cache. Model config SHA-256 `2c6e5047fbc5284f3dbdd101059d2d29f1ceb14cdc26ee93c9872c720398e35a`.

| Mode | Prompt | TTFT s | Prefill tok/s | Decode tok/s | Peak GB |
|---|---|---|---|---|---|
| 1 row | 1024 | 2.49 | 411 | 31.4 | 157.6 |
| 1 row | 4096 | 11.88 | 345 | 28.1 | 160.0 |
| 1 row | 8192 | 22.95 | 357 | 27.9 | 160.1 |
| 1 row | 32768 | 93.24 | 351 | 27.4 | 160.4 |
| BatchGenerator, 1 row | 1024 | 2.47 | | 31.7 (window) | 157.6 |
| BatchGenerator, 4 rows | 1024 each | 9.05 | | 67.4 (window), 42.4 aggregate | 160.5 |

Oracles, copied from the window output into the lab oracle directory. The JSON files are the `dsv4-parity` inputs, made with `scripts/lab/cb-studio/glm53_oracle_json.py` (`top_logprob` goes into `top_logit`):

| File | SHA-256 |
|---|---|
| `oracle_1024.npz` | `29cd60e5530227a7335d5d1d815dfe575efe599fe9ee8488936c1140f6130134` |
| `oracle_8192.npz` | `99c2c330dc476df8898cd4bb1ac643e895edc50f2a0dd9b1ffcbb20b4f6eb260` |
| `oracle_32768.npz` | `4af7beba7c075cb94cef0e29d32b4eff4694cd90c0efe2681891e6f60bb952d9` |
| `speed.json` | `963e43513c12820af4e746547623e0ed39b369982fb1019615eb32edf29d825c` |
| `oracle_1024.json` | `9a4b52976bbdd471f27dcd5084f93211e8c354ba1a817db3a2ba166bbed41f41` |
| `oracle_8192.json` | `681c6ac87ebc7b0762d67ebfdd7165cc1ceb76f3a0e7f428c406ca73864157a1` |
| `oracle_32768.json` | `b61db4d5b6006fce20b07537af27b99e60dd1ef75341f9d12b8353771d6f459f` |

Prompt int32 SHA-256 values are 1024 `343ae4eb…`, 8192 `c581a732…` and 32768 `8d9499ab…`, as recorded in `speed.json`. The top-2 log-prob gap at step 0 is 15 to 20, so top-1 is far from a tie.

### 6.2 Slices 2-4 (fork `Augustas11/mlx-swift-lm` branch `dsv4/2111-port`, commit `fe28d000c3af00f6880591a31e36f5064d9d142b`, one commit on `87dc5159`)
- `Libraries/MLXLLM/Models/DeepseekV4.swift` contains:
  - the configuration, with validation and the reference HISA defaults;
  - `DeepseekV4RoPE`, with the local base, the YaRN compress base and the compressor `freq_scale`;
  - the sqrt-softplus gate with hash routing from token ids;
  - the MoE, using `SwitchGLU` and the limited SwiGLU;
  - the compressor, with simple and overlapping windows;
  - the indexer, with HISA decode, HISA prefill and the flat path;
  - attention for ratios 0, 4 and 128, with sinks, inverse output RoPE, grouped `wo_a`, and sparse pooled attention;
  - `HyperHead`;
  - sanitize.
- mHC reuses `GLM5NextHyperConnection`, which gained a size-only init.
- `Libraries/MLXLMCommon/DeepseekV4PoolCache.swift` holds the remainder buffer and the pool. The 128-token window is the fork's `RotatingKVCache`.
- Module paths equal the artifact's tensor names, so `config.json`'s per-layer `mxfp4`/`mxfp8` entries apply unchanged on the generic quantized path.
- Tests, `Tests/MLXLMTests/DeepseekV4Tests.swift`, run CPU-only on the Studio:
  - A 4-layer fixture made by the reference has a hash layer, ratios 0/4/128/4, an 8-token window, and MXFP4/MXFP8. Its `make_fixture.py` sits beside it. The fixture decodes bit-identically to mlx-vlm `generate_step`: 24 tokens, max abs log-prob diff 0.0, for HISA and flat selection at chunk plans 64, 2048 and 16.
  - Pool-cache, config and sanitize unit tests.
  - `testArtifactLayoutMatchesModuleTree` builds lazy placeholders from the real artifact's safetensors headers. It checks every name, shape and quantization mode against the module tree without reading a weight.
- macprovider (#2112):
  - the fork pin;
  - `deepseek_v4` family detection, resident weights and the command-buffer budget;
  - the lab-only `dsv4-parity` command (`GLMParityCommand.Mode.vlmGenerateStep`).
- Not done yet: the real-weights parity run (GLM-off window). GPU numerics use the GLM fused HC decode kernels at one token per row and the op path elsewhere; the reference uses its Metal `hc_sinkhorn_collapse` kernel. Divergence is therefore judged by the §3 near-tie rule, not bit-exactness.
- Changing the pin changes the SPEC-048 decode-path digest (`DecodePathIdentity.generated.swift` regenerated). The signed native-MTP admission entries carry `runtime_revision 87dc5159`. They have to be rebound to the campaign's final revision and digest at the campaign cut, which happens after #2111 lands, per the operator rule.

### 6.3 Fast-decode research notes (for slice 5 and later)
The realistic 1-row target is 40-46 tok/s, against the reference's 27-31. The levers, in expected order of payoff:
- A fixed-shape whole-token decode graph (compile one token's forward at fixed shapes, so no per-step graph build).
- A fused MXFP4 MoE: router, gather and expert GEMV in mxfp4 tiles. This replaces `gatherQMM`, which is today's generic path.
- Fused MXFP8 attention projections (`wq_a`, `wq_b`, `wkv`, `wo_a`, `wo_b`, `indexer.wq_b`).
- Fused mHC, as GLM: mix GEMV plus Sinkhorn, collapse and norm, with a deferred expand.
- One sparse-attention kernel: window, gathered top-k pool entries and sink in a single softmax.
- An indexer fast path: HISA coarse and fine scoring in one kernel at decode, with the pool count fixed between window completions.

### 6.4 Serving, DSML and the listed catalog row (2026-10-23)
- Real-weights parity (slice 4 gate) PASSED in the 2026-10-22 window: 16/16 top-1 and 256/256 greedy tokens at 1k, 8k and 32k, no divergence; native decode 31-36 tok/s at 1 row, peak 165 GB.
- Fork `baec1724` (one commit on `fe28d000`): `DeepseekV4Model.prepare` prefills with the reference chunk plan (2048-token chunks while more than one prompt token is left, then the last token), whatever step size or chunking the caller passes. This is the plan the oracles used, and §1.4 makes the pools depend on it. Test: `TokenIterator` decodes the step-2048 tiny-fixture oracle cases exactly under remainder, balanced and unchunked parameters.
- Serving (`macprovider-cli serve`): serial. `ModelRuntime.modelSizesItsOwnKVCache` covers `DeepseekV4Model`, so the serve cap no longer fails `incompatibleCapacity` on the pool caches. Continuous batching and paged KV stay off: `deepseek_v4` is not in the paged-KV family gate and the caches are `CacheList`s. CB is slice 6.
- Prompt encoding (§1.9): `DeepseekV4Encoding` (M:`macprovider-cli/DeepseekV4ChatEncoding.swift`) ports `encode_messages`; `DeepseekV4ChatTokenizer` renders it for template-less `deepseek_v4`/`deepseek_v41` artifacts. Tools ride on the first system message (an empty one is added when there is none). Thinking mode by default; `reasoning_effort` none -> chat mode, high/xhigh -> high, max -> max, else low.
- Output: `ToolCallGrammar.dsml` and `ToolCallParser.parseDSMLCalls` (parallel invokes, schema-typed values); calls stream whole with one index each; reasoning goes through the existing `<think>` split. SPEC-018 v0.3.2 (Amendment 10).
- Goldens: `scripts/lab/dsv4/make_encoding_fixtures.py` runs the reference and writes `scripts/tests/fixtures/dsv4-encoding/cases.json`; `DeepseekV4EncodingTests` matches 4 reference prompts and 14 provider requests byte for byte and 7 parsed completions.
- Known gap: swift-transformers splits a newline from preceding punctuation (`.\n`, `\n\n`) where the HF tokenizer merges them (`.Ċ` 603, `ĊĊ` 271). Prompt text is identical and decodes back exactly; token ids differ on those boundaries (12 of 14 request prompts).
- Catalog release `published-2026-10-23-deepseek-v4-flash-listed-v1`: `deepseek/deepseek-v4-flash` listed, artifact `TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX@d6be051a`, snapshot hash `58ee40d4…` (HF tree, 62 files, 167,094,772,883 bytes), `min_ram_gb` 195 (165 GB peak + 26 GB floor + 4 GB margin). Rate row 45000 / 2500 / 130000 credits per Mtok ($0.045 / $0.0025 / $0.13), below every OpenRouter `deepseek/deepseek-v4-flash` endpoint on 2026-10-23 (floor: prompt $0.05 Relace, cache hit $0.014 StreamLake, completion $0.14 StreamLake) and DeepSeek's off-peak list price ($0.15 / $0.003 / $0.60; https://api-docs.deepseek.com/quick_start/pricing/).
