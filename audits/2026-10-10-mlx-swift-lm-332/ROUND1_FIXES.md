# Round 1 fixes: mlx-swift-lm 3.32.3 / MLX 0.32 (PR #1927)

Round 1 ran the three lanes over the scope in `SCOPE.md` (prompts
`PROMPT_*.md`). Verdicts: architecture 0 C / 1 H / 1 M / 3 L, code
0 C / 0 H / 1 M / 1 L (+1 INFO), security 0 C / 0 H / 0 M / 1 L.

Fork commits are on `Augustas11/mlx-swift-lm` branch `macprovider/3.32.3`,
tag `3.32.3-macprovider.6` (`72c4ab082a08f291ba270a7303880e90036742e3`). The
mlx-swift (`0.32.3-macprovider.2`) and MLX core (`v0.32.2-macprovider.2`) forks
are unchanged.

## Finding to fix

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Architecture HIGH | SPEC-048 R003 authorized only the 3.31.4-based `ca8c384c…` candidate and excluded other revisions and transitive sources. | `16750f2e3`: SPEC-048 v0.1.28. R003 adopts the permanent fork model, authorizes the exact three-fork tuple with upstream bases, adds compiled verification, declared compile state, exact-type fused-MoE eligibility, batch-invariant routing and every-thread erase to the authorized surface, and defines the per-rebase review gate. The upstream-replacement removal trigger, the re-review date and the `ca8c384c…` authorization are removed. CONFORMANCE version and R003 rationale updated; spec index regenerated. No expiry or review-due date added. |
| 2 | Architecture MEDIUM | The upgrade matrix did not document the fork rebase process. | `83934b573`: `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md` gains Fork model (repos, upstream bases, tag scheme, current tags and revisions), patch inventory per fork, pin sites, bounded routing exceptions, and the mandatory per-rebase acceptance gate. The model-specific compiled decode/verify row is separate from the generic #964 row; #965 is unchanged; `.remainder` stays until a reviewed balanced-prefill migration passes. |
| 3 | Code MEDIUM | Fused-MoE eligibility accepted subclasses (`RotateSwitchGLU`, `QLoRALinear`) and would drop their computation. | Fork `965f78e`: eligibility requires `type(of:) ==` the stock `SwitchGLU`, `QuantizedSwitchLinear` and `QuantizedLinear`; anything else takes the stock path. Rejection tests for a rotated `SwitchGLU` and LoRA adapters on the shared expert and router, with a stock control. Pinned in `38aff2880`. |
| 4 | Security LOW | Evidence recorded an unrelated live binary replacement, backup filename and watchdog timestamps. | `61cf9591b`: removed from `step3-compile-state.md`; the same class of detail (backup name, another session's deployment and canary) removed from `step45-throughput.md`. The rest of `docs/research/mlx-swift-lm-3.32.3/` was grepped for backup names, watchdog, kickstart, buyer-runner, Pearl and other-session details; the only other match is the `last_watchdog` status field name. |
| 5 | Code LOW | Compiled-verify tests never called `prepare()`, so the fused GDN projection was never in the traced step. | Fork `8941054`, `72c4ab0`: a prepared bf16 q4 fixture asserts every GDN layer has its fused projection and declares it as trace state; a reload regression loads new weights in place into the traced fused projection and requires the replay to match the general path, then frees and rebuilds models with different weights. Mutation check on the Studio: with the fused projection removed from `traceState(forLayers:)` the reload test fails (hidden state and cache bitwise mismatches); restored, it passes. Pinned in `38aff2880`. |
| 6 | Architecture LOW | The fork lowered swift-tools-version to 6.1 although the graph needs Swift 6.3. | Fork `e81dd7c`: upstream's 6.2 restored. Pushed history is not rewritten; the runbook inventory says to drop `784f021` and `e81dd7c` together on the next rebase. Pinned in `38aff2880`. |
| 7 | Architecture LOW | `native_mtp_rehearsal_release.py` stamped a literal runtime revision. | `763e975f2`: derived from `phase3-binary/Package.resolved` through `scripts/read_swiftpm_pins.py`, fail closed when absent or unreviewed; `scripts/tests/test_native_mtp_rehearsal_release.py` covers both. |

## Carried

| Lane / severity | Finding | Reason |
| --- | --- | --- |
| Architecture LOW | Build and signer toolchain profiles are encoded in both `scripts/build-release-provenance.py` and `scripts/validate-release-toolchain.py`. | Release-tooling refactor outside this dependency upgrade. A drift fails provenance generation loudly; it cannot publish a wrong record. |
| Code INFO | `qvm`, `QQMatmul` routing exceptions. | Recorded with bounds in the runbook; serve shapes do not split a row's route by batch size. The `GatherQMM` part of this finding is fixed (see "Grouped prefill route" below). |

## Grouped prefill route (from the Code INFO finding)

The carried `GatherQMM` exception was a real divergence and is fixed in
`6b1d366bb`.

**Mechanism.** `GatherQMM::eval_gpu` (core `v0.32.2-macprovider.2`,
`mlx/backend/metal/quantized.cpp` ~1901) takes `gather_qmm_rhs` when
`M == 1`, `B >= 16`, the gather is sorted and `B / E >= 4`, else
`gather_qmv`; `SwitchGLU` (`3.32.3-macprovider.6`) sorts at 64 selections.
CB groups up to four prefill rows with one cursor and chunk length, and the
group carries every row's selections. On A3B (E = 256, top-8) a chunk of
`c` tokens alone has `B = 8c` (switch at 128 tokens); `k` grouped rows have
`B = 8kc`.

**Fix.** `ContinuousBatchPrefillGroupingRule` (`ContinuousBatchScheduler.swift`)
lets a chunk share a prefill forward only when
`chunk x top-k >= max(16, 64, 4 x experts)`, from the loaded model's
`config.json` (top level or `text_config`; A3B: 128 tokens). Shorter chunks
prefill alone. An MoE configuration without both counts, or no readable
configuration, prefills every chunk alone; dense models are unconstrained.
`runPrefillStep` stops adding rows after a first row below the bound. The
serve path reads the config from the container's directory and logs
`event=continuous_batch_prefill_grouping min_grouped_chunk_tokens=N`; the
native-MTP hardware E2E runner passes the rule explicitly. SPEC-038 FR-CB2
v0.3.11 records it; the runbook routing section now points at it.

**Other neighbour-dependent routes checked.** The fused A3B MoE path selects
on tokens per row (at most 7) and its kernels are batch invariant, so
grouping cannot move a row across it; prefill rows of at most 7 tokens are
below the bound and prefill alone anyway. Non-sorted gathers stay on
`gather_qmv` (`M == 1` after expansion). `QQMatmul` and non-transposed `qvm`
are not on serve shapes. One decode-side switch remains with fused MoE off
(`MLX_LM_QWEN35_FUSED_MOE=0`): 8 decode rows reach 64 selections, so the
gather is sorted and Qwen3.5 takes the direct weighted reduction (still
`gather_qmv`). The 8-row probe below matched the lone outputs on 14/14 rows
with fused MoE on and off. The grouping rule cannot cover decode; it is
recorded in the runbook.

**Tests** (Studio, Xcode 26 toolchain, metallib `f42aef60…` beside the test
runner so the MLX tests run instead of skipping):
`testPrefillGroupingRuleFromModelConfiguration` (A3B 128, Qwen3-30B 64,
GLM 64, gpt-oss-120b 128, gpt-oss-20b 32, Gemma 4 64, dense 1, incomplete MoE
and unreadable config never group), `testPrefillChunksBelowTheGroupingBoundPrefillAlone`
(scheduler decision, including a grouped first chunk whose short tails split),
`testRealQwen35MoEPrefillGroupingFollowsTheKernelRouteBound` (tiny real
Qwen3.5 MoE, 4 experts top-2, 4-bit experts, bound 32: two 24-token prompts
arriving together prefill alone, two 32-token prompts share one forward, and
both match their lone serial greedy tokens; 6/6 runs pass). Mutation: with the
rule replaced by `.unconstrained` the real-model test fails on the grouping
assertion (the tiny fp32 model does not itself flip a greedy token). Suites:
`ContinuousBatchSchedulerTests` 156 tests, 0 failures;
`PagedKVRuntimeBridgeTests` 67 tests, 0 failures.
`PagedKVRuntimeMixedCacheTests.testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin`
fails with the same 4 assertions on the unmodified `42c1b0bd6` tree; it is
metallib-gated (skipped on CI) and unrelated to this change.

**Studio probe** (A3B artifact `3fed776d…`, CB on, isolated loopback
18191-18194, greedy, 48 max tokens, live provider untouched). Prompts of
40/41/43 and 77/78/80 tokens, four per length, run alone and then as pairs and
quads sent together behind a decoding anchor row, 3 trials each (108 row
comparisons per build); output compared exactly (reasoning and content).

| Build | Grouped rows differing from lone run | First-delta spread in a group | 8-row decode |
| --- | --- | --- | --- |
| `38aff2880` (= `42c1b0bd6` code), fused on | **69/108**: 0/18 pairs of 40-43 tokens (`B` 656-688 < 1024), 21/36 quads of 40-43 (`B` >= 1280), 18/18 pairs and 30/36 quads of 77-80 (`B` >= 1232). Same output in all 3 trials. | 0.0-0.4 ms (one forward) | not run |
| `6b1d366bb`, fused on | **0/108** | 70-408 ms (rows prefill one after another) | 0/14 |
| `6b1d366bb`, `MLX_LM_QWEN35_FUSED_MOE=0` | **0/108** | 82-347 ms | 0/14 |
| `6b1d366bb`, fused on, 143-token prompts (above the bound) | **0/18** | 0.0-0.1 ms (still grouped) | 0/8 (4 rows + anchor) |

Startup probes on `6b1d366bb` (release executable SHA-256
`d9cf30ad97c872bf09f38d3c41445e513917f7f65fb379a580e1869f9c6ee0f9`,
metallib `f42aef60…`):

| Probe | Parity | Batched isolation | CB | Grouping |
| --- | --- | --- | --- | --- |
| A3B fused MoE on | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` | `min_grouped_chunk_tokens=128` |
| A3B fused MoE off | `established=true`, 640/640 | same | same | `min_grouped_chunk_tokens=128` |

**AGENTS rule 2.** No decode-path line changed: the change is the prefill
group selection in `runPrefillStep`, configuration plumbing, and the E2E
runner's configuration. R015 prompts are 1536 and 4096 tokens in 512-token
chunks; every chunk is 512 tokens (>= 128), so their prefill grouping is
unchanged and R015 is not rerun.

## Verification

Fork (Mac Studio, Xcode toolchain via `DEVELOPER_DIR`, metallib `f42aef60…`):
`swift test --filter "Qwen35FusedMoETests|Qwen35CompiledVerifyTests"` at
`72c4ab0`: 12 tests, 0 failures. A Studio-only probe (not committed) loaded the
served A3B artifact through `LLMModelFactory` with the `.6` code:
`blocks=40 fusable=40 forward_fused_T1=true`, so the stock A3B layout still
takes the fused path.

macprovider build `38aff2880` on the Studio (`swift build -c release`,
resolved `72c4ab08…` / `ca2f61d2…` / core `c9196eb7…`), executable SHA-256
`fbf355ac31fe5ffe375eba52bb738d9d933b1865e23b5ac787982f168ae18782`, metallib
`f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756`. Startup
probes on isolated loopback:

| Probe | Parity | Batched isolation | CB |
| --- | --- | --- | --- |
| A3B fused MoE on (default) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` |
| A3B fused MoE off (`MLX_LM_QWEN35_FUSED_MOE=0`) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` |

Native-MTP R015 was not rerun: `.6` changes no decode-path line relative to
the R015 build's fork (eligibility restriction for non-stock module types,
tests, manifest tools version), and the stock A3B layout resolves to the same
fused path (AGENTS rule 2).

Checks: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
scripts.tests.test_upstream_watch` (27 OK),
`scripts.tests.test_native_mtp_rehearsal_release` (2 OK),
`bash scripts/test-swift-package-lock.sh` (passed),
`python3 scripts/check_spec_governance.py` (passed),
`python3 scripts/gen_spec_index.py --check` (up to date),
`python3 scripts/check_spec_pr_declaration.py` on the updated PR body
(passed).
