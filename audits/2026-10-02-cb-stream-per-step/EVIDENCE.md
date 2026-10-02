# CB per-step streaming — Studio evidence (2026-10-02)

Host: Mac Studio M3 Ultra 256 GB (`ssh macstudio`), isolated loopback serve on
:18080 with `--no-join` (never joined the coordinator), live :8080 paused by
`/Users/a1/lab-cb-sampling/bench.sh` and resumed (`LIVE_RESUMED`), Pearl
`malibu-buyer-runner-studio` stopped for the windows and restarted after, lab
lock `/Users/a1/.lab-window.lock` held and released.

Model: `meta-llama/llama-3.1-8b-instruct`
(`mlx-community/Meta-Llama-3.1-8B-Instruct-4bit@241a666d`, sha `67b26d6b…`),
non-hybrid, `cache_class: KVCacheSimple`, production lockstep window 16.
Config: `continuous_batching: canary`, `max_concurrency_override: 8`,
metallib sha `84e48718…` (same as live). Every lab request carried
`X-Request-ID` and was admitted to the batched route (`batching_admitted`
59/59 in round 2; the single `batching_unsupported` line is the pre-measure
startup line).

Binaries (`swift build -c release`, built on the Studio):
- base: `origin/main` `b29b7b8f5`
- fix round 1: branch at `4f356d29c`
- fix round 2: branch at `5e1fe9760` (audit round-1 fixes). Later commits
  change only post-token failure classification and a window-length guard,
  neither on the success path measured here.

Scripts: `stream_cadence.py` (buyer-observed SSE chunk arrival gaps and
throughput; 256 tokens/row, temperature 0, unique prompts, 3 reps per
concurrency), `stream_semantics.py` / `cancel_probe.py` (greedy parity
digests, stop mid-window, client disconnect mid-window, health after),
`cb-step-lab*.sh` (window drivers).

## Throughput and cadence (means of 3 reps; fix/base ratio)

| run | slots | agg tok/s base → fix (ratio) | decode tok/s sum ratio | gap p50 ms | gap p99 ms | gaps > 50 ms |
|---|---|---|---|---|---|---|
| R1 | 1 | 109.3 → 109.2 (0.999) | 0.999 | 1.2 → 8.7 | 128.7 → 9.5 | 6.3% → 0.0% |
| R1 | 4 | 185.7 → 183.0 (0.985) | 0.992 | 1.4 → 19.3 | 291.3 → 28.3 | 7.0% → 0.8% |
| R1 | 8 | 201.4 → 199.2 (0.989) | 1.004 | 1.7 → 34.6 | 531.3 → 115.7 | 7.4% → 1.6% |
| R2 | 1 | 109.2 → 109.9 (1.006) | 1.007 | 1.1 → 8.7 | 129.2 → 9.5 | 6.3% → 0.0% |
| R2 | 4 | 184.7 → 182.7 (0.989) | 0.989 | 1.4 → 19.2 | 290.7 → 28.7 | 7.0% → 0.8% |
| R2 | 8 | 202.8 → 200.6 (0.989) | 0.998 | 1.8 → 34.6 | 529.3 → 114.3 | 7.2% → 1.4% |

Base delivers 16-token bursts (p50 ~1 ms inside a burst, one ~130/290/530 ms
gap per window at 1/4/8 slots). Fix delivers one token per decode step (p50 =
step time). All fix runs keep >= 98.5% of window-16 aggregate throughput.
The remaining >50 ms gaps at 4/8 slots are prefill of later-arriving rows
(present in base too), not window bursts.

## Semantics (round 2, base and fix identical)

- Greedy parity: four fixed prompts, 160 tokens, at 4 concurrent and 1 at a
  time: identical content digests base vs fix and c4 vs c1.
- Stop mid-window: 4 concurrent "reply OK" requests finish `stop` with 1
  completion token on both.
- Client disconnect after 10 chunks (4 concurrent, and mixed with a live
  row): live row completes with the same digest as base; subsequent requests
  healthy; no `forward_failed` / `blockTableMismatch` / `cleanup_failed` /
  `stream_mismatch` / `invalid_decode_token` lines in the serve log.

Raw: `studio-results-20261002T004124Z.txt`,
`studio-results-20261002T012746Z.txt`, `studio-semantics-20261002.txt`.
