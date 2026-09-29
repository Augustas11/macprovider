# Lane C — Gemma 4/3n, VLM, audio, embeddings, OCR (upstream sweep, 2026-09-28)

Pin: `ml-explore/mlx-swift-lm` **3.31.4**, rev `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`
(tagged 2026-06-30; `phase3-binary/Package.resolved`; checkout verified at
`phase3-binary/.build/checkouts/mlx-swift-lm`, `git rev-parse HEAD` == pin).
We serve **text-only** via `LLMModelFactory` (MLXLLM). No MLXVLM product. Catalog
Gemma row: `mlx-community/gemma-4-26b-a4b-it-4bit` (`phase3-binary/catalog/autotune/tier2-catalog.json:9`).

## Table

| # | Type | Class | Why |
|---|------|-------|-----|
| 282 (Gap 2) | **NUGGET/RISK** | P0 | Our pinned `Gemma4Text.swift` has **no** MoE router/experts code; upstream PR #364 (adds it) merged 3 weeks *after* our pin, 2 weeks after our own P0 bench claimed success loading the same MoE checkpoint. Needs re-verification. |
| 258 | RISK | P1 | Gemma4 26B-A4B repetitionPenalty broadcast crash — not currently reachable (we never set `repetitionPenalty`), but a live landmine if penalty support is ever wired up. |
| 279 / 282(Gap1) | NUGGET | P1 | `gemma4_assistant` MTP-drafter registration gap — informs our own SPEC-048 native-MTP work; community data says MoE 26B-A4B gets little/no speedup from drafting. |
| 220 | SKIP | — | TokenRing.loadPrompt 2D-batch crash — fixed by PR #170, merged 2026-05-11, already in our pin. |
| 231 | SKIP | — | Gemma4 K=V double-transpose broadcast crash — reporter confirms already fixed on upstream main (#247/#342); not exercised by our non-K-eq-V catalog row anyway. |
| 261 | SKIP | — | Gemma4 MXFP4 loader crash (`per_layer_input_gate.biases`) — we don't catalog an MXFP4 Gemma4 SKU (only 4-bit). Brief note only. |
| 270 | SKIP | P2 watch | gpt-oss-20b-tq3 needs upstream TurboQuant (`mlx` core, not yet landed). Not actionable until MLX core ships it. |
| 498 | SKIP | — | gemma3n_E2B CI hang/jetsam — MLX's own xctest harness issue (serial multi-GB model loads with no eviction), gemma3n isn't in our catalog. Mechanism (Metal-compiler jetsam under sustained pressure) doesn't map cleanly to our SPEC-023 swap/pressure gate (different signal: `vm_stat`/GPU compiler XPC vs `kern.memorystatus_vm_pressure_level`). |
| 338, 558 | SKIP | — | Gemma4 QAT KV-shared-layer loader gaps — both are `VLMModelFactory`/`MLXVLM` specific; our `LLMModelFactory` text path already carries the equivalent fix (commit `4bba1a8b` / PR #342, present in our pinned checkout). |
| 292, 374, 299 | SKIP | — | Vision-embedding/vision-encoder-dtype/image-input bugs — MLXVLM only. |
| 393, 207, 400, 392, 194 | SKIP | — | Gemma4/Gemma3n audio encoder feature requests/PRs — audio, not in scope. |
| 328 | SKIP | — | NomicBert embeddings — embeddings, not in scope. |
| 638 | SKIP | — | EmbeddingGemma bidirectional-attention bug — embeddings, not in scope. |
| 191 | SKIP | — | Qwen3-VL broadcast crash — VLM, and not our model family. |
| 219 | SKIP | — | "Gemma 4 model execution failed" — generic/stale duplicate of the loader-gap cluster (282/338/292); no distinct new content. |
| 197, 198, 177 | SKIP | — | Original "add Gemma 4 support" request issues, now superseded — Gemma4 loads today via #342/#333/#247 etc. |
| 101, 21, 15, 22 | SKIP | — | PaddleOCR-VL / Hunyuan / DeepSeek-OCR / LLaVA "model wanted" requests — unrelated families, OCR/VLM. |
| 25 | SKIP | — | gemma3n unsupported model type — gemma3n isn't in our catalog (we use gemma4). |
| PR 580, 535, 473, 454, 301 | SKIP | — | VLM image-attachment/OCR/GLM-OCR fixes — MLXVLM only. |
| PR 400, 392, 194 | SKIP | — | Gemma4/Gemma3n audio-encoder PRs — audio, not in scope. |
| PR 352 | SKIP | — | Gemma diffusion — unrelated architecture. |

---

## P0-01 — 282 (Gap 2): MoE gemma4 text-path load — evidence conflict, needs re-verification

**What upstream says:** Issue #282 ("Gemma 4 model family: three independent loader gaps") Gap 2:
prior to PR #364, `LLMModelFactory`'s `Gemma4Text.swift` had **no** handling for the
26B-A4B MoE tensor keys (`experts`, `router`, `post_feedforward_layernorm_1/2`,
`pre_feedforward_layernorm_2`) — PR #364's own description: "loading fails with
`Unhandled keys [...]`". PR #364 ("MLXLLM Gemma4Text: add MoE block (router +
experts) for the text path") ports `Gemma4TextRouter`/`Gemma4TextExperts`
(`SwitchGLU`) from `MLXVLM/Models/Gemma4.swift` into the LLM text path and
**merged 2026-07-21T19:43:49Z** — already tracked in
`beta/throughput-engineering/UPSTREAM_WATCH.json` as
`mlx_swift_lm_364_gemma_moe`, `status: awaiting_release_tag` (not in any tagged
release yet).

**What we have:**
- Our pin is `bd4b7434` / tag `3.31.4`, **tagged 2026-06-30** — three weeks
  *before* #364 merged.
- Verified directly against the checked-out source at
  `phase3-binary/.build/checkouts/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift`
  (confirmed `git rev-parse HEAD` == our pin): `grep -n "router\|experts\|MoE"`
  returns **zero matches**. There is no `enableMoEBlock` config field, no
  `Gemma4TextRouter`, no `Gemma4TextExperts` class, and `sanitize(weights:)`
  does not drop/remap `experts.*`/`router.*` keys — only KV-shared
  `k_proj`/`v_proj`/`k_norm` weights (that part *is* fixed, via commit
  `4bba1a8b` "Fix Gemma4 QAT load: KV-shared layers carry no k_proj/v_proj/k_norm
  (#342)", which is the last touch to this file before our pin).
- Yet our own catalog-expansion runbooks report **successful, correct**
  generation from exactly this checkpoint through exactly this factory path on
  this exact pin, dated **2026-07-07** (also before #364 merged):
  - `beta/catalog-expansion/P0-04-gemma4-template-probe.md` — `serve --no-join`
    → `LLMModelFactory.shared.loadContainer` (cites `ModelRuntime.swift:1887–1890`),
    3 chat probes + streaming, all `finish_reason: stop`, correct answers
    ("42", "Berlin", valid JSON), verdict GREEN.
  - `beta/catalog-expansion/P0-01-moe-memory-parity.md` — same checkpoint,
    ~15 GB resident, 4K-token probe, `kv_cache_request_completed` event with
    `prompt_tokens: 3284, completion_tokens: 64, finish_reason: "length"`.
  - `beta/catalog-expansion/P1-gemma4-bench-matrix.md` — full autotune bench,
    12.5 tok/s median, 3/3 Stage2 trials completed, 0 load failures.

**The conflict:** if the pinned source genuinely lacks any MoE-key handling,
`LLMModelFactory.shared.loadContainer` should have thrown an `UpdateError`
(unhandled/unused key) on `experts.*`/`router.*` tensors the first time it ran
against this checkpoint — not loaded cleanly and produced correct, coherent
multi-probe output three separate times. Either:
1. the load silently tolerated the unhandled keys and the bench was
   unknowingly exercising a **degraded/dense-only** forward pass (weights for
   the FFN experts never actually applied), which happened to still produce
   short, simple, correct answers by chance/luck on trivial prompts, or
2. something about the specific quantized conversion of this HF repo avoids
   the code path #364 targets, or
3. the documented load path in the P0 runbooks doesn't match what actually ran.

We did not find a local mlx-swift-lm fork/patch — the `.build/checkouts` tree
is stock upstream at the pinned rev.

**Concrete action:** this is a correctness question about a live catalog
model, not upstream's problem to fix — re-run the P0-04 probe fresh
(`serve --no-join --model mlx-community/gemma-4-26b-a4b-it-4bit --log-level
debug`) and grep the serve log for `Unhandled key`/`UpdateError`/warning-level
messages during load, and diff a longer (200+ token) generation's quality
against what a MoE-aware runtime (e.g. Python `mlx-vlm`, or a post-#364
mlx-swift-lm build) produces for the same prompt. If the experts/router
weights are indeed being silently dropped, our GA gemma-4-26b-a4b-it-4bit
provider may be serving effectively-broken/degraded output today. This should
happen before any further gemma4 catalog-expansion work builds on the P0/P1
runbooks' "GREEN" verdicts.

**Priority: P0.**

---

## P1 — 258: Gemma4 26B-A4B 8-bit repetitionPenalty broadcast crash

**What upstream says:** `GenerateParameters.repetitionPenalty != nil` crashes
`mlx-community/gemma-4-26b-a4b-it-8bit` on first `generate()` with
`[broadcast_shapes] Shapes (repetitionContextSize) and (seqLen) cannot be
broadcast` — Gemma4-specific (same params work fine on Qwen3.6 35B-A3B on the
same substrate). Reporter explicitly did **not** test the 4-bit variant.
Suspected site: `MLXLMCommon/Evaluate.swift`'s `RepetitionContext.process(logits:)`.

**What we have:** confirmed by direct grep of
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` —
`makeServeGenerateParameters` (line 1312) builds `GenerateParameters` with
`maxTokens`, `maxKVSize`, `kvBits`, `temperature`, `topP`,
`prefillStepSize` only; `repetitionPenalty` is never set (stays `nil`,
disabled). Our OpenAI-compat surface accepts buyer `presence_penalty`/
`frequency_penalty` (`OpenAICompatibleLoopbackRuntime.swift:1733-1734`,
`PromptCanonicalizer.swift:18-19`) and plumbs `presencePenalty`/
`frequencyPenalty` fields through `ContinuousBatchScheduler.swift` (rows,
inputs) — but no function anywhere in `phase3-binary/Sources/macprovider-cli/`
actually applies them to logits/sampling (grep for "penalty"-applying
functions returns nothing). They're accepted, canonicalized for receipts, and
otherwise dead fields today.

**Concrete action:** no code change needed now — the crash path is not
reachable. Flag for whoever builds real presence/frequency-penalty support:
do **not** map buyer `frequency_penalty`/`presence_penalty` straight onto
mlx-swift-lm's `GenerateParameters.repetitionPenalty` for gemma4 (any variant)
without testing against the 4-bit catalog SKU specifically — issue #258 only
confirmed the 8-bit crashes, and #220 shows the underlying
`RepetitionContext`/`TokenRing` broadcast-shape class of bug has hit
non-Gemma models too (fixed once already, by #170, already in our pin — but
that was a different root cause, 2D-batch `dim(0)`, not this one).

**Priority: P1** (blocks any future repetition-penalty feature for gemma4;
zero current-runtime impact).

---

## P1 — 279 / 282 (Gap 1): `gemma4_assistant` MTP-drafter registration

**What upstream says:** Google published MTP (multi-token-prediction) drafter
checkpoints for the whole Gemma4 family (`gemma-4-{E2B,E4B,26B-A4B,31B}-it-
assistant-bf16`, `model_type: gemma4_assistant`) that plug into
`generate(..., draftModel:, numDraftTokens:)`. `LLMTypeRegistry` doesn't
register the type yet. Discussion (maintainer + community, through #415)
converges on needing a generalized `LMOutput.State` extension so drafters can
consume the target's hidden states + share its KV cache — the same mechanism
this whole family of drafters (and any future EAGLE/lookahead-style scheme)
needs. One commenter explicitly notes: **"per Google's MTP overview, 26B-A4B's
realized speedup at batch 1 may be limited on Apple Silicon (poor MoE expert
reuse offsets drafting gains). Dense 31B and E-series should be the clean
wins."**

**What we have:** our own native-MTP work is SPEC-048
(`specs/SPEC-048-native-mtp-serving.md`) plus the blocked campaign PR
`gh pr view 1774` (blocked on upstream #645, filed by us, not in this lane's
issue list). Our only gemma4 catalog row is the MoE 26B-A4B variant. No gemma4
MTP-specific benchmark evidence exists in our repo to contribute upstream.

**Concrete action (NUGGET, not code — a planning input):** if/when SPEC-048's
native MTP work extends past its current target model(s) to gemma4, prioritize
a dense Gemma4 variant over the MoE 26B-A4B for drafting gains, per the
community's stated expectation of weak MoE/drafting synergy — consistent with
our own general finding in `spec038-cb-throughput-measured-net-negative.md`
that MoE/MLX immaturity tends to eat batching/parallel-decode gains. Track
`gemma4_assistant` registration (#279) as a soft blocker if gemma4 MTP is ever
scoped; no action needed today since gemma4 isn't in the MTP roadmap.

**Priority: P1** (planning-only; no current blocker).

---

## P2 — 270: gpt-oss-20b-tq3

**What upstream says:** request to support a TurboQuant (tq3) gpt-oss-20b
checkpoint; maintainer reply says it needs TurboQuant kernel support landed in
MLX core first (`ml-explore/mlx#3404`), referencing a stalled PR (#232) — not
something mlx-swift-lm can add unilaterally.

**What we have:** our gpt-oss catalog row is `openai/gpt-oss-20b`
(`mlx-community/gpt-oss-20b-MXFP4-Q8`), a different quantization scheme
entirely; TurboQuant isn't in our runtime. No action possible until MLX core
ships kernel support.

**Priority: P2** — watch only, re-check when `mlx` core lands TurboQuant.

---

## SKIP notes (one-liners, no further action)

- **498** (gemma3n_E2B CI hang/jetsam): MLX's own xctest suite ran ~20 multi-GB
  models serially with no eviction between loads before the jetsam; the fix
  direction (per-test eviction, `MLX_RUN_FULL_COHERENCE` gating) is CI-only.
  gemma3n isn't in our catalog. The general "sustained memory pressure kills a
  loaded-model process" shape *rhymes* with our SPEC-023 swap-gate work
  (`macprovider-swap-gate-8gb-false-reject-pr836.md`), but the actual signal
  (`kern.memorystatus_vm_pressure_level` sampling we use) is unrelated to
  their Metal-compiler-XPC-jetsam symptom, so there's no direct evidence to
  contribute.
- **261**: Gemma4 MXFP4 (`gemma-4-e2b-it-mxfp4`) load crash on
  `per_layer_input_gate.biases` — not our SKU (we use 4-bit, not MXFP4, for
  gemma4); noted for awareness only if an MXFP4 Gemma4 row is ever proposed.
- **231**: reporter's own comment says this is already fixed on upstream
  `main` (#247/#342); our non-K-eq-V 26B-A4B row wouldn't hit this path
  anyway (K-eq-V affects the E-series/12B/31B dense "unified" configs).
- **338/558**: both are `VLMModelFactory`-only; our text path already has the
  equivalent KV-shared-layer fix (commit `4bba1a8b`, PR #342, present in our
  pinned checkout).
- **220**: fixed by PR #170 (merged 2026-05-11), already included in our pin
  (tagged 2026-06-30).
- Everything else in the table (embeddings, VLM image/vision, audio, OCR,
  diffusion, non-Gemma model-wanted requests) is out of scope for a
  text-only, MLXLLM-only serving stack.

---

## Summary (top 5)

1. **P0 — #282/PR #364 (MoE gemma4 text-path load):** our pinned mlx-swift-lm
   (`bd4b7434`/3.31.4) has zero MoE router/experts code in
   `Libraries/MLXLLM/Models/Gemma4Text.swift`, yet our own P0-01/P0-04/P1-01
   runbooks report clean, correct generation from the MoE catalog checkpoint
   `mlx-community/gemma-4-26b-a4b-it-4bit` on that exact pin, weeks before
   upstream PR #364 (which adds that missing code) even merged. This is a
   real discrepancy, not resolved by this sweep — recommend re-running the
   P0-04 probe with debug logging to check for silently-dropped
   `experts.*`/`router.*` weights before trusting any further gemma4 work on
   those runbooks.
2. **P1 — #258 (repetitionPenalty broadcast crash on gemma4 8-bit):** not
   reachable today (`repetitionPenalty` is never set; buyer
   presence/frequency_penalty fields are accepted but never applied to
   sampling anywhere in the codebase) — but a documented landmine for future
   penalty-support work, especially since the reporter never tested the 4-bit
   variant we actually catalog.
3. **P1 — #279/#282 Gap 1 (`gemma4_assistant` MTP drafters):** informs
   SPEC-048 planning — community consensus is MoE 26B-A4B gets weak
   speculative-decoding payoff on Apple Silicon; prioritize dense Gemma4
   variants if gemma4 MTP is ever scoped.
4. **P2 — #270 (gpt-oss-20b-tq3):** blocked on MLX-core TurboQuant kernels,
   not actionable now; watch only.
5. **SKIP cluster (338/558/292/374/299/231/220/261/498 + all audio/embedding/
   OCR/VLM items):** either already fixed in our pin, VLM/audio/OCR-only, or
   model families we don't serve. No action.
