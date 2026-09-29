# mlx-swift-lm upstream sweep — 2026-09-28

Scope: every open issue (67) and open PR (48) on `ml-explore/mlx-swift-lm`, plus
the merged-but-untagged commits on `main` since our pin (`3.31.4`, `bd4b7434`,
tagged 2026-06-30; 155 commits since, none tagged). Each item was read in full
and cross-checked against our provider code, SPECs, runbooks and lab evidence.

Goals:

1. Find upstream fixes, techniques or findings that should change our runtime
   or plan.
2. Find threads where our 3–4 months of production serving and Qwen-family
   benchmarking is evidence upstream does not have.

Per-lane detail (every item classified, with sources):

- [lane-A-runtime.md](lane-A-runtime.md) — KV cache, speculative/MTP, batching,
  compile, perf (16 issues, 23 PRs)
- [lane-B-tokenizer-tools.md](lane-B-tokenizer-tools.md) — detokenizers, tool
  calling, chat templates, Harmony, Qwen numerics, release/CI (24 issues, 16 PRs)
- [lane-C-gemma-vlm.md](lane-C-gemma-vlm.md) — Gemma 4 / 3n, VLM, audio,
  embeddings, OCR, other ports (27 issues, 9 PRs; mostly SKIP for text-only
  serving)


## Status (2026-09-29, parked)

- Streaming truncation (#636 class), MLX cache clear after prefill (#620), and `preserve_thinking` (#154) shipped
  in PR #1784 (`08074278`), with receipt binding and SPEC-018 v0.2.10 / SPEC-019 v0.2.6. Studio evidence:
  `studio-e2e-stream-fix-2026-09-28.md`.
- Parity runbook correction (partial-RoPE lead refuted) landed on main (`5f8278762`).
- #1770 native-MTP: the serve path rejected the real #1774 artifacts at two admission gates (drafter tensor
  namespace; MLX `affine` quantization mode). Fix is parked as a draft PR on `fix/1770-standalone-drafter-admission`.
  Resume condition: Studio `MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1` run reports `serve_path_verified: true`.
- Not started: gemma-4 catalog load check/delist (§1 P0), balanced CB prefill chunking (#470), penalties no-op,
  toolchain migration for the next mlx-swift-lm tag, `UPSTREAM_WATCH.json` refresh.

---

## 1. Act on now (our defects surfaced by upstream threads)

| Pri | Finding | Upstream | Our code | Status of evidence |
|---|---|---|---|---|
| **P0** | Catalog row `gemma-4-26b-a4b-it-4bit` most likely **cannot load** on our pin | #282 Gap 2, PR #364 (merged 07-21, untagged) | pinned `MLXLLM/Models/Gemma4Text.swift` | Verified: pinned file has 0 router/experts code; checkpoint on Studio has `enable_moe_block: true`, 128 experts, 420 `experts.*`/`router` keys; loader uses `update(parameters:verify:[.all])`, which rejects unused keys. Contradicts the 2026-07-07 catalog probes (`beta/catalog-expansion/P0-04`, `P0-01`, `P1`). **Not yet run** — needs one load on the Studio. |
| **P0/P1** | Streaming answers silently truncate after the first non-prefix decode | #636 | `ModelRuntime.streamDelta` (L7247), `SerialStreamingTextEmitter` (L7898), CB `appendCleaned` (L4102) | Code confirmed: `streamDelta` returns `""` whenever current decode does not start with emitted text and never re-anchors. Offline repro with real tokenizers: gemma-4 stalls at token 17 (52/88 chars delivered); Llama-3.x on `" 's"`-style text. Qwen/gpt-oss/GLM/Nemotron unaffected (`clean_up_tokenization_spaces: false`). Needs a Swift test. |
| P1 | Short requests never clear the MLX buffer cache | #620 (merged, untagged) | serve `TokenIterator` path; `applyMLXCacheLimit` returns nil when `mlx_cache_limit_mb` unset (`ModelRuntime.swift:1843-1853`) | Upstream: Llama-8B 5.5→12 GB over 8 short requests, flat 4.6 GB with fix. Consistent with (not proven for) the 2026-09-24 Studio 50→130 GB growth + jetsam. Fix: `Memory.clearCache()` after prefill; consider a fleet-default cache limit. |
| P1 | Qwen3.6/3.8 multi-turn prompts are not append-only with `enable_thinking=false` | #154 | `templateAdditionalContext` (L7478) | Verified by rendering Qwen3.6-27B template: only 52/93 chars of turn 1 survive as prefix, so the previous answer is re-prefilled every turn. Passing `preserve_thinking: true` (present in 3.6-35B-A3B, 3.6-27B, 3.8-27B templates) restores append-only. Gain unmeasured — check `kv_cache` telemetry on turn 2. |
| P1 | CB prefill uses fixed-stride chunking | #470 (merged, untagged) | `ContinuousBatchScheduler.prefillEnd` | Upstream: ~9% at 32K on Qwen3.6-35B-A3B (51.0→46.2 s). Split each row's remaining span into the fewest equal chunks ≤ `maxChunkTokens`. Serial path gets it free on bump. |
| P2 | Quadratic streaming cost (full re-decode + full tool-tag rescan per token) | #624 / #625 | serial decode ~L6197; `NativeToolCallStreamEmitter.observe` (L8009) | Unmeasured on our side; benchmark a long tool call first. |
| P2 | No placeholder-token masking for gemma-4 | #412 | sampler | gemma-4 declares image/audio/video ids, ships no `suppress_tokens`. Leak unverified on 26B-A4B. |
| P2 | Tool calls never synthesized for gemma-4 / GLM-4.5-Air | #626 / #628 / #623 | `ToolCallParser.swift`, SPEC-018 §3.1 | SPEC bump first; #628 grammar is the reference for a Gemma row. |
| P2 | Buyer `presence_penalty` / `frequency_penalty` accepted but never applied | #258 (adjacent) | `makeServeGenerateParameters`, `ContinuousBatchScheduler` | Dead fields. #258's gemma-4 repetition-penalty broadcast crash becomes reachable if we wire them. |

The two gemma findings compound: the gemma-4 row either fails to load, or (if
it loads through some path we have not identified) its streamed output
truncates on code. Verify that row end to end before anything else.

## 2. Correct our own records

- `docs/runbooks/cb-qwen-hybrid-parity-investigation.md`: the partial-RoPE
  hypothesis for the qwen3.5/3.8 serial≠batched parity FAIL is refuted. HF
  configs give `partial_rotary_factor 0.25` on 3.5, 3.6 and 3.8 (3.5 under
  `rope_parameters`, which 3.31.4 reads), and `layer_types` match. #633 and
  #450 also do not explain it (row-local op identical on both paths; failing
  models are uniform 4-bit while the passing 3.6-35B-A3B is the mixed-quant
  one). Remaining leads: #488 Kahan GDN recurrence (merged) and batch-shape
  dependent reduction order, which may make bit-exact unreachable (#643 saw
  the same class from batched verification).
- The 2026-07-07 gemma-4 catalog probes need a re-check note (see §1 P0).
- `beta/throughput-engineering/UPSTREAM_WATCH.json` is stale: it lists
  swift-transformers 1.0.0 (we resolve 1.3.4) and was last checked
  2026-08-16. Proposed additions: #598 (required for SPEC-048), #620, #631,
  #633, #514, #335, #636. That file is not docs-only, so it goes through the
  #1774 campaign PR or its own PR.

## 3. Next pin bump — what it brings and what it breaks

The next tag is expected around 2026-09-28/29 (#617). It is the tag that
finally carries #364 (gemma MoE), #453 (typed KV cache), the MTP work
SPEC-048 needs, and #550 (compile for dense caches).

**Blocker:** upstream `main` requires swift-tools 6.2 and mlx-swift ≥ 0.31.6.
`docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md` keeps production on Xcode 16.4 /
Swift 6.1 and records that mlx-swift 0.31.5+ needs Swift 6.3. The release-runner
toolchain migration has to be planned now. `main` also adds an xgrammar C++
shim target — new build surface to check against signing and packaging.

**Gains:** ~5–10% Qwen3.6 decode (#467/#468/#469/#572/#573, upstream M3 Max
numbers), ~9% long-prompt prefill (#470), 1.8× faster cold loads (#575),
non-blocking loads (#579), cooperative prefill cancellation (#423/#389).

**Must-have for SPEC-048 / #1774:** #598 (`28a7f305`). 3.31.4 double-shifts
Qwen3.5 RMSNorm weights when a checkpoint retains `mtp.*`
(`Qwen35.swift:592-596`, confirmed), so any MTP-retaining checkpoint loads as
garbage. Production is safe today: 0 `mtp.` keys in all five catalog Qwen
repos. Add `28a7f305` to SPEC-048-R003 alongside #351/#516/#584, plus a
qualification test on an MTP-retaining checkpoint. Also #632 (drafter reads
only the `mtp.` shard, 15.1→0.85 GB) for the loader bound.

**Risks:**

- #514/#453/#526 enforce `maxKVSize` on hybrids. Our serve always sets it
  (`ModelRuntime.swift:1312-1327`), so hybrid attention layers become
  `RotatingKVCache`, breaking assumptions in `pagedKVRuntimeCacheClass`,
  ConversationCache's Rotating guard and the SPEC-037 cold tier. `newCache`
  also becomes throwing. Add a per-catalog-model serve/cache-class test.
- #572 is merged but its reload leak fix #631 is not (3.0→5.3→7.6 GB per
  reload). Bump must include #631 or set `MLX_QWEN_FOUR_GDN=0`.
- #633 (open) changes every Qwen3.5/3.6/3.8 token (pinned effective eps is
  headKDim× too large). Pre-register as an intended diff; regenerate parity
  SHAs, SPEC-039 allowlist evidence, MSB fixtures; re-prove Qwen3.6
  serial==batched.
- #335 (open, "ready to go"): `ModelContainer` deprecated, `BaseLanguageModel`
  no longer a `Module`. Budget a migration.
- Aliasing: `RecurrentStateCheckpoint` and `PagedKVCache.concreteCopy` hold
  array references on the invariant that cache arrays are replaced, never
  mutated. #467/#468 move GDN state updates into compiled traces. Pin the
  invariant with a test before the bump.
- #450: mixed-quant checkpoints with overrides inside `linear_attn` load
  cleanly and generate garbage at our pin. Catalog admission for OptiQ/DWQ
  style checkpoints needs a coherence check.

**Compile:** #550 fixes our #406 only for upstream dense `KVCacheSimple`
(Qwen2/Llama). Our CB frozen-offset bug was in our own `PagedKVCache` and stays
mitigated by `compiledDecode:false` (`ModelRuntime.swift:3391`). Do not port
#550; after the bump, measure #467's segment-split compile (KV write stays
eager) on the paged path.

## 4. Watch only

DFlash2 #606/#607 (3–4.5× single-stream on Qwen3.8-27B, conflicts with CB),
prompt lookup #643/#425 (hybrids not trimmable), #614 (skip vocab projection on
prompt positions, −10.7% prefill — check our scheduler prefill projects only
last positions), #640 logprobs, #639 KV memory reporting, #581/#459/#595 MTP
sampling, #563 gemma channels, #270 gpt-oss TurboQuant (blocked on MLX core),
#279 gemma4 MTP drafter (community reports weak payoff on 26B-A4B).
