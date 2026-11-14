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
- If neither loads the model, say so in the cell. Bonsai used its model pack's own runtime (#2201). Nemotron 3.5 Bolt has no mlx-lm or mlx-vlm support; its reference is NVIDIA's own model code from `nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16` @ `e09a4ced` in PyTorch bf16 with two corrections: prefill carries the Mamba state across 128-token chunks as single-step decode does, and dt has no 0.001 floor (the trained GPU path has none). `scripts/lab/nemotron-bolt/README.md` records both and the self-check (#2329).
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
