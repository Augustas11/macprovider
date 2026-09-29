# Lane B — tokenizers / detokenizers, tool calling, chat templates, Harmony / reasoning, Qwen correctness, release/CI, text-LLM ports

Sweep date: 2026-09-28. Our pin: mlx-swift-lm 3.31.4 (bd4b7434), mlx-swift 0.31.4 (dc43e62d), swift-transformers 1.3.4 (c21fdcde), per `phase3-binary/Package.resolved`.
Repo HEAD read: `a22780ed1`. Raw upstream dumps and the offline `sim.py` repro were kept in local session scratch (not committed).

## Summary table

| Item | Type | Class | Why (1 line) |
|---|---|---|---|
| #636 NaiveStreamingDetokenizer drops chars when decode shrinks | issue | **NUGGET (P0/P1) + CONTRIBUTE** | Our own serial streaming path has a *worse* form of the same bug: on a non-prefix decode it stops emitting for the rest of the stream. Reproduced offline for gemma-4-26b-a4b (catalog model) |
| #633 epsilon scaling in Qwen gated-delta q/k norm (PR) | PR | **RISK (P1)** | Pin uses `rmsNorm(eps: 1e-6)` where the reference L2 norm needs `1e-6/headKDim`. Changes every Qwen3.5/3.6/3.8 token on pin bump. Does **not** explain our CB parity FAIL |
| #450 per-layer mixed-quant Qwen3.5 garbage | issue | RISK (P2) + small CONTRIBUTE | Our failing CB models are uniform 4-bit, and our passing Qwen3.6-35B-A3B is the mixed one, so it does not explain the parity FAIL. It is a catalog-admission hazard for OptiQ/DWQ-style checkpoints at the pin |
| #154 Qwen3 enable_thinking | issue | **NUGGET (P1) + CONTRIBUTE** | We force `enable_thinking=false` from template bytes (#1700). Verified: that makes Qwen3.6 multi-turn prompts non-append-only (KV reuse loss). `preserve_thinking=true` fixes it |
| #214 RFC token-level response-format parser / Harmony | issue | CONTRIBUTE (P2) | Our `HarmonyResponseParser.swift` is already the token-ID, fail-closed, incremental parser the RFC proposes. We have production failure modes to share |
| #61 GPT-oss requires Harmony | issue | CONTRIBUTE (P2), same as #214 | Same evidence. Point to #214 |
| #617 "Release soon?" | issue | **RISK (P1) + CONTRIBUTE (P1)** | Next tag likely bumps mlx-swift and tools 6.2, which forces a toolchain migration on us. We can offer RC validation with our upgrade matrix on M3 Ultra / M5 |
| #221 upstreaming from forks | issue | CONTRIBUTE (P2) | Credible offers: #636 fix/evidence, Harmony parser semantics, serial-vs-batched parity data. No fork-sized dump |
| #624 ToolCallProcessor quadratic end-tag rescan | issue | **NUGGET (P2)** | Our serial streaming path re-decodes the whole generated prefix *and* rescans the whole text for tool delimiters on every token |
| #625 PR fixing #624 | PR | NUGGET (P2) | The technique (scan only appended chunk + tag overlap) applies to `NativeToolCallStreamEmitter.observe` |
| #563 Gemma 4 reasoning channels + `Generation.reasoning` | PR | RISK (P2) / watch | Changes `.chunk` semantics on pin bump. We don't consume `Generation.chunk` on the serve path, so low impact. Relevant to gemma-4 channel handling |
| #412 suppress_tokens + mask multimodal placeholders | PR | NUGGET (P2) | gemma-4-26b-a4b (catalog) declares image/audio/video placeholder ids and ships no `suppress_tokens`. We do no masking |
| #626 Gemma nested tool args | PR | NUGGET (P2, gap note) | SPEC-018 has no Gemma-4 row, so tool calls on a recommendable catalog model are never synthesized. Upstream parser is the reference grammar if we add one |
| #628 Gemma dialect parser | issue | NUGGET (P2), same as #626 | Grammar spec is directly reusable for a SPEC-018 Gemma row |
| #623 / #491 GLM-4-0414 markerless tool calls | PR/issue | SKIP (note) | We serve GLM-4.5-Air (`<arg_key>` dialect), not 0414. SPEC-018 has no GLM row either (same gap as Gemma) |
| #642 drop MTP weights in Qwen3.5 **VLM** sanitize | PR | SKIP | We load text-only via MLXLLM, which already drops `mtp.*` |
| #637 MiniCPM5 tool parser | PR | SKIP | Not in catalog |
| #635 NemotronH dense config keys optional | PR | SKIP | We serve Nemotron-3-Nano-30B-A3B (MoE), which decodes today |
| #634 LFM2.5 2.6B | PR | SKIP | Not in catalog |
| #528 LFM2.5 prod support + DSpark spec decode | PR | SKIP (lane D may care) | Not in catalog. DSpark rollback-across-conv-cache is spec-decode lane material |
| #630 Bonsai 2 27B (ternary Hadamard Qwen3.8) | PR | SKIP (catalog idea, P2) | 8.6 GB weights, ~30 tok/s vs 22 for the 4-bit pack on M3 Max (upstream numbers). Candidate for low-RAM providers only if quality holds |
| #627 Qwen3VL PreparedInputSplitting | PR | SKIP | VLM only |
| #551 weight-load progress | PR | SKIP | Needs unreleased mlx-swift |
| #489 docs/skills | PR | SKIP | Docs |
| #288 pre-quantized MXFP8 + minicpmv4_6 | PR | SKIP | Not our models |
| #87 Linux WIP | PR | SKIP | Metal-only product |
| #543 Xcode 27 beta 5 FM compile | issue | SKIP | We don't depend on MLXFoundationModels |
| #539 SDK-27 test bundle segfault on macOS 26 | issue | SKIP | Test-bundle-only; FM types |
| #588 Metal kernels need plain-MLX fallback | issue | SKIP | Metal-only |
| #517 gigatoken / swift-tokenizers | issue | SKIP (watch) | Tokenizer swap is a separate token-exact migration for us (#966) |
| #497 GPTNeoXTokenizer unsupported | issue | SKIP | Not our models |
| #496 31B MTP diagnostics never run in CI | issue | SKIP | Upstream CI (MTP lane may care: gemma MTP e2e is effectively untested upstream) |
| #492 env-var test gates under xcodebuild | issue | SKIP | Upstream CI |
| #441 multi-turn tool calling (FM) | issue | SKIP | FM API. Thread also carries spam |
| #217 3.31.3 upgrade notes 404 | issue | SKIP | Docs |
| #189 v3 todos | issue | SKIP | `*.jinja` download pattern already handled on our side (we read `chat_template.jinja` directly) |
| #98 pure lib without HF dep | issue | SKIP | Done in v3 (Tokenizer protocol) |
| #85 structured Tool API | issue | SKIP | API ergonomics |
| #79 `.thinking` Generation case | issue | SKIP | Superseded by #563. We strip thinking ourselves |
| #31 FunctionGemma Jinja modulo error | issue | SKIP | Not our model |

(#628 is listed above. #633 is technically a PR and was included because the lane brief asked about it.)

---

## (a) #636: does it affect our streaming output? **Yes, and our variant is worse.**

**Upstream:** `NaiveStreamingDetokenizer.next()` emits `newSegment.suffix(new.count - old.count)`. When `clean_up_tokenization_spaces` rewrites earlier text (`" ." -> "."`, `" 's" -> "'s"`), characters are dropped. Trigger: swift-transformers defaults cleanup to **on** when the key is absent (`Tokenizer.swift:532` `cleanUpTokenizationSpaces.boolean(or: true)` in our checkout of 1.3.4). Gemma-4 ships no key.

**Our serving paths** (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`):
1. **Serial streaming (main path):** each step fully re-decodes all generated tokens (`context.tokenizer.decode(tokenIds: tokens)` ~L6197). It then runs `streamingSafePrefix` and hands the result to `SerialStreamingTextEmitter.step` (~L7927). That calls `ModelRuntime.streamDelta(from:to:)` (L7247), which **returns "" whenever the new decode does not extend what was already emitted**, and `emittedText` is not updated. After the first non-prefix decode, every later delta is also "" because the old emitted text never becomes a prefix again. `finish()` uses the same `streamDelta`, so the tail is never flushed. **Result: the rest of the streamed answer is silently lost** while `finish_reason` is still normal. Non-streaming answers are fine, since they use the final full decode.
2. **CB serial-tool rows:** `ByteLevelIncrementalTextDecoderBox.appendCleaned` (L4103) reimplements the cleanup by rewriting the last 4 characters of already-returned text, so it has the same non-prefix exposure. The consumer uses the same `streamDelta`.
3. **Classic speculative path** (L5725) and **Harmony final channel** (L6132) use upstream `NaiveStreamingDetokenizer` directly, so #636 applies to them as-is. Harmony is gpt-oss, where cleanup is `False`, so it is unaffected. Classic speculation is disabled by default per `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md`.

**Which catalog models have cleanup on** (checked via HF `tokenizer_config.json`): Llama-3.1-8B, Llama-3.2-3B, Llama-3.3-70B = `True`. gemma-4-26b-a4b = **absent, so on**. All Qwen, gpt-oss, GLM-4.5-Air and Nemotron = `False`.

**Offline repro** (`laneB/sim.py`: Python `tokenizers` 0.22.2 with the real `tokenizer.json`, applying swift-transformers' exact cleanup rules, and mimicking our prefix-diff emitter):
- gemma-4-26b-a4b, upstream's SwiftUI sample: the first non-prefix decode is at token 17, where the indent token `"    "` is followed by the `"."` token (`'…")\n    '` becomes `'…")\n   .'`). Our stream delivers **52 of 88 chars**. Any chained-method code (`.foregroundColor`, `.map`, builder chains) triggers it.
- Llama-3.2 tokenizer: code samples pass (its tokenizer merges `" ."`). The contrived English `"It 's fine ."` stalls at token 3 (4 of 42 chars). The Llama exposure is real but rarer.
- Caveat: the gemma result uses Python `tokenizers` decode plus the Swift cleanup rules, not a Swift run. Confirm with a Swift unit test before shipping.

**Action (NUGGET, P0 for gemma-4 streaming / P1 overall):**
- Target: `SerialStreamingTextEmitter.step`/`finish` plus `streamDelta` in `ModelRuntime.swift`, and `ByteLevelIncrementalTextDecoderBox.appendCleaned`.
- Preferred fix: for streamed rows, decode with cleanup disabled and use the same decode for the final text. Stream and final then agree, and the output is prefix-stable by construction. This is also what swift-transformers#391 moves toward for BPE.
- Minimum fix: never let a non-prefix decode stall the emitter permanently. Re-anchor on the longest common scalar prefix and continue. Because a streamed byte can't be retracted, emitted bytes will differ from the final non-stream text by the cleaned space, which is better than truncation.
- Test: add a Swift test with the real gemma-4 tokenizer and the #636 SwiftUI sample, asserting that concatenated stream == final content. Add the same for Llama-3.2 with `" 's"`.
- A second, latent issue in path 2: `byteLevelBytes` returns nil for SentencePiece pieces (`▁`), so a gemma row on that path would emit literal `▁`. This only matters if gemma ever becomes CB-eligible. The comment in the code scopes the path to Qwen and Llama 3.3.


---

## (b) #214 / #61 (Harmony) vs our HarmonyResponseParser + SPEC-018

**Upstream:** #61 says gpt-oss can't be used correctly through `generate()` without Harmony. #214 proposes a token-ID-level `ResponseFormatParser` with `feed(tokenId:)` + `finish()` and a channel/recipient event struct. DePasqualeOrg points to Open Responses (#260).

**What we have:** `phase3-binary/Sources/macprovider-cli/HarmonyResponseParser.swift` (1113 lines) is already the design #214 argues for:
- It works on token IDs (`channelTokenID 200_005`, `start 200_006`, `end 200_007`, `message 200_008`, `constrain 200_003`, `return 200_002`, `call 200_012`) and has an incremental `parse(newTokenIDs:)`.
- Status is `parsed/incomplete/malformed`, with a `Mode.complete(finishReason:)` that separates a length-truncated final from a malformed one. This is exactly the `finish()` motivation in #214.
- It enforces per-call and per-response byte caps (SPEC-018: 1 MiB per call, 2 MiB per response, depth 32).
- It counts `finalContentTokenCount` for visible-final accounting.
- Structural token-ID framing is honored only for the gpt-oss family (SPEC-018 §3.2 rationale: decoded marker-looking bytes are data), which answers #214's point 4 about string-level mis-triggering.

**Intersection with our SPEC-018 evidence:**
- #1682 "502" is not a parser bug. It is the SPEC-018 §3.10 fail-closed when the budget is spent in `analysis` and no terminated `final` frame exists. Measured on a Mac Studio with gpt-oss-20b MXFP4-Q8 at temp 0: simple prompt at 512 max tokens gives a valid final (370 completion tokens). A reasoning-heavy prompt at medium effort with 128 max tokens never reaches `final` and fails closed (source: memory note `gptoss-502-is-spec018-failclosed-not-bug`).
- Accounting: `usage.completion_tokens` counts visible-final tokens only. Total decode is exposed separately (`macprovider_generated_completion_tokens`, PR #877). This is the kind of hidden-vs-visible accounting split a `GenerationEvent` needs to carry.
- History: #743 was channel leakage to clients before the token-level parser. It is the same failure as #214's point 1.

**Impact on pin bump:** none directly, since upstream has not merged a Harmony parser. If upstream adds one to `generate()`, our matrix row "upstream parser adoption does not double-parse Macprovider's implementation" (`MLX_ENGINE_UPGRADE_MATRIX.md`) already guards it.


---

## (c) Do #633 or #450 explain our qwen3.5/3.8 CB parity FAIL? **No.**

Our failure (`docs/runbooks/cb-qwen-hybrid-parity-investigation.md`, Studio M3 Ultra 256GB, v1.8.201, `msb-throughput --engine scheduler --no-compile --scenario leftovers`, 48 greedy tokens): serial ≠ batched token SHA for qwen3.5-35b-a3b, qwen3.5-27b and qwen3.8-27b. The qwen3.6-35b-a3b and qwen3.6-27b pair is bit-exact.

**#633:** The pin's `Libraries/MLXLLM/Models/Qwen35.swift:266-272` computes `invScale² * rmsNorm(q, eps: 1e-6)` and `invScale * rmsNorm(k, eps: 1e-6)`, so the effective L2 epsilon is `headKDim × 1e-6`. That is a real deviation from the reference (the PR reports max per-row relative error 0.912 → 3e-7). It cannot explain serial≠batched, for three reasons:
1. The op is row-local and identical in both paths. Our CB code has no separate gated-delta implementation (no `gatedDelta`/`headKDim` in `phase3-binary/Sources/macprovider-cli`).
2. All five models share `linear_key_head_dim=128` and `rms_norm_eps=1e-6` (verified from HF `config.json`), so the bug is identical on passing and failing models.
3. It changes serial and batched outputs equally.

It remains a quality issue on every Qwen3.5+ hybrid we serve. The PR's own checks show large relative error only at small q/k magnitudes, and the impact on end-to-end generation is unmeasured.

**#450:** It is garbage from token 1 with per-layer mixed quant (OptiQ overrides on `linear_attn.in_proj_qkv`), fixed at upstream HEAD but not in 3.31.4. Our quantization layouts (HF `config.json`):
- Qwen3.5-35B-A3B, Qwen3.5-27B, Qwen3.8-27B (the failing models) are **uniform 4-bit/g64 with no overrides**.
- Qwen3.6-35B-A3B (passing) has **80 8-bit overrides** on `mlp.gate` and `shared_expert_gate`.

So mixed quant correlates with *passing*, and #450 is not the cause. The runbook's partial-rotary lead (`partial_rotary_factor 0.25` on 3.6 only) and a batched-path numerics lead remain the candidates.

**RISK from #633 (P1):** when it lands in a tag, every Qwen3.5/3.6/3.8 greedy token SHA we have recorded will change:
- the parity baselines in the runbook,
- SPEC-039 allowlist evidence,
- MSB throughput fixtures,
- any golden token tests.

The upgrade matrix already allows "a row explicitly documents an intended upstream correction". Pre-register #633 as an intended diff for the Qwen hybrid rows, and re-run CB parity for 3.6 on the new pin, because a bit-exact serial==batched result must be re-proven.

**RISK from #450 (P2):** at our pin, any future catalog candidate with per-layer overrides inside `linear_attn` (OptiQ, DWQ-style) can load cleanly and generate garbage. Catalog admission for such checkpoints should require a coherence check against Python mlx-lm at our pin.


---

## (d) #617 "Release soon?" + #221 "upstreaming from forks": what we can credibly offer

**State (#617):** the maintainer plans to cut an mlx-swift tag on about 28–29 Sep, then mlx-swift-lm, probably bumping the base mlx-swift. Upstream `main` `Package.swift` already has `swift-tools-version: 6.2` and `mlx-swift .upToNextMinor(from: "0.31.6")`.

**RISK for us (P1):**
- `MLX_ENGINE_UPGRADE_MATRIX.md` hard rule 4 keeps production on Xcode 16.4 / Swift 6.1 and notes that mlx-swift 0.31.5/0.31.6 require Swift 6.3. We resolve mlx-swift 0.31.4.
- The next tag therefore cannot be consumed without a separately reviewed toolchain migration.
- Several awaited items are blocked on that tag: #364 Gemma MoE, #453 typed cache, the #645 MTP work behind PR #1774, and #406 compile.
- Plan the Xcode/Swift 6.3 release-runner migration now, so it isn't discovered at tag time.
- Upstream main also adds an xgrammar C++ shim target (`Package.swift` ~L202). This is new build surface to check against our signing and packaging.

**Credible offer (CONTRIBUTE, P1): RC validation on real hardware using the matrix we already maintain:**
- **Hardware:** Mac Studio M3 Ultra 256GB (lab). M5 32GB is also available. Do not offer the canary Air (no contributor access).
- **Models:** Qwen3.6-35B-A3B / 27B, Qwen3.5-35B-A3B / 27B, Qwen3.8-27B, gpt-oss-20b / 120b, gemma-4-26b-a4b, Llama-3.x, Nemotron-3-Nano-30B-A3B, GLM-4.5-Air (all 4-bit mlx-community).
- **Per model:** load success, temp-0 token-exact diff vs 3.31.4 (with #633 pre-declared as an expected diff on Qwen hybrids), EOS/stop behavior, decode tok/s and prefill tok/s, plus serial-vs-batched parity where we have it.

**#221:** the maintainer wants small PRs. Honest upstreamable items from us:
1. #636 evidence and a fix for a prefix-stable streaming detokenizer (above).
2. Harmony token-level parser semantics and test vectors for #214.
3. Serial-vs-batched greedy parity data for Qwen hybrids (a runbook table of 5 models × parity).
4. The #406 compile-offset finding we already track.

Our paged-KV/CB engine lives in our CLI and is not a small PR. Don't offer it as such.


---

## (e) #154 Qwen3 enable_thinking: how we handle it (plus a nugget)

**How we handle it:**
- `ModelRuntime.chatTemplateSupportsThinkingToggle` (~L6896) byte-scans `chat_template.jinja|json|txt` and `tokenizer_config.json` for `enable_thinking`.
- `templateAdditionalContext` (L7478) then always passes `["enable_thinking": false]`.
- This landed in #1700 (d0aa3556c). Per `docs/releases/cli-release-train.md` it passed exact-answer and no-thinking checks across 11 cached catalog artifacts (Qwen2.5/3/3.5/3.6/3.8, GLM-4.5-Air, Nemotron).
- Buyers cannot enable thinking, and there is no `reasoning_content` surface. That covers #154's concern of a template missing the toggle: no marker means no context is passed.

**NUGGET (P1): multi-turn KV prefix break.** This is the QwenLM#1826 issue that #154 cites, verified on our catalog template. I rendered `mlx-community/Qwen3.6-27B-4bit` `chat_template.jinja` with jinja2 and `enable_thinking=false`:
- Turn-1 ledger: `…<|im_start|>assistant\n<think>\n\n</think>\n\nHello there.<|im_end|>`
- Turn-2 prompt renders the prior assistant as `<|im_start|>assistant\nHello there.` because the empty think block is dropped for turns before the last user query.
- The common prefix is 52 of 93 chars, so the prior answer must be re-prefilled every turn. For hybrid (gated-delta) caches, which can only rewind to checkpoints, the loss can be larger.
- With `preserve_thinking=true`, the turn-1 ledger **is** a prefix of the turn-2 prompt (verified).
- `preserve_thinking` is present in the Qwen3.6-35B-A3B, Qwen3.6-27B and Qwen3.8-27B templates, and absent in Qwen3.5-35B-A3B.

Action:
- In `templateAdditionalContext`, also pass `"preserve_thinking": true` when the template bytes contain `preserve_thinking`, using the same byte-scan pattern.
- Validate with `kv_cache` telemetry (cached prompt tokens on turn 2 of a Qwen3.6 chat) and the existing no-thinking answer checks.
- I did not verify how our conversation cache currently matches against the ledger. Measure before claiming the gain. This applies to our top-demand Qwen3.6 rows.


---

## Other NUGGET / RISK details

### #624 / #625 quadratic tool-call scanning: NUGGET P2
- Upstream measured a 40k-char call streamed character by character at 13.7 s on M3 Max. The fix scans only the appended chunk plus the tag overlap.
- Ours: the serial streaming path does a **full re-decode of all generated tokens per step** (`ModelRuntime.swift` ~L6197), and `NativeToolCallStreamEmitter.observe` (L8009, `range(of: startDelimiter/endDelimiter)` over the whole text) rescans the full text each step. Both are O(n²) per request.
- The CB path already avoids the re-decode (the `ByteLevelIncrementalTextDecoderBox` comment says so).
- Action: reuse the incremental decoder on the serial path (after fixing (a)), and keep a scan cursor in `NativeToolCallStreamEmitter` using #625's window rule.
- We have no measured cost on our side. Benchmark a long `write`-style tool call before prioritizing.

### #412 suppress_tokens / multimodal placeholder masking: NUGGET P2
- gemma-4-26b-a4b `config.json` declares `image_token_id 258880`, `audio 258881`, `eoi 258882`, `eoa 258883`, `video 258884`, `boi 255999`, `boa 256000`. Its `generation_config.json` has no `suppress_tokens`.
- We have no logit masking for these, and upstream saw `<audio|>` leak on the gemma-4-12B unified checkpoint.
- Unverified whether 26B-A4B leaks. Cheap fix: add a sampler mask for these ids on gemma4 text serving.

### #626 / #628 Gemma tool args, and GLM: gap note, P2
- SPEC-018 §3.1 covers Qwen, Llama-3.3, Nemotron and Harmony only. `ToolCallParser.swift` `ToolCallFormat.detect` matches only qwen2.5/qwen3/llama-3.3.
- gemma-4-26b-a4b and GLM-4.5-Air are recommendable catalog rows, but tool requests on them never yield `tool_calls[]`.
- If we add a Gemma-4 row, #628's grammar (marker-quoted strings `<|"|>`, bare keys, depth cap 32) plus #626's tests are the reference.
- SPEC-018 §3 requires a SPEC bump first.

### #563 Gemma 4 channels + `Generation.reasoning`: RISK P2 / watch
- On pin bump, `StandardTokenStreamDecoder` would split `<think>`/channels out of `.chunk`. Our serve paths decode tokens themselves, so impact is low.
- Relevant: the gemma-4 template with thinking off primes `<|channel>thought\n<channel|>` in the prompt. If the model emits channel tokens anyway, check whether our decode leaks `<|channel>`/`<channel|>` to clients. This is unverified, and gemma was not in the #1700 no-thinking 11-artifact check.

## Hygiene notes
- `gh issue view --comments` printed only comments (and returned empty for some items). All items were re-fetched via `--json … --jq` for full bodies.
- No GitHub posts were made. The repo was not modified. Scratch files stayed in local session scratch.
