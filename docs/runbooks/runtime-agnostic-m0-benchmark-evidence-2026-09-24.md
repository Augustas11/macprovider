# #1690 M0: llama-server vs native MLX benchmark evidence (2026-09-24)

This is premise measurement M0 for #1690: does an external runtime earn a place next to native MLX? **Verdict: the premise fails for now.** Throughput arm (a) fails, and coverage arm (b) has no evidence in 30 days of production request logs. Under the plan's kill criterion, the external-runtime earning path (M4-M6) is on hold until 2026-10-24 for evidenced (b) demand. M1 (pool activation) and M2 (buyer-correct loopback adapter) stand on their own.

## Setup

| Item | Value |
|---|---|
| Hardware | Mac Studio M3 Ultra, 256 GB, macOS 26.4.1 |
| Catalog key | `qwen/qwen3.6-27b` (dense), the Studio's live key |
| Native | `mlx-community/Qwen3.6-27B-4bit` snapshot `c000ac2c`, provider CLI built from the #1719 branch, sha256 `b9a6c366…a3e5` |
| External | llama.cpp `llama-server` b11149 (`d2e54583c`), `unsloth/Qwen3.6-27B-GGUF` Q4_K_M, sha256 `5ed60d0a…92a0` (matches the HF LFS oid), `-np 8 -fa on --load-mode none` |
| Workload | Identical token sequences on both sides (shared corpus, same extension rule), prompt 1024, forced decode 256 (`ignore_eos`), temperature 0, no prompt cache, 1 warmup + n=5 per level |
| Isolation | Throughput runs: the live :8080 provider was operator-paused (see "Process notes"). Perplexity: unpaused, because quality is contention-independent. |
| Harness | `macprovider-cli msb-loopback` / `msb-throughput` / `msb-perplexity`, `phase3-binary/scripts/bench-1690-loopback-vs-native.sh` |

## Throughput and TTFT

The native baseline is **production serial decode**. That is what buyers get on this key: continuous batching (CB) for Qwen3.6 was not live at run time.

| Concurrency | Native serial aggregate tok/s | llama-server aggregate tok/s | llama / native | Native TTFT p50 | llama-server TTFT p50 / p95 |
|---|---|---|---|---|---|
| c=1 | 37.9 | 30.4 | 0.80x | 3.34 s (measured) | 3.47 / 3.47 s |
| c=4 | 37.9 (queued) | 32.2 | 0.85x | ≈18.5 s (derived) | 13.85 / 14.77 s |
| c=8 | 37.9 (queued) | 26.5 | 0.70x | ≈38.7 s (derived) | 28.67 / 31.69 s |

- **Run-to-run variation:** llama-server aggregate CV 0.8 / 2.7 / 3.9%; native serial CV ≤1.2%.
- **Derived native queued TTFT:** a burst of c simultaneous requests served serially. Per-request service time is 3.34 s + 256/37.9 s ≈ 10.1 s, so request k's TTFT is 3.34 + 10.1·k s. This is not measured, because measuring it needs the live provider paused again.
- **Peak phys footprint:** llama-server 26.9 GB; native serial ≈38.3 GB (the native value is taken from the rows=2 run and includes batched-harness state).
- **Excluded as invalid:** the native "contiguous batched" figures from the same runs (61.9 / 71.5 / 80.0 tok/s at rows 2/4/8). They come from the `msb-throughput --engine contiguous` lab loop with `MLX.compile` on. That is not a serving path, it predates the compiled frozen-offset fix (#1716), and the harness has no output-content check.

**Reading:**
- llama-server never beats native serial on aggregate throughput; it reaches 0.70-0.85x, far from the premise's ≥1.5x.
- Its only edge is TTFT under bursts, because it interleaves requests while native serial queues them. That edge applies only while native serves serially. v1.8.192 (#1646) turns on a Qwen3.6 CB canary at 8 seats on this Studio, and native CB should close that gap. Re-measure there before relying on it.

## Perplexity (wikitext-2 raw test, ctx 512, 150 chunks, llama-perplexity chunking)

| Runtime | PPL |
|---|---|
| llama.cpp Q4_K_M | 6.618 ± 0.084 |
| Native MLX 4-bit (affine g64) | 6.747 |

- Both sides tokenize the text to 297,193 tokens and split it into the same 580 chunks, so tokenization is consistent. 150 chunks keep GPU time short next to the live provider.
- Native is ~2% worse. That fits Q4_K_M's higher bits per weight; it is a quant difference, not a runtime difference.

## Coverage arm (b): production demand

Source: 30 days of production `request_log` (Pearl coordinator), unserved rows only (no provider, or status ≥400):
- Every unserved request is for a model native MLX already serves: Llama-3.2-3B, Qwen3-Coder-30B-A3B, Qwen3-8B, Qwen3.6-27B.
- The traffic comes from 1-3 accounts each.
- The failures are capacity or availability failures: 503, `queue_full`, 5xx.

There is no model that buyers asked for and native cannot run. The demand signal says "more native capacity", not "external runtimes".

## Verdict and next steps

- **(a) fails.** (b) has no evidence. M4-M6 are on hold until 2026-10-24. Before then, only evidenced (b) demand reopens them: ≥100 unserved requests for a native-unservable model, or a written buyer commitment. If (b) does appear, re-measure (a) against native CB.
- **#1719 freezes at M0 harness + M1 code + M2 adapter.** The M3 SPEC bundle (audited to 0 C/H/M over 4 rounds) stays parked on a branch and is not merged without its implementation.

## Process notes

- Attempt 1: the provider refused the pause (`drain_timeout`, 30 s drain window). Attempt 2: llama-server rejected `--no-mmap`, which b11149 renamed to `--load-mode none`. Attempt 3 is the run reported above.
- The live provider was operator-paused during attempts 2 and 3, about 05:03-05:20Z and 05:31-05:45Z. Coordinator `request_log` shows no Qwen3.6 buyer requests in those windows. The operator did not explicitly approve these pauses. The runner now never pauses unless told to, and live-provider actions need per-action approval.
- Raw results on the Studio: `/Users/a1/bench-1690/results/20260924T053142Z`, `/Users/a1/bench-1690/results/ppl-20260924T103352Z`.
