# Step 1 root cause: batched-isolation gate fails on the 3.32.3 pin (2026-10-09)

**Status: root cause found, fix proven in the lab, and published: the fork
pins resolve from GitHub and the deps branch builds on them (see
"Publication").**

## Root cause

MLX core 0.32.2 (bundled by mlx-swift 0.32.3) picks a different quantized
matmul kernel by the number of rows `M` in the call, and the kernels reduce
`K` in different orders. A row's output therefore depends on how many other
rows share the call. MLX core 0.31 (bundled by mlx-swift 0.31.4, live 1.8.230)
had none of these routes: small `M` always took `qmv`, large `M` always took
`qmm`, and both reduce `K` in one fixed order for any `M`.

Two routes break this on `qwen/qwen3.6-35b-a3b` (all linears are affine
quantized: 4-bit, router `gate` and `shared_expert_gate` 8-bit, group 64):

| Core route (MLX 0.32.2) | Upstream commit | Where it fires in the probe | Serial (1 row) | Shared forward (2 rows) |
| --- | --- | --- | --- | --- |
| `qmv_wide` for `2 <= M < vector_limit`, affine on Apple GPU gen 15+ (M3 is gen 15) | `548dd80e8` (#3764) | every decode step and the 1-token final prefill chunk | `qmv` (M = 1) | `qmv_wide` (M = 2), different `K` lane split and shuffle-ladder order |
| `qmm_splitk` for `M >= vector_limit`, transposed, non-batched; `split_k = 512 / (n_tiles * m_tiles)` | `38ad25708` (#3120) | the 512-token prefill chunk on narrow outputs: router `gate` (N = 256) and `shared_expert_gate` (N = 1) | M = 512: 4 and 32 K-splits | M = 1024: 2 and 16 K-splits |

`mlx/backend/metal/quantized.cpp` at core `1f8e74e3f` (v0.32.2):
`dispatch_qmv` line 1762 (`if (M >= 2 && use_qmv_wide(mode, d) && !global_scale)`)
and `QuantizedMatmul::eval_gpu` lines 1807-1814 (`qmm_splitk` for
`transpose_ && B == 1`).

The macprovider probe is not at fault. Its serial path
(`PagedKVRuntimeParityProbe.greedyGenerate`, `model(MLXArray, cache:)` on
`KVCacheSimple`/`MambaCache`) and the shared path
(`PagedKVSharedForwardBackend.prefill` / `decodeLockstepWindow`,
`model(LMInput.Text, cache:)` on `PagedKVBatchLayerCache` + packed
`MambaCache`) use the same chunk boundaries (512 + 1 for the 513-token prompt,
`defaultPromptChunkTokens` = 512 on both sides) and, at B = 1, the same model
route: both decode through the 3.32 compiled segment schedule
(`Qwen35TextModelInner.decodeStep`; `PagedKVBatchLayerCache.makeMask` returns
`.none` for equal-length n = 1 rows). The 1-row shared forward matches serial
token for token on the unfixed build (below). Only the row count differs, and
only the core kernel choice depends on it.

None of the mlx-swift-lm candidates is involved: the fork is unchanged by the
fix, fused A3B MoE on and off both pass with it, and every mlx-swift-lm 3.32
change (direct expert reduction, shared router top-k, gated-delta precision,
GDN conv folding, #511, the GDN checkpoint commit, compiled decode segments)
runs identically before and after the fix.

## Bisect

Diagnostic build: the 3.32.3 pin with mlx-swift-lm and mlx-swift as local path
dependencies, env-gated switches in core `quantized.cpp`/`matmul.cpp`, and a
probe log line with the first divergent token index for the 1-row and 2-row
shared forwards against serial. Same Studio, artifact, config and metallib
(`f42aef60…`) as the step 1 runs. 48 greedy tokens after the 513-token parity
prompt of challenge pair 0.

| Run | Core routes disabled | 1-row A first divergence | 2-row A | 2-row B | Gate |
| --- | --- | --- | --- | --- | --- |
| `base` | none (stock 0.32.2) | none | token 0 | token 21 | `proven=false` |
| `only-noqmvwide` | `qmv_wide` | none | token 0 | none | `proven=false` |
| `only-nosplitk` | `qmm_splitk` | none | token 0 | token 21 | `proven=false` |
| `qmvwide-splitk` | `qmv_wide`, `qmm_splitk` | none | none | none | `proven=true`, pairs 0-2 parity exact |
| `alloff` | `qmv_wide`, `qmm_splitk`, `gemv_wide`, `dot_product` | none | none | none | `proven=true` |
| `widem1-nosplitk` | `qmm_splitk`; M = 1 also sent to `qmv_wide` (tile >= 2) | none | none | none | `proven=true` |

Row A token 0 is sampled from the 1-token final prefill chunk after the
512-token chunk, so it sees both routes (2-row `qmv_wide` in the final chunk,
2-row `qmm_splitk` in the 512 chunk); either alone flips it. Row B's token 21
is decode-only (`qmv_wide`). `gemv_wide` and `dot_product` (new bf16/fp16
small-M routes, same class of defect) do not fire on this all-quantized model.

## Fix

Core MLX, host routing only (no kernel or metallib change):
every small-M quantized product goes to `qmv` and every `M >= vector_limit`
product to `qmm`, as in MLX 0.31.

| Repo | Branch | Commit |
| --- | --- | --- |
| MLX core (fork of ml-explore/mlx, base v0.32.2 `1f8e74e3f`) | `macprovider/0.32.2` | `ff1b9483201578cf55e9c9220414c46427f20969` "Keep small-M quantized matmuls batch-invariant", `mlx/backend/metal/quantized.cpp` +9/-13 |
| mlx-swift (fork, base 0.32.3 `19601207`) | `macprovider/0.32.3` | `d073a644c559318d93e267ed2a53baf434787a41`: `Source/Cmlx/mlx` gitlink to the core commit, `.gitmodules` URL to the core fork |
| mlx-swift-lm (`macprovider/3.32.3`, on `d9897e6`) | `macprovider/3.32.3` | `37f0d7c`: `Package.swift` resolves mlx-swift from the fork at `d073a644…`. Model code unchanged. |

The macprovider isolation gate, its tolerance and CB enablement are unchanged.

Why route back to `qmv` instead of sending M = 1 through `qmv_wide`:
`qmv_wide`'s per-vector sum does not depend on its tile width, so M = 1 on a
2-vector tile reproduces batched rows exactly (`widem1-nosplitk` passes). It
costs about 5% single-stream decode, which is the common light-load case; the
`qmv` route costs nothing at one row (table below).

No env kill switch: switching the fix off brings back the batch-dependent
kernels, the gate fails closed and CB does not attach.

## Proof

Release build of the diagnostic tree with the switches removed: macprovider
sources identical to `fe398edbd`, mlx-swift-lm `d9897e6` (unchanged), mlx-swift
0.32.3 with the core commit above applied (same diff, `git diff` SHA-1
`ee05d071…`). Executable SHA-256
`c92bac5f4ec7d5614f7e5d6f6d1306fcbfd038cc78a1d39503dfe6175cc5824b`, metallib
`f42aef60…` (unchanged: the fix is host code). Isolated loopback 18195-18199,
`build/lab-serve.sh` config.

| Run | Env | Paged-KV parity | Batched isolation | `/v1/status` CB |
| --- | --- | --- | --- | --- |
| `proof-fused` | default (fused MoE on) | `established=true` (640/640 gather calls) | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` (pair 2; pairs 0 and 1 parity-exact but indistinguishable, as on 1.8.230) | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `unsupported_reason=null` |
| `proof-stock` | `MLX_LM_QWEN35_FUSED_MOE=0` | `established=true` | same as fused | `active=true`, `attached`, `passed` |

Both logs end `measure OK: runtime measurement complete, paged-KV attach
eligible for model=qwen/qwen3.6-35b-a3b`. The pair sequence and sampled
tokens match the 1.8.230 control run line for line.

### Serial output against 1.8.230

Temperature 0, 96 max tokens, chat completions on an isolated port (CB policy
off, so requests take the serial path):

| Prompt | Prompt tokens | 1.8.230 control | 3.32.3 unfixed | 3.32.3 fixed |
| --- | ---: | --- | --- | --- |
| Haiku about autumn leaves | 20 | "Crimson, gold, and brown, / Dancing on the cooling wind, / Whispering goodbye." (23) | same as control | "… / Dancing on the cooling wind, / Fall returns again." (22) |
| Why the sky is blue, two sentences | 23 | 48 tokens | identical | identical |
| First ten primes | 22 | `2, 3, 5, 7, 11, 13, 17, 19, 23, 29` | identical | identical |
| One-sentence summary of a repeated paragraph | 782 (512 + 270 chunks) | "A river delta forms when sediment carried by a current settles as the water slows near the sea." | identical | identical |

The haiku differs only in its third line. Its 20-token prompt is prefilled as
one M = 20 call, below `vector_limit`: the unfixed build takes `qmv_wide`
there, the fixed build takes `qmv`, and 1.8.230 takes 0.31's `qmv`. All three
compute the same bf16 math in different summation orders, and the third line
is a near-tie between two valid continuations, so neither output is more
faithful to the model in any measurable sense; the control agreeing with the
unfixed build is a coin flip, not evidence. The fixed build is the only one
whose serial output a continuously batched row reproduces exactly, which is
the property the gate exists to prove. The >512-token prompt and the other
short prompts are identical across all three builds.

## Throughput

Same build, switches toggled at runtime, Studio shared with the live provider
(single samples; differences under ~3% are within noise). `decode-bench`
(512-token prompt, 256 decode tokens, 3 runs, two interleaved rounds) and
`msb-throughput --engine paged` (1024-token prompts, 128 decode tokens,
compiled lockstep).

| Metric | Stock 0.32.2 | Fixed (`qmv` + `qmm`) | M = 1 via `qmv_wide` (not chosen) |
| --- | ---: | ---: | ---: |
| Single-stream decode tok/s (p50, 2 rounds) | 98.3 / 98.8 | 101.8 / 98.8 | 93.9 / 92.9 |
| Prefill tok/s (p50) | 1613 / 1616 | 1618 / 1606 | 1633 / 1622 |
| Paged aggregate tok/s, 2 rows | 111.8 | 109.9 | 111.1 |
| Paged aggregate tok/s, 4 rows | 162.2 | 155.5 | 164.3 |
| Paged aggregate tok/s, 8 rows | 210.8 | 200.2 | 203.9 |

The fix costs nothing at one row and in prefill. Batched decode gives back the
`qmv_wide` gain that MLX 0.32 added: about 2-5% of aggregate at 2-8 rows
against stock 0.32.2. Against live 1.8.230, which never had `qmv_wide` or
`qmm_splitk`, these routes are unchanged. The stock number is not usable in
production either way, because without the fix CB does not attach and all
concurrent traffic is serial-routed.

## Publication

The forks exist, and the pinned tree resolves and builds from them.

| Repo | Ref | Commit |
| --- | --- | --- |
| `Augustas11/mlx` (core) | branch `macprovider/0.32.2`, tag `v0.32.2-macprovider.1` | `ff1b9483201578cf55e9c9220414c46427f20969` |
| `Augustas11/mlx-swift` | branch `macprovider/0.32.3`, tag `0.32.3-macprovider.1` | `d073a644c559318d93e267ed2a53baf434787a41` |
| `Augustas11/mlx-swift-lm` | tag `3.32.3-macprovider.2` | `37f0d7ceacf6f5eca3ec2ceddc96d0f6e91ed2f1` |

All refs were checked with `git ls-remote` on 2026-10-09. `phase3-binary/Package.resolved` on the deps
branch (`531ce132a` and later) pins mlx-swift-lm `37f0d7c…` and mlx-swift
`https://github.com/Augustas11/mlx-swift` at `d073a64…`. A clean Studio
`swift build -c release` resolves both from GitHub, with the core submodule at
`ff1b948…`. Steps 1-5 are rerun on that tree in `README.md`.

## Follow-ups found on the way

- `gemv_wide` (bf16/fp16, `0ebcee8db`) and `dot_product` (M = N = 1,
  `36fde2757`) are the same class of batch-dependent route for unquantized
  matmuls. They do not fire on this model; a model with unquantized linears
  would fail the same gate. Check with the step 2 rows (`qwen/qwen3.6-27b` is
  also in the accepted tuples).
- The attach log's `reason=paged_fallback_metallib` (README) mislabels an
  isolation-gate failure.
