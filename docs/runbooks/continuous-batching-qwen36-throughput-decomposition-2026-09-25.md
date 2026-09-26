# Qwen3.6 throughput decomposition on the Mac Studio (2026-09-25)

Question: why does Qwen3.6-27B serve at about 15 tok/s under continuous
batching (CB) on a 256 GB M3 Ultra, when 100 tok/s was expected?

## Physics

- **Serial decode: 36–38 tok/s at every context length.** This is close to the
  bandwidth ceiling: about 15 GB of weights are read per token at about
  819 GB/s. A single stream cannot reach 100 tok/s.
- **100 tok/s is an aggregate target.** Only batching can reach it, because one
  weight read then serves several rows.
- **Prefill runs at about 300 tok/s serial,** so a 4k-token prompt takes about
  14 s before its first token.

## Before (`b0f3d45f`): batched decode lost to serial at long context

Steady-state aggregate decode, measured only over the window where every row is
decoding (`steady_decode.py`):

| Prompt × rows | tok/s |
| --- | --- |
| 32 × 4 | 54.8 |
| 1.5k × 2 | 36.8 |
| 1.5k × 4 | 43.2 |
| 3k × 3 | 29.1 |
| 4k × 4 | 28.1 |

The profile (`profile-steady-decode-3x3072.txt`) showed
`PagedKVCache.update` doing this on every decode step:

- re-concatenating the row's whole K/V history;
- re-splitting it into blocks.

That made each step O(context).

## Fix (`3a91f1bc`): in-place paged-KV writes

- Each layer keeps contiguous `[B,H,capacity,D]` backing buffers. They grow in
  256-token steps, capped at `maxResidentTokens`.
- New tokens are written with slice assignment.
- Block views are derived on demand, and `trim` is O(1).
- Output is byte-identical to the old path on a random-weight model locally, and
  all 3439 package tests pass.

## After (`3a91f1bc`, binary `e45d3a983cb77ef6`)

Data: [`data/cb-perf-2026-09-25/after-o1/`](data/cb-perf-2026-09-25/after-o1/).

### Steady-state batched decode

| Prompt × rows | Before | After |
| --- | --- | --- |
| 32 × 4 | 54.8 | **67.6** |
| 1.5k × 2 | 36.8 | **54.7** |
| 1.5k × 4 | 43.2 | **64.0** |
| 4k × 1 serial | 36.4 | 36.4 |

Batched decode now reaches 1.5–1.75× serial, and the drop from 32 to 1.5k
tokens of context is small.

At 4k × 4 and 8k × 4 no steady window exists: the first row finishes 768
tokens before the last row's prefill ends. See the next section.

### End to end (128 output tokens, `matrix.jsonl`)

| Prompt × rows | Aggregate tok/s | Worst first token | Prefill per row |
| --- | --- | --- | --- |
| 512 × 4 | 36.4 | 9.3 s | 110 tok/s |
| 1.5k × 4 | 19.9 | 25.0 s | 117 tok/s |
| 4k × 4 | 8.8 | 69.6 s | 117 tok/s |

End to end, prefill dominates:

- The scheduler admits one prefill per iteration, and the prefill chunks of
  that one row alternate with decode steps.
- Per-row prefill drops from about 300 tok/s serial to about 117 tok/s under
  load.
- Rows queue behind each other's prompts.

The remaining gap to 100 tok/s is prefill scheduling, not decode.

### Correctness

- **Startup probes:** parity `established=true`; batched isolation proven with
  0 cross-row divergences.
- **`isolate_q36`:** 5 of 5 scenarios, every row exact.
- **`crossrow_q36` (greedy, compared against serial):**
  - n=2 and n=4: every row exact.
  - n=8: 7 of 8 rows exact. The eighth diverges at char 83 with no leak signal,
    which is the FR-CB6 accumulation-order tolerance.
- **Failures:** 0 `batching_forward_failed` or `batching_prefill_failed` events.

## MLX ceiling: the model-level harness (`msb-throughput`, same binary)

This measures aggregate decode for N rows, with no scheduler, HTTP or prefill
involved. Runs used 128 decode tokens. Data:
[`data/cb-perf-2026-09-25/msb-scale/`](data/cb-perf-2026-09-25/msb-scale/).

| Rows | Stock MLX contiguous KV, L=32 | Stock MLX, L=1.5k | Our paged engine, L=32 | Our paged engine, L=1.5k |
| --- | --- | --- | --- | --- |
| 1 | 37.2 | 38.0 | 34.2 | 34.5 |
| 2 | 59.7 | 63.1 | 56.6 | 57.3 |
| 4 | 70.6 | 72.6 | 66.4 | 68.0 |
| 8 | 78.7 | 81.3 | 76.1 | 79.1 |

- **Stock MLX peaks at about 80 tok/s at 8 rows** for this 4-bit 27B hybrid
  model. The stock engine is a plain `KVCacheSimple` with a batch dimension,
  compiled.
- **Our paged engine is now within 3–6% of that ceiling.** The serve's
  steady-state 64.0 tok/s at 1.5k × 4 is within about 6% of the harness figure
  of 68.0.
- **Where the limit comes from:** past about 4 rows, per-step cost grows almost
  linearly with rows. This is a property of MLX's small-batch quantized matmul
  and the gated-delta recurrent layers, not of our scheduler or cache.
- **What 100 tok/s would need:** more than 8 rows, or kernel-level work in MLX.

## Where the "15 tok/s" comes from

Take a typical agent request: a ~1.5k-token prompt and ~150 output tokens.

- Prefill takes about 5 s at the compute-bound ~300 tok/s.
- Decode takes about 4 s.

Per request that is about 16 output tok/s, which matches what buyers see. The
dominant cost is prefill, and prefill is compute-bound: about 54 GFLOP per token
× 300 tok/s ≈ 16 TFLOPS on the M3 Ultra.

The levers that move it:

- **Prefix and conversation reuse.** M4 turned a 76.6 s re-prefill into a 1.0 s
  follow-up.
- **Enough concurrency to fill 8 rows.**
- **Prefill/decode fairness,** so prompts do not stall other rows.

## Production decodes at 20.5 tok/s because launchd runs it at background priority

Production v1.8.192 measures about 20.5 tok/s single-stream decode, while the
campaign serve measures 36.4. Data:
[`data/cb-perf-2026-09-25/process-type/`](data/cb-perf-2026-09-25/process-type/).

| Process | Priority | Decode tok/s (768 tokens, serial) |
| --- | --- | --- |
| Live `:8080` (launchd, `ProcessType` `Adaptive`) | 4 | 22.3–23.4 |
| v1.8.192 release binary, shell launch | normal | 37.7 |
| Same binary under `taskpolicy -b` | 4 | 22.1 |
| Same binary, launchd `ProcessType` `Adaptive` | 4 | 22.3 |
| Same binary, launchd `ProcessType` `Standard` | 20 | **37.8** |
| Lab binary with the live `max_context_override` of 200000 | normal | 37.7 |

What this rules out, and what it shows:

- **Not the binary, the config, the context setting or the measurement.** The
  release binary at normal priority decodes as fast as the campaign build.
- **The cause is launchd priority.** launchd leaves an `Adaptive` job at
  background priority unless XPC activity boosts it, and a network daemon never
  gets that boost. The `Background` value that SPEC-003 specified behaves the
  same way.
- **Why priority matters here.** Decode issues many small Metal command
  buffers per token, and background QoS throttles the CPU threads that encode
  and commit them.

Fix, SPEC-003 v0.11.4: the provider LaunchAgent uses `ProcessType` `Standard`
in all three sources: `install.sh`, `launchd-plist-template.plist` and the
signed compatibility-set template that auto-update renders.

## Final branch build, clean run with live paused

Binary `39733dde7e3dc378`: in-place KV with allocator-block growth, the decode
window while prefilling, and no prefill logits. The live `:8080` provider was
paused for the whole run. Data:
[`data/cb-perf-2026-09-25/clean-final/`](data/cb-perf-2026-09-25/clean-final/).

Before this run, lab figures taken while live served traffic at `Standard`
priority were depressed by GPU sharing (for example, 1.5k × 4 measured 40.5
instead of 64). Lab benchmarks now pause live.

### Steady-state aggregate decode (tok/s)

| Prompt × rows | Before the milestone | Final |
| --- | --- | --- |
| 32 × 4 | 54.8 | 66.3 |
| 1.5k × 2 | 36.8 | 54.3 |
| 1.5k × 4 | 43.2 | 64.9 |
| 1.5k × 8 | — | **76.3** |
| 1.5k × 1 serial | 37 | 37.3 |

### An active row while long prompts prefill (`stall.py`)

| Arriving prompts | Base (one token per chunk) | Final (8-token window) | Long-prompt first token |
| --- | --- | --- | --- |
| 1 × 4k | 3.48 tok/s | **6.17 tok/s** | 16.4 s → 18.1 s |
| 3 × 4k | 1.64 tok/s | **4.44 tok/s** | last: 47.0 s → 52.6 s |
| 1 × 8k | — | 5.18 tok/s | 35.5 s |

The maximum inter-token gap stays at about 2 s, which is one 512-token prefill
chunk. Smaller gaps would need smaller chunks.

### End to end (128 output tokens)

This is still prefill-bound: 1.5k × 4 aggregates 19.5 tok/s and 4k × 4
aggregates 9.2. Prefill is compute-bound at about 300 tok/s, so short-output,
long-prompt traffic is limited by prefill, not by batching.

### Correctness

- `isolate_q36`: 5 of 5 scenarios, every row exact.
- `crossrow_q36`: n=2 and n=4 fully exact; n=8 has 7 of 8 rows exact, with 0
  leaks.
- Failures: 0 forward or prefill failures.
- Startup probes: parity established, batched isolation proven.

## Live production, end to end from a remote client (2026-09-26)

The live `:8080` provider after the #1742 cut (binary `3dc6bd356af0e791`,
launchd `ProcessType` `Standard`, priority 20, CB `canary` with 8 slots) was
measured from a remote client through the OpenAI-compatible endpoint,
streaming. Prompts were about 1.5k tokens and each request asked for 300
output tokens. First-token times include about 1 s of network.

| Sampling | Concurrent requests | Aggregate tok/s | Per-request decode tok/s | First token p50 / p95 |
| --- | --- | --- | --- | --- |
| Greedy | 1 | 19.7 | 35.4 | 6.8 s / 7.1 s |
| Greedy | 2 | 26.3 | 23.6 | 11.9 s / 13.3 s |
| Greedy | 4 | 29.4 | 11.8 | 16.0 s / 26.1 s |
| Temperature 0.7 | 4 | 28.8 | 11.8 | 17.8 s / 25.9 s |

The same measurement on v1.8.192 at `Adaptive` priority gave 13.6, 9.9 and
11.7 tok/s aggregate at 1, 2 and 4 requests, and 15.9 at 4 sampled requests.

- Sampled requests now batch at the same throughput as greedy ones.
- A single request decodes at about 35 tok/s, in line with the serial figure
  above.
- All 45 requests succeeded, and billed usage matched the client's token counts
  exactly.
- First-token time is the remaining gap. It grows with queued prompts, which is
  the prefill scheduling work below.


## Next

Prefill scheduling:

- Prefill several admitted rows together.
- Give prefill a token budget per iteration, so a long prompt cannot starve
  decode rows or queue other prompts behind it.

Then profile the hybrid prefill kernel itself, which runs at about 300 tok/s
serial.
