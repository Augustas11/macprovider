# P0-04 — Gemma-4 chat template / OpenAI API compatibility

**Task:** P0-04 (Model Catalog Expansion Runbook)  
**Date:** 2026-07-07  
**Executor:** runtime probe only (no catalog/code changes)  
**MLX pin:** `mlx-swift-lm` 3.31.4, rev `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` (`phase3-binary/Package.resolved`)

---

## Hardware & binary

| Field | Value |
|-------|-------|
| **Machine** | MacBook Air (Mac17,3) |
| **Chip** | Apple M5 |
| **Unified RAM** | 32 GB |
| **OS** | macOS 26.5 (25F71) |
| **macprovider-cli** | **1.8.16** (release build: `phase3-binary/.build/release/macprovider-cli`) |
| **Model cache** | `~/Library/Caches/models/mlx-community/gemma-4-26b-a4b-it-4bit` (~15 GB on disk) |
| **Load path** | `serve --no-join` → `LLMModelFactory.shared.loadContainer` + `#huggingFaceTokenizerLoader()` (`ModelRuntime.swift:1887–1890`) |

### Serve command

Port **8080** was occupied by a local `node` process; probe used **18080**.

```bash
cd phase3-binary
./.build/release/macprovider-cli serve \
  --no-join \
  --model mlx-community/gemma-4-26b-a4b-it-4bit \
  --port 18080 \
  --log-level info
```

**Ready signal:** `GET http://127.0.0.1:18080/v1/models` returned the model list after ~2 min load + idle prewarm.

**Serve log:** `/tmp/p0-04-gemma4-serve.log`

---

## Probe results

### Probe A — single-turn arithmetic

| Check | Result |
|-------|--------|
| **HTTP status** | **200** |
| **Request (truncated)** | `{"role":"user","content":"What is 17 + 25? Reply with just the number."}` |
| **Response content** | `42\n` |
| **finish_reason** | `stop` |
| **Template leakage** | **N** |
| **Arithmetic** | **PASS** (42) |
| **Stop behavior** | Natural stop at 3 completion tokens |

Raw: `/tmp/p0-04-probe-a.json`

---

### Probe B — multi-turn system + user + assistant

| Check | Result |
|-------|--------|
| **HTTP status** | **200** |
| **Request (truncated)** | system → user (France capital) → assistant (Paris) → user ("And Germany?") |
| **Response content** | `Berlin is the capital of Germany.` |
| **finish_reason** | `stop` |
| **Template leakage** | **N** |
| **Multi-turn** | **PASS** (Berlin) |
| **Stop behavior** | Natural stop at 7 completion tokens |

Raw: `/tmp/p0-04-probe-b.json`

---

### Probe C — JSON-style smoke (no tools)

| Check | Result |
|-------|--------|
| **HTTP status** | **200** |
| **Request (truncated)** | `{"role":"user","content":"Return a JSON object with keys \"color\" and \"count\" for: three red apples."}` |
| **Response content** | ` ```json\n{\n  "color": "red",\n  "count": 3\n}\n``` ` |
| **finish_reason** | `stop` |
| **Template leakage** | **N** |
| **JSON shape** | Correct keys/values; wrapped in markdown fences (cosmetic only) |
| **Stop behavior** | Natural stop at 20 completion tokens |

Raw: `/tmp/p0-04-probe-c.json`

---

### Streaming — Probe A repeat

| Check | Result |
|-------|--------|
| **HTTP status** | **200** (SSE) |
| **SSE parse** | Valid `data:` chunks + `[DONE]` |
| **Reassembled delta** | `42\n` (chunks: `4`, `2`, `\n`) |
| **finish_reason** | `stop` on final chunk |
| **Template leakage** | **N** |

Raw: `/tmp/p0-04-probe-a-stream.txt`

Provider log:

```json
{"event":"kv_cache_request_completed","model_id":"mlx-community/gemma-4-26b-a4b-it-4bit","prompt_tokens":24,"completion_tokens":3,"finish_reason":"stop","stream":true}
```

---

## Evaluation checklist (rollup)

| Check | A | B | C | Stream A |
|-------|---|---|---|----------|
| HTTP 200 | ✓ | ✓ | ✓ | ✓ |
| Non-empty `choices[0].message.content` | ✓ | ✓ | ✓ | ✓ (deltas) |
| No template leakage | ✓ | ✓ | ✓ | ✓ |
| Natural stop / no repetition | ✓ | ✓ | ✓ | ✓ |
| Task-specific correctness | 42 ✓ | Berlin ✓ | JSON ✓ | 42 ✓ |
| Crash / OOM | None | None | None | None |

**Leakage patterns checked:** `<start_of_turn>`, `<end_of_turn>`, `<bos>`, `<eos>`, `user\n`, `model\n`, `<|turn>`, `<turn|>`, tool-call tokens — **none present in any assistant output**.

---

## Tokenizer / stop-token findings

### Local snapshot (`tokenizer_config.json`)

| Token key | Value | Notes |
|-----------|-------|-------|
| `bos_token` | `<bos>` | Picked up by `StopTokenConfigExtractor` |
| `eos_token` | `<eos>` | Picked up by `StopTokenConfigExtractor` |
| `sot_token` | `<\|turn>` | Gemma-4 turn start (legacy Gemma used `<start_of_turn>`) |
| `eot_token` | `<turn\|>` | Gemma-4 turn end (legacy Gemma used `<end_of_turn>`) |
| `chat_template` | **absent** | Chat formatting delegated to mlx-swift-lm `Gemma4Processor` / factory |
| `processor_class` | `Gemma4Processor` | Multimodal-capable processor schema present |

### `config.json` EOS IDs

```json
"eos_token_id": [1, 106, 50]
```

Multiple EOS IDs (includes turn-end semantics). Generation stopped cleanly on all probes with `finish_reason: stop` — mlx-swift-lm handles stop IDs at decode time; MacProvider output filter (`StopTokenFilter` via `StopTokenConfigExtractor`, `ModelRuntime.swift:416–421`) strips `<bos>`/`<eos>` only and did not need `<turn|>` stripping in observed outputs.

### `extraEOSTokens` in ModelConfiguration

Not required for this probe. No garbled or runaway generations observed; no evidence that MacProvider must add Gemma-4-specific `extraEOSTokens` before P1.

### Darkbloom behavioral compare

**Not run** — no reachable reference API configured in this session.

---

## Verdict: **GREEN**

| Criterion | Result |
|-----------|--------|
| Clean assistant text on 3 prompt shapes | **PASS** |
| Stable stops (`finish_reason: stop`) | **PASS** |
| No template / special-token leakage | **PASS** |
| No crash on 32 GB M5 | **PASS** |
| Streaming SSE path | **PASS** |

**Minor note (non-blocking):** Probe C wraps JSON in markdown code fences — common model formatting, not a template bug. No workaround required for P1.

---

## Recommended fix (if YELLOW/RED)

N/A — probe GREEN. No code changes indicated.

---

## One-line impact on P1

- **P1-01 (Gemma bench matrix):** **Unblocked** — chat completions path validated; can proceed alongside catalog work.
- **P1-03 (catalog rollout):** **Unblocked** — OpenAI-compatible `/v1/chat/completions` produces usable assistant text for Gemma-4 on pinned mlx-swift-lm 3.31.4.

---

## P0 rollup / G0

With P0-04 **GREEN**, all six P0 tasks (P0-01, P0-02, P0-03, P0-04, P0-05, P0-06) have GREEN artifacts. **G0 can close** pending pinned-session verification and `P0_SUMMARY.md` rollup.

---

## Raw artifacts (local)

| Artifact | Path |
|----------|------|
| Serve log | `/tmp/p0-04-gemma4-serve.log` |
| Probe A | `/tmp/p0-04-probe-a.json` |
| Probe B | `/tmp/p0-04-probe-b.json` |
| Probe C | `/tmp/p0-04-probe-c.json` |
| Stream A | `/tmp/p0-04-probe-a-stream.txt` |
