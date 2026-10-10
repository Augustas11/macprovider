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

## Rebase onto main with #1910

The branch is rebased onto `origin/main`: first onto `ea6711ed8`, which
contains #1910 ("ragged shared prefill", SPEC-038 v0.3.11, merge
`702c33788`), with the conflicts below; then, without conflicts, onto
`cdfb74d5f` (nine later main commits; the only Swift change is in
`CoordinatorClient.swift`). Hashes earlier in this file are pre-rebase. The
two grouping-rule commits are now `44658175e` and `bb60acf48`; their messages
still name their old SPEC versions (v0.3.11/v0.3.12, now v0.3.12/v0.3.13).

**Conflicts and resolutions.**

| File | Resolution |
| --- | --- |
| `.github/workflows/ci.yml` | Main split the Swift job into four test shards, a journeys job, an app-test job and an aggregator (#1939). The Xcode 26.6 commit now applies to that layout: every Swift job (`swift-test-shard`, `swift-journeys`, `malibu-app-tests`, `swift-package-lock`) runs on `macos-26` and selects `Xcode_26.6.app`; main's cache keys already carry the `xcodebuild -version` hash. |
| `specs/SPEC-038-continuous-batching.md` | Main's v0.3.11 (ragged shared prefill) keeps its number. Ours renumber after it: kernel-route-invariant groups v0.3.11 -> v0.3.12, dense route bound v0.3.12 -> v0.3.13, plus the new v0.3.14 below. Change-log entries stay newest first; the FR-CB2 body tags follow the new numbers. |
| `specs/CONFORMANCE.json` | SPEC-038 version follows the SPEC; both sides' SPEC-038-R002 test mappings kept; #1910's two shortening tests replaced by their renamed/rewritten successors. |
| `specs/README.md` | Regenerated with `scripts/gen_spec_index.py` at every step. |
| `ContinuousBatchScheduler.swift` | Main's `allowsRaggedPrefillOffsets` dispatch kept beside our `prefillGrouping`; the grouping break moved into main's `selectEqualOffsetPrefillGroup`. |
| `ModelRuntime.swift` | `productionContinuousBatchSchedulerConfiguration` takes both `prefillGrouping` and `allowsRaggedPrefillOffsets`. |
| `ContinuousBatchSchedulerTests.swift`, `PagedKVRuntimeBridgeTests.swift` | Both sides' tests and helper parameters kept. |

**Integration (`07c6a10a2`, SPEC-038 v0.3.14).**

1. *Grouping rule in the ragged path.* `ContinuousBatchPrefillGrouping.select`
   takes `minimumGroupedChunkTokens`; below it the group is the head alone.
2. *No chunk shortening.* #1910 let the head shrink to a peer's chunk (down
   to half its own) and let peers shrink to the group length. That changes a
   row's chunk partition from its lone one, and can leave a remainder below
   the bound (A3B: a 200-token chunk cut to 128 leaves 72 tokens, which take
   `gather_qmv` alone where the lone 200-token chunk took `gather_qmm_rhs`).
   A row now joins a group only when the group length is its own balanced
   chunk, in both selectors. The equal-offset selector had the same issue
   (a peer's chunk was recomputed under the head's length) and is fixed the
   same way. Uniform-length workloads group as before; mixed-length rows
   whose balanced chunks differ prefill separately.
3. *Attention mask route.* Read in core `v0.32.2-macprovider.2`
   (`fast.cpp`, `backend/metal/scaled_dot_product_attention.cpp`,
   `softmax.cpp`, `matmul.cpp`, `kernels/steel/attn/kernels/steel_attention.h`):
   - `use_fallback` sends every prompt chunk (query length > 8) of head dim
     192 or 256 to the unfused SDPA regardless of mask form; the NAX fused
     exception needs >= 1024 query tokens, a causal mask and no array mask,
     which CB chunks (at most 512) never reach. The unfused path builds the
     causal mask as the same boolean `where(mask, scores, finfo.min)` that a
     boolean array mask takes. Head dim 128 takes the fused steel kernel
     with `do_causal` (blocks past the diagonal skipped) or `has_mask`
     (masked entries set to `finite_min`); both give exact zeros.
   - So the mask form is not a route difference. The padded key length is:
     a ragged row attends over `max offset + L` keys, alone over
     `offset_b + L`. Studio bitwise check (bfloat16, 16 Q / 2 KV heads):
     head dim 128 bit-equal in every case; head dim 256 not bit-equal
     (3128 keys padded to 4096: 7.5e-9; 4028 -> 4228 and 2064 -> 4164:
     2.4e-4; 7128 -> 8228: 1.2e-4). Slicing each row's own keys out of the
     padded buffer and attending with the causal mask is bit-equal to the
     lone call in every case.
   - Fix: a ragged forward builds `PagedKVRaggedPrefillBatchLayerCache`,
     which implements `KVCacheAttentionProtocol.updateAndAttend`: it updates
     the batch as before, then runs SDPA per row over exactly that row's
     `offset + L` keys with `.causal`, the lone call. Projections, MoE, GDN
     and the output head stay batched. Decode and equal-offset prefill
     still build the plain `PagedKVBatchLayerCache`. A model that calls SDPA
     itself (not through `attentionWithCacheUpdate`) reaches `update`
     without `updateAndAttend`; the backend logs
     `event=continuous_batch_ragged_prefill_disabled` and stops forming
     ragged groups. None of the CB catalog families do; no probe run logged
     it.

**Tests** (Studio, Xcode 26.6 toolchain, metallib `f42aef60…` beside
`xctest`): `ContinuousBatchSchedulerTests` 163/0 failures,
`PagedKVRuntimeBridgeTests` 73/0, `ServingKnobsConfigTests` 114/0,
`ContinuousBatchFirstTokenClockTests` 4/0, `PagedKVRuntimeMixedCacheTests` 11
with the same 4 pre-existing assertion failures in
`testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin`. New:
`testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise`,
`testRealQwen35RaggedPrefillGroupingFollowsTheKernelRouteBound`,
`testRaggedPrefillGroupingKeepsChunksBelowTheGroupingBoundAlone`,
`testRaggedPrefillGroupingNeverShortensARowsChunkToMeetAPeer`;
`testPrefillChunksBelowTheGroupingBoundPrefillAlone` runs both selectors.

**Studio probes** (`docs/research/mlx-swift-lm-3.32.3/ragged-prefill-rebase/`).
Before = rebased branch without the integration (`fdc28226…`); interim =
rule and natural chunks, padded attention (`9cd6c057…`); after = the commit
(`d2d148c1…`, built from `07c6a10a2`'s Swift sources before the second
rebase, which added only a `CoordinatorClient.swift` change).

| Probe | Model / mode | Before | Interim | After |
| --- | --- | --- | --- | --- |
| equal-length pairs/quads | A3B fused on | 69/108, decode-8 5/14 | 0/108, 0/14 | 0/108, 0/14 |
| equal-length pairs/quads | A3B fused off | 63/108, decode-8 6/14 | 0/108, 0/14 | 0/108, 0/14 |
| keyed equal-length pairs/quads | 27B | 3/108 | 0/108 | 0/108 |
| keyed ragged arrivals (short + staggered long) | A3B fused on | 13/24 | 0/24 | 0/24 |
| keyed ragged arrivals | A3B fused off | 9/24 | 0/24 | 0/24 |
| keyed ragged arrivals | 27B | 3/24 | 0/24 | 0/24 |
| staggered identical 1337-token prompts (ragged 443-token groups) | A3B fused on | 7/12 | 0/24 | 0/12 |
| staggered identical prompts | A3B fused off | 3/12 | n/a | 0/12 |
| staggered identical prompts | 27B | 0/12 | 0/24 | 0/12 |

The before build formed ragged groups of 7- and 21-token keyed tails,
equal-offset A3B groups of 36-86 tokens, and shortened 258-305-token chunks.
The after build formed ragged groups only of 443-token chunks (A3B: 3 groups
of 3 rows per mode; 27B: one of 4) and every row matched. The interim build's
padded attention flipped no greedy token in these runs; the bitwise check
above is why it is replaced anyway.

Startup probes on the after build: A3B fused on and off `established=true`
640/640, 27B `established=true` 1024/1024; all `proven=true rowsDecoded=2
rowFailures=0 crossRowDivergences=0`, `active=True paged=attached
proof=passed slots=8`, `min_grouped_chunk_tokens` 128 / 128 / 33.

**AGENTS rule 2 (decode path).** Against the R015-qualified build:
- #1910 changed these lines on functions decode runs: the `hop_decode`
  `CBTrace.log` and its `windowStartedNs` timestamp around
  `decodeLockstepWindow` (trace only, off unless `MACPROVIDER_CB_TRACE=1`);
  `servePathDecodeLockstepWindow`'s `MACPROVIDER_LAB_HYBRID_DECODE_WINDOW`
  override (compiled only into the lab harness, which R015 runs, and inert
  unless that variable is set); `PagedKVBatchLayerCache.makeMask`'s ragged
  branch, which replaced a debug-only `assert` and needs `n > 1` with
  distinct row offsets (decode is `n == 1`; packed MTP verification returns
  earlier); and the streaming TTFT clock wrapping `onChunk` (receipt timing,
  not tokens). None changes a decode token.
- This integration changes no decode-path line. `PagedKVBatchLayerCache`
  lost `final` and three members became `fileprivate` so the ragged
  subclass can read them; decode never builds the subclass.
- R015's native rows keep the equal-offset rule; its 1536/4096-token prompts
  in 512-token chunks group as before. R015 is not rerun on this basis; the
  operator decides on the #1910 lines above.
