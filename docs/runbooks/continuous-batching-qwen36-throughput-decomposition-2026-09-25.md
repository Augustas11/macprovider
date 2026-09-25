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

## Next

Prefill scheduling:

- Prefill several admitted rows together.
- Give prefill a token budget per iteration, so a long prompt cannot starve
  decode rows or queue other prompts behind it.

Then profile the hybrid prefill kernel itself, which runs at about 300 tok/s
serial.
