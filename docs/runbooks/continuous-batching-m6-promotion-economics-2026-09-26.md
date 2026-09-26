# M6: continuous-batching promotion economics (2026-09-26)

## Scope and inputs

This is deterministic offline modeled evidence for the #1646 campaign. It
converts the already re-measured final Qwen3.6 matrix into a provider-earnings
proxy per wall-clock hour. It does not reconstruct ledger settlement, call a
provider or coordinator, change the catalog rate card, or alter live
configuration.

- Matrix: [`data/cb-perf-2026-09-25/clean-final/matrix.jsonl`](data/cb-perf-2026-09-25/clean-final/matrix.jsonl)
- Matrix SHA-256: `f1df7ccbcaf1a1602f41f5d0c802d3ea77c253ecf94fe0740e721ff4b6689d2b`
- Catalog rate card: `phase3-binary/catalog/autotune/rate-card.json`
- Rate-card file SHA-256: `20d62a3d8c934560566ca94a861a6c7a203472e38c7f7d9db85959ae5d661173`
- Rate-card version: `bab7acfb9d1b40b7bbfc3da90bb40689ab8e7c7f6c53065c07143c1e5ed32bd4`
- Exact selected row: `qwen3.6-27b`
- Row economics: prompt `240000` credits/Mtok, completion `2160000`
  credits/Mtok, cache-hit prompt `60000` credits/Mtok,
  `global_multiplier_ppm=1000000`, `provider_share_bps=9000`
- USD peg: 1,000,000 credits = USD 1

Reproduction command:

```bash
python3 scripts/measure_cb_promotion_economics.py \
  docs/runbooks/data/cb-perf-2026-09-25/clean-final/matrix.jsonl \
  phase3-binary/catalog/autotune/rate-card.json \
  --rate-card-row qwen3.6-27b
```

The calculator validates the rate card's projection-hash version and
release-global multiplier/share, but it does **not** verify a rate-card
signature. It rejects malformed or ambiguous evidence and emits stable
canonical JSON with exact SHA-256 hashes of both input byte streams.

`perf_matrix.py` records `prompt_tokens` as the median across requests, not a
sum. It records aggregate completion tokens, but it does not retain the
individual prompt or completion count for each request. The calculator
therefore models prompt volume as `median_prompt_tokens_per_request × rows` and
uses the aggregate completion count. It applies the published prompt and
completion rates, global multiplier, and provider share using exact rational
`Fraction` arithmetic internally. It applies round-half-even only when
formatting fixed-width decimal report values. This avoids inventing aggregate
ledger rounding in the earnings/hour comparison.

SPEC-005 §5.3 instead rounds gross credits and then provider credits separately
for every request. Because the per-request token counts were not retained, the
exact sum of those request-level rounded credits cannot be reconstructed for
observations with more than one row. Every earnings, credit, USD/hour, and
earnings-ratio value below is consequently a deterministic modeled proxy, not
an exact settled-credit claim. Batched observations are compared only with the
serial control having the same `L_target`. The model applies no cache discount
because these were full-prompt observations.

## Deterministic modeled end-to-end result

Modeled USD/hour is the unrounded provider-share proxy for the whole
observation, divided by wall time and scaled to one hour. The modeled earnings
and worst-TTFT ratios use the matching serial row as 1.0×.

| Prompt target | Mode × rows | Median prompt/request | Modeled prompt total | Aggregate completion | Wall s | Modeled provider credits | Modeled provider USD/hour | Modeled earnings vs serial | Worst TTFT s | Worst TTFT vs serial |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 512 | serial × 1 | 551 | 551 | 128 | 5.3 | 367.848 | 0.249859 | 1.000000× | 1.92 | 1.000000× |
| 512 | batched × 1 | 549 | 549 | 128 | 5.7 | 367.416 | 0.232052 | 0.928733× | 2.39 | 1.244792× |
| 512 | batched × 2 | 550 | 1,100 | 256 | 8.9 | 735.264 | 0.297410 | 1.190312× | 4.98 | 2.593750× |
| 512 | batched × 4 | 550 | 2,200 | 512 | 16.1 | 1,470.528 | 0.328814 | 1.315997× | 10.12 | 5.270833× |
| 512 | batched × 8 | 551 | 4,408 | 1,024 | 30.7 | 2,942.784 | 0.345082 | 1.381107× | 22.75 | 11.848958× |
| 1,536 | serial × 1 | 1,668 | 1,668 | 128 | 8.9 | 609.120 | 0.246386 | 1.000000× | 5.44 | 1.000000× |
| 1,536 | batched × 1 | 1,671 | 1,671 | 128 | 9.4 | 609.768 | 0.233528 | 0.947816× | 6.01 | 1.104779× |
| 1,536 | batched × 2 | 1,668.5 | 3,337 | 256 | 16.6 | 1,218.456 | 0.264243 | 1.072479× | 12.67 | 2.329044× |
| 1,536 | batched × 4 | 1,669 | 6,676 | 512 | 32.1 | 2,437.344 | 0.273347 | 1.109428× | 27.25 | 5.009191× |
| 1,536 | batched × 8 | 1,669.5 | 13,356 | 1,024 | 62.4 | 4,875.552 | 0.281282 | 1.141633× | 56.82 | 10.444853× |
| 4,096 | serial × 1 | 4,421 | 4,421 | 128 | 17.7 | 1,203.768 | 0.244834 | 1.000000× | 14.25 | 1.000000× |
| 4,096 | batched × 1 | 4,421 | 4,421 | 128 | 18.4 | 1,203.768 | 0.235520 | 0.961957× | 14.97 | 1.050526× |
| 4,096 | batched × 2 | 4,424 | 8,848 | 256 | 36.0 | 2,408.832 | 0.240883 | 0.983863× | 32.25 | 2.263158× |
| 4,096 | batched × 4 | 4,424.5 | 17,698 | 512 | 70.5 | 4,818.096 | 0.246030 | 1.004886× | 67.07 | 4.706667× |
| 4,096 | batched × 8 | 4,422.5 | 35,380 | 1,024 | 140.0 | 9,632.736 | 0.247699 | 1.011701× | 136.15 | 9.554386× |

## Interpretation and Gate A5 decision

The decode-only ceiling and end-to-end earnings answer different questions.
M3 showed that steady-state paged decode at batching depth clears its overhead
ceiling and reaches materially higher aggregate decode throughput. This M6
calculation includes prompt prefill, scheduler behavior, completion decode, and
the entire recorded wall time. Long prompts are prefill-bound, so the
decode-only gain does not translate directly into modeled provider
earnings/hour.

The current end-to-end modeled economics are mixed and do **not** satisfy Gate
A5 promotion:

- 512-token prompts improve modeled provider earnings/hour at batching depth: +19.0%
  at two rows, +31.6% at four, and +38.1% at eight. Worst TTFT grows to 11.85×
  serial at eight rows.
- 1.5k-token modeled gains are modest: +7.2%, +10.9%, and +14.2% at two, four, and
  eight rows. Worst TTFT reaches 10.44× serial.
- 4k-token modeled economics are essentially flat: -1.6%, +0.5%, and +1.2% at two,
  four, and eight rows, while worst TTFT reaches 9.55× serial.
- A one-row request on the batched path loses modeled earnings/hour at every prompt
  length relative to serial.

These measurements do not define or invent a universal materiality threshold.
They show the measured tradeoff for this exact tuple and rate-card row. Gate A5
also lacks a real predeclared, signed OPoI window and its required independent
review/custody evidence. Therefore M6 cannot authorize
`continuous_batching: on`.

Keep the existing canary/off boundaries unchanged. This evidence makes no live,
configuration, catalog, or rate-card change.

## Mac Studio reproduction

The final calculator, tests, matrix, and rate card were copied byte-for-byte to
an isolated directory on the Mac Studio and run there without pausing or
contacting the live provider.

- Host: macOS 26.4.1 (`25E253`), Python 3.9.6
- Test result: 20 passed, 0 failed
- Two independent CLI runs: byte-identical
- Report size: 8,508 bytes
- Report SHA-256: `5219ada184cc9fb59b795893019604620910429d0bdd635a05443bc5d39f4116`
- Matrix and rate-card hashes matched the inputs recorded above
- Live impact: none; no provider pause, restart, configuration change, or
  coordinator interaction
