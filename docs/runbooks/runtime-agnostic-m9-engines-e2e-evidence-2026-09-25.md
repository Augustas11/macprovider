# #1690 M9 lab e2e: LM Studio, oMLX, and disconnect billing on every external engine (2026-09-25)

**Issue:** #1690 M9, epic branch `feat/1690-m1-catalog-gguf` (PR #1754).
**Code under test:** `1e1279f4` (slices 1-5) for runs R1 and R2, and
`598ae3e6` (plus the LM Studio tools fix) for the post-fix runs F1 and F2.
Every lab binary (coordinator, coordinator-cli, gateway, labtool, lab CLI,
lab native CLI) was built on the Mac Studio from one export of that HEAD
(`scripts/lab/1690-m6/rig.sh build`).
**Host:** Mac Studio (M3 Ultra, 256 GB), isolated 127.0.0.1:191xx, lab dir
`/Users/a1/lab-1690-m6/m9`. The live provider on :8080 was never addressed;
the lab signals only processes pidguard recorded, and LM Studio only through
its own `lms` CLI with `HOME` set to the lab install.
**Model:** Qwen2.5-0.5B-Instruct: MLX 4-bit for native, `mlx_lm.server` and
oMLX; Q4_K_M GGUF (sha256 `74a4da8c…a7d9db`) for llama.cpp and LM Studio;
Ollama `qwen2.5:0.5b`.

## Engines

| Engine | Version | Installed as | Pool |
|---|---|---|---|
| native (`mlx_cache`) | branch CLI | lab native CLI | A (and global) |
| llama.cpp | `llama-server` b11149 | release build | A |
| `mlx_lm.server` | mlx-lm 0.31.3 | lab venv | M |
| Ollama | 0.34.4 | release binary, lab `OLLAMA_MODELS` | O |
| LM Studio | headless `llmster` 0.0.25-1, engine `llama.cpp-mac-arm64-apple-metal-advsimd@2.45.0` | `lmstudio.ai/install.sh` with `HOME=/Users/a1/lab-1690-m9/lmshome` (no launchd item, no PATH change) | L |
| oMLX | 0.7.0rc1 (`jundot/omlx@3f2d07e`, mlx 0.32.2) | `pip install -e` from source into a lab venv; `setproctitle` removed so pidguard can verify the process | X |

Both new engines installed and served on the Studio, so both have lab
evidence; neither is covered by unit tests alone.

## Result

- **All six engines** served their Trusted Pool: the member joined with the
  expected class and identity (`lmstudio_loopback` / `macprovider.gguf-file.v1`,
  `omlx_loopback` / `macprovider.snapshot-manifest.v1`, both `hash_verified`,
  `ready`), disclosed `X-MacProvider-Engine`, and settled
  `pool_operator_attested` with a verified receipt.
- **E2E-F3 is closed for every external engine.** A buyer that disconnects
  after 4 content events is debited the delivered prefix, and the provider
  credit is bound by a verified `buyer_cancel` receipt: 26 of 26 external-engine
  disconnects across R1, R2, F1 and F2 passed `disconnect_prefix_billed`
  (table below). Before M9 slice 1, Ollama and `mlx_lm.server` disconnects
  were free (`missing_receipt_deadline_elapsed`, quarantined, refunded).
- **Engine selection:** 1870 selection checks (every selector on the global
  route and on every pool that existed, per engine and pin), 0 failures.
  Non-native selections on a global route, classes outside a pool's
  allowlist, unknown or conflicting values, and `native` on an
  external-only pool all failed closed with the documented codes.
- **One new finding, fixed:** M9-E1 below (LM Studio tool calls).
- Remaining failures are pre-existing and carried: E2E-F1 (the coordinator's
  prompt bound charges fewer prompt tokens than the engine reported), and on
  native only E2E-F3 (native disconnect receipt-less), E2E-F5-fixed
  (zero_settled refund, by design) and E2E-F6. `summarize.py` classified every
  failure; 0 unclassified in every run.

## Matrix

Harness: `scripts/lab/1690-e2e/` (`full_run.sh`, `run_matrix.sh`, `matrix.py`,
`summarize.py`) over `scripts/lab/1690-m6/rig.sh`, extended in M9 for
LM Studio (pool L) and oMLX (pool X). Per engine and gateway pin (0 = off,
1 = `require_settlement_trailers`): the shape x behaviour matrix on the
engine's pool route (`plain`, `tool`, `long`, `cap`, each streamed and not;
`disconnect`, `slow`, `early_close`, `abort`), the global route (external
engines must refuse), and the selection matrix. Invariants per request are
listed in `matrix.py`; M9 adds `disconnect_prefix_billed`. Evidence per
request is in `LAB/e2e/results/<label>.json`, tables in
`LAB/e2e/summary-{R1,R2,F1,F2}.md`.

### R1 and R2 (`1e1279f4`), engine runs, pins 0 and 1

| Engine (pool) | R1 pin0 | R1 pin1 | R2 pin0 | R2 pin1 | Failed checks by finding (every run) |
|---|---|---|---|---|---|
| native (A + global) | 218/240 | 220/234 | 218/240 | 219/234 | E2E-F1, E2E-F3 (native), E2E-F5-fixed, E2E-F6 |
| llama.cpp (A) | 141/149 | 141/149 | 141/149 | 141/149 | E2E-F1 only |
| `mlx_lm.server` (M) | 137/141 | 139/145 | 137/141 | 137/141 | E2E-F1 only |
| Ollama (O) | 141/149 | 141/149 | 141/149 | 141/149 | E2E-F1 only |
| LM Studio (L) | 133/139 | 133/139 | 133/139 | 133/139 | E2E-F1, M9-E1 (2 tool requests per run) |
| oMLX (X) | 139/145 | 138/143 | 138/143 | 138/143 | E2E-F1 only |

Selection labels (`-sel`, 44-66 requests each): only E2E-F1 failures, and
every selection expectation passed.

### F1 and F2 (`598ae3e6`, after the M9-E1 fix)

| Engine (pool) | F1 pin0 | F1 pin1 | F2 pin0 | F2 pin1 | Failed checks by finding |
|---|---|---|---|---|---|
| LM Studio (L) | 141/149 | 141/149 | 141/149 | 141/149 | E2E-F1 only; tool calls 200, streamed and not |
| Ollama (O) | 141/149 | 141/149 | - | - | E2E-F1 only (regression check of the shared logprobs switch) |

### Disconnects on external engines

`disconnect`: streamed `long` (max_tokens 700), buyer closes after 4 content
events. Debit and verified prefix are `[prompt, completion]`; "received" is the
lab tokenizer's count of what the buyer got (text never stored).

| Run | Engine | Received tokens | Buyer debit | Verified prefix (receipt) | Terminal | Usage source | Provider credit |
|---|---|---|---|---|---|---|---|
| R1 pin0 / pin1 | llama.cpp | 4 / 4 | [61,4] / [60,4] | [61,4] / [60,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| R1 pin0 / pin1 | `mlx_lm.server` | 4 / 4 | [58,3] / [61,4] | [58,4] / [61,4] | buyer_cancel | pool_operator_attested | 30 / 31 |
| R1 pin0 / pin1 | Ollama | 4 / 4 | [60,4] / [60,4] | [60,4] / [60,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| R1 pin0 / pin1 | LM Studio | 4 / 4 | [61,4] / [60,4] | [61,4] / [60,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| R1 pin0 / pin1 | oMLX | 124 / 124 | [61,124] / [60,124] | [61,124] / [60,124] | buyer_cancel | pool_operator_attested | 139 / 139 |
| R2 pin0 / pin1 | llama.cpp | 4 / 4 | [57,4] / [60,4] | [57,4] / [60,4] | buyer_cancel | pool_operator_attested | 29 / 31 |
| R2 pin0 / pin1 | `mlx_lm.server` | 4 / 4 | [59,4] / [61,4] | [59,4] / [61,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| R2 pin0 / pin1 | Ollama | 4 / 4 | [61,4] / [58,4] | [61,4] / [58,4] | buyer_cancel | pool_operator_attested | 31 / 30 |
| R2 pin0 / pin1 | LM Studio | 4 / 4 | [61,4] / [61,4] | [61,4] / [61,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| R2 pin0 / pin1 | oMLX | 125 / 124 | [61,125] / [59,124] | [61,125] / [59,124] | buyer_cancel | pool_operator_attested | 140 / 139 |
| F1 pin0 / pin1 | LM Studio | 4 / 4 | [61,4] / [60,3] | [61,4] / [60,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| F1 pin0 / pin1 | Ollama | 4 / 4 | [60,4] / [59,4] | [60,4] / [59,4] | buyer_cancel | pool_operator_attested | 31 / 31 |
| F2 pin0 / pin1 | LM Studio | 4 / 4 | [61,4] / [61,4] | [61,4] / [61,4] | buyer_cancel | pool_operator_attested | 31 / 31 |

- The verified prefix equals the tokens the buyer received on every run: the
  per-chunk `logprobs` count (Ollama, LM Studio), the snapshot tokenizer
  recount (`mlx_lm.server`, oMLX), and llama-server's timings all agree with
  an independent tokenizer count of the delivered text.
- The prompt is the engine's own count, asked once after the cancel (a
  one-token, non-streamed completion of the same body); the usage tap shows
  it as a `max_tokens: 1` request. It falls in the same 57-61 range as the
  prompt tokens the engine reported for its normal `long` completions (the
  prompts differ only in a per-request id suffix).
- oMLX streams several tokens per chunk (4 events carried 124-125 tokens), so
  its prefix is larger; the count still covers exactly the delivered text.
- A debit one token below the verified prefix (R1 `mlx_lm.server` pin0, F1
  LM Studio pin1) is the SPEC-022 R-5.6 gateway-to-buyer bound (E2E-F4 fix):
  the buyer pays the smaller of the verified prefix and what the gateway
  wrote to it, the provider keeps the verified prefix. `matrix.py` counts it
  as `debit_eq_settled[buyer-delivered-bound]`.

## Review round: disconnect re-run D2 (`9e518db5`)

After the review fixes (the 1.25 s cancel budget, the pinned and
catalog-verified recount tokenizer, the binding re-check before the prompt
count), `scripts/lab/1690-e2e/disconnect_rerun.sh D2` re-ran only the
disconnect cases on the five external engines, gateway pin on, twice each:
`disconnect` (short prompt, idle engine) and `disconnect_busy` (a prompt of
about 2400 tokens, disconnected after 4 content events while three other
long-prompt streams kept the engine busy; its check
`disconnect_billed_or_free` accepts an exact bill or a fully free cancel and
nothing else). Result: 5 of 5 labels PASS, 280 of 280 checks, 20 of 20
disconnects billed exactly (none fell back to free), 0 held.

| Engine | `disconnect` debit / verified prefix | `disconnect_busy` debit / verified prefix | Busy received tokens |
|---|---|---|---|
| llama.cpp | [61,4]/[61,4], [59,4]/[59,4] | [2274,4]/[2709,4] x2 | 4, 4 |
| `mlx_lm.server` | [59,4]/[59,4] x2 | [2274,4]/[2708,4], [2274,3]/[2708,4] | 4, 4 |
| Ollama | [59,4]/[59,4], [61,4]/[61,4] | [2274,4]/[2709,4], [2274,4]/[2710,4] | 4, 4 |
| LM Studio | [60,4]/[60,4], [61,4]/[61,4] | [2274,4]/[2709,4], [2274,3]/[2709,4] | 4, 4 |
| oMLX | [60,125]/[60,125], [59,124]/[59,124] | [2274,25]/[2709,25] x2 | 25, 25 |

- Every busy cancel was answered inside the coordinator's 2 s wait: the
  prompt count on a busy engine returned within the 1.25 s budget, and the
  pinned tokenizer was loaded at serve start.
- The busy prompt debit (2274) is below the attested prompt (about 2709):
  that is the coordinator's independent prompt bound (E2E-F1, pre-existing),
  which only lowers the buyer debit. A completion debit one token below the
  prefix is the SPEC-022 R-5.6 gateway-to-buyer bound.
- The first attempt (D1) stopped at llama.cpp with 413
  `context_length_exceeded` (2048 tokens per slot); the rig now loads
  4096 per slot and the busy prompt is about 2400 tokens.
- The free branch (a prompt count or tokenizer that is late) is covered by
  unit tests; no engine was slow enough in the lab to take it.

## Upstream per-chunk usage, probed on the Studio

| Engine | Stream carries per chunk | Prompt tokens before the end | Used for a cancelled stream |
|---|---|---|---|
| llama.cpp | `timings` with `timings_per_token` | yes (`prompt_n + cache_n`) | timings |
| Ollama 0.34.4 | `choices[0].logprobs.content`, one entry per token, when `logprobs: true` | no | logprobs + prompt count call |
| LM Studio 0.0.25 | the same, when `logprobs: true`, except with `tools` (400 "logprobs is not supported with tools + stream") | no | logprobs + prompt count call; unattested with tools |
| `mlx_lm.server` 0.31.3 | nothing (one chunk per decoded segment, no token data) | no | snapshot tokenizer + prompt count call |
| oMLX 0.7.0rc1 | nothing (multi-token chunks, no logprobs) | no | snapshot tokenizer + prompt count call |

Every engine answered a non-streamed `max_tokens: 1` request with the full
`usage.prompt_tokens` (Ollama reports it in full even when cached).

## Serving-time bindings, probed

- **LM Studio:** REST reports no file path. `GET /api/v1/models` lists the
  key, `publisher`, `format`, exact `size_bytes` and `loaded_instances`
  (with `config.context_length`), which is the binding (SPEC-010-R007(i)). A
  chat request that names the key is served by a loaded instance of it
  (`model` in the response is the instance id). A custom `--identifier`
  replaces the key in `/api/v0/models`, so the lab loads under the key.
- **oMLX:** `GET /v1/models/status` lists each model's `id`, absolute
  `model_path`, `model_type`, `engine_type` and `distributed`; without an API
  key and on a loopback bind it needs no auth (SPEC-010-R009(f)). oMLX wrote
  nothing into the snapshot directory (`--no-cache`; settings and logs go to
  its `HOME`), so the CLI's per-request snapshot re-check held throughout.

## Findings

### M9-E1 (MEDIUM, code, new in M9 slice 2, FIXED `598ae3e6`): LM Studio tool calls failed

- **Repro:** LM Studio, pool L, `tool` shape (tools + `get_weather`), R1 and
  R2, both pins.
- **Effect:** non-streamed 502 `upstream_provider_error` (three attempts),
  streamed `stream_malformed`. Nothing was billed: the attempts had no
  receipt and were quarantined.
- **Root cause:** slice 2 asked LM Studio for per-chunk `logprobs` on every
  request, and LM Studio's llama.cpp engine rejects `logprobs` with `tools` on
  a stream (`event: error`, 400).
- **Fix:** a request with tools asks LM Studio for no logprobs
  (`streamsPerTokenLogprobs(_:hasTools:)`); a disconnect during such a
  request stays unattested and free. Regression test
  `LMStudioLoopbackTests.testToolRequestsAskLMStudioForNoLogprobs`. F1 and F2
  show LM Studio tool calls at 200, streamed and not.

### Carried, pre-existing

E2E-F1 (prompt bound), native E2E-F3/F5/F6, as in
`runtime-agnostic-e2e-evidence-2026-09-25.md`. LM Studio also rejects
`response_format: {"type": "json_object"}` (it accepts only `json_schema` or
`text`); that request maps to 400 `invalid_request`, which is LM Studio's own
limit, not a MacProvider change.

## Live provider

The live provider on :8080 was restarted twice during the session, at
14:46:04Z (R1, LM Studio phase) and 15:33:29Z (F1, Ollama phase), each after
about 48 minutes of uptime. The unified log shows both as `launchctl
kickstart` of `gui/501/live.malibu.provider` from a shell outside the lab
(a periodic job; the provider watchdog records no restart). No lab script
calls `launchctl`, and the lab signals only pidguard-verified lab processes.
After every run no lab process and no 191xx listener remained.

## Reproduce

```bash
WT=/Users/a1/macprovider-m1-catalog
LAB=/Users/a1/lab-1690-m6/m9 $WT/scripts/lab/1690-e2e/setup.sh    # links the lab llmster home and oMLX venv
( export LAB=/Users/a1/lab-1690-m6/m9; . $WT/scripts/lab/1690-e2e/env.sh
  $WT/scripts/lab/1690-m6/rig.sh model && $WT/scripts/lab/1690-m6/rig.sh build && $WT/scripts/lab/1690-m6/rig.sh build-native )
LAB=/Users/a1/lab-1690-m6/m9 E2E_STEPS=engines $WT/scripts/lab/1690-e2e/full_run.sh R1
LAB=/Users/a1/lab-1690-m6/m9 E2E_STEPS=engines $WT/scripts/lab/1690-e2e/full_run.sh R2
python3 $WT/scripts/lab/1690-e2e/summarize.py --prefix R1 --lab /Users/a1/lab-1690-m6/m9
```

LM Studio install (once): `HOME=<lab>/lmshome LMS_NO_MODIFY_PATH=1 sh install.sh`
(from `https://lmstudio.ai/install.sh`), then `HOME=<lab>/lmshome lms runtime
get llama.cpp -y`, and the pinned GGUF under
`<lab>/lmshome/.lmstudio/models/lmstudio-community/Qwen2.5-0.5B-Instruct-GGUF/`.
oMLX (once): `git clone https://github.com/jundot/omlx`, `python3.12 -m venv
<venv> && <venv>/bin/pip install -e ./omlx && <venv>/bin/pip uninstall -y
setproctitle`.
