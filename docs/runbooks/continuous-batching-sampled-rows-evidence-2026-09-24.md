# Sampled batched rows (SPEC-038 AC-6b): Studio evidence, 2026-09-24 (#1646)

Before this change, continuous batching admitted only greedy requests
(`temperature 0`, `top_p 1`). Ordinary sampled buyer traffic always
serial-routed. With 8 advertised seats it then queued behind the serial path:
an AntSeed stress test on live v1.8.192 saw first-token waits up to 140 s.

This change lets sampled rows share the batched forward. Each row samples with
the serial path's own sampler (`GenerateParameters(temperature:topP:).sampler()`)
on its own logits, seeded from its request ID and step (SPEC-038 v0.2.6 FR-CB6,
AC-6b).

Raw data: [`data/cb-sampling-2026-09-24/`](data/cb-sampling-2026-09-24/).

## Setup

- **Hardware and runtime:** Mac Studio M3 Ultra 256 GB. Lab build `fe78aa60`
  from `campaign/1646-cb-sampling` @ `cafcdb80`.
- **Serve:** `--no-join` on :18080, running next to the live v1.8.192 provider
  on :8080, which was not touched. Qwen3.6-27B, context 32768, `canary`,
  8 seats, `mlx_cache_limit_mb: 2048`, accepted tuple with metallib
  `84e48718…` and kernel `macprovider_paged_kv_gather_v1`.
- **Startup:** parity established on 16 layers, isolation proven, CB `active`,
  paged KV `attached`.
- **Routing:** serial = no `X-Request-ID`; batched = fresh `X-Request-ID`.

## Throughput: sampled traffic (`sampling.json`)

The workload was 8 concurrent requests at temperature 0.7 and top_p 0.95,
128 max tokens, 3 repeats.

| Path | Aggregate tok/s (median) | Runs |
| --- | --- | --- |
| Serial | 32.9 | 32.5 / 32.9 / 33.0 |
| Batched | **50.0** | 47.3 / 50.0 / 51.2 |

That is **1.52×**, on traffic that could not batch before. Of the 37 rows the
scheduler admitted, none had a forward or prefill failure. The footprint
stayed at 17–19 GB.

## Isolation: 8 concurrent sampled rows

The rows used temperature 0.8 and top_p 0.95, one distinct topic each. All 8
finished with `stop`, and none showed a leak signal: no row began with another
row's serial prefix. Seven of 8 passed the naive keyword topic check; the one
that didn't was "the moon landing", whose reply need not contain the word
"landing".

## Correctness against the serial sampler (`tie.jsonl`, `tie2.jsonl`)

The first check compared a near-deterministic sampled request
(`temperature 0.7, top_p 0.001`) with greedy serial output. That check turned
out to be wrong: **the serial path's own tiny-top_p output already differs from
serial greedy** (rows 3 and 4, at chars 193 and 139). Where two top tokens have
exactly equal bf16 logits, argmax keeps the lower token ID, while the top_p
filter keeps whichever token sorts last. A tiny temperature picks between them
at random. So tiny top_p is not greedy.

The meaningful comparisons are these. Both are deterministic across 2 repeats.

| Comparison | Divergence point per row (chars; `null` = identical) |
| --- | --- |
| serial top_p vs serial greedy | null, null, 193, 139 |
| batched top_p, **lone row**, vs serial top_p | null, 56, 21, 257 |
| batched top_p, **4 concurrent rows**, vs serial top_p (rep 0) | null, 56, 21, 257 |
| batched top_p, 4 concurrent rows, vs serial top_p (rep 1) | null, 56, 21, 257 |
| batched greedy, 4 concurrent rows, vs serial greedy (reference) | null, null, 21, null |

- **Neighbour independence (isolation).** A request produces the same output
  as a lone row and among 4 concurrent rows, in every repeat. Its neighbours
  do not affect it.
- **Tolerance only.** Where batched differs from serial, it is at positions
  where the batched forward's logits differ by accumulation order. Row 3
  diverges at char 21 under greedy too. The other rows diverge at near-tie
  positions. This is the FR-CB6 numerical tolerance; greedy batching already
  lives with it.
- **Algorithm equality.** On identical logits, the batched sampler's token
  equals the serial sampler's. This is pinned by `ContinuousBatchRowSamplerTests`,
  which is Metal-gated and skips on hosts without the MLX metallib.

## Not claimed

- Token-identical output against a particular serial sampled run. The serial
  path is not seeded, so no such run is reproducible.
- Tool-bearing, structured-output, `logit_bias` or logprobs requests. These
  still serial-route.
- Follow-up turns with cached prompt tokens (M4).
