# Studio lab e2e: fix/provider-stream-cache-thinking (2026-09-28)

Hardware: Mac Studio M3 Ultra 256GB. Live provider (port 8080) left untouched throughout (still listening, same PID after the run).

## Binaries

| Label | Source | Commit | macprovider-cli sha256 |
|---|---|---|---|
| fix | branch worktree (rsync, no .git) | `d5febeb97` (on `01ac80d01`, on `5f8278762`) | `0d3ce5d45a7b86a6878008135b90ed74cd827a810605285856b0b8e4cf65238c` |
| base | `git archive 5f8278762` (merge base = origin/main) | `5f8278762` | `b251b0ae8c0230e0c47d06977478dae9a35df7cf0a5801ddc98d89b15b806738` |

Build (both): `cd phase3-binary && swift build -c release --product macprovider-cli` (rc=0).
Staged next to each binary: `mlx.metallib` (sha256 `84e48718…fbaf`, same as the live install and prior lab rigs), `mlx-swift_Cmlx.bundle`, and the SwiftPM resource bundles from `.build/release`.

## Serve

```
cd <lab>/<fix|base> && ./macprovider-cli serve --config <lab>/<fix|base>/config-<llama|qwen>.yaml --no-join
```
Config (Llama; Qwen identical apart from the model rows):
```yaml
model: meta-llama/llama-3.2-3b-instruct         # qwen: qwen/qwen3.6-35b-a3b
model_artifact_path: <macprovider models>/mlx-community--Llama-3.2-3B-Instruct-4bit/7f0dc925…/e7e5bff4…
model_artifact_sha256: e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90  # qwen: 3fed776d…76ff1
model_catalog_model_id: mlx-community/Llama-3.2-3B-Instruct-4bit                          # qwen: mlx-community/Qwen3.6-35B-A3B-4bit
model_catalog_revision: 7f0dc925e0d0afb0322d96f9255cfddf2ba5636e                          # qwen: 38740b847e4cb78f352aba30aa41c76e08e6eb46
model_catalog_sha256: <same as artifact sha>
port: 18181 (fix) | 18182 (base)
max_concurrency_override: 1
max_context_override: 32768
enable_receipts: true
credential_store: protected_file
continuous_batching: "off"
```
Loopback 127.0.0.1 only, no coordinator. `mlx_cache_limit_mb` left unset (MLX default). One test serve at a time, run sequentially fix then base; each killed by its own PID after its run.
Conversation reuse is keyed by request header `X-MacProvider-Provider-Conversation: conv:<uuid>` (HTTPServer `withConversationKey`); cached tokens reported as `usage.cached_prompt_tokens` plus the serve log line `event=conv_cache action=hit … lcp=… recurrent_checkpoint=…`.
All requests temperature 0. Harness: `e2e.py` (stream with `stream_options.include_usage`, non-stream, `footprint -p PID` + `ps -o rss`).

## A. Streaming integrity (fix 1)

Llama-3.2-3B-Instruct-4bit (`clean_up_tokenization_spaces: true`), 20 prompts, max_tokens 200, each sent non-stream and stream.

| # | Prompt (short) | base stream vs non-stream | fix stream vs non-stream |
|---|---|---|---|
| 1 | Repeat: `It 's fine . Don 't stop , ok ? Yes !` | identical | identical |
| 2 | Repeat: `I 'm here , you 're there …` | identical | identical |
| 3 | Repeat: `Hello , world ! How are you ? I 'm fine .` | **TRUNCATED**: stream 30 chars `…How are you? I '` vs 36; finish=stop, completion_tokens 13 both | stream 37 chars `…I 'm fine.` vs non-stream `…I'm fine.` (one cleaned space kept), no truncation |
| 4 | SwiftUI `.padding()` / `.foregroundColor(.red)` / `.font(.title)` | identical | identical |
| 5 | SwiftUI VStack chained `.bold() .italic() .padding()` | identical (length) | identical (length) |
| 6 | Swift `.map .filter .sorted` chain | identical | identical |
| 7 | JS `.then().then().catch().finally()` | identical (length) | identical (length) |
| 8 | contractions paragraph | identical | identical |
| 9 | five questions | identical | identical |
| 10 | three exclamations | identical | identical |
| 11 | comma list `apples , pears …` | identical | identical |
| 12 | why sky is blue | identical | identical |
| 13 | Python `' '.join()` / `.split()` | identical | identical |
| 14 | haiku, `It's autumn, isn't it?` | identical | identical |
| 15 | Repeat: `She said , ' hello ' .` | identical | identical |
| 16 | Kotlin `Modifier.padding(8.dp) .fillMaxWidth()…` | identical (length) | identical (length) |
| 17 | dialogue with contractions | identical | identical |
| 18 | count one to ten | identical | identical |
| 19 | Repeat: `Wait . . . what ? No ! Yes , it 's true .` | **TRUNCATED**: stream 152 chars ending `…Yes, it '` vs 158 | stream 159 chars ending `…Yes, it 's true.` vs non-stream `…it's true.`, no truncation |
| 20 | jQuery `.addClass() .removeClass() .fadeIn()` | identical | identical |

Summary: base truncated 2/20 streams (the stream stops emitting at the cleanup rewrite; finish_reason still `stop`, usage unchanged, so the loss is silent). Fix truncated 0/20; 18/20 byte-identical, 2/20 differ from non-stream only by one uncleaned space (`I 'm`, `it 's`). No duplication on either binary. finish_reason and completion_tokens match stream/non-stream on every prompt on both binaries.

Qwen3.6-35B-A3B-4bit (cleanup off), 5 prompts, max_tokens 160: stream == non-stream byte-identical 5/5 on base and 5/5 on fix; the fix and base outputs are identical to each other.

Receipt binding (d5febeb97): not observable in this lab. `--no-join` serve has no receipt keypair (`receipt_omitted reason=no_keypair` on every request), so no receipt/output hash is emitted to compare against the concatenated deltas.

## B. preserve_thinking (fix 3)

Qwen3.6-35B-A3B-4bit, ~1.7k-token system prompt, 3 turns on one conversation key, each turn streams (max_tokens 96) and the next turn includes the previous assistant reply exactly as streamed. Plus a turn-3 control on a fresh key (miss).

| Turn | base prompt tok | base cached | base LCP | base TTFT s | fix prompt tok | fix cached | fix LCP | fix TTFT s |
|---|---|---|---|---|---|---|---|---|
| 1 | 1729 | 0 | - | 1.140 | 1729 | 0 | - | 1.387 |
| 2 | 1815 | 1722 | 1725 | 0.190 | 1819 | 1722 | **1794** | 0.195 |
| 3 | 1899 | 1808 | 1811 | 0.150 | 1894 | 1812 | **1871** | 0.146 |
| 3 miss (fresh key) | 1899 | 0 | - | 1.157 | 1894 | 0 | - | 1.156 |

(LCP from the serve log `event=conv_cache action=hit … lcp=…`; `cached` is `usage.cached_prompt_tokens` = the recurrent checkpoint used.)

- Fix renders history assistant turns with the empty `<think>\n\n</think>\n\n` prefix (+4 tokens per turn), so the prompt is now append-only through the whole previous reply: LCP 1794 / 1871 vs base 1725 / 1811 (base diverges right after the previous assistant header).
- Cached tokens and TTFT barely move (turn 2: 1722 both; turn 3: 1812 vs 1808, 82 vs 91 tokens re-prefilled). On this hybrid model, serial-path reuse is bounded by the recurrent checkpoint at the start of the last turn (`trim_by` 59-72). The longer LCP only pays off once a checkpoint is saved at the end of the generated reply.
- No visible thinking text in any turn on either binary (`<think>` / `</think>` absent from all content). Answers are coherent on both. Turn 1 is identical across binaries; turns 2-3 are worded differently because the prompts differ.

## C. MLX buffer cache (fix 2)

Llama-3.2-3B-Instruct-4bit, 1 warmup request, then 40 sequential non-stream requests (max_tokens 32/48/64 rotating, varied prompts), `footprint -p PID` every 5 requests.

| After N requests | base phys_footprint MB | fix phys_footprint MB | base RSS MB | fix RSS MB |
|---|---|---|---|---|
| 0 | 4136 | 4004 | 3691 | 3688 |
| 5 | 4295 | 4034 | 3692 | 3688 |
| 10 | 4295 | 4026 | 3692 | 3689 |
| 15 | 4295 | 4027 | 3692 | 3689 |
| 20 | 4295 | 4028 | 3693 | 3689 |
| 25 | 4296 | 4035 | 3693 | 3689 |
| 30 | 4296 | 4028 | 3693 | 3689 |
| 35 | 4296 | 4027 | 3693 | 3689 |
| 40 | 4296 | 4027 | 3693 | 3689 |
| peak | 4296 | 4130 | | |

Base settles at ~4296 MB. Fix stays at ~4027 MB, which is about 270 MB (6%) lower, and its peak is 166 MB lower. Neither binary grows after the first 5 requests, and RSS is the same on both. The gain is in the retained MLX buffer cache after prefill, not the model weights.

## Verdicts

- Fix 1 (streaming cleanup rewrite): **PASS**. Base truncated 2 of 20 Llama streams. Fix truncated 0 of 20 and never duplicated. It differs from non-stream only by one uncleaned space (2 prompts). Qwen stream == non-stream on 5 of 5 on both binaries. The receipt-binding sub-item was not observable because the no-join serve has no receipt keypair.
- Fix 2 (MLX cache clear after prefill): **PASS**. Steady footprint is 4027 MB vs 4296 MB and peak is 4130 MB vs 4296 MB. Neither binary grows over 40 requests.
- Fix 3 (preserve_thinking): **PASS** on correctness. The prompt is now append-only (LCP +69 tokens on turn 2, +60 on turn 3) and no thinking text shows. The measured cached-token and TTFT gain on Qwen3.6-35B-A3B is about 0 (1722 = 1722; 1812 vs 1808). Hybrid serial reuse is capped at the last-turn-start recurrent checkpoint.

## Cleanup

Both test serves were stopped by PID, and no lab process remains. Build dirs `/Users/a1/macprovider-stream-{fix,base}` and lab dir `/Users/a1/lab-stream-fix` (binaries, configs, `out/`) are kept.
