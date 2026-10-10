# Issue #700: Gemma 4 MoE on mlx-swift-lm 3.32.3 (T1-01 matrix rows, T1-02 prep)

Date: 2026-10-10. Host: the 256 GB M3 Ultra lab Studio, isolated `serve --no-join`
instances on loopback lab ports only. The live provider was not stopped,
restarted or reconfigured. No throughput was measured; every number below is
a correctness or token-count result.

## Build under test

| Item | Value |
| --- | --- |
| Source | `origin/main` `0117e6a72` (#1927 merged) |
| `mlx-swift-lm` | `Augustas11/mlx-swift-lm` `72c4ab08` (tag `3.32.3-macprovider.6`) |
| `mlx-swift` | `Augustas11/mlx-swift` `ca2f61d2`; MLX core submodule `c9196eb7` (`v0.32.2-macprovider.2`) |
| Build | `swift build -c release --product macprovider-cli` (Swift 6.3.3), exit 0, 365 s |
| Binary | `macprovider-cli` 1.8.232, SHA-256 `24fdd36a4e19b83e5c9650c96f23865351cbed46d1f0593a32311678bed9b860` |
| Metallib | `mlx.metallib` SHA-256 `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` |

Metallib provenance: the Studio has Command Line Tools only (no `metal`
compiler), so `phase3-binary/scripts/build-mlx-metallib.sh` was run on the
operator Mac against a fresh `mlx-swift` checkout at `ca2f61d2` with its pinned
MLX submodule. The output is byte-identical (`f42aef60…`) to the metallib the
earlier 3.32.3 lab builds used, so it matches this MLX.

Pre-bump reference binary, used only to tell a bump regression from an existing
provider behaviour: the released 1.8.232 CLI (release commit `36758c05`,
`mlx-swift` 0.31.4, `mlx-swift-lm` fork `ca8c384c`), SHA-256
`16bd99286b4d4278b4eb930dd7ba58933ef7c651bad0e3cf644abffe8be3dbcb`, with its
own metallib `84e48718…`, copied into the lab directory and run the same way.
In its run (`runs/gptoss20b-prebump`), plain, reasoning and tools pass, with
the same fail-closed 400 on the tool-history turn. The `max_tokens: 400` essay
request returns the SPEC-018 fail-closed 502 because analysis used up the
budget (see F3), and the stop-string request hits F2.

## Gemma 4 26B-A4B artifact

| Item | Value |
| --- | --- |
| Catalog key | `google-gemma-4-26b-a4b-it` (`runtime_status: recommendable`, `min_sustained_tps: 10`) |
| Artifact | `mlx-community/gemma-4-26b-a4b-it-4bit` @ `0d77464eeb233a2da68ebf9d7dc4edaac7db956d` |
| `macprovider.snapshot-manifest.v1` | `b245e39f1476907653e3fe1897bba36b0e2a90c471828a9e13b5fdf3e1b6db01` (recomputed on the Studio, equals the signed catalog row) |
| Size | 3 shards, 15,341,205,776 bytes of weights |

The reviewed revision was already in the Studio model store, so nothing was
downloaded. Per-file SHA-256s: [`gemma-artifact-manifest.txt`](gemma-artifact-manifest.txt).

## Gemma 4 MoE loader and key mapping

`config.json` has `model_type: gemma4` with `text_config.model_type:
gemma4_text`, `enable_moe_block: true`, `num_experts: 128`, `top_k_experts: 8`,
`moe_intermediate_size: 704`, 30 layers, and a per-layer 8-bit quantization
override for every `router.proj`. Every text-config key is decoded by
`Gemma4TextConfiguration`.

The 1,697 artifact tensors:

| Group | Count | Fate |
| --- | --- | --- |
| `vision_tower.*`, `embed_vision.*` | 358 | dropped on purpose by `Gemma4Model.sanitize` (text-only path) |
| `language_model.*` | 1,339 | all loaded |
| of which `experts.switch_glu.{gate,up,down}_proj.{weight,scales,biases}` | 270 (9 x 30 layers) | loaded into `Gemma4TextExperts.switch_glu` |
| of which `router.{proj.weight,proj.scales,proj.biases,scale,per_expert_scale}` | 150 (5 x 30) | loaded into `Gemma4TextRouter` (8-bit `proj` honoured via per-layer quantization) |
| of which `post_feedforward_layernorm_{1,2}`, `pre_feedforward_layernorm_2` | 90 (3 x 30) | loaded |

The artifact already stores split `switch_glu` expert tensors, so the fused
`gate_up_proj` remap in `Gemma4TextModel.sanitize` is not exercised. The
loader applies weights with `model.update(parameters:verify: [.all])`
(`noUnusedKeys`, `allModelKeysSet`, `shapeMismatch`), and the model loaded
without error. No expert or router tensor is left unloaded, and no module
parameter is left unset. The 3.31.4 failure (`Unhandled keys ["experts",
"post_feedforward_layernorm_1", "post_feedforward_layernorm_2",
"pre_feedforward_layernorm_2", "router"]`) is gone.

## MLX_ENGINE_UPGRADE_MATRIX rows

Probe: [`scripts/lab/issue700_correctness_probe.py`](../../../scripts/lab/issue700_correctness_probe.py),
driven by [`scripts/lab/issue700_lab_serve.sh`](../../../scripts/lab/issue700_lab_serve.sh).
Temperature 0. Per-run evidence is under [`runs/`](runs/).

| Row | Run | Result |
| --- | --- | --- |
| Gemma 4 MoE: load, greedy generate, EOS stop, max-tokens stop, stop strings, usage, no loader/shape mismatch | `runs/gemma-cb-off` | **PASS**, except the engine-independent stop-string billing gap F1 below |
| Gemma 4 MoE with CB requested (`canary` + paged KV + lab accepted tuple) | `runs/gemma-cb-canary` | Same results. CB does **not** attach for Gemma, so every request is serial (see below) |
| GPT-OSS plain text (20b) | `runs/gptoss20b-post` | **PASS**: no channel/control-token leakage, stream matches non-stream |
| GPT-OSS reasoning (20b) | `runs/gptoss20b-post` | **PASS**: final channel extracted (`6:05 pm`), `completion_tokens` = visible final (5), `macprovider_generated_completion_tokens` = all channels (87), stream parity |
| GPT-OSS tools (20b) | `runs/gptoss20b-post` | **PASS**: one `get_weather` call, `{"city":"Vilnius","unit":"c"}`, `finish_reason: tool_calls`, streamed arguments byte-equal to non-streamed; a tool-history turn fails closed with 400 `unsupported_modelID_for_multi_turn` and `inference_ran: false` (current contract) |
| GPT-OSS plain/reasoning/tools (120b) | `runs/gptoss120b-post` | **PASS** on every check except the non-streamed stop-string request, which hit F2 below |
| Stop handling (EOS, max tokens, multi-token stop) | all runs | **PASS** for output text and finish reasons; billing gap F1 |

Gemma details (`runs/gemma-cb-off/probe.json`): `The capital of France is
Paris.` twice, byte-identical, 7 completion tokens, `finish_reason: stop`, no
`<turn|>`/`<end_of_turn>` leakage, `total_tokens = prompt_tokens +
completion_tokens`, streamed output and usage equal to non-streamed;
`max_tokens: 24` ends with `length` and exactly 24 tokens in both modes; `stop:
["12"]` and the multi-token `stop: ["15, 16"]` cut the text at the right place.

GPT-OSS on the post-bump build produces the same visible answers as the
pre-bump release, but greedy analysis-channel length differs (51 vs 59 hidden
tokens for the same question). That is consistent with MLX numerics moving; the
visible contract is unchanged.

### Continuous batching for Gemma

With `continuous_batching: canary`, `paged_kv.enabled: true` and a no-join lab
accepted tuple for the Gemma artifact, the startup paged-KV measurement does
not run:

```
[paged-kv] measure nil: preconditions (family=gemma4 recognized=false modelID=true modelSHA=false)
event=batching_unsupported action=serial_routed reason=kv_bits_unsupported
```

`/v1/status` reports `paged_kv_decision: fallback_paged_fallback_quantized`,
`cache_class: mixed`, `unsupported_reason: kv_bits_unsupported`,
`local_proof_result: failed`. Gemma 4 is not in the paged-KV recognized-family
set, and the runtime sets `kvBits` for Gemma (`KVQuantRecommendation` has a
K8V8 Gemma 4 entry), which CB refuses (`ContinuousBatching.swift` ~328). The isolation probe therefore cannot run for
Gemma on this build. The signed CB policy names only `qwen/qwen3.6-35b-a3b`, so
production behaviour is the same serial path. This is a scope fact for CB, not
a T1-02 blocker.

## Findings (engine-independent, also present before the bump)

**F1. Non-streamed request `stop` strings bill tokens past the stop.** The
serial non-stream decode loop (`ModelRuntime.swift` ~7525-7570) stops on a
request stop string only when `serialToolStopApplies`. Otherwise it decodes to
EOS or `max_tokens`, cuts the text afterwards (`applyOutputFilters`, ~7595), and
reports `completion_tokens = generationTokenCount`. Gemma, same request: the
non-streamed response reports 109 completion tokens and the streamed one 37,
for identical text. For GPT-OSS, visible `completion_tokens` is recomputed and
matches (33/33), but `macprovider_generated_completion_tokens` (the settlement
`tokensOut`) is 148 non-streamed vs 93 streamed. These lines were last changed
in #1338. #1927 did not touch them.

**F2. Harmony non-streamed `stop` strings match hidden analysis text.**
`applyOutputFilters` (`ModelRuntime.swift` ~10416) matches request stops
against the raw generated text, analysis channel included. When the analysis
contains the stop string, the text is cut before the final channel, and the
request fails closed with 502 `malformed_tool_call_final_json` although the
model produced a valid final answer. Reproduced on post-bump 120b and on the
pre-bump 1.8.232 release with 20b (`runs/gptoss20b-prebump`). This is not a
bump regression.

**F3. GPT-OSS greedy decode varies across processes.** The same temperature-0
essay request with `max_tokens: 400` gave 163 and then 244 visible tokens in two
post-bump processes. The pre-bump release varies the same way: the same request
returned 200 in one process and a fail-closed 502 in the next. Within one
process, repeats are identical. Correctness rows compare streamed and
non-streamed output within a process, so they are not affected.

**120b load note.** Three of four 120b load attempts died early in weight
loading: two on the post-bump binary and one on the pre-bump binary, with exit
137 (SIGKILL) where the exit code was captured. The unified log recorded no
reason. The fourth attempt loaded (about 65 GB RSS) and served. The Studio is
shared, so memory contention is the likely cause. This is not an engine
failure.

## T1-02 plan (prepared, not run)

T0-02 baseline (`beta/throughput-engineering/T0-02-baseline-matrix.json`, M5 32
GB MacBook Air, 2026-07-07, `mlx-swift-lm` 3.31.4, `decode-bench` 512
prefill / 256 decode, 5 runs + warmup, generation-only TPS):

| Model | T0-02 decode p50 | prefill p50 | TTFT p50 | Catalog `min_sustained_tps` |
| --- | --- | --- | --- | --- |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` (dense control) | 27.1 | 420.7 | 1288 ms | n/a |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` (MoE control) | 26.3 | 314.2 | 1853 ms | 15 (12 in T0-02's catalog) |
| `mlx-community/gemma-4-26b-a4b-it-4bit` (MoE primary) | not measurable (3.31.4 load failure) | | | 10 |

The gate is `bench_gate.min_sustained_tps` in the signed candidate catalog
(`phase3-binary/catalog/autotune/autotune-candidates.json`). It is decoded at
`AutotuneRecommend.swift` ~1052-1074 and enforced at ~2906-2927
(`benchmark.sustainedTPS < candidate.benchGate.minSustainedTPS`). The Gemma
gate provenance is `measured_single_host`, M5 32 GB.

Script: [`scripts/lab/issue700_t1_02_moe_decode_delta.sh`](../../../scripts/lab/issue700_t1_02_moe_decode_delta.sh),
staged with both binaries under `<studio-home>/lab-700/`.

- **Studio leg (same-host pre/post delta):** for each model, pre-bump 1.8.232
  then post-bump `0117e6a72`, interleaved for 2 rounds, `decode-bench
  --prefill-tokens 512 --decode-tokens 256 --runs 5 --report-sparsity
  --total-params-b {7.0,20.0,26.0} --bandwidth-gbps 819`. Gemma's pre-bump leg
  is a single load attempt that is expected to fail. The script refuses to
  start while another benchmark window is active, and it records the live
  provider's `requests_total` before and after each run so contention is visible.
  ```
  cd <studio-home>/lab-700
  ./issue700_t1_02_moe_decode_delta.sh prepare   # done 2026-10-10: Qwen2.5-7B-Instruct-4bit @ c26a38f6 fetched to lab-700/models, t1-02/manifest.txt written
  ./issue700_t1_02_moe_decode_delta.sh run
  ./issue700_t1_02_moe_decode_delta.sh summary   # t1-02/summary.json: p50s, delta %, gate PASS/BELOW_GATE, >5% regression flag
  ```
- **Reference-host leg (the T0-02 hardware, against the recorded rows above):**
  copy `bin/` (binary + `f42aef60…` metallib) to the M5 32 GB host and run
  `SKIP_PRE=1 BW_GBPS=120 LAB=<dir> MODELS_DIR=<model store> ./issue700_t1_02_moe_decode_delta.sh prepare|run|summary`.
  T0-02 freed that host before it ran, so this leg needs the same.

Pass/fail (runbook T1-02): GREEN if the Gemma post-bump p50 is at least 10 TPS
on the gate's hardware class. YELLOW if it is below that, which sends the work
to T2-01. RED on a regression of more than 5% on any model without an
explanation.

Related: #700
