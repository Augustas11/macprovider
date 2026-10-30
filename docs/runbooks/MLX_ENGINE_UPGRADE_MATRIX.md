# MLX engine dependency-upgrade release gate

This is the mandatory correctness-first matrix for any change to `mlx-swift-lm`, `mlx-swift`, bundled core MLX/metallib, or adjacent generation APIs. It implements the acceptance surface tracked by #700. `phase3-binary/Package.resolved` is the production dependency authority.

## Hard rules

1. Resolve production only from the immutable fork tags in [Fork model](#fork-model), each pinned by full revision. Never resolve production from a branch, a version range, or a moved tag.
2. Record exact before/after versions and revisions for `mlx-swift-lm`, `mlx-swift`, `swift-transformers`, and `swift-jinja`.
3. Keep `swift-transformers` unchanged during the MLX engine migration; evaluate it separately under #966.
4. Build, test, resolve, candidate, and release jobs that compile `phase3-binary` or Malibu.app run only on the protected build toolchain: Xcode 26.6 (17F113) at `/Applications/Xcode_26.6.app`, Swift 6.3.3, macOS SDK 26.5, on the `macos-26` / `macos-26-intel` images. It replaced Xcode 16.4 / Swift 6.1 in the reviewed release-toolchain migration that landed with the mlx-swift-lm 3.32.3 dependency upgrade (`mlx-swift 0.32.3` declares `swift-tools-version: 6.3`; Related: #1906, #700). The protected `macos-15-intel` signers stay on the pinned signer toolchain (Xcode 16.4) for the sealed OpenSSL bottle and never compile the package. Any further toolchain move needs its own reviewed migration and release-runner proof.
5. Correctness, token accounting, cache ownership, and artifact parity gate throughput. No performance waiver may override a red correctness row.

## Evidence header

Every run must attach:

- branch and commit;
- macOS, Xcode, Swift, Mac model/chip/RAM, power and thermal state;
- all four resolved package versions/revisions;
- executable SHA-256, model ID and artifact SHA-256;
- `default.metallib` SHA-256 and the MLX/core revision it was built from;
- generation parameters, random seed, prompt fixture revision, and cache/prefill/speculative settings;
- baseline and candidate JSON outputs containing prompt token IDs, generated token IDs, decoded bytes, stop reason, prompt/completion accounting, and tool/reasoning parse result.

## Fork model

The production MLX runtime is three operator-owned forks under `Augustas11`.
They are the permanent production runtime: MacProvider makes no upstream
contributions and does not wait for upstream to carry its patches. Each
upstream release MacProvider adopts is a rebase of all three patch stacks onto
the new upstream tags, new fork tags, and a pass of the per-rebase acceptance
gate below. SPEC-048 MTP-3 (R003) names the exact authorized tuple; a new tuple
needs a SPEC revision.

| Fork | Upstream | Tag scheme | Current tag | Revision | Upstream base |
| --- | --- | --- | --- | --- | --- |
| `Augustas11/mlx-swift-lm` | `ml-explore/mlx-swift-lm` | `<upstream>-macprovider.<n>` | `3.32.3-macprovider.10.16.5` | `939d938cdb6ef8bdc61facf0face5fead843863f` | `3.32.3` (`3b339ad6…`) |
| `Augustas11/mlx-swift` | `ml-explore/mlx-swift` | `<upstream>-macprovider.<n>` | `0.32.3-macprovider.9` | `29d3b93375cc56cd2649b40e4310a8bc445e9874` | `0.32.3` (`19601207…`) |
| `Augustas11/mlx` (MLX core) | `ml-explore/mlx` | `v<upstream>-macprovider.<n>` | `v0.32.4-macprovider.4` | `2f512e3997349c8648f5d7c5113eb2c825aa242d` | `v0.32.4` (`36969c09…`) |

Tags are immutable: a change is a new `<n>`, never a moved tag. Each link pins
the next by full revision: `phase3-binary/Package.swift` pins mlx-swift-lm,
mlx-swift-lm's manifest pins mlx-swift, and mlx-swift's `Source/Cmlx/mlx`
submodule commit pins core (`Source/Cmlx/mlx-c` stays upstream). Swift 6.3 is
the effective minimum for the graph (mlx-swift declares tools version 6.3);
the mlx-swift-lm fork keeps upstream's tools version.

### Current tuple delta

As of 2026-10-30, `Package.resolved` and SPEC-048 R003 select
`3.32.3-macprovider.10.16.5` (`939d938cdb6ef8bdc61facf0face5fead843863f`).
It retains the combined GLM packed-verification, Prism loader, LFM expert-order
and DeepSeek CB work, then aligns DeepSeek's arithmetic and bounded full-context
prefill with the QAT-off reference and selects its artifact-tested packed
verifier. The `.10.16.5` successor uses a scalar fallback only on CPU;
the `.10.16.4` artifact-tested GPU packed body remains byte-identical.
DeepSeek's final prefill chunk remains whole, bounded at 32768 tokens;
prompt snapshots retain only earlier whole chunks. Native DSpark depth/R015
qualification remains separate and pending. The mlx-swift and core pins are
unchanged. Historical measurements retain their actual dependency identities.

### Patch inventory

Every rebase replays these stacks and drops any patch upstream now carries
(record which, and why it is equivalent).

mlx-swift-lm (`3.32.3..939d938c`, tag `3.32.3-macprovider.10.16.5`, branch
`codex/2151-fidelity-resume`): tag `3.32.3-macprovider.10.5` (`c8be0f61`)
plus main’s GLM packed projections, Prism/Bonsai loader and LFM expert-order
correction from `3.32.3-macprovider.10.15.1`, together with DeepSeek-V4 fidelity to DeepSeek's reference and embedded DSpark with
exact packed-prefix verification. The current successor also corrects
reference norm, rotary, hyper-connection, router and indexer arithmetic; it
retains shared MXFP8 projection tiles across two to eight DeepSeek vectors.
Throughput qualification remains separate. 10.5 is tag
`3.32.3-macprovider.10.4` (`676a62a4`) plus
shared attention/compressor/indexer work, per-row rotary offsets, keys-only
windows and geometric pool storage. 10.4 is `3.32.3-macprovider.10.3` (`baec1724`,
`dsv4/2111-port`) plus row-owned DeepSeek-V4 batched decode and incomplete
pool continuation safety. The prior tag adds DeepSeek-V4 to
`3.32.3-macprovider.10.1` (`87dc5159`, `glm53/tuple-0324`) on the
`3.32.3-macprovider.10` stack. `3.32.3-macprovider.10.2` remains an unrelated
GLM candidate outside the tuple. CPU fixture parity is separate from the
pending real-weight native four-row throughput gate and campaign freeze audit.

| Patch | Commits | What it carries |
| --- | --- | --- |
| MTP cache transactions | `87cefcd` | Public row-mapped `MTPKVCacheTransaction` stage/commit/discard/rewind. |
| Packed MTP verification | `d7404cf`, `5c8811c`, `2c36a18`, `5402834`, `47835cf`, `038edb7`, `53e32e9`, `edeee8a` | `verifyMTPPackedTargets`, exact state across rounds, row state outside drafters, serialized drafter access, standalone Qwen MTP for packed hybrid schedulers, padded zero-proposal Mamba fix, host offset mirrors, deferred Mamba commit evaluation. |
| Packed drafter | `49aa6af` | `advanceAndProposePacked`: every native row's drafter advances and proposes in one forward. |
| GDN verify checkpoint | `9500c78` | `gatedDeltaUpdateCheckpointed`, one recurrent pass, bit-identical to the split recurrence. |
| SSM mask skip | `d9897e6` | No all-true SSM mask when no packed verify row is padded. |
| Fused A3B MoE | `e787537`, `965f78e` | `MLX_LM_QWEN35_FUSED_MOE` decode/verify-width kernels; eligible only for the exact stock module types and exact quantized layout, stock path otherwise. |
| Compiled MTP verify | `1007bc6` | Qwen 3.5 verify step compiled like single-token decode (`MLX_LM_QWEN35_COMPILED_VERIFY`). |
| Compile-state ownership | `7be182c` (upstream #631, `-x`), `905170f` | The fused GDN projection and every array a verify trace reads are declared compile state. |
| Core pin | `37f0d7c`, `5203b73`, `45ffd95`, `b07d662`, `dbe8bcb` | Resolves the mlx-swift fork. |
| Tests | `8941054`, `72c4ab0` | Prepared fused-GDN compiled-verify fixture and in-place reload regression. |
| Exact prefix rewinds (upstream #622) | `b4077dc` | `RotatingKVCache` exact prefix rewinds and `KVCache.maxTrimCount` (`canTrimPromptCache(_:numTokens:)` gates per layer). |
| GLM-5-Next (epic #2029) | `414f315` .. `15d9c57` | `GLM5Next.swift`, `GLM5NextDecodeKernels.swift`, `GLM5NextAttentionCache.swift` (latent cache with exact `trim`, `GLM5NextLatentCache` / `GLM5NextBatchedLatentCache` / `GLM5NextLatentCacheBatch` for batched rows), the per-channel gated delta update, the two-input `SwitchGLU` activation, model registration, `00d8019` core pin. Batched rows equal serial bit for bit up to 8 flattened tokens per forward. |
| GLM-5-Next MTP-1 (epic #2029) | `b9ecf9b`, `6c837df`, `dcbf933`, `fa72942`, `e46cd52`, `7d8dbf5`, `5a2b4ee`, `2abf8e5`, `b25ef44`, `423aa6c`, `3d95241`, `bbdabc4`, `18ca526` | In-place verification with a one-token rewind (`mtpCacheCheckpointIndexKey` runs every column as a one-token decode step; sparse layers trim exactly, KDA restores its checkpoint; `SpeculativeCacheRewindModel` depth 1; `maxTrimCount` reports the latent cache's exact rewind depth for #622's per-layer gate), and packed verification inside continuous batching (`GLM5NextLatentCacheBatch` as an `MTPPackedVerificationCache` with per-row `GLM5NextLatentRowTransaction`, right-padded columns that attend nothing and write no cache, KDA padded columns that keep the row's state), the multi-vector projection `glm5NextQMVBatch` for 2...8-token forwards (bitwise equal to the one-vector qmv), the one-dispatch KDA verify step `glm5NextKDAVerifyStep`, and a single-sync greedy round in the shared `MTPSpeculativeTokenIterator` (same tokens; unused by the provider), the pre-final-norm hidden state and shared latent for the head (`validLatent`), and the parameterless `GLM5NextMTPDraftModel` (`GLM5NextMTP.swift`, MTP-1 drafter, block size 2, packed advance) with its registration; depth-D drafting and verification up to 7 with in-place rollback (`MambaCache` per-prefix states; the depth-1 checkpoint path unchanged) and serving at depth 1 by default (`maximumDepth`), the optional `MTPAdaptiveDepth` controller in the shared iterator (unused by the provider), verify-path kernel work (deferred hyper-connection kernels in verify, indexer inputs projected once, each weight read once per verify) and a staged-eval lab knob. |
| GLM-5-Next config validation (epic #2029) | `87dc515` | `GLM5NextConfiguration.validateModelConfiguration` rejects `index_topk` outside `index_kpool...65536` or not a whole number of pools, `index_kpool` outside `1...1024`, unknown `mlp_layer_types` / `indexer_types` values, and sparse MLP layers without `1 <= num_experts_per_tok <= n_routed_experts`. No decode-path line. |
| Qwen2-VL per-image vision attention (#2035) | `5eb60da`, `918ecc2`, `3545cb0`, `8ee6305` | MLXVLM `Qwen2VL.swift` vision blocks attend within each image (and each video frame group) instead of across all of a request's images (it used `frames[0].t`); equal-length images batch; the rotary batch axis is dropped before per-image attention. |
| DeepSeek-V4 (#2111) | `fe28d00`, `baec172` | `DeepseekV4.swift` (text model, compressed pools, HISA indexer, reference prefill plan in `prepare`), `DeepseekV4PoolCache.swift`, the `deepseek_v4` `LLMModelFactory` registration, and the tiny test fixture. `GLM5Next.swift` refactor only: `makeLimitedSwiGLU` loses `private`, `GLM5NextHyperConnection` gains a memberwise init behind the identical convenience init. |
| DeepSeek-V4 CB (#2111) | `362659f`, `676a62a` | `DeepseekV4Model.decodeBatch(_:rowCaches:)`: 1...8 ragged decode rows share projections/MoE and keep independent window/pool/indexer caches; per-row 2048+final-token prefill unchanged. Correct incomplete multi-token pool continuation; CPU tiny exactness, join/leave/reordering and boundary regressions. No native-MTP adapter or signed policy activation. |

| DeepSeek-V4 CB performance (#2111) | `c8be0f6` | Shared compressor/indexer projections and rotary offsets; one batched attention body for homogeneous rows, two for mixed dense/sparse rows to preserve exact arithmetic; keys-only windows and geometric row-owned pool storage. CPU exact 1/2/4/8-row fixtures pass; GPU parity and throughput remain pending. |
| DeepSeek-V4 reference fidelity (#2111) | `a4fd218`, `a985f94`, `7285658`, `28db1cf`, `9b5108b`, `012a2c6`, `72f8345`, `19b2c2b`, `790b4fd`, `c14b360`, `c9baca4` | `deepseek_v4` follows DeepSeek's `inference/model.py`/`kernel.py`: ratio-4 overlap state carried in `DeepseekV4PoolCache` (state, metaState, `copy()`), exact indexer top-k by default (HISA only by explicit config; prefill scores tiled under a 512 MiB workspace), float32 router (gate weight widened in sanitize), attention over each query's reference-ordered key list (window in temporal order, then the ratio-128 entries or the indexer's top-k by descending score) in the kernel's 64-key blocks with a running max and bf16 weights before the value product (query tiles for long chunks; explicit-config HISA does not batch: `batchesExactly`), compressor, expert SwiGLU/combine and head logits (`deepseekV4LinearF32`, a bf16-weight float32 GEMV kernel for up to 8 GPU rows). Tiny-fixture oracle regenerated from a port of the reference (`make_oracle.py`), within 7.6e-4 log-probability on the CPU; fixture `tid2eid` made duplicate-free. Full-model parity and throughput pending a Studio window. |
| DeepSeek-V4 CB/DSpark (#2111) | `cddd1e2`, `7c361cb`, `48fdc4b`, `098c339`, `0c0e58f` | Retains the three embedded draft stages, batches target verification projections/MoE across at most eight ragged positions, ranks cumulative confidence deterministically, and commits exact cache prefixes including ratio-4 overlap. Tests cover every rollback prefix and independent/packed rows. Swift test execution, token parity, throughput, acceptance, TTFT and peak memory remain pending hardware. |

`784f021` (Swift 6.1 tools version) is reverted by `e81dd7c`; drop both on the
next rebase.

mlx-swift (`0.32.3..0.32.3-macprovider.9`, branch `macprovider/0.32.3`):
`d073a644`, `ca2f61d2`, `cb3559bc`, `1931b6f9`, `647bdffa`, `29d3b933` move the
`Source/Cmlx/mlx` submodule to the core fork; `0c9854fc` expects NaN for
E4M3FN `0x7F`/`0xFF` in the fp8 decode test (core v0.32.4 behavior). No API
change. The #2028 tuple used `0.32.3-macprovider.8` (`745f5e48`, branch
`macprovider/0.32.3-core0.32.2`).

MLX core (`v0.32.4..v0.32.4-macprovider.4`; the #2028 tuple carried the same
patches on `v0.32.2..v0.32.2-macprovider.5`):

| Patch | Commit | What it carries |
| --- | --- | --- |
| Batch-invariant small-M quantized matmul | `4f2d384ce` (`ff1b94832` on v0.32.2) | No `qmv_wide` (every small-M product stays on `qmv`) and no `qmm_splitk` (`qmm` reduces K in one order for every M), so a continuously batched row matches its serial result. |
| Every-thread compiled-function erase | `1e6dc0f6d` (`c9196eb71` on v0.32.2) | Freeing a compiled function erases it from every thread's compile cache, so a later function at the same address never replays a dead trace. |
| `gather_qmm` signature for mlx-c | `1b1948045` | Keeps the pre-0.32.3 `gather_qmm` signature mlx-c 0.32.3 binds. |
| Internal ops on the caller's stream | `8a9975f82`, `77cd76b31`, `2f512e399` (`91a45ed47`, `b3397bfc9`, `49d94e9fe` on v0.32.2) | Every internal call inside a stream-taking op passes the caller's stream: the `quantized_matmul` casts of `x`/`scales`/`biases`, `indices_or_default`, `gather`, `scatter`, `affine_quantize`, the bool-mask SDPA fallback, the implicit random key split (`KeySequence::next`, reached by temperature sampling), `categorical`, `layer_norm` and its VJP, `linalg` `l2_norm`/`cross`, the `fft` zero-pad, `number_of_elements`, `imag`, and nine transformation rules (vjp/jvp) that now use the primitive's `stream()`. mlx-swift runs every op on its own pooled stream, so a stream-less internal op ran on the thread's default stream: a second Metal queue, a cross-queue event wait and a separate submit per op. gpt-oss-20b decode (8-bit affine projections over float32 activations) paid 140 per token, 30% slower than 3.31.4 (#2028). Upstream v0.32.4 already passes the stream in `indices_or_default` and the SDPA fallback; the v0.32.4 rebase carries the rest (`8a9975f82`, `77cd76b31`, `2f512e399`). |

`MLXCoreStreamPropagationTests` (CI, `swift test`) enforces this on the
resolved core by running `scripts/check_mlx_core_streams.py`. The script reads
every top-level core header and source (`mlx/*.h`, `mlx/*.cpp`), takes the op
names declared with a `StreamOrDevice` parameter and the array operator
overloads the headers declare, and inspects every body with a caller stream: a
`StreamOrDevice` or `Stream` parameter (by value or reference), or a primitive
rule (`Class::vjp`/`jvp`/`vmap`, or any body using `stream()`). In those bodies
it fails on a call to one of those ops (plain or `mlx::core::`-qualified; a
local lambda that shadows an op name is not the op) whose last argument is not
the caller's stream or an alias of it (a device such as `Device::gpu` is not),
and on any operator overload applied to an array value, read per statement so
an expression split across lines is still one expression. It fails closed on
missing files or an empty scan. It is a lexical check, not a C++ parser: code
that hides an op behind a macro or a template the scan does not expand is out
of its reach, which the Studio per-stream accounting above still covers.
The test also checks the resolved mlx-swift's `Source/Cmlx/mlx`
gitlink and the checked-out core HEAD equal `SPEC048_MLX_CORE_REVISION`
(`scripts/read_swiftpm_pins.py`). A rebase that introduces a stream-less
internal op fails CI until that op passes the stream; run the script against
the rebased core before tagging.

### Bounded routing exceptions

Within each route, `QuantizedMatmul` is batch invariant: a row's result
does not depend on how many rows share the call. These routes still depend on
the call's shape:

- `QuantizedMatmul` (`mlx/backend/metal/quantized.cpp` ~1798) flattens
  `[rows, chunk]` to `M = rows x chunk` and takes `qmv` (`qmv_quad` at K
  64/128) below `vector_limit`, `qmm` at or above it.
  `vector_limit = get_qmv_batch_limit(K, N, device)` for transposed weights
  (4 otherwise); across every architecture generation, device class and shape
  its largest value is 33 (M3 Ultra: 32 for K, N <= 2048, 18 up to 4096, 12
  above; M5-class: 33/25/13). **Prefill is enforced by the CB grouping
  rule** below: a chunk co-batches only at 33 tokens or more, where it
  already takes `qmm` alone. Before that bound, on the Studio every
  Qwen3.6-27B projection has limit 12, so a 6-11-token chunk took `qmv` alone
  and `qmm` beside a second row. Keyed hybrid rows prefill their generation
  prompt (about 5 tokens after the last `<|im_start|>` checkpoint) as their own
  final chunk, so equal-length keyed rows grouped it: on build `af3144ee9`
  12 of 126 grouped 27B rows differed from their lone greedy runs, and 0 of
  126 on the fix (`audits/2026-10-10-mlx-swift-lm-332/ROUND3_FIXES.md`). Decode carries one token per row, so `M` is
  the decode row count. **Decode is enforced by
  `ContinuousBatchDecodeRouteBound`** (`ContinuousBatchScheduler.swift`, a
  port of `get_qmv_batch_limit`): a decode forward carries at most the
  device's smallest vector limit minus one rows (Ultra 11, M1/M2 non-Ultra
  5, M3-or-later non-Ultra 12; the K or N above 4096 branch, which every
  served output head reaches), and more active rows decode in consecutive
  forwards. The serve log prints
  `event=continuous_batch_decode_row_bound max_decode_rows_per_forward=N`.
  Packed native-MTP verification multiplies `M` by the verify width:
  `PagedKVSharedForwardBackend.verifyNativeMTPPackedRound` verifies a round
  in consecutive packed forwards of at most the same bound in target tokens
  (rows x the group's widest row; one row wider than the bound verifies
  alone). Studio, A3B, width 2: 8 rows in one forward (16 tokens) were not
  bit-identical to their lone verification, 5 and 2 rows were. Without the
  decode bound, 16 rows of unequal length in one forward flipped 30-38
  greedy tokens out of 256 against their lone runs (A3B fused on/off, 27B);
  with it, 0.
- `GatherQMM` (`mlx/backend/metal/quantized.cpp` ~1901) takes
  `gather_qmm_rhs` for sorted gathers when `M == 1`, `B >= 16` and
  `B / E >= 4`, otherwise `gather_qmv`. MoE expert projections sort once a
  call carries 64 or more expert selections (`SwitchGLU`), with `B` =
  tokens x top-k; Qwen3.5 then also takes the direct weighted reduction.
  Decode stays below the `gather_qmm_rhs` switch: A3B (256 experts, top-8) at
  8 rows is `B / E = 0.25`, and decode/verify widths of at most seven tokens
  per row take the fused path when it is on. With `MLX_LM_QWEN35_FUSED_MOE=0`,
  8 decode rows reach 64 selections and switch to the sorted gather and the
  direct reduction (still `gather_qmv`); the 2026-10-10 grouped-prefill probe
  (`audits/2026-10-10-mlx-swift-lm-332/ROUND1_FIXES.md`) found 14/14 rows
  token-identical to their lone runs at 8 rows.
  **Prefill is enforced by the CB grouping rule.** Continuous batching groups
  up to four prefill rows with one chunk length into one forward (at one
  cursor, or at different cursors under ragged shared prefill), and a group
  carries every row's selections. Before the rule, a
  32-127-token A3B chunk took `gather_qmv` alone and `gather_qmm_rhs` when
  grouped, and greedy outputs depended on the neighbours (Studio, build
  `38aff2880`: 69 of 108 grouped rows differed from their lone runs, exactly
  in the groups whose combined selections reach 1024). Now
  `ContinuousBatchPrefillGroupingRule` (`ContinuousBatchScheduler.swift`,
  SPEC-038 FR-CB2 v0.3.12-v0.3.14) co-batches a chunk only when it is at
  least 33 tokens (the `QuantizedMatmul` bound above) and, on MoE models,
  `chunk x top-k >= max(16, 64, 4 x experts)`, read from the loaded model's
  `config.json` (A3B: 128 tokens; Qwen3.6-27B: 33). Shorter chunks prefill
  alone; an MoE configuration without both counts, or a configuration that
  declares no quantization or excludes a layer from it, prefills every chunk
  alone. The serve log prints
  `event=continuous_batch_prefill_grouping min_grouped_chunk_tokens=N` at
  scheduler build. At the default 512-token chunk the scheduler balances
  the chunks of an uncached prompt of 128 or more tokens to at least 128
  tokens each, so long prompts still group (R015: 1536/4096 tokens in
  512-token chunks).
  Every grouped row prefills its own balanced chunk, so grouping never
  changes a row's chunk partition.
  The rule's constants are the fork's routing bounds: a rebase that changes
  `get_qmv_batch_limit`, the `GatherQMM` condition or the `SwitchGLU` sort
  threshold updates them.
- Unquantized matmuls (steel GEMM) take `gemv_wide` for 2-15 rows and pick
  split-K partitions and tiles from M. The served Qwen3.6 text paths have no
  unquantized matmul (the only unquantized text weights are the depthwise
  `conv1d` of the linear-attention layers, a per-row kernel; the unquantized
  vision tower does not run for text). The grouping rule never groups a model
  whose configuration declares no quantization or excludes a layer.
- Attention picks its kernel from the query length, key length, head
  dimensions and mask, never from the batch. Equal-offset grouped rows share
  chunk length and key length, so they take the same attention route as each
  row alone. With head dimension 256 and more than 8 query tokens the unfused
  path runs batched GEMMs whose tile size follows `rows x heads x L x keys`;
  tiles change the blocking, not each element's K accumulation order.
  Rows of different lengths share one KV buffer padded to the longest row,
  and attention routes follow the padded length. The unfused prompt path
  (query length over 8, head dims 192/256) blocks its GEMMs by it (Studio,
  bfloat16: up to 2.4e-4 apart), so every padded prompt row attends in its
  own call over exactly its own keys with the causal mask. The vector
  decode/verify kernels (query length at most 8) pick one or two passes
  (1024 keys on Max/Ultra, 4096 with GQA elsewhere), the two-pass partition
  count (Ultra with 6 or more simdgroups: 128 / 512 / 1024 at 16384 and
  65536 keys) and the no-mask `_gqa` first pass from it; both kernels deal
  key `i` to partition `i mod P` and skip masked keys, so a padded row keeps
  its lone bits exactly when its own key length selects the padded call's
  route. `PagedKVBatchLayerCache.updateAndAttend` keeps one padded call for
  those rows and gives every other padded row its own call over exactly its
  own keys and query columns, with the mask its lone call takes (none for
  decode, its slice of the packed mask for verification); an unknown route
  always splits. `PagedKVVectorAttentionRoute` ports the dispatch (core
  `scaled_dot_product_attention.cpp` lines 754-763, 772-812, 1508, 1577 at
  `v0.32.4-macprovider.4`; the file is unchanged since `.1`); `testVectorAttentionRouteMatchesTheCoreDispatchBoundaries`
  pins every boundary, and `testSharedDecodeAndVerifyAttentionMatchLoneBitsAtServedHeadDims`,
  `testSharedDecodeWindowAttentionMatchesLoneBitsEveryStep` and
  `testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise` check every
  row bit for bit through the batch caches (Metal hosts only; run them on the
  Studio at each rebase). The table tests pin the ports, not core: a core
  change is caught by `testCoreRoutingSourcesMatchThePortedDispatch`, which
  hashes the resolved core's `get_qmv_batch_limit`, the `sdpa_vector_2pass`
  partition choice, the one/two-pass choice and `kernels/sdpa_vector.h`;
  when it fails, re-derive the ports and both tables before updating the
  digests. Split rows take their lone call's mask only under plain masks the
  batch cache built (padding and causality, no window); under any other
  array mask each split row attends with its own slice of that mask.
  Sliding-window decode rows attend over their presented suffix. A padded
  call the cache cannot isolate (stored keys not matching a row's extent,
  an unmasked multi-token call) is treated like a model calling SDPA
  itself. The FR-CB10 self-check result is keyed by this isolation policy
  and the device's forward bounds (`ModelRuntime.continuousBatchingSelfCheckRuntimeBuild`). Before the fix (Studio, head dim 256, 16/2 heads)
  rows of 600-1023 keys padded past 1024 and a 4095-key row padded to 16400
  differed by up to 2e-3. A model that calls SDPA itself bypasses this;
  any padded update that reaches the batch cache outside `updateAndAttend`
  (prefill, decode or verification) fails that forward's rows before
  sampling, and from then on the backend forms no ragged groups and decodes
  and verifies one row per forward
  (`event=continuous_batch_ragged_prefill_disabled reason=attention_outside_cache phase=...`).

  Why provider-side and not a core-fork change: the batch cache owns each
  row's real key extent, so it can make exactly the lone row's call. A core
  change (fixed key partitioning in the vector kernels) would still leave the
  pass-count, GQA-variant and unfused prompt-path differences, change every
  serial request's numerics, and need three new fork tags and a SPEC-048 R003
  tuple revision. The cost is the dispatch port above, re-derived at each
  core rebase.
- Non-transposed small-M products keep `qvm` / `qvm_split_k`. The served
  quantized linears are transposed, so serve shapes do not use them.
- `QQMatmul` always takes the vector route. It is independent of `M`, so it
  cannot split a row's result by batch size.

A new model, expert count, top-k, or batch/prefill shape re-runs the startup
isolation probe and re-derives these bounds before it serves.

### Pin sites

Moving a tag changes these together. The checks that catch a disagreement:

- `phase3-binary/Package.swift` against `phase3-binary/Package.resolved`: the
  CI `swift-package-lock` job resolves with
  `-onlyUsePackageVersionsFromResolvedFile`.
- `Package.resolved` against `KVBuildIdentity.mlxSwiftLMRevision`
  (`KVConversationColdTierAdapter.swift`): `KVBuildIdentityDriftTests`.
- `Package.resolved` against `scripts/read_swiftpm_pins.py`, which holds the
  reviewed fork tuple (fork revisions and upstream bases): the reader fails
  closed on an unreviewed fork revision, and
  `scripts/tests/test_upstream_watch.py` reads the checked-in file.
- `read_swiftpm_pins.py` against the SPEC-048 R003 fork table:
  `ReviewedForkTupleSourceTests` in `test_upstream_watch.py`.
- `scripts/check-upstream-throughput-blockers.sh` imports the tuple from
  `read_swiftpm_pins.py` and carries no revision of its own; the same test
  class fails if it hardcodes one or binds a different value.

The native-MTP bench (`NativeMTPHardwareE2ERunner.upstreamRevision`) reads
`KVBuildIdentity`, and `scripts/native_mtp_rehearsal_release.py` reads
`Package.resolved` through `read_swiftpm_pins.py`.

### Per-rebase acceptance gate

Mandatory for every new fork tuple, in addition to the matrices below. Record
results in the evidence header.

| Row | Required proof |
| --- | --- |
| Patch replay | Each inventory patch applies or is dropped with a recorded upstream equivalent; the fork tests for every touched surface pass. |
| Startup batched-isolation (fused MoE on) | On the Studio A3B tuple: `established=true`, `proven=true`, `crossRowDivergences=0`, `paged_kv_decision=attached`, with the fused path active. |
| Startup batched-isolation (fused MoE off) | The same with `MLX_LM_QWEN35_FUSED_MOE=0`. |
| CB enable gate | The rows of `docs/runbooks/continuous-batching-enable-gate.md` that run on the Studio pass on the new build; an open row that also fails on the previous build is recorded, not hidden. |
| Native-MTP R015 | Required when a decode-path line changed since the last R015 evidence (AGENTS rule 2): name the line, or record that none changed. |
| Cross-thread model reload | A reload loop that frees and rebuilds models across threads shows zero stale trace replays (every replay bit-exact to a fresh trace). |
| Compile-state ownership | Every compiled trace declares every model array it reads; the compiled verify/decode steps stay bit-identical to the general path on a `prepare()`d model, including after weights are reloaded in place. |
| Fused-layout eligibility and fallback | The stock A3B layout is fusable; mismatched layouts, rotated `SwitchGLU`, and adapter-backed projections fall back to the stock path. |
| Weight-file discovery | Every `.safetensors` file the rebased mlx-swift-lm loader can consume (`safetensorWeightURLs`, index and additional files included) is inside the native-MTP observer's recursive scan (SPEC-048 MTP-2). |
| Routing bounds | The core routing patches still apply, and the bounded exceptions above are re-derived for the new upstream, including the constants in `ContinuousBatchPrefillGroupingRule` and the `get_qmv_batch_limit` port in `ContinuousBatchDecodeRouteBound` and the `sdpa_vector` dispatch port in `PagedKVVectorAttentionRoute` (their table tests and the Metal-host bitwise attention tests pass on the Studio). |
| Grouped short prefill | On the A3B tuple with CB on, 32-127-token prompts sent concurrently in pairs and quads behind a decoding row produce exactly their lone greedy outputs, fused MoE on and off. The same on the dense 27B tuple with keyed (`conv:`) prompts, whose generation-prompt tail chunk is below the 33-token bound. |

## Package and toolchain preflight

| Gate | Required result |
| --- | --- |
| Fork tags | Every fork in the tuple has a new immutable tag on the rebased stack, pushed before the pin moves; each link pins the next by full revision (see [Fork model](#fork-model)). |
| Deterministic resolution | A clean `Package.resolved` regeneration resolves the reviewed exact graph; no branch dependencies or unexplained transitive drift. |
| Protected toolchain | Debug and release manifests/builds pass on the protected Xcode/Swift pair. A newer pair requires its own migration and release-runner proof. |
| API inventory | Compile errors and deprecations from `GenerateParameters`, cache creation/configuration, model factories, loading and generation are explicitly adapted and reviewed. |
| Core provenance | The core MLX revision carried by `mlx-swift` is recorded; a newer standalone core release is not claimed unless it is actually bundled. |

Pin bumps that change tokenizer cleanup rules must re-run the table-driven incremental cleanup oracle in `StreamingEmitterCleanupRewriteTests`.

## Serving-family snapshot — 2026-10-29

This snapshot reads main at `7c55c5ed2`; it is not a new qualification result.
Every runtime cell marked **T** uses the exact common production fork tuple in
[Fork model](#fork-model): mlx-swift-lm **3.32.3-macprovider.10.15.1**
(`36d24585f9373c2661f61f5e5b485c8d66c43a2b`), mlx-swift
**0.32.3-macprovider.9** (`29d3b93375cc56cd2649b40e4310a8bc445e9874`),
and MLX core **v0.32.4-macprovider.4**
(`2f512e3997349c8648f5d7c5113eb2c825aa242d`). MLXLLM and MLXVLM below are
modules from that same mlx-swift-lm fork, not separate engines or pins.

CB support means the exact identity may attempt attach and the runtime
parity/isolation/self-check gates; it does not assert a live slot grant for
all machines. Signed CB grants are tuple-specific. Prefix retention means
keyed KV/snapshot reuse under SPEC-024 and the memory budget, not guaranteed
residency or a guaranteed hit. **Unknown** explicitly marks unestablished
family-specific live acceptance. The catalog's `recommendable` status alone
does not establish current deployment.

| Serving family / catalog keys | Runtime engine and fork pin | CB status | Native MTP and profile | Prefix retention |
| --- | --- | --- | --- | --- |
| GLM-5.3-Flash — `zai-org/glm-5.3-flash` | MLXLLM `glm5_next`, T | Exact KDA/DSA hybrid admitted; signed four-slot grant with `cached_turns_accepted=true`. | Greedy live: `glm5_next_mtp_v1`, `native_mtp_greedy_text_v1`, depth one, one native row. Sampled qualification pending #2144. | Whole-stride serial prompt snapshots; role-marker CB snapshots under the signed cached-turn grant (SPEC-024-R005). Agent snapshots obey headroom bounds. |
| Qwen3.6 — `qwen/qwen3.6-27b`, `qwen/qwen3.6-35b-a3b` | MLXLLM Qwen3.5 dense/MoE implementations, T | Exact hybrid identities admitted. Signed policy entries cover 35B-A3B; their cached-turn grant is false. Current live slots otherwise unknown. | Signed 35B-A3B entry: `qwen3_5_mtp_v1`, `native_mtp_sampled_text_v1`, depth one, one native row. No 27B entry; current live use unknown. | Keyed recurrent checkpoints/prompt snapshots; CB cached-turn admission remains independently gated. Family-wide live retention unknown. |
| gpt-oss — `openai/gpt-oss-20b`, `openai/gpt-oss-120b` | MLXLLM `gpt_oss` / Harmony handling, T | Only exact 120B mixed sliding/full-attention identity admitted. 20B is excluded from this paged-CB exception; live slots unknown. | No signed admission/profile. | Keyed hot-cache eligibility follows runtime trim/checkpoint support; ordinary contiguous disk seed is unsupported for mixed caches. Family-specific live retention unknown. |
| Llama — `meta-llama/llama-3.1-8b-instruct`, `meta-llama/llama-3.2-3b-instruct` | MLXLLM Llama, T | Base contiguous fp16 KV route eligible; no signed family grant in current CB policy. Live slots unknown. | No signed admission/profile. | Standard keyed contiguous-KV reuse; persistence only for supported unquantized cache classes. Current live retention unknown. |
| LFM2.5 — `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` (prepared, absent from current candidate catalog) | MLXLLM `LFM2MoE`, T | Exact 40-layer one-slot short-convolution hybrid provisionally admitted for ordinary-CB evaluation. Qualification/activation unknown; catalog quality gate remains pending. | Ordinary-only exception; no signed native-MTP admission/profile. | Fixed reference-plan prompt snapshots for serial serving. Live acceptance unknown. |
| Qwen3.8 — `qwen/qwen3.8-27b` | MLXLLM Qwen3.5 dense implementation with Qwen3.8 template/identity handling, T | Exact hybrid identity admitted; no signed CB policy entry. Live slots unknown. | No signed admission/profile. | Keyed checkpoint reuse subject to actual cache support; family-specific live retention unknown. |
| Bonsai — `prism-ml/ternary-bonsai-2-2b-mlx-2bit` (`candidate`) | MLXVLM `PrismHadamardQwen35` schema-2 loader, T | Exact 24-layer hybrid, ordinary-only provisional exception; three-row lab parity recorded. Production attach/self-check pending. | No head in the admitted config; no native-MTP admission/profile. | Owned artifact/cache snapshots and bounded keyed retention; production retention unknown. |
| DeepSeek V4 — `deepseek/deepseek-v4-flash` | MLXLLM `deepseek_v4`, row-owned pools, T | Catalog advertises serial serving. Row-pool CB implementation exists; production enablement pending #2151. | No registered provider adapter or signed admission/profile. | Fixed 2048-token reference-plan snapshots; ordinary CB row snapshots implemented. Live CB retention unknown. |
| Qwen3.5 — `qwen/qwen3.5-27b`, `qwen/qwen3.5-35b-a3b` | MLXLLM Qwen3.5 dense/MoE, T | Exact hybrid identities admitted; no signed CB policy entry. Live slots unknown. | Adapter code does not grant these identities admission; no signed profile. | Keyed checkpoints; 27B serial snapshots preserve whole prefill strides. FP32 keyed paths remain serial. Current live retention unknown. |
| Qwen3 dense — `qwen3-8b`, `qwen3-32b` | MLXLLM Qwen3, T | Contiguous fp16 KV eligible; signed four-slot entry for `qwen3-8b` has cached turns false. 32B live slots unknown. | No signed admission/profile. | Standard keyed contiguous-KV reuse; CB cached-turn grant remains separate. Current live retention unknown. |
| Qwen3 MoE/Coder — `qwen/qwen3-30b-a3b-instruct-2507`, `qwen3-coder-30b-a3b-instruct` | MLXLLM Qwen3 MoE, T | Base Qwen route requires measured MoE isolation and exact attach/self-check; no signed policy entry. Live slots unknown. | No signed admission/profile. | Standard keyed reuse where cache trim/ownership permits; family-specific live retention unknown. |
| Qwen2.5 Coder — `qwen2.5-coder-32b-instruct` | MLXLLM Qwen2, T | Base contiguous fp16 Qwen route eligible; no signed policy entry. Live slots unknown. | No signed admission/profile. | Standard keyed contiguous-KV reuse; current live retention unknown. |
| Qwen2-VL — `mlx-community/qwen2-vl-2b-instruct-4bit` | MLXVLM Qwen2-VL, `qwen2vl-inline-v1`, T | Family recognition alone is not a qualified vision-CB tuple; current CB acceptance unknown. | No signed admission/profile. | Vision profile identity remains part of reuse eligibility; current family-specific retention unknown. |
| Gemma 4 — `google-gemma-4-26b-a4b-it` | MLXLLM Gemma 4, T | `gemma4` outside recognized paged-CB families; serial fallback. | No signed admission/profile. | Mixed runtime caches cannot use the ordinary contiguous disk seed; hot retention/live acceptance unknown. |
| GLM-4.5-Air — `z-ai/glm-4.5-air` | MLXLLM `glm4_moe`, T | Outside recognized paged-CB families; serial fallback. | No signed admission/profile. | Family-specific retention unknown. |
| Nemotron — `nvidia/nemotron-3-nano-30b-a3b` | MLXLLM `nemotron_h`, T | Outside recognized paged-CB families; serial fallback. | No signed admission/profile. | Recurrent cache eligibility is runtime-gated; ordinary contiguous disk seed unsupported. Live retention unknown. |

Catalog coverage: all 21 keys in
[`autotune-candidates.json`](../../phase3-binary/catalog/autotune/autotune-candidates.json)
are covered above, including the candidate Bonsai row; LFM2.5 is an additional
prepared-family row, not an asserted catalog activation. The current
`not-buyer-serving.json` exclusion list is empty.

Factual authorities:

- [SPEC-039](../../specs/SPEC-039-paged-kv-attention-engine.md), FR-PKV12, and
  [`PagedKVAttachGate`](../../phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift)
  define family/cache admission; `ModelRuntime.pagedKVModelCapabilities` defines
  exact hybrid identities, and `ModelRuntime` selects the LLM/VLM loader.
- [CB policy](../../phase3-binary/catalog/autotune/continuous-batching-policy.json)
  and [native admission](../../phase3-binary/catalog/autotune/native-mtp-admission.json)
  establish checked-in signed grants, not independent proof of live use.
- [SPEC-024](../../specs/SPEC-024-prefix-cache-billing.md), FR-CI2/FR-CI2a and R005,
  and `ModelRuntime` snapshot policies define retention. `ConversationCache.swift`
  enforces ownership and budget; `5c730ebf8` / `8d5c45109` refine reachable-capacity
  budgeting and its regression coverage. `7c55c5ed2` adds counters, not a retention
  guarantee.
- [SPEC-048 R003](../../specs/SPEC-048-native-mtp-serving.md) and
  [`Package.resolved`](../../phase3-binary/Package.resolved) bind T. See the
  [release narrative](../releases/provider-cli-1.8.277-notes.md) for promotion,
  the current GLM profile boundary, and next-cut identity rebinding.

## Token-exact model and protocol matrix

Run temperature 0 with identical fixtures and parameters. Unless a row explicitly documents an intended upstream correction, baseline and candidate token IDs, EOS/stop reason, tool-call payload, and accounting must match exactly.

| Row | Required proof |
| --- | --- |
| Dense control | Existing Llama-family and Qwen dense models load and generate exact baseline output. |
| Gemma 4 MoE | Reviewed Gemma 4 26B-A4B artifact loads, generates, stops, and reports usage without loader/shape mismatch. |
| GPT-OSS plain text | Harmony plain-text response has no channel/control-token leakage. |
| GPT-OSS reasoning | Analysis/final channel extraction and hidden/reported token accounting match the current contract. |
| GPT-OSS tools | Tool rendering, recipient/channel parsing, argument bytes, and terminal handling match; upstream parser adoption does not double-parse Macprovider's implementation. |
| Qwen tools | Qwen XML/JSON grammar covers hyphenated names, declared-tool allowlisting, null/default schemas, and streaming fragments. |
| Nemotron tools | Nemotron template, tool grammar, EOS, and accounting remain exact. |
| Stop handling | EOS IDs, explicit stop strings, multi-token stops, cancellation, and max-token termination have exact output and completion-token counts. |
| Safetensors indexes | Single-file and sharded/indexed artifacts resolve the intended tensors and reject ambiguous/missing files. |
| Null/default schemas | Absent, null, empty and default-valued tool schemas remain deterministic and fail closed where required. |

## Cache, prefill, compile, and speculative matrix

| Row | Required proof |
| --- | --- |
| Reusable fp16 KV | Two-turn and multi-turn hot reuse recover late prior-turn facts; cache offsets equal the committed canonical token ledger. |
| Quantized reusable KV | #965 real-model ownership/aliasing/mutation tests pass before `kvBits` is re-enabled for any `conversation_key`. Until then Macprovider must fail closed to fp16 reuse. |
| Cold-tier ABI | Persist/promote/reuse passes with exact identity; old dependency-version cache state is invalidated or explicitly migrated, never silently read. |
| Paged KV | Default-off behavior, descriptor admission, bridge capability and metallib/kernel parity remain intact; no unsupported tuple becomes routable. |
| `.remainder` prefill | Legacy/current prefill boundary produces exact tokens and accounting across below/equal/above-step prompts. Every generation path that chunks through mlx-swift-lm `PrefillParameters` (the serial paths) keeps legacy `.remainder` chunking until a reviewed balanced-prefill migration passes the next row. Continuous batching does not use `PrefillParameters`: `ContinuousBatchScheduler.prefillEnd` balances its own chunks, qualified separately under SPEC-038 FR-CB2 (serial/shared-forward parity on the same partition) and constrained by the prefill grouping rule above. |
| Balanced/adaptive prefill | Evaluate only after `.remainder` parity is green, as its own reviewed migration: exact output and accounting against `.remainder`, memory bounds, and cancellation behavior must all pass before any path leaves `.remainder`. |
| Compiled decode (generic) | The generic `GenerateParameters` compile path stays off until #964/upstream #406 is released and stateful KV offsets, retrace and failure recovery pass. This row does not cover the model-specific compiled traces below. |
| Compiled decode/verify (Qwen 3.5, fork) | The fork's model-specific compiled single-token decode segments and compiled MTP verify step (`MLX_LM_QWEN35_COMPILED_VERIFY`) stay on only while the per-rebase compile-state rows pass: bit-identical to the general path, every array a trace reads declared as compile state, zero stale trace replays across model reload. They are not the generic compile path and do not satisfy or reopen #964. |
| Speculative pre-wrap | Exact target-only output parity with accepted/rejected draft paths in streaming and non-streaming modes. |
| Speculative cache wrap | #377 crosses the rotating-window boundary and proves exact rollback. While upstream #424 is unresolved, classic production speculation remains disabled by default; the global-context boundary check is defense in depth, not enable authority. |
| Speculative failure | Draft load/generation/cancellation failure falls back before mixed output and leaves no conversation lease or stale cache state. |
| Concurrency | Concurrent model requests, load/swap, cancellation, heartbeat and coordinator control traffic remain responsive and isolated. |

## Artifact and release parity

This matrix is subordinate to
`docs/runbooks/provider-cli-release-verification.md`. A GREEN engine matrix does
not authorize publication unless the complete provider release contract also
passes, including previous-stable updater behavior, nested-signing posture,
immutable downloaded-asset verification, live authority/recommendation checks,
and failed-publication recovery.

- Build with `phase3-binary/dist/package.sh` or the release workflow, not only `swift run`.
- Verify the installed executable and every packaged metallib against immutable SHA-256 values.
- Prove the metallib was built for the same resolved MLX graph as the executable.
- Run model load/generation from the installed release candidate with the worktree absent from `PATH`.
- Verify standalone CLI and Malibu-packaged CLI byte identity where both ship.
- Reject benchmark records whose dependency metadata differs from `Package.resolved`.
- Run cold start, warm start, model swap, cancellation, restart/reboot, and failure recovery.

## Performance evaluation (only after all correctness rows are green)

Measure TTFT, decode tok/s, peak RSS, Metal memory, energy/thermal state, and concurrency responsiveness against identical artifacts and fixtures. Report regressions as well as improvements. Existing catalog and regression budgets remain release gates; an unexplained failure outside those budgets is RED. oMLX may be used as a benchmark/reference implementation, never as proof that the Swift runtime is correct.

## Decision

- **GREEN:** every applicable correctness, artifact, and performance-budget row passes; no unexplained token/accounting delta; package and toolchain gates pass.
- **RED:** any correctness, ownership, rollback, accounting, tool parsing, cold-cache ABI, artifact-parity, or unexplained performance-budget failure. Revert the pin candidate.
- **BLOCKED:** required upstream release/package/toolchain condition is absent. Keep production pins unchanged.

Current campaign tuple (2026-10-23, epic #2029 and #2111): fork `mlx-swift-lm 3.32.3-macprovider.10.3` (`baec1724…`, `3.32.3-macprovider.10.1` (`87dc5159…`, on `3.32.3-macprovider.10`) plus DeepSeek-V4, upstream `3.32.3`), fork `mlx-swift 0.32.3-macprovider.9` (`29d3b933…`, upstream `0.32.3`), and fork MLX core `v0.32.4-macprovider.4` (`2f512e39…`, upstream `v0.32.4`). Protected baseline (2026-10-17, #2041): fork `mlx-swift-lm 3.32.3-macprovider.9.4` (`ce3bb523…`, upstream `3.32.3`; `.9` (`dbe8bcb3…`) plus the Qwen2-VL per-image vision attention fix only), fork `mlx-swift 0.32.3-macprovider.8` (`745f5e48…`, upstream `0.32.3`), and fork MLX core `v0.32.2-macprovider.5` (`49d94e9f…`, upstream `v0.32.2`), built on Xcode 26.6 / Swift 6.3.3 / macOS SDK 26.5; `swift-transformers` and `swift-jinja` exactly as pinned in `phase3-binary/Package.resolved`. Previous baseline (2026-09-04): `mlx-swift-lm 3.31.4`, `mlx-swift 0.31.4`, `swift-transformers 1.3.4`, `swift-jinja 2.4.2` on Xcode 16.4 / Swift 6.1.

`swift-transformers` was moved `1.0.0 → 1.3.3` by Dependabot #1336 without the
#966 token-exact gate, then to `1.3.4` under that gate (2026-09-04). The gate is
recorded in `audits/2026-09-04-swift-transformers-134/GATE.md`: token-exact for
all byte-level/BPE catalog families (Qwen, Llama, GPT-OSS); Gemma carries five
intended Unicode corrections (invalidate Gemma Unicode-heavy KV caches);
Nemotron is newly loadable. `mlx-swift-lm` / `mlx-swift` were frozen throughout.
