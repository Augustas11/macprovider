# Lane A: runtime core (KV cache, speculative/MTP, batching, compile, perf)

Swept 2026-09-28 against `ml-explore/mlx-swift-lm`. Our pin is `3.31.4` (`bd4b7434`, `phase3-binary/Package.resolved:31-37`). Raw fetches were kept in local session scratch (not committed).

Everything below is read-only analysis. Nothing was posted upstream.

## Summary table

| Item | Type | Class | Why (one line) |
|---|---|---|---|
| #645 | issue (ours) | SKIP/track | Filed by us today. No replies yet. Its dependencies are listed under (a). |
| #629 | issue | **CONTRIBUTE P1** | Branchable KV RFC. Our hybrid checkpoint plus paged-pool reuse is shipped evidence (TTFT 7.29 s → 0.58 s). |
| #618 | issue | CONTRIBUTE P2 | RotatingKVCache trim. Our serve path showed `maxKVSize` silently makes every layer a ring, so reuse was a no-op. |
| #606 | issue | NUGGET P2 | DFlash2 on Qwen3.8-27B: 3.0–4.5× single-stream on M3 Max. We serve qwen3.8-27b, serial only. |
| #522 | issue | SKIP | Concerns ChatSession system-prompt re-prefill. We don't use ChatSession. |
| #425 | issue | NUGGET P2 | Prompt-lookup proposal. See #643. |
| #424 | issue | RISK (tracked) | Already guarded in our code. Upstream #584 (merged) changes the trim semantics our guards assume. |
| #406 | issue (ours) | answered in (b) | Fixed by open PR #550 (dense models only). We already posted parity. |
| #312 | issue | SKIP (tracked) | Still open. No fix merged. Tracked in UPSTREAM_WATCH. |
| #294 | issue | SKIP | TurboQuant interest thread. #232 has merged. We don't use quantized KV. |
| #124 | issue | **CONTRIBUTE P2** | MoE Swift-vs-Python gap. The thread shows the gap closed. We have a QoS confounder (1.7×) and M3 Ultra numbers. |
| #123 | issue | SKIP | ChatSession plus loadPromptCache. |
| #81 | issue | SKIP | Duplicate root cause of #312. |
| #84 | issue | SKIP (answered in d) | Prompt cache. Mostly superseded by ChatSession and #436. |
| #42 | issue | **CONTRIBUTE P1** | Batch generation. Upstream merged only RoPE prep (#178, #212). We run a production paged CB engine with bit-exact parity data. |
| #19 | issue | SKIP | Qwen3-VL speed. We don't serve VLM. |
| #644 | PR | SKIP | ChatSession prefill progress reporting. |
| #643 | PR | NUGGET P2 | Bounded prompt-lookup decoding. 1.25–1.85× on copy/edit workloads, 0.92× on creative. |
| #641 | PR | SKIP | `ChatSession.fork`. Its TurboQuant `copy()` fix doesn't matter to us. |
| #640 | PR | NUGGET P2 | Per-token logprobs plus rotating-eviction counts. A possible OpenAI `logprobs` feature. It touches KVCache.swift. |
| #639 | PR | SKIP (P2 telemetry) | Adds `KVCacheStatus.memoryBytes`. Useful later for our KV telemetry. |
| #633 | PR | **RISK P1 / NUGGET** | Fixes a GDN q/k-norm epsilon that is headKDim× too large. Changes Qwen3.5/3.6/3.8 numerics, which moves our parity baselines. Candidate lead for the parity investigation. |
| #632 | PR | NUGGET P2 | MTP drafter loads only the `mtp.` shard (15.1 → 0.85 GB read). For SPEC-048. |
| #631 | PR | **RISK P1** | Fused GDN projection (merged #572) leaks about 2.3 GB per reload. A pin bump without #631 regresses warm model swaps. |
| #622 | PR | RISK P2 | Opt-in rewind reserve for RotatingKVCache. Touches KVCacheConfiguration and KVCache. |
| #621 | PR | SKIP | Reranker. |
| #619 | PR | SKIP | Streaming detokenizer extension point. We own our detokenization. |
| #614 | PR | NUGGET P2 | Skips vocab projection on prompt positions. Qwen3.5 prefill −10.7%. Prefill is our bottleneck. |
| #608 | PR | SKIP | ChatSession steering. |
| #607 | PR | NUGGET P2 | DFlash2 implementation plus same-input projection stacking (peak 22.97 → 17.84 GB at load). |
| #595 | PR | SKIP (watch) | Prepared sampler distributions. Groundwork for stochastic speculative decoding. |
| #581 | PR | SKIP (watch) | Resumable Qwen MTP in ChatSession. Not the external-scheduler boundary we need (#645). |
| #550 | PR | answered in (b), CONTRIBUTE P2 | FixedCapacityKVCache plus CompiledDecodeSession (Qwen2 and Llama only). |
| #545 | PR | SKIP (watch for SPEC-048) | Qwen3.8 MTP. We already serve Qwen3.8 text on 3.31.4. Its layer schedule is identical to Qwen3.6 (checked). |
| #510 | PR | CONTRIBUTE P2 | Rewindable MambaCache. Our checkpoint-at-boundary design is a measured alternative. |
| #459 | PR | SKIP (watch) | Distribution-correct MTP sampling. SPEC-048 v1 is greedy-only. |
| #436 | PR | SKIP (answered in d) | LRU PromptTrie. Our ConversationCache covers this. |
| #426 | PR | SKIP | Superseded by #643. |
| #335 | PR | **RISK P1** | `MaterializedArray` Sendable, `ModelContainer` deprecated, `BaseLanguageModel` no longer a `Module`. A breaking API change on bump. |

---

## Explicit answers

### (a) Merged-but-untagged commits since 3.31.4 that matter to us

`compare/3.31.4...main` returns 155 commits, the newest from 2026-09-22 (#603). None of them are tagged. The ones that matter:

**Qwen3.5/3.6/3.8 decode and prefill perf.** Our serial path picks these up for free on bump. The CB path needs a new parity run.
- `0bd3da45` **#467** compiles the Qwen3.5/3.6 decode step into traced segments split at the KV write. Measured +7.5% MoE decode at short context on M3 Max. They gated 108 A/B pairs as token-identical.
- `0321f28c` **#468** folds the GDN decode conv into the compiled step. +1.77% on 35B-A3B at 8K, bitwise-identical.
- `861649bf` **#469** adds a fused MoE router top-k kernel for decode. It replaces a full 256-way sort per layer per token and is bit-identical.
- `626516ba`/`db767efc` **#567/#568** share the fused router top-k across models.
- `846964d2` **#569** compiled decode segments for Qwen3-Next.
- `ebae3324` **#589** declares module weights as compile state (a compile-correctness fix).
- `37688d2c` **#572** fused GDN input projections (+4.6% decode on Qwen3.5-9B). This one carries the reload leak that open PR **#631** fixes. See RISK.
- `5b81858a` **#573** Qwen MoE direct reduction in prefill.
- `4c7874bc` **#470** balanced prefill chunking. Measured about 9% at 32K on Qwen3.6-35B-A3B (51.0 → 46.2 s).
- `f1bfca46` **#442** faster interleaved M-RoPE.

**Numerics and correctness of the GDN hybrid.**
- `d5d8b290` **#488** Kahan-compensated gated-delta recurrence. It changes low-order bits at long context.
- `5f4f5700` **#381** guard for non-multiple-of-32 GDN key dim. Not triggered: Qwen3.5 uses Dk=192.
- `65be34c6` **#399** state-threaded warm continuation. Only affects the ChatSession/VLM M-RoPE path; our text path isn't affected.
- `28a7f305` **#598**, which stops shifting norm weights twice when a checkpoint retains `mtp.*`. **3.31.4 still has this bug**: `Qwen35.swift:592-596` sets `shouldShiftNormWeights = hasMTPWeights || hasUnsanitizedConv1d`. It isn't live for us today, because all five catalog Qwen MLX repos have 0 `mtp.` keys in `model.safetensors.index.json` on HF main (checked for Qwen3.6-27B, 3.6-35B-A3B, 3.5-27B, 3.5-35B-A3B and 3.8-27B). It is a **hard requirement for SPEC-048 / #1774**: any MTP-retaining Qwen checkpoint loads as garbage on 3.31.4.

**KV cache, memory and serving hygiene.**
- `c6446cf7` **#620** clears the MLX cache on the first generated token. Without it, footprint grows unboundedly for requests under 256 tokens (Llama 3.1 8B: 5.54 → 11.95 GB over 8 requests, versus flat 4.6 GB with the fix). See NUGGET 1.
- `604fae71` **#584** makes RotatingKVCache trim wrap-aware.
- `38927f5f`/`5d8def8d`/`0b47e698` **#453/#514/#526** add typed KV cache configuration and enforce `maxKVSize` on hybrids. This is the largest API-behavior RISK for us.
- `4b0b4163` **#475** prompt cache persists model state and fails closed.
- `99c0e5f2` **#559** reports prompt-cache reuse.
- `9ce5b4f9` **#611** moves the generation loop onto a private serial executor. We already run decode on our own blocking executor (per our #406 comment: `ModelRuntimeSwapTests/testServingDecodeRunsThroughBlockingInferenceExecutor`), so impact is low.
- `2b03485a`/`10e0cb74` **#423/#389** cooperative cancellation in prefill and a cancellation race fix.

**Model load.**
- `e36d8ce3` **#575** parallel weight loading, up to 1.8× faster cold loads. This helps warm swap and restart TTFT.
- `1c1b2570` **#579** suspends instead of blocking cooperative threads during weight load.
- `ee673d6a` **#603** model cache extraction.
- `f5f18ed9`/`d6614025` **#408/#562** honor the safetensors index.
- `44a136ce`/`3de04ab3` **#490/#532** tied quantized Qwen3 MoE head sanitization.

**Speculative decoding and MTP (SPEC-028 / SPEC-048).**
- `01472a78` **#351** Qwen3.5 MTP.
- `bf4a9537` **#506** stands MTP down before the sliding cache wraps. It adds `isTrimmable(after:)`.
- `2af378b3` **#516** MTP past the sliding window.
- `6f609be9` **#533** LogitProcessor copy semantics for speculative decoding.
- `d443de77` **#592** DeepSeek MTP layer filtering.
- `78eaa5bb` **#415** Gemma 4 MTP.

Also present: **#146** Harmony tool-call parser, and **#232/#329/#520/#570** TurboQuant and variance-normalized KV. Other lanes cover these.

Net: an untagged main has roughly a 10% Qwen3.6 serial decode and prefill uplift waiting for us. It also has a fix we need before MTP (#598) and an unbounded-cache fix (#620). A bump must pull in #631, or set `MLX_QWEN_FOUR_GDN=0`. Otherwise warm swaps leak.

### (b) Does #550 overlap our #406 / CompiledDecode frozen-offset fix?

It has the same root cause but a different scope, and it does **not** fix our CB path.

- #550 fixes #406 as we filed it. That is `KVCacheSimple.update` using a Swift `Int` `offset`, which gets frozen into the compile trace.
  - The fix is a new `FixedCapacityKVCache` (preallocated, with the position held as an `MLXArray` threaded through compile, and masked unused capacity) plus a `CompiledDecodeSession`.
  - It is enabled only for `Qwen2Model` and `LlamaModel`. Hybrid, sliding and custom cache layouts are excluded.
  - We already validated it and commented (issuecomment 5326863007): exact token parity on Qwen2.5-7B-4bit, prefill 128 / decode 32.
  - That smoke run showed **compiled decode at 26.0 tok/s versus 27.9 uncompiled**, so compile was not a speed win there.
- Our production incident was the same bug class in **our own** cache, not upstream's.
  - `PagedKVSharedForwardBackend(compiledDecode: true)` replayed a trace that never re-ran the Swift `offset` update: `PagedKVCache.offset: Int`, `PagedKVCache.swift:138,224`.
  - The symptoms were greedy loops and `continuous_batching_invalid_cache_layout` at exactly 256 tokens.
  - PR #1716 (`d5b325b7`) fixed it by forcing `compiledDecode: false` on the serve path (`ModelRuntime.swift:3391`). `CompiledDecode.swift` stays env-gated behind `MACPROVIDER_COMPILED_DECODE` for decode-bench only.
- #550 therefore does nothing for the paged/CB path. To bring compile back to CB we would have to port its pattern into `PagedKVCache`: an MLXArray position as compile state, fixed-shape block-table inputs, and capacity masking.
- The more relevant upstream work for our hybrid Qwen models is **#467/#468/#569/#589**, which is already merged. It avoids the problem by splitting traced segments *at* the KV write, so the cache update stays eager.
  - That design could compose with our injected `PagedKVCache`, because the write happens outside the trace.
  - It needs a serial-versus-batched content parity rerun (the `msb-throughput --scenario leftovers` gate) before we trust it on the CB path.
- Recommendation: keep `compiledDecode:false` on serve. Don't port #550. After the bump, measure #467's segment compile on the paged path.

### (c) Does #124 (MoE 7.3× slower: per-token sync plus evalLock) match our Qwen3.6 MoE evidence?

No. The thread itself retracted the 7.3× figure, and our data agrees.

- **What the thread found:**
  - The original gap came from debug builds and float32 dtype contamination (`MLXArray.ones` / Swift `Float` literals adding `AsType` nodes). mlx-swift fixed that (#222 / `07fdf84`, #390).
  - Maintainers rejected evalLock and per-token sync as causes. davidkoski: "There is very little lock contention in single stream token generation."
  - john-rocky, M4 Max, Qwen3.5-35B-A3B-4bit: **Swift 117.3 vs Python 114.1 decode tok/s**.
- **Our numbers** (M3 Ultra 256 GB, pinned 3.31.4, from `cb-moe-serve-gate-hybrid-allowlist` memory and `docs/runbooks/cb-qwen-hybrid-parity-investigation.md`):
  - Qwen3.6-35B-A3B-4bit production serial baseline: **101.8 tok/s**. Batched: 290.6 tok/s at 8 rows (**2.86×**, bit-exact).
  - Qwen3-Coder-30B-A3B serial: 105.6 tok/s (`spec038-cb-throughput-measured-net-negative`).
  - That is roughly at the bandwidth bound for about 3B active parameters. There's no sign of a 7× MoE penalty.
- **What does match the thread's spirit:** the biggest Swift-side slowdown we found was **process QoS**, not MLX.
  - The launchd `ProcessType Adaptive` setting runs the provider at Mach priority 4.
  - Result on Qwen3.6-27B dense: **22.3 tok/s vs 37.8 under `Standard`**. `taskpolicy -b` gave 22.1.
  - Source: `docs/runbooks/qwen36-serving-runtimes-comparison-2026-09-25.md`; fixed in #1742.
  - This is a plausible hidden confounder for anyone benchmarking mlx-swift inside a daemon or app against Python in a terminal.
- **Per-token sync:** our 3× paged penalty was O(context) KV re-concatenation (fixed in `3a91f1bc`), not sync.
- **Worth posting** (P2): M3 Ultra MoE numbers plus the QoS finding.

### (d) Where our paged / CB / KV-survival work answers #629, #42, #84 and #436

- **#629 (branchable KV / copy-on-write prefix):**
  - SPEC-024 FR-CI2 hybrid reuse (`ConversationCache.swift`, `RecurrentStateCheckpoint`) matches spokvulcan/Tesseract's conclusion exactly:
    - trim the attention layers;
    - restore recurrent (`MambaCache`) state from checkpoints taken at stable prefix boundaries (C1 = end of system/tools scaffold, C2 = start of last turn);
    - have the batched scheduler split prefill chunks exactly at C1/C2 (`ContinuousBatchScheduler.prefillEnd`, around line 2867).
  - Measured on M3 Ultra, Qwen3.6, with a ~1.7k-token scaffold: first token **0.58 s hit vs 7.29 s miss**, 0.32 vs 6.88, 0.75 vs 7.36 (`docs/runbooks/continuous-batching-m4-hybrid-reuse-evidence-2026-09-24.md`). A 76.6 s re-prefill fell to 1.0 s.
  - Our SPEC-039 paged block pool with retained paged sequences (`PagedKVRetainedSequence`, FR-PKV10) is the "real shared storage" step. Tesseract gated that step and did not ship it.
  - Caveat to carry into our own code: Tesseract found `KVCacheSimple.copy()` aliases Metal buffers and hit SIGABRT on eviction while a command buffer was in flight.
    - `PagedKVCache.concreteCopy()` does `copied.state = state` (`PagedKVCache.swift:383-397`).
    - `RecurrentStateCheckpoint` holds array *references*, on the stated invariant that "ArraysCache replaces, never mutates" (`ConversationCache.swift:7-18`).
    - Both are aliasing-by-design. We should pin that invariant with a test before a bump, because #467/#468 move GDN state updates into compiled traces.
- **#42 (batch generation):**
  - Upstream has merged only the RoPE-offset prep (#178, #212). The CB PRs #150/#262/#263 were closed.
  - Our SPEC-038/039 engine is a working answer:
    - paged KV via a custom `MLXFast.metalKernel` gather, attached through the public `KVCache` protocol with no mlx fork (`SPIKE_PAGED_ATTN_PHASE0/2/3`);
    - a continuous-batch scheduler with prefill/decode interleave;
    - hybrid GDN support.
  - Numbers are in the CONTRIBUTE section below.
- **#84 (prompt cache):** answered by ConversationCache (in-RAM, keyed per conversation) plus the SPEC-037 encrypted disk tier (`KVDisk*`, merged dormant).
  - Our real-hardware lesson belongs on the upstream `maxKVSize` behavior: any `maxKVSize` makes `newCache` build `RotatingKVCache`, which is untrimmable after a wrap and wasn't serializable by our v1 tier. The persistence was therefore a silent no-op in real serve until we forced `KVCacheSimple` for eligible requests (`ModelRuntime.cacheParameters(forceSimpleKV:)`, `ModelRuntime.swift:1330-1345`).
- **#436 (cross-request LRU PromptTrie):** our ConversationCache is keyed by an explicit conversation key rather than a token trie. It uses byte-bounded reservation (the KVConversationColdTierAdapter HIGH-5 geometry estimate before deep copy) and treats hybrids as checkpoint-only.
  - The trie is a possible upgrade for keyless shared-system-prompt traffic.
  - We have no measured need yet, so it isn't worth porting now.

---

## NUGGET items

### N1 (P1): #620 clear the MLX buffer cache on the first token
- **Upstream:** `TokenIterator.next()` first clears at token 256, so short requests never clear. Llama 3.1 8B, 8 requests: footprint 5.54 → 11.95 GB, MLX cache 7.44 GB. With the fix it stays at 4.63 GB and 0.09 GB.
- **Us:**
  - Serve uses `TokenIterator` (`ModelRuntime.swift`).
  - `mlx_cache_limit_mb` is opt-in: `applyMLXCacheLimit` returns nil when unset (`ModelRuntime.swift:1843-1853`). Only the Studio config sets 2048.
  - The live Studio provider grew from about 50 → 130 GB under buyer traffic and was jetsam-killed on 2026-09-24 (`cb-compiled-decode-frozen-offset-invalidates-evidence` memory). That was not proven to be this cause, but it is consistent with it.
- **Action:** in our serial serve loop, call `Memory.clearCache()` once after prefill and before the first decode token (mirroring #620). Consider a fleet-default `mlx_cache_limit_mb`. **Expected gain:** a bounded resident footprint for short-request traffic without waiting for a tag.

### N2 (P1): #470 balanced prefill chunking
- **Upstream:** fixed-stride chunking leaves a remainder forward at the largest Lk. On Qwen3.6-35B-A3B at 32K, a 141-token remainder cost 2.94 s versus 0.98 s for a full 1024 chunk. Balanced chunking went 51.0 → 46.2 s (about 9%).
- **Us:** `ContinuousBatchScheduler.prefillEnd(for:maxChunkTokens:)` uses `min(promptTokenCount, cursor + maxChunkTokens)`, which is the degenerate fixed-stride pattern (also clipped at C1/C2). Serial serve uses upstream `prefillStepSize` chunking in 3.31.4, the pre-#470 behavior. Prefill is our measured bottleneck (about 300 tok/s serial, about 117 per row under load; `qwen36-serving-runtimes-comparison-2026-09-25.md`).
- **Action:** in `prefillEnd`, split each row's remaining span (up to the next checkpoint) into the fewest equal chunks of at most `maxChunkTokens`. The serial path gets #470 on bump. **Expected gain:** 5–9% long-prompt TTFT on Qwen3.6.

### N3 (P0 for SPEC-048 / #1774): #598 norm double-shift with retained `mtp.*`
- 3.31.4's `Qwen35.swift:592-596` double-shifts RMSNorm weights whenever `mtp.` keys are present.
- Native MTP needs checkpoints that keep `mtp.*`, and those produce garbage on our pin.
- **Action:** add "upstream contains `28a7f305`" to the SPEC-048-R003 qualification list, and to `UPSTREAM_WATCH.json` required commits next to #351, #516 and #584. Add a qualification test that loads an MTP-retaining checkpoint and asserts that the `input_layernorm` mean is about 1.0.

### N4 (P1 on bump): Qwen decode perf stack #467/#468/#469/#572/#573
- Free for serial after the bump. Expected roughly +5–10% Qwen3.6 MoE decode (upstream M3 Max figures; not re-measured on our M3 Ultra).
- **Action:** after the bump, rerun `msb-throughput --engine scheduler --no-compile --scenario leftovers` on all five Qwen hybrids. Batched parity must stay bit-exact on 3.6, and the #1771 allowlist evidence must be refreshed.

### N5 (P2): refuting the partial-RoPE hypothesis in `docs/runbooks/cb-qwen-hybrid-parity-investigation.md`, plus the #488/#633 GDN numerics
- The runbook says partial_rotary_factor is "absent/full on 3.5".
- HF configs show `rope_parameters.partial_rotary_factor = 0.25` for Qwen3.5-27B. 3.31.4 reads it from `rope_parameters`, defaulting to 0.25 (`Qwen35.swift:133-149`). Qwen3.6 and 3.8 are also 0.25.
- `layer_types` matches interval 4 on all three. So neither RoPE nor the layer schedule explains the qwen3.5/3.8 parity FAIL.
- The remaining upstream-visible GDN numerics differences are #488 (Kahan recurrence, merged) and #633 (epsilon headKDim× too large, open).
- **Action:** correct the runbook. As one probe in that investigation, rebuild the harness on upstream main plus #633 and re-run parity.
- A caveat to note in the runbook: #643 saw greedy divergence at near-tied logits from batched verification alone. Batch-shape-dependent reduction order may be the real cause, and it may not be fixable to bit-exact.

### N6 (P2): #614 skip vocab projection on prompt positions
- **Upstream:** Qwen3.5-9B prefill −10.7%, and −185 MiB peak memory.
- **Us:** the scheduler prefill needs only last-position logits. Check whether `PagedKVSharedForwardBackend.prefill` projects all positions through `lm_head`. If it does, slice hidden states before the head (the LanguageModel API that #614 adds would do this).

### N7 (P2): DFlash2 #606/#607 for qwen3.8-27b
- **Upstream:** 3.0–4.5× single-stream on M3 Max 48 GB, greedy and lossless (acceptance 2.5–5.8).
- **Us:** this is only relevant to a serial, low-concurrency lane. SPEC-028 forces `effective_max_batch=1` when drafting, so it conflicts with CB.
- Watch it; don't build on it. The upstream PR is open and 3.2k lines.

### N8 (P2): prompt lookup #643/#425
- **Upstream:** 1.25–1.85× on copy and edit workloads, 0.92× on creative. It is draft-free and needs trimmable caches.
- **Us:** hybrid GDN models aren't trimmable, so our main catalog is excluded on the current design.
- Relevant later for Llama and Qwen3-Coder coding-agent traffic.

### N9 (P2): #632 MTP drafter reads only the `mtp.` shard
Add it to the SPEC-048 loader bound (MTP-2): 15.1 → 0.85 GB read for Qwen3.5-27B.

---

## RISK items (pin bump)

- **R1 (P1): #514/#453/#526 typed KV config and enforced `maxKVSize` on hybrids.**
  - Our serve always sets `maxKVSize = maxContextTokens` (`makeServeGenerateParameters`, `ModelRuntime.swift:1312-1327`).
  - Today, hybrid Qwen models build their own cache and ignore it. After #514, the attention layers become `RotatingKVCache` on keyless serial traffic.
  - That changes our cache-class assumptions in `pagedKVRuntimeCacheClass` (`ModelRuntime.swift:1870-1885`), the ConversationCache Rotating guard (`ConversationCache.swift:322-325`), and the SPEC-037 cold tier.
  - The `newCache` API also becomes throwing (seen in our #550 validation).
  - **Action:** as part of bump qualification, add a per-catalog-model test asserting the serve and cache class.
- **R2 (P1): #631 not merged, while #572 is.** Reloading Qwen3.5-27B leaked 3.0 → 5.3 → 7.6 GB resident. The bump must include #631, or set `MLX_QWEN_FOUR_GDN=0`.
- **R3 (P1): #335 MaterializedArray.** This is a breaking API change: `ModelContainer` deprecated, `BaseLanguageModel` no longer a `Module`, `UserInput` media types changed. Maintainers call it "ready to go". Budget a migration on the bump after it lands.
- **R4 (P2): #584 (merged) and #622 (open) change RotatingKVCache trim semantics.** Our #424 guards stay conservative and are still correct after either change: `speculativeCacheWindowSafe`, `productionSpeculativeCacheWrapValidated = false` (`ModelRuntime.swift:1086-1113`), and the ConversationCache Rotating miss. Revisit whether they can be relaxed only after a cache-wrap parity proof.
- **R5 (P1): aliasing invariants.**
  - `RecurrentStateCheckpoint` assumes MambaCache slots are replaced, never mutated in place.
  - #467/#468 (compiled GDN step), #510 (checkpointing MambaCache) and any in-place state kernel could break that assumption silently.
  - Add a test that captures a checkpoint, steps once, and asserts the checkpoint arrays are unchanged.
- **R6 (P2): #633 numerics.** Qwen3.5/3.6/3.8 outputs shift (row relative error drops from 0.91 to 3e-7 against the reference). All stored parity SHAs and golden outputs need regenerating on bump.

---

## Top 5 for the caller
1. **N3 (P0 for #1774):** 3.31.4 double-shifts Qwen3.5 norms when `mtp.*` is present. SPEC-048 must require `28a7f305` (#598). Production is safe: 0 `mtp.` keys in the catalog repos.
2. **N1 (#620, P1):** the MLX buffer cache isn't cleared for requests under 256 tokens. Our fleet has no default `mlx_cache_limit_mb`. Add `Memory.clearCache()` after prefill.
3. **RISK bundle (P1) for the next pin bump:** #514 enforces `maxKVSize` on hybrids, which conflicts with our serve cache-class assumptions; #631 must accompany #572 (reload leak); #335 is a large API break. Merged main also carries about 10% Qwen3.6 decode and prefill uplift (#467/#468/#469/#470/#572).
4. **(b):** #550 fixes #406 only for dense upstream caches. Our CB frozen-offset bug was in our own `PagedKVCache` and remains mitigated by `compiledDecode:false`. Upstream's #467 segment-split approach is the better route back to compile.
