# R015 gated cells re-analysed on end-to-end throughput (#2442)

SPEC-048 0.1.116 changes the throughput hypothesis of a gated R015 cell from
the paired decode-throughput change to the paired end-to-end
committed-throughput change (`aggregate_committed_tps`, native over ordinary,
minus one). The margin (-5%), bootstrap seed and Holm family are unchanged.
Native-eligible cells keep the decode gate, and TTFT is unchanged.

Why: a gated cell's rows arrive 250 ms apart, so its decode window starts at
the earliest first token of either arm. Both arms produce the same tokens and
finish at about the same time, so the decode ratio follows which arm's first
prefill finished first. In the recorded Qwen 27B cells no native round ran
(`mtp_proposed_tokens` 0, every native row held at depth zero), yet the decode
ratio read 1.06 to 1.16.

This directory holds the re-derived analyses for every admitted tuple. The
committed analyzer outputs they re-analyse stay as they are: each is the
record of its own run.

## Re-derived analyses

Produced by `scripts/native_mtp_r015_analyze.py` at the commit that adds this
directory:

| File | SHA-256 | Inputs |
| --- | --- | --- |
| `qwen36-27b/r015-analysis.json` | `db95ec9d6894206a3acfd3652e84fa1f5e818d79dc0ecef58640adc2200c5788` | `../qwen27b-mtp-cap-2026-11-20/qwen36/r015.jsonl` (`edf1349a…`), `r015-policy.json` |
| `qwen38-27b/r015-analysis.json` | `a1dc083ae89b3d67fb3f5da3f09fa378cb6a07ac849cc0ef1cf20ad0e8037d72` | `../qwen27b-mtp-cap-2026-11-20/qwen38/r015.jsonl` (`dada8e99…`), `r015-policy.json` |
| `glm53-flash/prior-analysis.json` | `c0e1e6759af512d547198fa0c28d607015f9663d7073d61bbb9cee4ad2d12f9f` | `docs/research/spec048-r015/glm53-flash-r015-v2/window-20261019T010258Z/r015-glm53.jsonl` (`a0acbd83…`), `../policy.json` |
| `glm53-flash/cap-extension.json` | `3d7c535e4320c8399f8d679bb59c5b8e8ce8ba3d84034f102a90a567985d3a02` | `../glm53-mtp-cap-2026-11-05/cap-extension.json` with `prior_analysis_sha256` set to the re-derived prior; every other field unchanged |
| `glm53-flash/cap-extension-analysis.json` | `9b65ed71e351154f40e7726e153b74df1d191a22dba3f0735266268a25002675` | the record above, `../glm53-mtp-cap-2026-11-05/r015-glm53-p32k.jsonl` and `policy.json` |
| `qwen36-35b-a3b/r015-analysis.json` | `3f93cb7e211404c53f6a0325f08fd2fd292b6cd04f90da46ba23a69da053bbe1` | the 2026-10-21 raw runs (SHA-256 `bb4b4d59e67b34e18772785d295df0aa2260ea5a1e8d5524ff7f40399492607c`, held off-repo as for earlier tuples) and `docs/research/spec048-r015/qwen36-35b-r015-2026-10-21/qualification-policy.json` |

A cap extension needs its prior analysis to equal the current analyzer's
output, so the committed GLM record (`prior_analysis_sha256` `f607170c…`) now
returns `prior_analysis_not_rederived`; the record here binds the re-derived
prior instead.

Reproduce:

```bash
Q=docs/evidence/qwen27b-mtp-cap-2026-11-20
N=docs/evidence/r015-gated-end-to-end-reanalysis-2026-11-20
for m in 36 38; do
  python3 scripts/native_mtp_r015_analyze.py "$Q/qwen$m/r015.jsonl" "$Q/qwen$m/r015-policy.json" \
    | cmp - "$N/qwen$m-27b/r015-analysis.json"
done
R=docs/research/spec048-r015/glm53-flash-r015-v2
E=docs/evidence/glm53-mtp-cap-2026-11-05
python3 scripts/native_mtp_r015_analyze.py "$R/window-20261019T010258Z/r015-glm53.jsonl" "$R/policy.json" \
  | cmp - "$N/glm53-flash/prior-analysis.json"
python3 scripts/native_mtp_r015_analyze.py "$E/r015-glm53-p32k.jsonl" "$E/policy.json" \
  --cap-extension "$N/glm53-flash/cap-extension.json" \
  --prior-policy "$R/policy.json" \
  --prior-runs "$R/window-20261019T010258Z/r015-glm53.jsonl" \
  --prior-analysis "$N/glm53-flash/prior-analysis.json" \
  | cmp - "$N/glm53-flash/cap-extension-analysis.json"
```

The A3B raw runs are not in this repository; with them, the same command form
(`native_mtp_r015_analyze.py <runs> qualification-policy.json`) reproduces the
file. Before the change, the analyzer reproduced each committed analysis byte
for byte from the same inputs, A3B's `analyzer.final.json` included.

## Old and new gated results

Percent change, native over ordinary. "Old" is the committed analysis (decode
throughput); "new" is the re-derived one (end-to-end committed throughput).
LB is the Holm-corrected lower bound. `throughput_delta_ppm` is the
qualified-slots cell's median x 1e6, rounded.

| Record | Cell | Old median / LB | New median / LB | Cell verdict |
| --- | --- | ---: | ---: | --- |
| Qwen3.6-27B, 2026-11-20 | s2-p1536-o512 | +7.82% / +6.61% | +1.05% / +0.35% | PASS -> PASS |
| | s4-p1536-o512 | +0.62% / +0.37% | -2.44% / -2.67% | PASS -> PASS |
| Qwen3.8-27B, 2026-11-20 | s2-p1536-o512 | +6.87% / +5.59% | +0.92% / -0.03% | PASS -> PASS |
| | s4-p1536-o512 | +1.91% / +1.16% | -1.72% / -2.79% | PASS -> PASS |
| GLM-5.3-Flash v2, 2026-10-19 | s2-p1536-o512 | -0.04% / -0.12% | -0.70% / -0.75% | PASS -> PASS |
| | s4-p1536-o512 | -0.29% / -1.07% | -0.63% / -1.26% | PASS -> PASS |
| Qwen3.6-35B-A3B, 2026-10-21 | s2-p1536-o512 | -0.75% / -0.89% | -1.00% / -1.11% | FAIL -> FAIL (TTFT only) |
| | s8-p1536-o512 | +0.65% / +0.38% | +0.50% / +0.23% | PASS -> PASS |
| Qwen3.6-35B-A3B, 2026-10-06 (not admitted) | s2-p1536-o512 | -0.10% / -0.27% | -0.50% / -0.67% | PASS -> PASS |
| | s8-p1536-o512 | +0.14% / -0.21% | +0.03% / -0.39% | PASS -> PASS |

Every analysis keeps its overall verdict. The Qwen 27B, GLM and 2026-10-06 A3B
analyses stay PASS, and the GLM cap extension stays PASS (40 Holm hypotheses,
no failure). The 2026-10-21 A3B analysis stays FAIL on the same single
hypothesis, the s2 p95 TTFT regression that the SPEC-048 #2081 disposition
covers; its throughput hypotheses pass. No other hypothesis's corrected bound or status
changed; every native-eligible cell is byte-identical. The A3B 2026-10-06 raw
runs come from that directory's `raw.tar.gz`.

## Signed `throughput_delta_ppm`

| Tuple | Signed now | Re-derived | Source |
| --- | ---: | ---: | --- |
| `qwen/qwen3.6-27b` | 6221 | -24353 | `qwen36-27b/r015-analysis.json`, s4 |
| `qwen/qwen3.8-27b` | 19105 | -17162 | `qwen38-27b/r015-analysis.json`, s4 |
| `zai-org/glm-5.3-flash` and `-uncensored` | -2899 | -6275 | `glm53-flash/prior-analysis.json`, s4 |
| `qwen/qwen3.6-35b-a3b` | 6533 | 4951 | `qwen36-35b-a3b/r015-analysis.json`, s8 |

Every admitted tuple signs `max_native_active_rows` 1, so no serving decision
reads these values. `ordinary_baseline.aggregate_tps_milli` comes from the
ordinary committed median and does not change.

## Records not re-derived

None of these binds an admitted tuple. For each, the raw runs or the frozen
policy could not be found on the operator Mac: the Qwen 27B 2026-11-04 raw
runs (digests `45f7ebdc…`, `b81f9aa2…`) and the A3B 2026-10-02 raw runs are
not retained there, and the Gemma 4 12B raw runs are kept but their frozen
policies (SHA-256 `572bb187…`, `6dc02612…`) were not copied off the lab Mac. The new gated median equals the committed
`informational_metrics.end_to_end_throughput.median` exactly (same pairs, same
per-block statistic), so it is listed. The Holm-corrected bound and verdict
need the bootstrap over the raw runs and are not recomputed here; the 95%
interval shown is the committed two-sided end-to-end interval, not a gate
bound.

| Record | Cell | Old median / LB | New median | Recorded e2e 95% CI |
| --- | --- | ---: | ---: | ---: |
| Qwen3.6-27B, 2026-11-04 (superseded by 2026-11-20) | s2 | +16.02% / +15.31% | +0.47% | [+0.14, +0.96] |
| | s4 | +6.36% / +5.74% | -0.62% | [-1.08, +0.05] |
| Qwen3.8-27B, 2026-11-04 (superseded by 2026-11-20) | s2 | +13.09% / +12.65% | +0.79% | [+0.52, +1.05] |
| | s4 | +5.64% / +5.10% | -0.20% | [-0.54, +0.04] |
| Gemma 4 12B, 2026-11-16 (not admitted) | s2 | -0.12% / -0.21% | -0.16% | [-0.23, +0.19] |
| | s4 | -0.01% / -0.17% | -0.04% | [-0.15, +0.05] |
| Gemma 4 12B failed run `f6d62fe7e` (FAIL) | s2 | -5.19% / -5.28% (FAIL) | -4.63% | [-4.70, -4.30] |
| | s4 | -4.18% / -4.32% | -3.86% | [-3.95, -3.68] |
| Qwen3.6-35B-A3B, 2026-10-02 formal | s2 | -0.33% / -0.47% | -0.66% | [-0.89, -0.48] |
| | s8 | +0.00% / -0.64% | -0.45% | [-0.58, -0.11] |
| Qwen3.6-35B-A3B, 2026-10-02 superseded policy `525ac686` | s2 | -0.27% / -0.66% | -0.77% | [-1.01, -0.20] |
| | s8 | -0.26% / -2.28% | -0.10% | [-0.86, -0.04] |

The GLM-5.3-Flash 1.8.256 run
(`docs/research/spec048-r015/glm53-flash-v1.8.256/`) has only its policy in
the repository, so it has no analysis to re-read.

Related: #2442, #2410
