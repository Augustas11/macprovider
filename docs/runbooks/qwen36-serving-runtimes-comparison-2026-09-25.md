# Qwen3.6-27B serving runtimes on the M3 Ultra (2026-09-25)

Question: is our MLX runtime (paged KV + continuous batching) the right engine
for Qwen3.6-27B on the 256 GB M3 Ultra Mac Studio, and how does it compare with
the open-source runtimes that can serve this model?

Inputs:

- **Hardware:** Mac Studio, M3 Ultra, 60-core GPU, 256 GB, about 819 GB/s,
  macOS 26.4.
- **Model:** `mlx-community/Qwen3.6-27B-4bit` (affine 4-bit, group 64, about
  15 GB). `qwen3_5` hybrid: 64 layers, of which 16 are full attention (24 Q / 4
  KV heads) and 48 are Gated DeltaNet linear attention. It ships one MTP layer.
- **Our numbers:**
  - production v1.8.192, measured end to end (Appendix A);
  - the campaign-branch decomposition in
    [`continuous-batching-qwen36-throughput-decomposition-2026-09-25.md`](continuous-batching-qwen36-throughput-decomposition-2026-09-25.md)
    (#1742; the link resolves once #1742 lands).
- **External numbers:** a web-research pass (Codex) over runtime repos, issues
  and public benchmarks. Every external number below carries a source link, and
  unsourced figures are labelled `Estimate:`.

The one decision-grade external result was checked against its source page:
[oMLX v0.5.7 on M3 Ultra 60c / 256 GB, Qwen3.6-27B-4bit](https://omlx.ai/benchmarks/sr2m9wdd).
It reports 48.9 / 47.3 tok/s generation at 1k / 4k and 329.7 / 339.8 tok/s
prompt processing. Batch aggregates are 41.0 tok/s at 2 requests and 65.5 tok/s
at 4. MTP was on ("VLM MTP enabled").

## Comparison with the throughput decomposition

The decomposition doc postdates the research pass and changes its main
conclusion. Once the O(context) paged-KV fix `3a91f1bc` is in, our engine has
reached decode parity; the gap left is prefill.

All figures are tok/s. oMLX numbers are from its public benchmark pages.
Figures marked \* are from `continuous-batching-qwen36-throughput-decomposition-2026-09-25.md`.

| Metric | Prod v1.8.192 (end to end) | Campaign `3a91f1bc` | Stock MLX (`msb-throughput`) | oMLX 0.5.7, MTP on | oMLX 4-bit, no MTP |
| --- | --- | --- | --- | --- | --- |
| Single-stream decode | 20.5 | 36.4 serve, 34.5 harness\* | 38.0 at L=1.5k\* | **48.9** (1k), 47.3 (4k) | 25.4 (1k) |
| Serial prefill | 190–250 | about 300\* | — | 330–340 | 292–318 |
| Batched decode, 4 rows, about 1.5k context | 11.7 end to end | **64.0** steady serve, 68.0 harness\* | 72.6\* | 65.5 (4 requests, prompt length not stated) | not published |
| Batched decode, 8 rows | 45.9 at 30-token prompts | 79.1 harness\* | 81.3\* | not published | not published |
| End to end, 1.5k × 4, 128 output tokens | 11.7 aggregate, TTFT p95 31.9 s | 19.9 aggregate, worst TTFT 25.0 s\* | — | not published | not published |
| Per-row prefill under load | not measured | about 117\* | — | not published | not published |

### What the comparison shows

1. **Decode parity is reached on the campaign branch.**
   - At 4 rows and about 1.5k context, our paged engine measures 64.0 tok/s
     (steady serve) and 68.0 (harness).
   - That is within about 6% of stock MLX (72.6) and level with oMLX's published
     65.5 at 4 requests.
   - The research pass's highest-ranked lever (resident recurrent state, stop
     gathering KV) is therefore mostly addressed by `3a91f1bc`. The "3x gather
     penalty" it cites came from the pre-fix O(context) re-concatenation.
2. **Our single-stream decode is fine without MTP.**
   - The campaign branch decodes at about 36 tok/s serial, above oMLX's non-MTP
     4-bit figure of 25.4.
   - Only MTP puts oMLX higher, at 48.9. That is about 90% of the estimated
     55 tok/s bandwidth ceiling and about 1.3× our serial rate.
   - **Resolved:** production v1.8.192 decodes at 20.5 tok/s because launchd
     runs the provider at background priority. The LaunchAgent sets
     `ProcessType` `Adaptive`, which leaves a daemon at Mach priority 4.
     - Same release binary and config in a lab run on the Studio: 22.3 tok/s
       under `Adaptive` and **37.8 tok/s** under `Standard`.
     - Same binary under `taskpolicy -b`: 22.1 tok/s.
     - Not the cause: the binary, the config, the 200k context setting, the
       one-at-a-time path, or how each figure was measured.
     - Fix: #1742 (SPEC-003 v0.11.4). The provider job becomes `Standard`, and
       the fleet gets it through the auto-update plist template with the next
       signed cut.
     - Expect production figures to rise by about 1.7× once the fix ships. Quote
       36–38 tok/s serial, not 20.5.
3. **The real gap is prefill scheduling, and both documents agree.**
   - Serial prefill is about 300 tok/s for us and 330–340 for oMLX, so the
     kernels are close.
   - Under load our per-row prefill drops to about 117 tok/s, because the
     scheduler admits one prefill per iteration.
   - That is why 1.5k × 4 end to end is only 19.9 tok/s, and 11.7 on production.
   - The fixes the decomposition names are the ones the research ranks second
     and third:
     - batched prefill across admitted rows;
     - a per-iteration prefill token budget, or chunked prefill with a decode
       budget.
4. **The research's runtime recommendation is superseded.**
   - The research proposes oMLX as the immediate external engine. On decode,
     the campaign branch already matches it.
   - oMLX remains worth running once with the same request harness, as an
     end-to-end reference for prefill scheduling and MTP behaviour. It does not
     justify replacing the Swift runtime.

### Updated lever ranking

The research pass's ranking, adjusted with the decomposition data:

1. **Prefill scheduling:** batched prefill of admitted rows, plus a
   per-iteration prefill token budget. This is the largest end-to-end gain at
   realistic prompt lengths.
2. **Hybrid-safe prefix and conversation reuse:** M4 measured a 76.6 s
   re-prefill falling to 1.0 s. This is the largest TTFT gain for coding-agent
   traffic. Upstream hazards are
   [mlx-lm #980](https://github.com/ml-explore/mlx-lm/issues/980) and
   [#1292](https://github.com/ml-explore/mlx-lm/issues/1292).
3. **MTP in a greedy-only lane, with recurrent-state rollback:** a potential
   gain of about 1.3× single stream, going by oMLX. Public Apple-Metal evidence
   is mixed:
   - [llama.cpp #23011](https://github.com/ggml-org/llama.cpp/issues/23011);
   - [Mference M3 Ultra](https://github.com/NeelM0906/Mference/blob/main/docs/BENCHMARKS_M3_ULTRA.md),
     which saw no gain on an adjacent model.

   The port reference is
   [mlx-swift-lm `MTPDrafterModel.swift`](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/MTPDrafterModel.swift).
4. **MLX kernel work for the batch ceiling:** past 4 rows, cost grows linearly
   in small-batch quantized matmul and gated-delta layers. See
   [mlx-swift-lm #466](https://github.com/ml-explore/mlx-swift-lm/issues/466)
   and
   [mlx-lm #932](https://github.com/ml-explore/mlx-lm/issues/932).
5. **Quantization:** 5-bit measured faster than one 4-bit variant on oMLX's
   pages. Test it only after 1–3.

## Research summary (external runtime pass)

The summary below predates the decomposition, and the section above overrides
it where they conflict.

- **Best measured runtime for this exact box today: oMLX.** Its public M3 Ultra 60-core/256 GB result for Qwen3.6-27B-4bit reports 329.7 tok/s prompt processing and 48.9 tok/s generation at 1K context; its 4-request result reports 65.5 aggregate tok/s. The run is oMLX 0.5.7 on macOS 26.6, with MTP shown in the benchmark acceleration context. [oMLX exact-box benchmark, 2026-08-05](https://omlx.ai/benchmarks/sr2m9wdd)
- **Best serving architecture to benchmark next: vLLM-Metal.** It combines a vLLM scheduler, block-managed paged KV, OpenAI serving, chunked prefill controls, and hybrid Qwen3.5/3.6 support. Its current documentation marks hybrid automatic prefix caching experimental and explicitly says hybrid GDN targets are not supported by its Metal speculative-decoding path. [supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md), [speculative decoding](https://docs.vllm.ai/projects/vllm-metal/en/stable/speculative_decoding/)
- **Do not assume MTP is the answer for concurrent hybrid serving.** llama.cpp has native Qwen3.6 MTP support, but its own merged implementation calls out recurrent-state rollback, non-contiguous recurrent state, and Metal D2H/H2D work as remaining optimization areas. A separate Apple-Metal issue measured Qwen3.6-35B-A3B MTP at 1.93 tok/s versus 26.23 tok/s baseline despite 95.6% acceptance. [llama.cpp MTP PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673), [Metal MTP issue #23011](https://github.com/ggml-org/llama.cpp/issues/23011)
- **The current in-house result is below the exact-box public envelope.** Your 20.5 tok/s single-stream decode is below oMLX’s 48.9 tok/s MTP-enabled result and below its older/UD 25.4 tok/s 1K result, but those are not yet apples-to-apples: sampler, MTP, prompt length, cache state, output length, and benchmark harness differ. [oMLX 4-bit benchmark](https://omlx.ai/benchmarks/sr2m9wdd), [oMLX 4-bit UD benchmark](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at)
- **The likely bottleneck is the hybrid batch path, not raw memory bandwidth.** Upstream MLX uses a dense, left-padded `BatchKVCache` for attention layers and `ArraysCache` for stateful linear-attention layers; this is batching, but not the same as a fully block-addressed, recurrent-state-aware paged engine. [mlx-lm cache implementation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/cache.py)
- **Prefix caching is unusually valuable for coding agents but unusually easy to get wrong here.** Qwen3.5/3.6 linear-attention state is not an ordinary trimmable KV tensor. Upstream mlx-lm issue #980 documents broken hybrid prefix reuse; issue #1292 documents Qwen3.6 MTP truncation when a cached system prefix is reused with a different user message. [mlx-lm #980](https://github.com/ml-explore/mlx-lm/issues/980), [mlx-lm #1292](https://github.com/ml-explore/mlx-lm/issues/1292)
- **First engineering priority:** make the recurrent state a first-class per-sequence object with checkpoint/rollback semantics, and make the attention KV allocator genuinely block/prefix aware. Do not merely gather paged attention tensors into a larger dense batch; that reproduces the current cost cliff.
- **Second priority:** implement chunked, batched prefill with a decode-latency budget. Your reported 15K-prompt first-token time of about 68 seconds is inconsistent with a provider SLA for long coding-agent prompts; chunking will improve tail latency even if it does not increase isolated prefill tok/s.
- **Quantization is a secondary lever.** Public exact-box oMLX results are 25.4 tok/s at 4-bit UD, 30.8 tok/s at 5-bit, and 17.3 tok/s at 8-bit for the cited context points; this shows that “more bits = faster” is not a safe assumption on this stack. [4-bit UD](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at), [5-bit](https://omlx.ai/benchmarks/kmpqjots), [8-bit](https://omlx.ai/benchmarks/ij1dqrlf)
- **Recommended rollout:** benchmark oMLX 0.5.7 and vLLM-Metal stable side by side using the exact provider harness, with MTP off/on, prefix cache off/on, greedy/sampling lanes separated, and concurrency 1/2/4/8. Keep your Swift runtime as the optimization target; it already has the right product boundary and can port the best recurrent-state and scheduler ideas without adopting a desktop UI server.

## Runtime capability matrix

Legend: **Yes** means verified in current upstream documentation or code; **Partial/experimental** means the feature exists but not for all hybrid/MTP combinations; **No evidence** means I did not find a current, credible source proving it for Qwen3.6-27B on Metal. “Maturity” is serving maturity for this workload, not general project popularity.

| Runtime | Qwen3.6 / qwen3_5 hybrid on Apple Silicon | Continuous batching | Paged KV / prefix cache | MTP or speculative decoding | OpenAI API and maturity |
|---|---|---|---|---|---|
| **oMLX** | **Yes**, MLX-based; exact-box Qwen3.6-27B benchmarks exist. [repo](https://github.com/jundot/omlx), [benchmark](https://omlx.ai/benchmarks/sr2m9wdd) | **Yes**, through its BatchedEngine/MLX BatchGenerator. [architecture](https://github.com/jundot/omlx#readme) | **Yes/partial:** block-based RAM+SSD KV, prefix sharing, copy-on-write; not the same as proof that every Qwen3.6 recurrent state can be safely block-split. | **Yes in benchmark/product paths**, but hybrid CB behavior is version-sensitive; an oMLX issue reports MTP bypass under continuous batching for a related Qwen3.6-family model. [issue #2150](https://github.com/jundot/omlx/issues/2150) | **Yes**, `http://localhost:8000/v1`; strongest measured choice, but community-maintained. [repo](https://github.com/jundot/omlx) |
| **vLLM-Metal** | **Yes:** Qwen3.5/3.6/3.8 listed as hybrid SDPA+GDN; current table marks hybrid prefix caching experimental. [supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md) | **Yes**, vLLM V1 scheduler and paged-attention path; chunked prefill and `--max-num-seqs` are exposed. [configuration](https://docs.vllm.ai/projects/vllm-metal/en/latest/configuration/) | **Yes/experimental:** paged KV is the default path; automatic prefix cache for Qwen3.5/3.6 is marked experimental. [supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md) | **No for this target today:** Metal docs say hybrid GDN targets are unsupported by speculative decoding; MTP is currently documented for Gemma4. [spec decode docs](https://docs.vllm.ai/projects/vllm-metal/en/stable/speculative_decoding/), [hybrid MTP issue #610](https://github.com/vllm-project/vllm-metal/issues/610) | **Yes**, vLLM OpenAI server; high architectural maturity, low exact-box benchmark evidence. Stable v0.30.0 release notes pin MLX dependencies and native Qwen3.5/3.6 loading. [releases](https://github.com/vllm-project/vllm-metal/releases) |
| **Rapid-MLX / historical vLLM-MLX** | **Yes for family:** native MLX; current repo lists qwen3.5/3.6-family support and Qwen3.8-27B benchmark evidence. [repo](https://github.com/raullenchai/Rapid-MLX) | **Yes** | **Yes:** repo explicitly describes paged KV, radix/DeltaNet prefix cache, and quantized live KV. [repo](https://github.com/raullenchai/Rapid-MLX) | **Partial:** model-dependent; no current public Qwen3.6-27B M3 Ultra MTP result found. | **Yes**, drop-in OpenAI replacement; promising engineering project, but current public benchmark is Qwen3.8-27B rather than the fixed model. [benchmark section](https://github.com/raullenchai/Rapid-MLX#latest-large-model-benchmarks) |
| **mlx-lm** | **Yes** for Qwen3.5/3.6-family model code; current cache code distinguishes attention KV and `ArraysCache` linear state. [model/cache code](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/cache.py) | **Yes**, `BatchGenerator`, batched prefill/decode controls, and `batch_generate` paths exist. [server code](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/server.py) | **Partial:** prompt cache and batch caches exist, but upstream code is dense/array based rather than a general paged block pool; hybrid prefix reuse remains a known problem. [#980](https://github.com/ml-explore/mlx-lm/issues/980) | **Yes/fragile:** speculative decoding exists, but Qwen3.6 MTP plus prefix reuse has a documented truncation bug. [#1292](https://github.com/ml-explore/mlx-lm/issues/1292) | **Yes**, OpenAI-like HTTP API, but upstream explicitly says it is not recommended for production. [SERVER.md](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md) |
| **MLX Swift / mlx-swift-examples MLXLLM** | **Yes** where the Swift model registry has the family; `mlx-swift-lm` contains hybrid cache and MTP support. [MTP drafter](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/MTPDrafterModel.swift), [KV-cache guide](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/kv-cache.md) | **Library support exists;** the examples app is not itself a production scheduler/API server. | **Partial:** typed composite KV/SSM caches and checkpointing; no upstream general paged block allocator was found in the Swift examples. | **Yes:** native MTP drafter; hybrid Qwen uses recurrent-cache checkpoints for rollback. [MTP drafter](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/MTPDrafterModel.swift) | **Examples/library, not a ready provider server.** This is the best upstream surface for improving your Swift implementation. Perf work is tracked in #466. [#466](https://github.com/ml-explore/mlx-swift-lm/issues/466) |
| **llama.cpp** | **Yes:** Qwen3.5/3.6 converter/model support and GDN family work are in current tree; Qwen3.6 MTP was merged in PR #22673. [converter](https://github.com/ggml-org/llama.cpp/blob/master/convert_hf_to_gguf.py), [MTP PR](https://github.com/ggml-org/llama.cpp/pull/22673) | **Yes**, `-cb` continuous batching and `-np` parallel slots. [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) | **Yes/partial:** unified KV, flash attention, prompt cache, cache reuse, and recurrent context checkpoints; recurrent-state sharing/rollback is still a special case. [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) | **Yes:** native MTP, draft-model and other speculative modes; Metal MTP has serious open/closed regressions to check for target build. [#22673](https://github.com/ggml-org/llama.cpp/pull/22673), [#23011](https://github.com/ggml-org/llama.cpp/issues/23011) | **Yes**, `llama-server`; highest conventional server maturity, but no strong exact M3 Ultra/Qwen3.6-27B public result located. |
| **Ollama** | **Yes at model-package level:** official library exposes Qwen3.6 27B MLX and GGUF/MTP tags. [tags](https://ollama.com/library/qwen3.6/tags) | **Yes in the Ollama server**, but implementation and batching controls are intentionally abstracted. | **Partial:** KV/prefix behavior is present, but Qwen3.5/3.6 GDN fused decode and recurrent-state issues have been tracked. [GDN issue #16149](https://github.com/ollama/ollama/issues/16149), [state issue #15865](https://github.com/ollama/ollama/issues/15865) | **Partial/fragile:** MTP tags exist; model-loading and MTP issues remain version-dependent. [#16282](https://github.com/ollama/ollama/issues/16282) | **Yes**, OpenAI-compatible endpoint; excellent ergonomics, lower control and weaker evidence for a latency-sensitive provider. |
| **LM Studio** | **Yes through MLX and llama.cpp engines**, subject to engine/model version. | **Yes for llama.cpp;** MLX parallel-request/CB support has historically lagged or been documented as forthcoming. [parallel requests](https://lmstudio.ai/docs/app/advanced/parallel-requests) | **Partial:** llama.cpp engine has the stronger path; Qwen3.5 hybrid MLX prefix reuse has a reported full-recompute bug. [bug #1563](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1563) | **Engine-dependent;** no verified Qwen3.6-27B provider benchmark. | **Yes**, OpenAI-compatible local server; good interactive desktop product, not the preferred unattended provider runtime. |
| **mistral.rs** | **Family support is documented** and Qwen3 Next’s GDN/full-attention mix is recognized. [model notes](https://docs.mistralrs.dev/guides/models/model-family-notes/) | **Yes in server/runner**, but no target concurrency evidence found. | **Yes/experimental on Metal:** PagedAttention exists, but `auto` disables it on Metal; it must be forced on. [paged attention](https://docs.mistralrs.dev/guides/perf/paged-attention/), [runner](https://docs.mistralrs.dev/reference/python/runner/) | **Yes:** MTP docs list Qwen3.5/Qwen3.8; Qwen3.6 exact support should be verified against the current commit. [speculative decoding](https://docs.mistralrs.dev/guides/perf/speculative-decoding/) | **Yes**, Rust server/OpenAI-style APIs; credible but materially less Apple/hybrid evidence than oMLX/vLLM-Metal. |
| **exo** | **Yes:** v1.0.70 added Qwen3.6 model support and Qwen3.5 Flash Attention. [release](https://github.com/exo-explore/exo/releases) | **Distributed request scheduling,** not a documented vLLM-like single-box CB path. | **Prefix/KV improvements exist**; no verified target paged-KV/CB result. | Community/native MTP work exists, but not a stable target recommendation. | ChatGPT-compatible API and mature distributed UX; better for pooling Macs than this single provider box. |
| **mlxcel** | **Model-family support is not yet sufficiently demonstrated for Qwen3.6-27B** in the cited docs. | **Yes:** scheduler admits requests, interleaves chunked prefill/decode, and streams tokens. [CB design](https://github.com/lablup/mlxcel/blob/main/docs/CONTINUOUS_BATCHING.md) | **Yes:** shared copy-on-write paged block pool, automatic prefix cache, and a fused paged decode kernel; docs report 1.4–3.1x batch-4 improvement on an M1 Ultra, but not the fixed model/box. [paged decode](https://github.com/lablup/mlxcel/blob/main/docs/CONTINUOUS_BATCHING.md) | Docs say speculative/MTP verify is not handled by the fused single-query paged kernel; no target MTP evidence. | Emerging open-source server; promising code to inspect, not a production recommendation without target-model correctness tests. |
| **mlx-serve** | **Yes:** its model table explicitly lists `qwen3_5`, `qwen3_5_moe`, `qwen3_next`, and Qwen3.6-27B. [models](https://github.com/ddalcu/mlx-serve/blob/main/docs/models.md) | Not clearly documented as true CB for this model. | Not enough evidence for paged KV/prefix cache. | Qwen3.6 model entry says a draft head is baked in; operational MTP behavior was not independently verified. | OpenAI/Anthropic-compatible native Zig server; promising but low maturity for a remote buyer provider. [repo](https://github.com/ddalcu/mlx-serve) |
| **vMLX** | **Advertised support for Qwen3.5/3.6-family hybrid scheduling**, but model-specific correctness evidence is sparse. [repo](https://github.com/jjang-ai/vmlx) | **Yes**, explicit flag. | **Yes:** paged KV, content-addressable prefix/disk cache, KV quantization. [repo](https://github.com/jjang-ai/vmlx) | **Yes/advertised:** draft model and prompt-lookup decoding; no independent Qwen3.6-27B M3 Ultra result. | OpenAI-compatible server; interesting experimental alternative, not enough evidence to displace oMLX/vLLM-Metal. |
| **SGLang** | Qwen3.5/3.6 support is primarily CUDA/AMD-oriented. | Strong on CUDA; Apple support was still a roadmap/build-from-source surface when checked. [Apple roadmap #19137](https://github.com/sgl-project/sglang/issues/19137) | No credible Metal paged-KV result for this target. | No credible target Metal result. | Not recommended on this Mac today. |
| **Candle / MLC-LLM** | Candle has ongoing Qwen3.6 ports, but no production Metal hybrid serving result found; MLC-LLM’s Qwen3.5/3.6 work is a POC/issue rather than a mature path. [MLC issue #3492](https://github.com/mlc-ai/mlc-llm/issues/3492), [Candle issue #3514](https://github.com/huggingface/candle/issues/3514) | No verified target CB. | No verified target paged KV/prefix cache. | No verified target MTP. | Exclude from this decision; useful only if building a new backend.

## Benchmark evidence

Only results with enough methodological detail to be useful are listed. A source can be numerically interesting without being comparable. “First-party” means the runtime or project authors published it; “reputable third-party” means a reproducible benchmark/report by an independent operator; “anecdotal” means a personal report, issue comment, or result without a sufficiently controlled harness.

| Model / hardware | Runtime, version, quantization, context | Single-stream decode | Prefill | Multi-request throughput | Date / credibility / interpretation |
|---|---|---:|---:|---:|---|
| Qwen3.6-27B, M3 Ultra 60-core, 256 GB | oMLX 0.5.7, macOS 26.6, 4-bit; benchmark context 1K/4K; MTP appears in acceleration settings | **48.9 tok/s** at 1K; **47.3 tok/s** at 4K | **329.7 tok/s** at 1K; **339.8 tok/s** at 4K | **65.5 tok/s aggregate at 4 requests**; 2 requests **41.0 tok/s** | 2026-08-05; **reputable third-party/community benchmark hosted by oMLX**. This is the closest external comparison to the fixed box. [source](https://omlx.ai/benchmarks/sr2m9wdd) |
| Qwen3.6-27B, M3 Ultra 60-core, 256 GB | oMLX, 4-bit UD/older configuration; context curve | **25.4 tok/s** at 1K; **24.7** at 4K; **24.0** at 8K; **22.5** at 16K | **292.2 tok/s** at 1K; **317.8** at 4K; **316.1** at 8K; **308.0** at 16K | Not reported | 2026-04-22; **reputable third-party/community benchmark**. Treat as a variant baseline, not a guarantee for the exact `mlx-community` checkpoint or MTP setting. [source](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at) |
| Qwen3.6-27B, M3 Ultra 60-core, 256 GB | oMLX 0.4.0, 5-bit; context curve | **30.8** at 1K; **30.3** at 4K; **29.3** at 8K; **28.3** at 16K | **294.8** at 1K; **315.3** at 4K; **313.8** at 8K; **305.4** at 16K | Not reported | 2026-06-03; **reputable third-party/community benchmark**. Demonstrates that quantization/kernel choice can dominate the simple “fewer bits is faster” intuition. [source](https://omlx.ai/benchmarks/kmpqjots) |
| Qwen3.6-27B, M3 Ultra 60-core, 96 GB | oMLX 0.3.8, 8-bit; long-context curve | **17.3** at 32K; **15.6** at 64K; **13.1** at 128K | **288.8** at 32K; **253.3** at 64K; **198.8** at 128K | Not reported | 2026-05-09; **reputable third-party/community benchmark**, different RAM capacity and context. [source](https://omlx.ai/benchmarks/ij1dqrlf) |
| Qwen3.6-27B, M3 Ultra 80-core, 512 GB | oMLX 0.5.7, 4-bit; context curve | **33.4** at 1K; **32.3** at 4K; **31.1** at 8K; **29.2** at 16K; **20.4** at 64K | **425.9** at 1K; **440.9** at 4K; **439.4** at 8K; **428.7** at 16K; **349.8** at 64K | **108.5 aggregate at 8 requests**; **83.4 at 4 requests** | 2026-08-05; **reputable third-party/community benchmark**, but a different GPU/RAM system and apparently a different MTP/configuration path. [source](https://omlx.ai/benchmarks/3lc12iga) |
| Qwen3.6-27B, Apple M4 Max 128 GB | Ollama 0.32.4, `qwen3.6:27b-mlx` / NVFP4 tag, 8K context | **24.1 tok/s** | Not reported | Not reported | 2026-07-28; **reputable third-party benchmark database**, different chip and quantization tag. [source](https://llm-bench.io/benchmarks/cms4sjat6006p01o045xxhth2) |
| Qwen3.6-27B, Apple M4 / M4 Max reports | MLX/llama.cpp/Ollama personal comparisons | Roughly **18–25 tok/s** in one M4 report; other personal results vary materially | Not reported | Not reported | 2026; **anecdotal**. Useful as a sanity range only; not suitable for extrapolating to M3 Ultra. [M4 report](https://kyu.co/posts/qwen36-27b-benchmark-2026-05-11/), [community comparison](https://www.reddit.com/r/LocalLLM/comments/1uog5va/128gb_m3_max_local_llm_benchmark_qwen35_122ba10b/) |
| Qwen3.6-27B, DGX Spark / mixed GPU tests | llama.cpp MTP PR branch, Q6_K in a cited RTX test; not Apple | MTP results are reported in the PR discussion, but are not comparable to M3 Ultra | Not comparable | Not comparable | 2026-05/06; **first-party PR discussion plus community comments**. Use only to confirm MTP model wiring, not to predict Apple performance. [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) |
| Qwen3.6-35B-A3B, M1 Pro 32 GB | llama.cpp build b9117, Metal, Q4_K_M, `-np 1`, flash attention | Baseline **26.23 tok/s**; self-MTP **1.93 tok/s**; MTP acceptance **95.6%** | Not reported | Not reported | Issue opened 2026-05-13; **first-party issue reproduction**, different model/chip, but a critical warning that accepted drafts do not imply faster Metal serving. [issue #23011](https://github.com/ggml-org/llama.cpp/issues/23011) |
| Qwen3.8-27B, M3 Ultra, 256 GB | Mference MLX implementation; plain greedy and MTP k=3; context/measurement method differs | Plain **38.4–39.4 tok/s**; MTP **33.7–39.6 tok/s**; 10,611-token paged-KV test **26.6 tok/s** | Blocked streamed prefill **125 tok/s** in the long-needle test | Not reported | 2026; **first-party project benchmark**, adjacent dense Qwen family rather than fixed model. It explicitly found no MTP speedup on that host. [benchmark](https://github.com/NeelM0906/Mference/blob/main/docs/BENCHMARKS_M3_ULTRA.md) |
| Qwen3.5-35B-A3B, M3 Ultra 60-core, 256 GB | Rapid-MLX measurement, 8-bit, B=1, prefix cache disabled | **79.77 tok/s** on mlx-lm 0.31.3 vs **86.18** on 0.31.0 | **1715.46 tok/s** vs **1752.60** on the cited short bucket | Not reported | 2026-06-23; **third-party issue benchmark**, MoE and 8-bit, not target. It is useful evidence of hybrid-cache/scheduler regression sensitivity. [issue #1425](https://github.com/ml-explore/mlx-lm/issues/1425) |
| Qwen2.5 family, M2 Ultra 192 GB | Academic comparison of MLX, MLC-LLM, llama.cpp, Ollama, and MPS; several contexts up to 100K | Paper reports MLX as highest sustained generation throughput under its settings, but the abstract does not expose the per-model table | Not in abstract | Concurrency/cache studied, but no target-model table in the abstract | 2025-10-09; **academic third-party**, secondary context only because the model family, runtime versions, and hardware differ. [paper](https://arxiv.org/abs/2511.05502) |
| vLLM-MLX broad Apple benchmark | vllm-mlx paper; Qwen3-0.6B through Nemotron-30B on M4 Max | Reports **21–87% higher throughput than llama.cpp** across tested models | Not target-specific in abstract | Reports up to **4.3x aggregate at 16 concurrent requests** | 2026-01-27; **first-party academic/project benchmark**, not Qwen3.6-27B/M3 Ultra. [paper](https://arxiv.org/abs/2601.19139) |

### Reading the benchmark table

The exact-box oMLX numbers are the decision-grade external evidence, but they do not identify enough of the request mix to prove that oMLX will produce **65.5 aggregate tok/s at concurrency 4 with 1.5K prompts**. The public result is a benchmark point, not a provider SLA. The correct comparison is a new controlled run using the internal request format, fixed output length, identical sampler, cache state, and a reported accepted-token rate for MTP.

## Theoretical ceiling and the current gap

**Estimate:** if the quantized model and metadata occupy about 15 GB and every generated token rereads that entire resident weight set once, the bandwidth-only ceiling is:

`819 GB/s ÷ 15 GB/token ≈ 54.6 tok/s`.

That is an optimistic lower-bound model of work, not a hardware promise. It ignores activations, output projection, recurrent-state updates, attention reads, quantization unpacking, non-coalesced gathers, command submission, synchronization, and sampling. The 15 GB and 819 GB/s inputs are the fixed request values; the 54.6 tok/s result is an **estimate**.

**Estimate:** your 20.5 tok/s single-stream decode is about **37.5%** of that simple bandwidth ceiling and about **2.66x below** it. The exact-box oMLX 4-bit MTP result of 48.9 tok/s is about **89.6%** of the same simplistic ceiling, while the cited older/UD 25.4 tok/s result is about **46.5%**. These percentages are arithmetic estimates from the cited results, not claims that either runtime sustains 819 GB/s of weight traffic. [oMLX MTP result](https://omlx.ai/benchmarks/sr2m9wdd), [oMLX UD result](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at)

The more useful engineering interpretation is that a well-tuned single-stream path on this box appears capable of roughly the mid-20s to high-40s tok/s depending on quantization, MTP, context, and code path. **Estimate:** for ordinary one-token greedy decode without a beneficial MTP path, a practical target of 25–35 tok/s is more credible than treating 54.6 tok/s as attainable. Your 20.5 tok/s is therefore a meaningful but not catastrophic gap; the much larger problem is the fall to 11.7 aggregate tok/s at four long-prompt batched requests and 3.5 tok/s per stream.

The hybrid architecture changes the scaling math. The 16 full-attention layers carry token-indexed KV; the 48 Gated DeltaNet-style layers carry a recurrent state per request. A batch can share weights and launch matrix operations together, but it cannot treat every sequence’s recurrent state as one interchangeable KV page. A page allocator that gathers only full-attention KV can still pay per-row state movement and synchronization on every linear-attention layer. This is why the three-times gather penalty in your internal note is plausible, and why a dense-model paged-KV result should not be transferred to Qwen3.6 without measurement.

## Appendix A: comparison with the v1.8.192 production measurements

Production baseline: provider v1.8.192 (CB `canary`, 8 slots) on the Mac Studio, measured 2026-09-25 end to end from a remote client through the OpenAI-compatible endpoint, streaming. TTFT includes about 1 s of network.

| Path | Concurrency | Aggregate output tok/s | Per-stream tok/s | TTFT p50 / p95 |
|---|---:|---:|---:|---:|
| Batched paged KV + CB, approximately 1.5K-token prompts | 1 | 13.6 | 21.3 | 7.9 / 8.1 s |
| Same | 2 | 9.9 | 6.2 | 15.1 / 16.3 s |
| Same | 4 | 11.7 | 3.5 | 19.5 / 31.9 s |
| Same | 6 | 11.7 | 2.3 | 27.5 / 49.9 s |
| Serial contiguous KV, approximately 1.5K-token prompts | 1 | 14.8 | 22.7 | 6.3 / 8.4 s |
| Same | 2 | 15.5 | 21.5 | 24.7 s p50/p95 not supplied |
| Same | 4 | 15.9 | 22.1 | 60.3 s p50/p95 not supplied |
| Batched paged KV + CB, approximately 30-token prompts | 4 | 39.0 | 9.9 | 0.3–2.4 s |
| Same | 8 | 45.9 | 5.9 | 0.3–4.7 s |

Other internal points: single-stream decode about **20.5 tok/s**; prefill about **190–250 tok/s** for **2K–15K** prompts; a **15K** prompt takes about **68 s** to first token; paged-KV gathers cost about **3x** contiguous single-stream before batching; aggregate batching saturates around **6 rows**. These are our own measurements, not web benchmarks.

| Runtime evidence | Expected single-stream decode | Expected prefill | Expected c=4 aggregate at ~1.5K prompts | Confidence versus internal path |
|---|---:|---:|---:|---|
| oMLX exact-box 4-bit MTP result | **48.9 tok/s at 1K context**; estimate **mid-40s** around 1.5K if same settings | **329.7 tok/s at 1K**, **339.8 at 4K**; estimate **roughly 300–340** at 1.5K | **65.5 tok/s** is published at 4 requests, but the prompt mix is not identical; use as an upper comparison point, not a forecast | High for hardware/model, medium for apples-to-apples request mix. [source](https://omlx.ai/benchmarks/sr2m9wdd) |
| oMLX exact-box 4-bit UD/non-MTP comparison | **25.4 tok/s at 1K**; estimate **about 24–25** at 1.5K | **292.2 tok/s at 1K**, **317.8 at 4K**; estimate **about 300–320** | Not published; **estimate:** likely above your 11.7 if its hybrid batch path is enabled, but no evidence supports a numeric forecast | Medium. [source](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at) |
| vLLM-Metal paged path | No target-box published result; **estimate:** benchmark from 20–35 tok/s baseline, then test whether fused/paged kernels improve it | **Estimate:** likely competitive with MLX for prefill, but no Qwen3.6-27B/M3 Ultra number found | **Estimate:** this is the strongest candidate to beat 11.7 because scheduler/paged KV are native, but hybrid GDN and prefix-cache status is experimental | Medium-low until measured; high architectural relevance. [supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md) |
| llama.cpp Metal | No reliable exact-box target number found; **estimate:** use a fresh `llama-bench` and `llama-server` run rather than porting unrelated Qwen/M4 anecdotes | **Estimate:** likely robust for ordinary attention but hybrid prefill must be measured | **Estimate:** `-np 4 -cb` should provide a useful baseline; recurrent-state and MTP paths may erase the expected gain | Medium for maturity, low for target performance evidence. [server docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) |
| Rapid-MLX / mlxcel / vMLX | **Estimate:** potentially above your 20.5 because all advertise paged/compiled MLX paths, but no controlled fixed-model result | **Estimate:** unknown | **Estimate:** plausible candidates for the 11.7-to-30+ aggregate gap, but model support and correctness need direct tests | Low until exact harness runs. [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX), [mlxcel](https://github.com/lablup/mlxcel), [vMLX](https://github.com/jjang-ai/vmlx) |
| Ollama / LM Studio / mistral.rs | **Estimate:** likely in the broad 20–30 tok/s class for ordinary single-stream Q4 on this hardware, but do not use this as a measured claim | Unknown for this target | Unknown; desktop abstractions make admission and cache policy harder to control | Low for provider decision |

The key comparison is not “your 20.5 versus someone else’s 48.9.” It is that your contiguous serial path is already faster than your paged batched path at long prompts: **15.9 aggregate at concurrency 4 versus 11.7**. That is direct evidence that the current page gather/state layout is losing more to overhead than batching is recovering. The short-prompt c=8 result of **45.9 aggregate** proves the runtime can amortize work when prompt/prefix state is small; the long-prompt c=4 result identifies the long-context hybrid cache path as the priority.

## Ranked levers

### 1. Fix hybrid state ownership and page/gather overhead — highest expected gain, medium/high effort

Represent each request as a composite state:

1. full-attention KV page table for the 16 attention layers;
2. one versioned recurrent state per linear-attention layer group and sequence;
3. a prefix-cache record that is valid only at a token boundary where both components are checkpointed;
4. a cheap copy-on-write fork for a new request sharing an immutable prefix;
5. an explicit rollback record for MTP verification.

Do not page only the attention KV while copying or re-materializing the 48 recurrent states each decode step. Keep state resident for active rows, and only spill/fork at request boundaries. This is the most likely route to remove the current approximately 3x gather penalty and recover c=4 throughput.

Read or port from:

- [mlx-lm `ArraysCache` and `BatchKVCache`](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/cache.py);
- [mlx-swift-lm hybrid cache contract](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/kv-cache.md);
- [mlx-swift-lm MTP recurrent checkpoint logic](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/MTPDrafterModel.swift);
- [mlxcel paged decode v2 and shared block pool](https://github.com/lablup/mlxcel/blob/main/docs/CONTINUOUS_BATCHING.md);
- [vLLM-Metal paged-KV roadmap issue #148](https://github.com/vllm-project/vllm-metal/issues/148).

### 2. Add hybrid-safe prefix caching for coding-agent traffic — high gain for repeated prefixes, medium effort

Cache and reuse the common system/tool prefix only when the cached recurrent state and all full-attention KV pages are at the same boundary. A partial prefix hit must not silently reuse a state whose recurrent transition includes tokens after the claimed boundary. Use a content hash over token IDs plus model revision, tokenizer/template revision, sampler-independent model state, and cache format version.

Measure cold, exact-hit, and shared-prefix/different-suffix cases separately. The user workload has repeated system prompts, so this can reduce TTFT far more than decode micro-optimizations once correctness is established. Expect no benefit on a cache miss; that is an explicit limitation, not a failure.

The relevant upstream failures are [mlx-lm #980](https://github.com/ml-explore/mlx-lm/issues/980), [mlx-lm #1292](https://github.com/ml-explore/mlx-lm/issues/1292), [LM Studio #1563](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1563), and [exo’s Qwen3.6 prefix-cache fix](https://github.com/exo-explore/exo/releases).

### 3. Chunked and batched prefill with a decode budget — high latency gain, medium effort

Admit a long prompt in bounded chunks, interleave a chunk with active decode rows, and expose a policy such as “at most X prefill tokens or Y milliseconds per scheduler turn.” Use a separate larger batch budget for cold startup when no decode row is active. This directly targets the reported 15K-prompt ~68-second first-token time and the c=4 p95 of 31.9 seconds.

The `mlxcel` scheduler documentation is a useful design reference: it uses a prefill chunk size, a maximum batch-prefill token budget, and a grant interval to prevent a long prompt from monopolizing decode. [mlxcel continuous batching](https://github.com/lablup/mlxcel/blob/main/docs/CONTINUOUS_BATCHING.md)

### 4. MTP self-speculation — potentially high single-stream gain, high hybrid correctness/perf risk

Your model ships one MTP layer, so the natural experiment is a one-step self-speculative path: target produces the normal token plus drafter state, MTP proposes the next token, target verifies, and rejected drafts restore both attention KV and recurrent state. Start with greedy-only and one speculative token; add larger draft windows only after measuring acceptance, verify cost, and rollback cost.

Do not turn it on globally. vLLM-Metal currently excludes hybrid GDN targets from Metal speculation, llama.cpp has documented recurrent-state and Metal performance hazards, and mlx-lm has a Qwen3.6 MTP/prefix truncation bug report. Use MTP in a dedicated greedy lane first. [vLLM-Metal spec limits](https://docs.vllm.ai/projects/vllm-metal/en/stable/speculative_decoding/), [llama.cpp #23011](https://github.com/ggml-org/llama.cpp/issues/23011), [mlx-lm #1292](https://github.com/ml-explore/mlx-lm/issues/1292)

### 5. Compile/fuse the hybrid decode schedule — medium gain, medium effort

The Swift project’s current measured plan estimates dense Qwen3.5/3.6 decode improvement from compiled schedules, GDN conv1d fusion, decay-gate fusion, and pre-gather rotation. These are project estimates, not guaranteed results for your build; they are concrete implementation targets. [mlx-swift-lm #466](https://github.com/ml-explore/mlx-swift-lm/issues/466)

Profile per-layer command-buffer count, host synchronization, dynamic shape recompilation, and state write/read bandwidth. Your single-stream contiguous result being slightly above your paged path suggests launch/gather overhead is a larger target than weight bandwidth alone.

### 6. Quantization and KV-cache dtype — medium gain or loss, low/medium effort

Benchmark the exact same checkpoint family at MLX affine 4-bit group 64, MLX 5/6/8-bit, and GGUF Q4_K_M/Q5_K_M/Q6_K/Q8_0 with the same template and context. Public exact-box oMLX results show 5-bit faster than the cited 4-bit UD result, while 8-bit is slower at long context; this may reflect checkpoint/kernel differences rather than bit width alone. [4-bit](https://omlx.ai/benchmarks/performance?model=qwen3.6-27B&order=asc&quantization=4bit&sort=created_at), [5-bit](https://omlx.ai/benchmarks/kmpqjots), [8-bit](https://omlx.ai/benchmarks/ij1dqrlf)

Keep model weights and recurrent state at the dtype required for correctness. Quantize full-attention KV only after measuring quality and state-transition drift. For the provider, a small quality loss from Q4 to Q5 may be acceptable if it improves output rate, but it is not safe to infer that from the public results.

### 7. Sampling lanes and scheduler policy — low/medium effort, immediate operational gain

Your current canary batches only greedy requests and serializes other sampling modes. Keep that safety boundary, but avoid letting one non-greedy request force unrelated greedy requests onto the serial path. Partition the queue by compatible execution shape: greedy/MTP, ordinary sampling, grammar/logits processors, and long-prefill. This should improve utilization without changing model math.

Also cap active long-prompt rows based on measured memory and state bandwidth. The current c=6 aggregate plateau at 11.7 tok/s is evidence that “more rows” is not the same as “more throughput.”

### 8. Choose the right external baseline — low effort, high information value

Run, in order:

1. oMLX 0.5.7, target 4-bit, MTP off, prefix cache off;
2. oMLX same, MTP on, prefix cache off;
3. oMLX same, MTP off, prefix exact-hit and shared-prefix;
4. vLLM-Metal stable, paged KV on, prefix cache off/on;
5. llama.cpp current, Q4_K_M and Q5_K_M, `-np 1/4`, `-cb`, flash attention, MTP off/on;
6. your Swift path with identical requests and instrumentation for prefill, verify, gather, state-update, sampling, and transport time.

This separates runtime architecture from MTP and cache effects before any porting decision.

## Recommendation

### Single best runtime/configuration today

Use **oMLX 0.5.7 with `mlx-community/Qwen3.6-27B-4bit` as the immediate external production candidate**, configured with its block-based hot RAM cache, prefix sharing, continuous batching, and OpenAI endpoint. Start with a **four-request active cap** for long prompts, keep MTP in a separate greedy-only canary until the exact provider harness proves correct rollback and positive net throughput, and disable SSD spill for the active 256 GB box unless the cache policy is explicitly tested under memory pressure. The recommendation is based on the exact M3 Ultra/256 GB/Qwen3.6-27B public result, not on a generic “MLX is fast” assumption. [oMLX exact-box result](https://omlx.ai/benchmarks/sr2m9wdd), [oMLX server features](https://github.com/jundot/omlx)

At the same time, benchmark **vLLM-Metal stable** as the likely long-term serving architecture. It is the cleanest upstream path for a remote OpenAI-compatible provider because it provides vLLM scheduling and paged KV controls, but its current hybrid limitations mean it cannot yet be selected on documentation alone. In particular, its Metal speculative-decoding docs exclude hybrid GDN targets, and its hybrid automatic prefix cache is experimental. [vLLM-Metal supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md), [speculative decoding](https://docs.vllm.ai/projects/vllm-metal/en/stable/speculative_decoding/)

### What to change in the in-house Swift runtime to reach parity

1. **Replace “paged KV plus gather” with “paged attention plus resident recurrent state.”** Keep page tables for the 16 full-attention layers, but never gather the entire visible history into a contiguous tensor per row. For the 48 linear layers, store each row’s recurrent state in a stable slot and batch the state transitions directly.
2. **Add a composite cache interface.** Each cache object should expose `fork`, `commit`, `rollback`, `trim_to_boundary`, `prefix_fingerprint`, and `resident_bytes`. The implementation must be different for KV pages and GDN state, while the scheduler sees one transactional interface.
3. **Add prefix-cache validation before optimization.** Test exact prefix hit, shared system-prefix/different user suffix, cache eviction/reload, and cancellation during prefill. Compare token IDs and logits against a cache-disabled reference. Never treat a partial recurrent-state match as a valid prefix hit.
4. **Implement chunked prefill and admission control.** Start with fixed chunks, a separate prefill token budget, and a decode-yield interval. Report TTFT separately for cache hit and cache miss. This is the direct fix for long-prompt tail latency.
5. **Add one-step MTP with recurrent rollback.** Port the checkpoint depth idea from `MTPDrafterModel.swift`; for Qwen3.6 MTP-1, checkpoint the recurrent state before each verification input and restore it on rejection. Make MTP opt-in per request and record proposed, accepted, rejected, verify, and rollback timings.
6. **Fuse the Swift decode schedule.** Use the upstream Swift perf issue as a checklist: compiled per-layer schedule, fused GDN conv1d/decay operations, pre-gather rotation, and fewer host synchronizations. [#466](https://github.com/ml-explore/mlx-swift-lm/issues/466)
7. **Partition execution lanes.** Greedy/MTP rows, sampled rows, logits-processor/grammar rows, and chunked-prefill rows should not contend for one incompatible batch. Preserve streaming and cancellation semantics in every lane.
8. **Publish an apples-to-apples scorecard.** The scorecard should include B=1/2/4/8, prompt lengths 1K/4K/8K/16K, output 256/1K, MTP off/on, cache off/exact/shared-prefix, prefill tok/s, decode tok/s, aggregate tok/s, TTFT p50/p95, peak active memory, and acceptance rate. Without this, the public 48.9/65.5 result cannot be fairly compared with your end-to-end 20.5/11.7 numbers.

### Concrete upstream reading/port list

- [mlx-lm #923, hybrid cache](https://github.com/ml-explore/mlx-lm/pull/923), [#980, prefix cache broken on hybrid models](https://github.com/ml-explore/mlx-lm/issues/980), [#1292, Qwen3.6 MTP prefix truncation](https://github.com/ml-explore/mlx-lm/issues/1292), [#1480, long-context hybrid prefill OOM](https://github.com/ml-explore/mlx-lm/issues/1480), and [#932, Gated DeltaNet Metal slow path](https://github.com/ml-explore/mlx-lm/issues/932).
- [mlx-swift-lm `MTPDrafterModel.swift`](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/MTPDrafterModel.swift) and [hybrid KV/SSM cache guide](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/kv-cache.md).
- [mlx-swift-lm #466, measured hybrid performance pass](https://github.com/ml-explore/mlx-swift-lm/issues/466).
- [vLLM-Metal #148, paged KV/continuous batching roadmap](https://github.com/vllm-project/vllm-metal/issues/148), [#610, hybrid GDN prefix cache plus MTP limitation](https://github.com/vllm-project/vllm-metal/issues/610), and [release notes](https://github.com/vllm-project/vllm-metal/releases) for current MLX pins and Metal fixes.
- [llama.cpp #22673, Qwen3.6 MTP](https://github.com/ggml-org/llama.cpp/pull/22673), [#23011, Apple Metal MTP regression](https://github.com/ggml-org/llama.cpp/issues/23011), and [server cache/slot controls](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
- [mlxcel continuous batching and paged decode](https://github.com/lablup/mlxcel/blob/main/docs/CONTINUOUS_BATCHING.md), especially its recurrent/cache boundary and fused-decode dispatch rules.

## Open questions

- Does the oMLX exact-box 48.9 tok/s result use the same `mlx-community/Qwen3.6-27B-4bit` checkpoint, sampler, output length, and MTP acceptance behavior as the provider? The page exposes MTP-related settings but does not make the full apples-to-apples request harness available.
- At concurrency 4 with 1.5K prompts, is the current 11.7 aggregate ceiling caused primarily by paged attention gathers, recurrent-state copies, MLX graph recompilation, host synchronization, or network/request accounting? Instrument each layer and scheduler turn before changing kernels.
- Can the Swift MLX backend batch Gated DeltaNet state transitions without materializing per-row state arrays or synchronizing the host? This determines whether true CB can approach the short-prompt 45.9 aggregate result at long prompts.
- What is the correct cache boundary for a Qwen3.6 prefix hit when the suffix begins in a linear-attention layer? The answer must be token-boundary and model-cache-format specific, not inferred from full-attention KV length.
- What MTP acceptance rate and verify cost occur at 1K, 4K, 8K, and 16K total context on this M3 Ultra? A high acceptance rate can still lose if the verify path costs multiple ordinary decode steps, as demonstrated by Apple-Metal issue evidence and the adjacent M3 Ultra benchmark.
- Does KV-cache quantization preserve coding-agent quality and tool-call fidelity for this model? Test K/V separately, especially because linear-attention recurrent state is not equivalent to ordinary KV.
- Can vLLM-Metal’s hybrid prefix-cache implementation be made safe for Qwen3.6 before its MTP rollback support lands? The current issue says the two features cannot yet be enabled together.
- Which quantization is the true throughput/memory Pareto point on this machine: the current MLX affine Q4 group-64 checkpoint, a 5/6-bit MLX checkpoint, or a GGUF Q4/Q5 K-quant? Public oMLX results are not enough because checkpoint format and MTP settings differ.
- Which external server exposes the cleanest cancellation, per-request priority, admission, and health semantics for remote buyers? oMLX and vLLM-Metal have the strongest current candidates, but the final choice should follow a provider-level soak test rather than a single tok/s number.
