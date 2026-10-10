# Round 3 fixes: mlx-swift-lm 3.32.3 / MLX 0.32 (PR #1927)

Round 3 (final) ran the three lanes over the whole diff in `SCOPE.md`.
Verdicts: code 0 C / 0 H / 1 M / 0 L; security 0 C / 0 H / 0 M / 1 L;
architecture 0 C / 0 H / 0 M / 4 L (one carried from earlier rounds).

## Findings to fix

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Code MEDIUM | Dense prefill grouping could change a row's kernel route. A shared prefill flattens `rows x chunk` into `M` for every quantized projection; `QuantizedMatmul::eval_gpu` takes `qmv` below `get_qmv_batch_limit(K, N, device)` and `qmm` at or above it, and dense models were `.unconstrained`. | `32155dc2f`: `ContinuousBatchPrefillGroupingRule` groups a chunk only at 33 tokens or more, the largest value `get_qmv_batch_limit` returns for any branch (architecture generation, device class, K, N) in core `v0.32.2-macprovider.2`; MoE models take the larger of 33 and the sorted-gather bound. A configuration with no `quantization`/`quantization_config` object, or a per-layer `false` exclusion, never groups (unquantized steel GEMM picks split-K partitions and tiles from `M`). SPEC-038 v0.3.12 FR-CB2, CONFORMANCE (new test mapped to SPEC-038-R002), runbook routing exceptions and the per-rebase grouped-prefill row. See "Dense prefill route" below. |
| 2 | Security LOW | `SCOPE.md` exposed local checkout paths. | `57a65951f`: commands use `$MACPROVIDER`, `$MLX_SWIFT_LM_FORK`, `$MLX_SWIFT_FORK`, `$MLX_CORE_FORK`, with a note naming the repositories. A grep of the tracked files under `audits/2026-10-10-mlx-swift-lm-332/` and `docs/research/mlx-swift-lm-3.32.3/` for `/Users/` finds nothing else. The untracked `run*.log` files stay uncommitted. |
| 3 | Architecture LOW | The upstream watch hardcoded the fork revisions and upstream bases. | `0da863809`: `read_swiftpm_pins.py` holds the upstream bases beside the reviewed revisions; the watch imports them and carries no revision literal. `ReviewedForkTupleSourceTests` executes the watch's tuple assignments against the reader's constants, fails on any 40-hex literal in the watch, and checks the reader against the SPEC-048 R003 fork table. The runbook pin-sites section names the check covering each pair. |
| 4 | Architecture LOW | The `.remainder` row claimed every generation path keeps `.remainder`, but CB balances its own chunks. | `9cf7ddf45`: the row covers paths that chunk through `PrefillParameters` (the serial paths) and states that `ContinuousBatchScheduler.prefillEnd` chunking is qualified separately under SPEC-038 FR-CB2 and constrained by the grouping rule. |
| 5 | Architecture LOW | SPEC-048 R002 bound the observer to the "pinned 3.31.4 loader". | `1c96eab2d`: SPEC-048 v0.1.29 MTP-2 requires the observer to inspect every file the R003-authorized loader can consume. At `3.32.3-macprovider.6` `safetensorWeightURLs` takes index-named files (possibly in subdirectories), else top-level conventional names, plus declared additional files; the observer's recursive scan is a superset. Each rebase re-establishes containment: new per-rebase gate row "Weight-file discovery". PR governance block adds SPEC-048-R002. |

## Carried

| Lane / severity | Finding | Reason |
| --- | --- | --- |
| Architecture LOW | Build and signer toolchain profiles are defined in both `scripts/build-release-provenance.py` and `scripts/validate-release-toolchain.py`. | Carried from rounds 1 and 2. Release-tooling refactor outside this dependency upgrade; a drift fails provenance generation loudly and cannot publish a wrong record. |

## Dense prefill route

**Bound per model** (rule as built, from each artifact's `config.json`):
Qwen3.6-27B (`518ef47c…`, dense, 4-bit) 33 tokens; Qwen3.6-35B-A3B
(`3fed776d…`, 256 experts, top-8) 128 tokens (MoE bound, unchanged). On the
Studio (M3 Ultra) the exact largest vector limit over each model's projections
is 12 for 27B (every projection has K or N above 4096) and 32 for A3B
(attention k/v, router, shared expert); 33 is the device-independent bound.

**Other batch-dependent routes checked** (core `v0.32.2-macprovider.2`):

- Unquantized matmuls: `gemv_wide` (2-15 rows), `gemv` when N or M is 1, and
  steel split-K (partition count and tiles follow `M`) all depend on `M`. A
  weight scan of both served artifacts finds no unquantized text-path matmul:
  the only unquantized text weights are the depthwise linear-attention
  `conv1d` (`depthwise_conv_1D_gpu`, per element), and the vision tower does
  not run for text. The rule never groups a configuration without declared
  quantization or with an excluded layer.
- Attention: kernel choice follows query length, key length, head dims, GQA
  and mask, never batch. Grouped rows share chunk length and offset. With
  head dim 256 and more than 8 query tokens the unfused path's batched GEMM
  tile size follows `rows x heads x L x keys`; tiles change blocking, not each
  element's K accumulation order. Covered empirically by the probes below.
- Logits: the shared prefill computes the full `[rows, chunk, vocab]` head, so
  `lm_head` has the same `M` as the other projections.
- Decode: one token per row, `M` = decode rows (at most 8). Below every limit
  on the Studio and on Ultra and M3-or-later devices; M1/M2 non-Ultra devices
  have limit 6 for K or N above 4096, so 6-8 decode rows switch to `qmm` there.
  The grouping rule cannot cover decode; recorded in the runbook.

**Where it fired.** Fresh chat prompts are at least about 20 tokens, already
`qmm` on the Studio for 27B. Keyed (`conv:`) rows on a hybrid model checkpoint
at the last `<|im_start|>`, so the generation prompt (about 5 tokens) is its
own final chunk; equal-length keyed rows grouped it.

**Tests** (Studio, Xcode toolchain, metallib `f42aef60…` beside `xctest`):
`testRealQwen35DensePrefillGroupingFollowsTheKernelRouteBound` (new; tiny dense
Qwen3.5, every projection 4-bit: two 24-token prompts prefill alone, two
33-token prompts share one forward, both match their lone serial greedy
tokens), `testRealQwen35MoEPrefillGroupingFollowsTheKernelRouteBound` (now
fully quantized, bound 33), `testPrefillGroupingRuleFromModelConfiguration`
(dense 33, gpt-oss-20b 33, few-expert MoE 33, unquantized and excluded-layer
configs never group), `testPrefillChunksBelowTheGroupingBoundPrefillAlone`.
Suites: `ContinuousBatchSchedulerTests` 156/0 failures,
`PagedKVRuntimeBridgeTests` 68/0, `PagedKVRuntimeMixedCacheTests` 10 with the
same 4 pre-existing assertion failures in
`testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin` recorded in
round 1 (fails on the unmodified tree, metallib-gated, skipped on CI).

**Studio probes** (isolated loopback 18191-18194, CB on, greedy, 48 max
tokens, pairs and quads sent together behind a decoding anchor row, 3 trials,
exact reasoning+content comparison; live provider untouched). Builds:
`af3144ee9` = `6b1d366bb` Swift sources, executable `d9cf30ad…`; fix
`32155dc2f` sources, `swift build -c release`, executable
`8cdca598fbb4a93def2999d4946f1ae618b5169633bd21ccf5d382d279215bb2`; metallib
`f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` for both.

| Model / mode | Build | Grouped rows differing from lone run | First-delta spread |
| --- | --- | --- | --- |
| 27B, keyed prompts 43-106 tokens | `af3144ee9` | **12/126** (67-token quads 3/12, 106-token pairs 3/6, 106-token quads 6/12) | 0.0-0.3 ms (tails grouped) |
| 27B, keyed prompts 43-106 tokens | fix | **0/126** | 170-1465 ms (tails prefill alone) |
| A3B fused MoE on, prompts 40-80 tokens | fix | **0/108**; 8-row decode 0/14 | 159-840 ms |
| A3B fused MoE off (`MLX_LM_QWEN35_FUSED_MOE=0`), prompts 40-80 tokens | fix | **0/108**; 8-row decode 0/14 | 73-443 ms |

A first 27B run sent keys without the required `conv:` prefix, so the server
dropped them and every prompt was one chunk of 27-67 tokens: 0/162 on
`af3144ee9`, as the mechanism predicts (above the Studio's 27B limit of 12).

Startup probes on the fix build:

| Probe | Parity | Batched isolation | CB | Grouping |
| --- | --- | --- | --- | --- |
| 27B | `established=true`, 1024/1024 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` | `min_grouped_chunk_tokens=33` |
| A3B fused MoE on | `established=true`, 640/640 | same | same | `min_grouped_chunk_tokens=128` |
| A3B fused MoE off | `established=true`, 640/640 | same | same | `min_grouped_chunk_tokens=128` |

**AGENTS rule 2.** No decode-path line changed: the change is the grouping
rule's bound and its configuration reading, which select prefill groups in
`runPrefillStep`. R015 prompts are 1536 and 4096 tokens in 512-token chunks,
above both bounds, so R015 grouping is unchanged and R015 is not rerun.

**Main moved.** `origin/main` has since landed SPEC-038 v0.3.11 "ragged shared
prefill" (#1910), which lets rows at different offsets share a prefill forward
with per-row positions and causal masks. Rebasing this PR renumbers its
SPEC-038 entries and must apply the grouping rule in the ragged path; a
per-row array mask versus the lone row's causal mask is also an attention
route difference that the rebase has to check.

## Verification

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_upstream_watch scripts.tests.test_native_mtp_rehearsal_release`: 39 tests, OK
- `bash scripts/test-swift-package-lock.sh`: passed
- `python3 scripts/check_spec_governance.py`: passed
- `python3 scripts/gen_spec_index.py --check`: up to date
- `python3 scripts/check_spec_pr_declaration.py --event <PR body with SPEC-048-R002> --base origin/main --head HEAD`: passed
- `bash -n scripts/check-upstream-throughput-blockers.sh`: OK; the watch's import prelude runs against `scripts/`
