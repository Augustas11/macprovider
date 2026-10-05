# SPEC-048 R015 on the chunked fused baseline, Studio build 26A434

This directory holds a formal R015 run for the Qwen3.6 A3B native-MTP tuple.
The ordinary path uses the chunked fused MLX fork revision
`b181102984a4d1875efbd9e0eab3a7dfd1c012c5` (SPEC-048 0.1.23). The run is on
the designated Studio's current macOS build `26A434`. Every earlier R015
policy binds the retired envelope and build `25E253`.

The frozen byte-exact `policy.json` has SHA-256
`2c8a234462c1d3dcaff16268915e714774bbf3fff0aa944880208e807707e19a`. It was
committed in `67ad742d3` before any measured request and was not modified
afterward. Compared with the 2026-10-03 fused-baseline policy (`de99e85c…`),
only `os_build`, `provider_commit`, `mlx_fork_revision`, and `seed`
(`20261006`) changed. The tuple, matrix, block count, sustained window, and
thresholds are unchanged. Proposal depth stays 1.

**Status: FAIL** (`overall_status: FAIL`, 2026-10-05 22:53–23:53Z). Native MTP
stays default-off. This evidence enables nothing.

## Identity

| Field | Value |
| --- | --- |
| Host | `Mac15,14`, Apple M3 Ultra, 256 GB, macOS 27.0.1 build `26A434`, Swift 6.3.3 (Command Line Tools, no Xcode) |
| Provider | `280f0e95d623353873147e523391e78d71327c5b` (origin/main after #1832), built fresh on the Studio with `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`; resolved fork pin `b1811029…` |
| Lab binary | `macprovider-cli` SHA-256 `b96c5ebc48cfa4e475370bd9ce2505492f6d67e38ded36f10ab08462f38d67b8` |
| `mlx.metallib` | `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf`, the mlx-swift 0.31.4 library reused from prior runs (unchanged mlx-swift pin) |
| Fixture | `q36-a3b-cat`: target `3fed776d…`, MTP `fa01beec…`, tokenizer `87a7830d…` |
| Isolation | Isolated, no coordinator join, lab lock held for the whole window |

The window ran the following in order: `native-mtp-hardware-e2e` (serve path,
PASS), then `native-mtp-bench --phase matrix` (exit 0, 133 records), then
`--phase sustained` (exit 0, 203 records in total). Raw JSONL, logs, and the run
script stay on the lab host under `~/mtp-r015-26a434-20261006/`. Their
SHA-256 values are in `raw-sha256.txt`; the final JSONL is `23d1ad20…`.
`analysis.json` and `analysis.md` are the unmodified output of
`scripts/native_mtp_r015_analyze.py` on that file and policy (exit 1).

## Result

Decode ratio is the ratio of native to ordinary median aggregate decode
throughput. LB and UB are the Holm-corrected bounds, as fractions.

| Cell | Class | Ordinary / native decode tok/s | Decode LB (gate) | TTFT UB (gate) | ITL UB (gate) | Acceptance | Status |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | native-eligible | 110.4 / 127.5 | **+13.5%** (≥ 15%) | +4.5% (≤ 10%) | **+56.3%** (≤ 0) | 0.888 | FAIL |
| s1-p1536-o512 | native-eligible | 93.7 / 107.0 | **+13.6%** | +4.3% | **+53.6%** | 0.855 | FAIL |
| s1-p4096-o128 | native-eligible | 91.1 / 103.7 | **+11.0%** | +5.4% | **+56.6%** | 0.917 | FAIL |
| s1-p4096-o512 | native-eligible | 91.1 / 99.9 | **+10.0%** | +5.2% | **+55.3%** | 0.843 | FAIL |
| s2-p1536-o512 | gated | 121.1 / 120.6 | **-8.2%** (≥ -5%) | +2.8% (≤ 5%) | **+104.0%** (≤ 5%) | n/a | FAIL |
| s8-p1536-o512 + 1830 s sustained | gated | 178.7 / 182.4 | -3.1% | +1.2% | +2.6% | n/a | PASS |

Capacity-rejection UB is 0 in every cell. Parity mismatches, fallbacks, and
errors are 0 in all 202 run records, including s8. The chunked fused envelope
fixed the 10-03 eight-slot parity failure (8 of 10 blocks then).

Gate evidence in the native runs (every hold ended clean, none unresolved):

| Cell | Native admissions | Load-gate downgrades | Depth-zero rounds | Hold episodes | Held to clean finish |
| --- | ---: | ---: | ---: | ---: | ---: |
| s2-p1536-o512 | 10 | 10 | 340 | 10 | 10 |
| s8-p1536-o512 | 10 | 70 | 390 | 10 | 10 |
| s8 sustained (35 blocks) | 35 | 245 | 1428 | 35 | 35 |

Sustained window: 1830 s, 70 runs. Thermal state was nominal at the start and
end, and the minimum available memory fraction was 0.634. Peak physical
footprint was 42.3 GB, which is well inside 256 GB with the 8 GiB margin.

## Diagnosis

- **Native-step overhead caps the one-slot gain.** At s1-p1536-o128, native MTP
  commits about 1.90 tokens per target forward (0.527 forwards per token,
  acceptance 0.89). Each native step (2-token verify plus drafter) takes
  about 15.0 ms at p95, while one fused ordinary decode token takes about
  10.0 ms (p50 14.6 ms vs 9.0 ms). The ratio, 1.90 / 1.62 ≈ 1.17, matches the
  measured decode ratio of 1.16. Against the stock baseline (2026-10-02,
  policy `30934c07…`), ordinary one-slot decode rose from 87 to 110 tok/s.
  Native rose only from 111 to 128. The fused kernel speeds up the 1-token
  ordinary forward more than the native step, so the native gain fell from
  +22–28% to +10–16%.
- **The ITL failure is structural at this emission granularity.** The bench
  times gaps between non-empty streamed content chunks. Ordinary now emits one
  chunk per token, so its p95 gap is one forward. Native emits one chunk per
  verify step, so its p95 gap is one native step, 1.5x to 1.55x as long. While
  native emits accepted tokens as one chunk, the `<= 0` ITL gate cannot pass
  at any acceptance rate. The 2026-10-02 PASS (ITL UB -0.90) is not
  comparable. Its ordinary stream was coalesced (p50 gap 0.05 ms, p95 180 ms),
  so that gate compared different emission patterns.
- **Concurrent live load contaminated the window.** The live Malibu provider
  on the same Studio was not paused (by rule) and served production-shaped
  requests the whole time: one about every 30 s, 1–4k completion tokens,
  about 1 CPU core in `contamination.log`. Isolated dips show up on both arms.
  At s1, these are native 72 and 57 tok/s and ordinary 43 and 79 tok/s blocks.
  At s2, 4 native and 2 ordinary runs have p95 gaps of 25–44 ms against a
  17.3 ms steady state. That noise drives the s2 decode LB (-8.2%) and ITL UB
  (+104%), while the s2 medians are at parity (0.995 decode ratio, 17.3 vs
  17.8 ms). The one-slot verdict does not depend on the contamination. Even
  the clean steady-state blocks give +10% to +17%, under the 15% bar in 3 of
  4 cells, and the native p95 gap is 1.5x to 1.55x the ordinary one in every cell.

## Run history

The frozen policy was used once, with no reruns, exclusions, or partial
cells. No threshold, cell, or field changed after measurement.
