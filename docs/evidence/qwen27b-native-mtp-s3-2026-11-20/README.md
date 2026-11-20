# Qwen3.6-27B native MTP, 3-row R015 cell (exploratory), 2026-11-20

Related: #2440

One exploratory SPEC-048 R015 cell, `s3-p1536-o512`, for the tuple with the signed
`max_native_active_rows` 1. The recorded R015 runs had no 3-row cell for any tuple.

**Setup.** Apple M3 Ultra (Mac15,14, macOS 27.0.1 build 26A434), lab build of main `018ded3a0`
(`cli_sha256` prefix `cb8dd47e720bab3b`), model `qwen/qwen3.6-27b`, `policy.json` validated
(`validate.out`). Three rows arriving 250 ms apart, 1,536-token prompts, 512 output tokens,
10 paired blocks of ordinary continuous batching against native MTP, plus one excluded
warm-up per arm. The natively admitted row is always the first arrival.

| | ordinary | native MTP |
|---|---|---|
| Committed tok/s (median of 10 runs) | 31.52 | 31.03 |
| Decode tok/s (median) | 37.42 | 38.51 |
| Time to first token per row, rows 1 / 2 / 3 (s, medians) | 4.99 / 15.39 / 15.14 | 6.21 / 11.62 / 16.16 |
| MTP proposed / accepted tokens | 0 / 0 | 7 / 7 |
| Errors / fallbacks | 0 / 0 | 0 / 0 |

- **Tokens:** output token ids are identical to the ordinary arm for every row in all 10 blocks.
- **Admission:** in the native arm, the row admitted while it was the only active row took
  `native_mtp/eligible` (10 admissions). The rows admitted at 2 and 3 active rows took
  `ordinary/capacity_above_native_bound` (20 load-gate downgrades), as bound 1 implies.
- **Native rounds:** all 7 native rounds are in block 2 (`bench.jsonl`: `mtp_proposed_tokens` 7,
  `mtp_forwards` 7, `gated_depth_restorations` 1; every other block records 0 for all three).
  In that block the natively admitted row ran to 512 tokens after the other two stopped at
  306 and 322, and the log's only `restore active_rows=1 bound=1` event fits depth being
  restored once that row was alone. The issue expected zero native rounds, so the 3-row cell
  matches that except for this one block. That the rounds ran in the single-row tail is
  inferred from that event and the completion times; individual rounds are not timestamped.
  The 7/7 acceptance is one block of 7 proposals, not a measured rate.
- **Throughput:** end-to-end committed throughput is 1.5% lower in the native arm
  (95% CI −2.4% to −1.2%), while decode tok/s is 2.6% higher.
- **Time to first token:** the median over rows (15.14 s ordinary, 11.62 s native) is not
  a speed-up. Per row, native is slower on the first and last rows (+1.22 s and +1.02 s).
  The middle row's earlier first token (11.62 s vs 15.39 s) is likely a different prefill
  interleave; the records do not show the scheduling.
- **Analyzer:** `analysis.json` reports `overall_status` `EXPLORATORY_NO_VERDICT`. It also
  gives the cell `status` PASS and `cell_class` "gated" (`analysis.md` shows the PASS), but
  `gated_cells` in the policy is empty, so treat both labels as exploratory.

Not covered: other tuples, other chips, bounds above 1.

Files: `policy.json`, `validate.out`, `bench.jsonl` (raw records), `analysis.json`,
`analysis.md`, `s3-p1536-o512.log` (serve log with load-gate events), `summary.txt`.
