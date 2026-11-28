# Model family performance intake

Related: #2322

## Purpose

One measurement procedure for every model family, so numbers from different campaigns can be compared. Run it when:

- a new model family or engine port is added;
- a decode-path line that a served family executes changes: decode code, a kernel route or a fork pin. A pin move that only adds another model's files does not count. Run only the cells that line can affect.

It replaces no gate (see [Existing gates](#existing-gates)). It fixes the cells, the tools and the reference that sit in front of those gates. Until now each family chose its own prompt lengths, repetitions, statistic and reference (#2322).

## Before running a cell

AGENTS.md hard rule 2 applies. List the existing evidence for the family (the [coverage table](#coverage) is the index) and name the decode-path line that changed since it was produced. No named line, no new run.

Record with every cell:

- the build commit;
- the fork pins: `mlxSwiftLMPin` in the `decode-bench` and `msb-throughput` reports, `mlxSwiftLMRevision` and `mlxSwiftRevision` in the `glm-parity` report;
- the decode-path digest: `python3 scripts/decode_path_digest.py` prints the tree's digest, and `--binary PATH` prints the one embedded in a built CLI.

## Metrics

| Metric | Tool | Output field | Definition |
|---|---|---|---|
| Single-row decode tok/s | `decode-bench` | `samples[].decodeTPS` | `(decodeTokensActual - 1) / decodeSeconds`. The clock starts at the first generated token. Greedy. Runs the `generate()` path on serve's model load path. |
| Prefill tok/s | `decode-bench` | `samples[].prefillTPS` | `promptTokensActual / prefillSeconds`. |
| TTFT | `decode-bench` | `samples[].ttftSeconds` | Equal to `prefillSeconds`: wall time from the start of the run to the first generated token, in process. It includes chat-template rendering and tokenization. It includes no HTTP. |
| Serial baseline inside the batch tool | `msb-throughput` | `productionSerialTPSp50`, `productionSerialTTFTSecondsRuns` | The same `(n - 1) / time after first token` formula on `generate()`, from the exact token ids of one batched row. |
| Multi-row aggregate, equal lengths | `msb-throughput` (default `--scenario throughput`) | `aggregateTPSp50`, `aggregateVsProductionSerial`, `perRowTPSp50` | Total decoded tokens after each row's first, over one common window. With `--engine scheduler` the window runs from the earliest delivered first token to the latest completed request, so it includes scheduler work and any later row's overlapping prefill. With the `contiguous` and `paged` engines one untimed step produces each row's first token and the window spans exactly `--decode-tokens` batched steps, with prefill outside it. |
| Multi-row aggregate, mixed lengths | `msb-throughput --scenario msb03` | `makespanAggregateTokensPerSecond`, `serialMakespanAggregateTokensPerSecond`, `makespanVsSerial` | Decoded tokens over the makespan: first request's arrival to the last row's last token. Prompts are 512 / 1024 / 1536 / 2048 tokens. The denominator is the serial makespan: the same requests served back to back on the serial path (SPEC-038 FR-CB14, since v0.3.37). |
| Batched-versus-serial parity | `msb-throughput --scenario parity` | `oneRowMatch`, `standaloneRowMatches`, `batchedRowMatches`, `firstDivergenceIndex`, `pass` | Greedy tokens of each row alone on the scheduler and inside the batch, compared with the serial path over `--parity-tokens` tokens (default 32). Rows 2..N join after row 0's first token, so rows sit at different KV offsets. This is parity inside our runtime, not against a reference. |
| Parity against a reference | `glm-parity` (lab build) | `freeRunning.firstDivergence`, `freeRunning.matchingTokens`, `teacherForced.top1Agreement` / `top1Compared`, `maxAbsLogitDiff` | Greedy decode from the reference oracle's prompt ids. If the free run leaves the oracle, a teacher-forced pass feeds the oracle's tokens and reports per-step top-1 agreement and logit error. `teacherForced` is absent when the free run matched. Top-1 and logit error cover only the steps the oracle logged: the first 16 in the reference scripts. |
| Native-MTP gain and acceptance | `native-mtp-bench`, then `python3 scripts/native_mtp_r015_analyze.py <jsonl> <policy>` | `aggregate_decode_tps`, `ttft_p50_seconds`, `ttft_p95_seconds`, `mtp_proposed_tokens`, `mtp_accepted_tokens`, `parity_mismatch` | Native MTP against ordinary decode at the same slot count, on the SPEC-048 MTP-15 (R015) cells. The analyzer gives the verdict. How to run `native-mtp-bench` per cell: `docs/runbooks/studio-lab-window.md`. |
| Peak memory | see below | see below | Three different measures exist. |

`glm-parity` also reports `decodeTokensPerSecond`, `prefillTokensPerSecond` and `ttftSeconds` with the same formulas, on the oracle's prompt and its own pipelined loop. `glm-parity`, `dsv4-parity` and `native-mtp-bench` exist only in a debug build or a build with `-Xswiftc -DMACPROVIDER_LAB_HARNESS`. Lab build: `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`. `decode-bench` and `msb-throughput` are in every build but hidden from `--help`.

### Peak memory

| Measure | Where | What it counts |
|---|---|---|
| Resident size | `msb-throughput` `peakRSSMB` | `resident_size`, sampled between runs. It misses Metal allocations. |
| Lifetime peak physical footprint | `msb-throughput` `peakPhysFootprintMB` and its stderr line `lifetime_peak_phys_footprint_mib`; `glm-parity` `peakPhysFootprintMB`; `native-mtp-bench` `peak_phys_footprint_bytes` | The process high-water mark, Metal included. It covers everything the process did, including serial baselines and warm-up. |
| MLX peak | `glm-parity` `prefillPeakMemoryGB`, `peakMemoryGB`; reference scripts `peak_memory_gb` (`mx.get_peak_memory()`) | The MLX allocator's peak, reset before prefill. |

`decode-bench` reports no memory. These measures are not comparable with each other: #2201 marks a process footprint next to a reference MLX peak "not comparable", and #2290 reports the same kind of pair.

- For native against the reference, use MLX peak on both sides.
- For sizing a row, use lifetime peak physical footprint, one cell per process.
- State the MLX cache limit of the run (`--mlx-cache-limit-mb`, or serve's default). #2236 measured its peaks with an unbounded cache and called the result provisional for `min_ram_gb`.

## Numbers from different tools are not comparable

Two tools give three aggregate multi-row tok/s figures, each for its own gate:

1. **`msb-throughput`, equal-length rows.** On the scheduler engine: earliest first token to latest completion, over raw token-id prompts (`msbAggregateThroughput`). Rows that arrive together prefill as one cohort (#2202), so the window is close to a pure decode window.
2. **`msb-throughput --scenario msb03`.** Makespan. The interval runs from the first arrival to the last token, so every row's prefill is inside it.
3. **`native-mtp-bench`.** The same window definition as the scheduler engine (earliest first token to latest completion), but on chat-completions requests with its own prompts and arrival order. With concurrent or staggered rows the window also covers other rows' prefills.

So one build gives three different "4-row tok/s" figures. #2261 shows the effect on one model: the decode-interval aggregate fell while the total time for the four requests stayed the same.

Each gate compares a ratio inside one tool, with both sides in the same run. That is sound. Rules for everything else:

- Never put absolute tok/s from two tools in one table column.
- Always name the tool, the scenario and the denominator next to a number.
- A ratio to a Python reference is a ratio between two tools. Say which native tool and which reference loop produced it.
- Single-row figures follow the same rule. `decode-bench` (templated text prompt), `msb-throughput` serial (raw token ids) and `glm-parity` (oracle ids, own loop) share a formula but not a prompt or a loop.

## Cell matrix

Every family runs these cells. Where the context window cannot hold a prompt length, write "not applicable".

| Cell | Rows | Prompt tokens | Tool |
|---|---|---|---|
| 1-row decode, prefill, TTFT | 1 | 1K, 8K, 32K | `decode-bench` |
| Multi-row aggregate | 4 (3 on 8 GB Macs, the tool's cap), plus the family's served slot count if it differs | 1K, 8K | `msb-throughput --engine scheduler` |
| Mixed-length aggregate | 4 (3 on 8 GB Macs, the tool's cap) | 512 / 1024 / 1536 / 2048 (fixed by the tool) | `msb-throughput --engine scheduler --scenario msb03` |
| Batched-versus-serial parity | 4 (3 on 8 GB Macs, the tool's cap) | 1K | `msb-throughput --engine scheduler --scenario parity` |
| Parity against the reference | 1 | 1K, 8K, 32K | `glm-parity` on the reference's oracles |
| Native MTP | per SPEC-048 MTP-15 | per SPEC-048 MTP-15 | `native-mtp-bench`; only for a family with an MTP layer |
| Peak memory | 1 and 4 | the longest prompt run | see [Peak memory](#peak-memory) |

Fixed settings:

| Setting | Value | Where it comes from |
|---|---|---|
| Output length | 256 tokens | Default `--decode-tokens` of both tools and `--decode` of the reference scripts. Campaigns used 128 and 256 (#2322). |
| Sampling | Greedy | Hard-coded in `decode-bench` and in the `msb-throughput` serial path (`temperature` 0, `topP` 1). |
| Warm-up | One untimed run | Built into both tools. |
| Repetitions | `--runs 5` | The `msb-throughput` default. `decode-bench` defaults to 3, so pass `--runs 5`. |
| Statistic | p50 plus spread | Both tools use nearest-rank p50 (`decodeBenchPercentileTPS`); with 5 runs it is the middle value. Spread: min and max of `samples[]` for `decode-bench`, the `...CVPct` fields for `msb-throughput`. `decode-bench` prints its p50 only on its stderr summary line (`decode_tps_p50`, `prefill_tps_p50`); the JSON holds the samples. |
| Engine | `--engine scheduler` | It drives `ContinuousBatchScheduler`. The default `contiguous` engine is a ceiling measurement. |
| Parity length | `--parity-tokens 256` | Matches the output length. The tool default is 32. |
| Prefill chunk | record `--prefill-step-size` | `decode-bench` defaults to 512, `glm-parity` to 2048 (the reference lane's chunk). Use the same chunk on both sides of a comparison. `msb-throughput` has no such option: its scheduler engine prefills in 512-token chunks. |

Five runs is the intake setting, not a new gate. Gate evidence keeps its own counts: SPEC-048 MTP-15 requires at least ten counterbalanced measured runs per cell, RESEARCH_232 §3.1 asks for at least twenty valid repetitions per MSB scenario, and the SPEC-038 DeepSeek V4 campaign gate uses the median of three timed runs.

```bash
macprovider-cli decode-bench --model <id-or-path> --prefill-tokens 1024 --decode-tokens 256 --runs 5 --output <path>
macprovider-cli msb-throughput --model <id-or-path> --engine scheduler --rows 4 --prompt-tokens 1024 --decode-tokens 256 --runs 5 --output <path>
macprovider-cli msb-throughput --model <id-or-path> --engine scheduler --scenario parity --rows 4 --prompt-tokens 1024 --parity-tokens 256
macprovider-cli glm-parity --model-dir <dir> --oracle <oracle.json> --steps 256 --output <path>
```

What the tools do that changes what a cell means:

- **`decode-bench` prompt length is approximate.** It repeats a fixed sentence and sends it as one user chat message. Report `promptTokensActual`.
- **`decode-bench` stops at an end-of-sequence token.** Report `decodeTokensActual`. In #2335 each run stopped at 52 of 256 tokens.
- **`msb-throughput` fails a run** whose rows did not all decode exactly `--decode-tokens` tokens. On the scheduler engine every row must also end on its length limit. If a model stops at an end-of-sequence token on the synthetic prompt, the cell is not obtainable with this tool: record the failure line.
- **`msb-throughput` interleaves** its serial, single-row and batched runs, so neither side of a ratio always meets a cooler GPU (#2200).
- **Templates and thinking.** `decode-bench` renders the model's chat template with no extra context, so the template's default applies. `msb-throughput` and `glm-parity` feed raw token ids: no template runs and thinking does not apply. `native-mtp-bench` sends chat-completions requests through the production template path; where the template has an `enable_thinking` toggle it is rendered off (#2222), and prompt strata are counted after the template (SPEC-048 MTP-15). Its `tools_history_reasoning` request shape sets `reasoning_effort` to `high`; only `plain_text` is the thinking-off shape.

## Reference

- One pinned Python reference per family: mlx-lm by default; mlx-vlm for vision-language families and where mlx-lm lacks the architecture or a needed fix. The GLM-5.3-Flash and DeepSeek V4 lanes use mlx-vlm (`glm53_bench_vlm.py`, `dsv4_reference_bench.py`), and #2189 records a released mlx-lm that lacked a GLM fix. Past cells: mlx-lm for gpt-oss (#2300) and Ripple-65B (#2279), mlx-vlm for MiniMax M3.1-Flash (#2224). LFM3, a text family, used mlx-vlm (#2290).
- If neither loads the model, say so in the cell. Bonsai used its model pack's own runtime (#2201). Nemotron 3.5 Bolt has no mlx-lm or mlx-vlm support; its reference is NVIDIA's own model code from `nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16` @ `e09a4ced` in PyTorch bf16 with two corrections: prefill carries the Mamba state across 128-token chunks as single-step decode does (the shipped fallback `torch_forward`, `modeling_nemotron_h.py:695`, sums the carry over the target-chunk axis, so it is wrong past 128 prompt tokens), and dt has no 0.001 floor (the CUDA kernel path clips to `dt_limit` (0, inf)). `scripts/lab/nemotron-bolt/README.md` records both and the self-check (#2329).
- Record the `mlx` and `mlx-lm` or `mlx-vlm` versions with every cell.
- Run the reference on the same machine, back to back with the native cell.
- The GPU must be otherwise idle: stop the provider on that Mac for the measurement. #2335 measured Llama-3.2-3B 4-bit on an M1 8 GB Mac with the provider stopped: the Python reference ran 28.1 to 29.6 tok/s (its reference used a pipelined `async_eval` loop on a different prompt), the 11 November lab build and CLI 1.8.287 13.6 to 15.5, and the October builds 25.2 to 25.6. #2290 had recorded about 0.65x for that model on an M1 8 GB Air. A cell taken under other load says so (#2201 phase B, #2300).
- Use the decode loop the reference ships (`generate_step` for one row, its `BatchGenerator` for several), as `scripts/lab/dsv4/dsv4_reference_bench.py` does. That is what users compare against. A bare forward loop does not give a valid decode tok/s (`scripts/lab/dsv4/README.md`).
- Use the same decode formula on the reference side: `(n - 1) / (last token time - first token time)`, as that script does.
- `decode-bench` does not export its prompt ids, so a reference run next to it matches the token count, not the prompt. Say so, as #2335 does. For the same prompt on both sides use the oracle path: the reference writes an `.npz` oracle (`glm53_bench_vlm.py` or `dsv4_reference_bench.py`; an mlx-lm family needs an equivalent that writes prompt ids, greedy ids, and top-16 ids with their logits or log-probabilities for the first 16 steps), `scripts/lab/cb-studio/glm53_oracle_json.py` converts it, and `glm-parity` decodes from its prompt ids.

## Hardware classes

Intake coverage, not a merge gate: a kernel or route change is measured at 1 row:

- on the serving hardware of every affected row; and
- on at least one small dense affine 4-bit model, on a non-Ultra chip older than the newest GPU generation.

Why:

- #2234 planned the `qmv_mma` A/B on two Mac classes, the M3 Ultra and one non-Ultra Mac, and named the 1-row cell as the one that matters most.
- #2265 reports cells from the M3 Ultra only. Its 1-row cell is GLM-5.3-Flash, and the same PR sends GLM decode projections through the GLM-specific `glm5NextQMVBatch` kernel. It reports no non-Ultra cell. Its local M5 could not run the route, which is off on NAX GPUs.
- #2335 then found single-row decode of Llama-3.2-3B 4-bit about 45% slower on an M1 8 GB Mac across the builds that span #2265. The cause is not yet isolated. MXFP4 models do not take that route.
- Routes differ by GPU generation (#2310), so one chip does not stand for another.

## Existing gates

This runbook replaces none of these. Read the pass rule at the source.

- **Port done** (`AGENTS.md` rule 15): a new port passes "Parity against the reference" and the "1-row decode vs reference" and "Long-prompt prefill" cells at 1K, 8K and 32K. Its decode tok/s and prefill tok/s must each be at least 95% of the reference, measured in the same Studio window, before its catalog row ships.

- **MSB-01..05** (`docs/runbooks/continuous-batching-enable-gate.md`, SPEC-038 FR-CB14): "MSB-02 > 1.5x MSB-01, MSB-03 > 1.2x MSB-01, at least one Entry 110 multi-slot tier > 1.3x aggregate TG, within the memory bound". For MSB-03: "the shortest prompt's batched TTFT p95 MUST be at most 2x its serial TTFT p95". Since SPEC-038 v0.3.52, a backend whose prefill group runs one forward per row (GLM-5.3-Flash pagedMLA) has an MSB-03 makespan bar of above 1.0x serial instead of 1.2x; the report's `prefillKind` and `makespanBar` fields name the bar used.
- **R015** (SPEC-048 MTP-15): "the lower bound for aggregate decode throughput improvement over the best ordinary baseline MUST be greater than 0 in each cell at the intended advertised slot count"; "The corrected upper bound for native-MTP p95 TTFT regression MUST be no more than 10%"; "the corrected upper bound for p95 per-output-token latency (TPOT) regression MUST be no more than 0%". MTP-15 also gates chunk gaps, rejections and memory.
- **CB self-check** (SPEC-038 FR-CB10): it grants a rung "only when that gain is at least 1.2x; otherwise a fresh Mac serves serially" (`ContinuousBatchingSelfCheck.minimumAggregateGain`).
- **Catalog `bench_gate`** (SPEC-023 §3.2): "`bench_gate.min_sustained_tps` and `bench_gate.max_4k_ttft_ms` are advisory drift targets only; they do not veto paid or donor selection."

## Coverage

Each cell links the thread that holds the measurement. Numbers are not copied here because they go stale. A cell with a qualifier is not a full cell of the matrix above. Filled only from the threads in [Sources](#sources).

| Family | 1-row decode vs reference | Multi-row aggregate | TTFT | Long-prompt prefill | Parity vs reference | Native MTP | Peak memory | Open issue |
|---|---|---|---|---|---|---|---|---|
| GLM-5.3-Flash | not measured (build vs build: #2221) | measured: #2265, #2261 | measured: #2261, #2265 | previous build only: #2221 | not measured (batched vs serial: #2265) | measured: #2265, #2225 | not measured | #2331 |
| DeepSeek V4-Flash | native only: #2151, #2111 | measured: #2151 | measured: #2111 | TTFT only: #2111 | measured: #2151 | one cell: #2151 | measured: #2111 | #2323 |
| gpt-oss-20b | measured: #2201, #2300 | measured: #2300, #2310 | measured: #2201 | measured to 8K: #2201 | measured: #2300 | not measured | measured: #2201 | #2324 |
| gpt-oss-120b | measured: #2201, #2300 | measured: #2201, #2300 | measured: #2201 | measured to 8K: #2201 | measured: #2300 | not measured | measured: #2201 | #2324 |
| MiniMax M3.1-Flash | measured: #2189, #2306 | measured: #2224 | measured: #2224 | measured: #2189, #2306 | measured: #2224, #2306 | not measured | measured: #2224, #2306 | #2189 |
| Ripple-65B | measured: #2279 | not measured | not measured | not measured | BF16 vs a PyTorch transcription: #2279 | not measured | not measured | |
| LFM3 1.7B | measured: #2290 | not measured (serves serial: #2290) | measured: #2290 | measured to 3.6K: #2290 | measured: #2290 | not measured | measured, methods differ: #2290 | #2325, #2335 |
| Ternary Bonsai 2B | measured, prompts differ: #2201 | measured, 2 and 3 rows: #2163 | measured: #2201, #2163, #2303 | TTFT only: #2163, #2303 | measured: #2303 | not measured | measured, methods differ: #2201, #2163 | |
| Nemotron 3 Nano | measured: #2207, #2201, #2236 | not measured | measured: #2207 | TTFT only: #2207 | measured: #2207 | not measured | native only: #2201 | |
| Nemotron 3.5 Bolt | native only: #2329 | measured: #2329 | measured: #2329 | TTFT only, 8K: #2329 | measured, NVIDIA code: #2329 (batched vs serial fails: #2329) | not measured | measured, 2 GB cache limit: #2329 | #2329 |
| Nemotron 3.5 Lightning | native only: #2236, #2313 | measured: #2236, #2313 | not measured | not measured | measured: #2236 | not measured | measured, unbounded cache: #2236 | |
| Qwen3.6/3.8-27B | not measured | not measured | R015 cells only: #2222 | not measured | not measured | measured: #2222 | not measured | |
| Qwen3-8B | not measured (vs serial: #2202) | measured: #2202, #2310 | not measured | not measured | not measured (batched vs serial: #2202) | not measured | not measured | |
| Llama 3.1 8B | measured, serve path: #2317, #2318 | measured: #2202, #2242 | not measured | not measured | not measured (batched vs serial: #2242) | not measured | 4 rows only: #2202 | #2326 |
| Llama 3.2 3B | measured: #2335 | ratio only: #2200 | not measured | not measured | not measured | not measured | not measured | #2335, #2325, #2330 |
| Qwen2-VL-2B | measured, text and image: #2207 | not measured | measured: #2207 | TTFT only, 8K text: #2207 | measured, text: #2207 | not measured | not measured | #2327 |
| GLM-4.5-Air | measured: #2201 | not measured | measured: #2201 | measured to 8K: #2201 | measured: #2201 | not measured | measured, methods differ, unbounded cache: #2201 | |

Open issues for families without a row here: #2328 (Gemma-4-12B native MTP).

## Known levers

Ideas with a measured result somewhere. Scouts read this list before
proposing a candidate, and every measured result (kept or rejected) is added
here with its issue. "Theirs" means a result outside this repo, on other
hardware and runtimes; it sets a prior, not an expectation. A lever that
changes output is excluded: every speed cell is gated by identical output.

| Lever | What it can touch | Theirs | Ours | Issue |
|---|---|---|---|---|
| Measure the ceiling first: decode = measured bandwidth / bytes read per output token; prefill = about half the measured matmul peak / compute per token | Where the headroom is; whether a target is possible | Method [1] (`references/ceilings.md`) | Not yet measured on the box | |
| Prune the speculative draft's output vocabulary; the target still verifies on the full vocabulary | Native-MTP draft step time | +14% and +27% decode [1] | Rejected. GLM-5.3-Flash: saves about 1 ms of a 38 ms cycle (2.3–2.5%); a narrow 7.8k-id list cut acceptance 0.75 to 0.58 and decode 7–8%. Ceiling about +2% on GLM-5.3-Flash and +2.5–3.5% on Qwen3.8-27B: their output layers are 0.67 and 0.72 GB against the whole step | #2428 |
| Draft length by row count and context length | Native-MTP decode at many rows and long context | Best was 4 drafts at 1 row, 3 at 4 rows, 2 at 16 rows (B70); at 128k context 1 draft beat 3 by about 1.9x (B390) [1] | Qwen 27B, depth 1, one row, SPEC-048 R015 formal matrix: native/ordinary decode 1.12x (Qwen3.6-27B) and 1.13x (Qwen3.8-27B) at a 32,768-token prompt with 512 output, 1.30-1.39x at 1.5K-4K prompts; end to end 0.97-0.98x at 32K (TTFT upper bound about +3.5%). Both caps raised 4,096 to 32,768. Qwen3.6-35B-A3B: 1.20x at 8K, 0.99x at 32K (exploratory), cap stays 4,096 | #2429 |
| Verify speculative steps on the decode attention path, not the prefill kernel | Native-MTP step time at long context | Verification through the prefill kernel lost 3.5 ms per step per 1k tokens of context [1] | Not yet checked | |
| Speculation on low-bandwidth Macs | Whether native MTP pays at all on small Macs | 6.35 to 3.25 tok/s on an Apple M4 with 3 MTP drafts [1] | Not yet measured (our tuples run 1 draft) | |
| Prefix cache hits on second and later turns | Turn-2 TTFT, the TTFT most agent and chat buyers see | 66k-token turn 2 went from 36 s to 0.45 s once the cache hit [1] | GLM-5.3-Flash (batched): turn 2 caches 3,671 tokens, TTFT 9.6-9.9 s to 0.26-0.31 s. Qwen3.8-27B (serial): never hit until PR 2437; now caches 3,511 tokens, TTFT 10.7-10.9 s to 0.53 s | #2430 |
| Recurrent-state slots and page size for linear-attention models | Multi-row aggregate | State slots and page size capped concurrency; a page-size fix took 10 to 14 streams, +17% aggregate [1] | Not yet measured | |
| Batching width tie band in the self-check | Multi-row aggregate | | Kept. GLM-5.3-Flash: the 15% tie band granted 3 of 4 verified rows; a 3% noise band grants 4. 4-row cells, same window, between two pinned-3 controls: +23.0% aggregate at a ~200-token prompt, +9.3% at 4k; identical reasoning text and token counts; per-request tok/s falls (19.0 to 15.6). 1- and 3-row cells unchanged | #2409 |
| Per-forward row cap inherited from another family's fused kernels | Multi-row aggregate | | Qwen3.8-Flash-Next ran at most 8 rows per decode forward (a GLM-5-Next cap) although 16 were verified: 16 rows = 8 rows = 100 tok/s vs mlx-lm 150. Lifted to the device bound (11) on the campaign branch: 108.5 tok/s at 11 rows (mlx-lm 129.2); no old-cap control in that window | #2409 |
| Batched per-row attention prep (norm, RoPE, output gate as one batched op instead of one per row) | Multi-row decode | | Qwen3.8-Flash-Next CB, ~200-token prompt, 512 output, 3 trials per leg, control/candidate/control: +1.5% at 8 rows (102.3 vs 100.8/100.8 tok/s), +2.8% at 11 rows (111.2 vs 108.0/108.2), 0% at 1 row, inside noise at 4. Kept (engine 3.32.3-macprovider.84). Token identity from engine tests (batched == per-row bitwise); served multi-row output already varies between identical control runs | #2409 |
| Start-up time against its floor (weight bytes / disk read speed) | Downtime per provider restart; lab window time | The floor holds only when compile caches persist [1] | GLM-5.3-Flash lab start 388.6 s mean on main, 117.5 s with weights hashed once in parallel (merged) | #2431, #2434 |
| Larger M-block in grouped MoE matmuls (reuses dequantized weights across rows) | MoE prefill | +7% prefill, identical output [1] | Not yet microbenchmarked | |
| Merge small kernels | Decode | Rarely paid under CUDA/XPU graph capture, where launch overhead is already gone [1]; MLX on Apple GPUs has no comparable graph capture, so this prior is weak here | Not yet measured | |
| Share the decode attention's K/V read across a native-MTP verify window | Native-MTP verify step at long context | +24% at 32K, M3 Ultra (TensorFold) | Rejected. Qwen3.8-27B, 29.5K, 1 row, depth 1: full attention is 11.5 ms of a 72 ms verify step against 7.6 ms in decode, so a perfect shared read saves at most 4.0 ms (5.5%, about +0.9 on 19.6 tok/s). Matters only at depth 3 or more (about 15%) | #2469 |
| Read each routed expert once per native-MTP verify window | Native-MTP verify step on MoE models | 50.0 to 53.0 tok/s, 8-bit experts (TensorFold) | Rejected. GLM-5.3-Flash, 4-bit routed experts, 2-token verify: routed experts are 10.87% of a 124 ms step and 85.4% of picks are unique, so at most 1.6% (about +0.2 on 12.1 tok/s). Already exists as `shareExpertLoads` | #2470 |
| Larger prefill chunks | Prefill speed, at the cost of other rows' decode stalls | Trade-off, not a win [1] | Rejected (changes output). GLM-5.3-Flash, one row, serial: step 2048 vs 512 cut TTFT 13.5% (11.23 to 9.72 s, 3,673-token prompt) and 14.8% (43.66 to 37.20 s, 14,126), MLX peak 192 to 206 GB, but greedy tokens left step 512 at token 13 and token 75. Each step was deterministic. No chunk-length logic found in the engine: a full 2048 chunk takes different MLX matmul kernels (split-K partition count, router GEMM, gathered expert matmul), so summation order changes | #2409 |
| One gated-delta pass that also returns the state checkpoint, instead of two calls (prefix, then suffix) on every native-hybrid MTP verify step | Native-MTP step time on Qwen3.5/3.6 (linear-attention layers) | mlx-vlm already does this (`gated_delta_update_with_states`) | Kernel only, base M5, mlx 0.32.4, Qwen3.6-35B-A3B shapes (30 layers): the split costs 1.0-1.65 ms more per verify step than one call (verify length 2-4), bit-identical. Each extra call re-reads and re-writes the 2 MiB fp32 state per layer. End-to-end tok/s not yet measured. Needs a checkpoint output in mlx core `fast::gated_delta_update`, then mlx-c, mlx-swift, mlx-swift-lm | upstream ml-explore/mlx-swift-lm 753 |
| `state_at` on `mx.fast.gated_delta_update`: the sequential Metal kernel writes the prefix state in the same pass | Native-MTP verify step on Qwen3.5/3.6 linear-attention layers | mlx-vlm `gated_delta_update_with_states` | Apple M5, 30 layers, Qwen3.6-35B-A3B shapes (Hk 16, Hv 32, Dk = Dv = 128), batch 1, bf16 inputs, fp32 state, scalar gate. Sample = median of 300 iterations, includes Python graph building. Median of 18 two-call samples and 6 `state_at` samples: T=2 split 1, 2.572 vs 1.922 ms (25.3%); T=3 split 1, 2.639 vs 1.917 (27.4%); T=3 split 2, 2.713 vs 1.963 (27.7%); T=4 split 1, 3.918 vs 2.828 (27.8%); T=4 split 2, 4.207 vs 2.764 (34.3%); T=4 split 3, 4.290 vs 3.392 (20.9%). Beat both neighbouring two-call runs in 33 of 36 rounds. Output, final state and `state_at` state bit-identical to the split. Same-pass only when unmasked, supported shape, and per-key gate or T <= 8; otherwise the op runs the split. CUDA is that split and was not built or run. Extra state about 0.4-1.2 ms and 60 MiB per step across the 30 layers. End-to-end tok/s not measured. Log `lab-753/bench2-m5-idle.log`. Opened as mlx #4922 (`aaa4cab10`) | mlx-swift-lm #753, mlx #4922 |
| Inkling-2-Mini decode: conv state kept across steps, stacked block residuals, fused tails (`convstate`, `blockstack`, `tails`, fork 2467 branch at 5c0ccd88) | 1-row decode on Inkling 2 (oQ4e, compiled path) | none | Rejected, slower. Output identical (16/16 exact, 64/64 vs mlx-vlm). M3 Ultra, same window, A/B/A: all three on 25.06/24.34/21.79 tok/s at 1K/8K/32K vs compiled controls 26.47–26.53/25.55–25.59/22.80–22.83 (about -5%). The compiled path alone is 91–92% of mlx-vlm (29.0/27.9/24.7). | #2467 |
| Sparse-MLA prefill GEMMs that read the selected latent rows in place instead of a `take` copy, keeping steel_gemm_fused's per-element K order (bitwise) | Prefill past `index_topk` on DSA/MLA models (GLM-5.3-Flash) | none | Rejected, slower. GLM-5.3-Flash uncensored, M3 Ultra, batching route, one window, A/B/A, medians of 6: TTFT 20.35 s vs 9.33/9.31 s at 3,673 tokens (+118%), 109.30 vs 36.81/36.72 s at 14,126 (+197%); tokens identical in all four cells. Section profile (3,673 tokens, 1,837-token chunks): sparse MLA 881 ms of 9,595 (9.2%); the gather it removes is 145 ms (1.5%), q@kᵀ 276 ms and p@v 233 ms (about 53% and 63% of the bf16 peak, derived). Ceiling for the lever: 653 ms (6.8%), and only by beating steel. Kernel not profiled (likely: scalar loads, unpadded tiles, transposed B writes). Replay: fork `macprovider/2524-sparse-mla-91` `d2e22614`, `scripts/lab/2474/job.sh` from `campaign/2524-sparse-mla` | #2524 |
| Fused bit-exact KDA prefill kernels: depthwise conv + SiLU + q/k L2 norm in one kernel, gated RMSNorm in one kernel, MLX's op order and rounding kept (oMLX `glm53_kda_prework` pattern) | KDA / linear-attention prefill (GLM-5.3-Flash, 34 KDA layers) | oMLX 0.8.0rc1 `glm53_kda_prework`: the same two fusions, bit-compatible with its unfused path by its description; in our same-window profile its prework 113 ms and norm-gate 46 ms against our 247 and 104 | Kept, in mlx-swift-lm `3.33.0-macprovider.93`. GLM-5.3-Flash uncensored, M3 Ultra, batching route, one window, A/B/A, medians of 6: TTFT 8.983 s vs 9.311/9.323 s at 3,673 tokens (-3.5%), 35.514 vs 36.555/36.706 s at 14,126 (-2.9%/-3.3%; -3.1%/-3.6% at 512 out); tokens identical in all four cells; fork bitwise tests pass. Profiled first against oMLX in one window with the same chunking: KDA attention 2,573 vs 2,132 ms, prework +134 ms, norm-gate +58 ms, recurrence +177 ms or more (oMLX's recurrence kernel sums in a different fp32 order: not taken). Replay: `scripts/lab/2474/job.sh` JOB_MODE=abab with the fork tests `testKDAPrefillFusion*`. | #2524 |

Excluded: int8 prefill (changes output). Not evaluated: CUDA/XPU graph
capture, the source's first decode lever; MLX on Apple GPUs has no direct
equivalent (`mx.compile` is the closest).

[1] [sybil-solutions/inference-optimisation-skill](https://github.com/sybil-solutions/inference-optimisation-skill), read 2026-11-18. Results mostly on Intel Arc and NVIDIA GPUs (vLLM, SGLang, ExLlama); one Apple M4 result, runtime not stated.

## How to report a cell

```text
Model:              <repo id @ revision>
Quantization:       <e.g. affine 4-bit, MXFP4>
Hardware:           <chip, RAM>
OS:                 <macOS version>
Build commit:       <sha>
Fork pins:          <mlx-swift-lm, mlx-swift revisions>
Decode-path digest: <python3 scripts/decode_path_digest.py>
Tool and command:   <exact command line>
Reference:          <mlx-lm or mlx-vlm version, mlx version, decode loop>
GPU state:          <provider stopped, or the other load>
Rows:               <n>
Prompt tokens:      <actual, per row>
Tokens generated:   <actual, per row>
Runs:               <n timed, after one warm-up>
p50:                <value, unit, tool field name>
Spread:             <min-max, or CV %>
Ratio:              <native p50 / reference p50; name both tools>
Parity result:      <first divergence, matching tokens, top-1, max logit diff; or "not run">
Peak memory:        <value, which measure, MLX cache limit>
```

Write "not measured" on a line you do not have. Do not leave the line out.

## Sources

Code and scripts (paths from the repo root; line ranges as of the commit that added this runbook). Swift files are under `phase3-binary/Sources/macprovider-cli/`.

- `DecodeBenchCommand.swift`: options 41-60; prompt and warm-up 141-171; one sample 368-426; p50 441-446; `msbAggregateThroughput` 470-498; report fields 574-603.
- `MSBThroughputCommand.swift`: engines and TPS semantics 28-54; options 76-176; peak footprint line 211-216; run order 415-428; row-count check 1109-1123; scheduler run 752-862; serial path 1134-1169; msb03 serial makespan 1183-1212; parity 1613-1688; report fields 2606-2656.
- `MSBThroughputLeftovers.swift`: scheduler row timing 5-23; makespan sample 28-37; scenarios 41-52; parity fields 124-135; msb03 fields 173-187; msb03 prompt lengths and gate 205-233.
- `MSBLoopbackCommand.swift`: peak physical footprint 474-486.
- `GLMParityCommand.swift`: purpose 9-24; options 33-55; measurement 165-320; report fields 447-536.
- `NativeMTPBenchCommand.swift`: request body 1507-1545; record fields 1721-1771; decode throughput window 1788-1818.
- `MacProviderCLI.swift`: lab-only subcommands 56-61. `ModelRuntime.swift`: template thinking context 15927-15945. `ContinuousBatchingSelfCheck.swift`: line 247. `ProviderStatus.swift`: row cap 226-238. `ContinuousBatchScheduler.swift`: line 514.
- `scripts/native_mtp_r015_analyze.py` (arguments 1642-1664), `scripts/decode_path_digest.py` (usage 1-41).
- `scripts/lab/dsv4/README.md`, `scripts/lab/dsv4/dsv4_reference_bench.py` (1-14, 65-96), `scripts/lab/cb-studio/glm53_bench_vlm.py` (71-103), `scripts/lab/cb-studio/glm53_oracle_json.py` (1-8).

Specs and docs:

- `specs/SPEC-038-continuous-batching.md`: FR-CB10 (self-check grant rule) and FR-CB14 (MSB-01..05, the v0.3.37 makespan, the DeepSeek V4 campaign gate).
- `specs/SPEC-048-native-mtp-serving.md`: MTP-15 (SPEC-048-R015). `specs/SPEC-023-installer-autotune-recommend.md`: §3.2 (`bench_gate`).
- `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` §3.1, `docs/runbooks/continuous-batching-enable-gate.md`, `docs/runbooks/studio-lab-window.md`, `AGENTS.md` hard rule 2.

Issues and PRs: #2111, #2151, #2163, #2189, #2199, #2200, #2201, #2202, #2207, #2221, #2222, #2224, #2225, #2234, #2236, #2242, #2253, #2255, #2256, #2261, #2265, #2279, #2290, #2300, #2303, #2306, #2310, #2313, #2317, #2318, #2322, #2323, #2324, #2325, #2326, #2327, #2328, #2329, #2330, #2331, #2335.
