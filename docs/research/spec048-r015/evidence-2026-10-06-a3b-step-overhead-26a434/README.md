# SPEC-048 R015 on the step-overhead fork candidate, Studio build 26A434

This directory holds a formal R015 run for the Qwen3.6 A3B native-MTP tuple on
the step-overhead fork candidate `ca8c384c4fb6bc7d2fbb7c70a18c34b935701805`
(SPEC-048 0.1.24, review pending). The candidate adds a single-pass
checkpointed GDN verify kernel and skips the all-true SSM mask for unpadded
packed verification. The provider folds the drafter seed conversion into the
round's staged evaluation. Ordinary decode code is unchanged from the
2026-10-06 run (`../evidence-2026-10-06-a3b-fused-26a434/`).

The frozen byte-exact `policy.json` has SHA-256
`0c1b42bec091ab762ba56c9c8d460b9cf2ddc74950f9d98aa59d0af7b290aa87`. It was
committed in `82f5c1411` before any measured request and was not modified
afterward. Compared with the 2026-10-06 policy (`2c8a2344…`), only
`provider_commit` and `mlx_fork_revision` changed. The seed (`20261006`), so
the preregistered run order, the tuple, matrix, block count, sustained window,
and thresholds are unchanged. Proposal depth stays 1.

**Status: FAIL** (`overall_status: FAIL`, 2026-10-06 05:12–06:13Z). Native MTP
stays default-off. This evidence enables nothing.

## Identity

| Field | Value |
| --- | --- |
| Host | `Mac15,14`, Apple M3 Ultra, 256 GB, macOS build `26A434`, Swift 6.3.3 (Command Line Tools, no Xcode) |
| Provider | `006a34ba845f3a5b2d306eb77356f0d5f6e59a07` (PR #1862), built fresh on the Studio with `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`; resolved fork pin `ca8c384c…` |
| Lab binary | `macprovider-cli` SHA-256 `3d5a1ed5df7be6e39f95897e977d7a97fe1dfaefae5beccd1106822825c30364` |
| `mlx.metallib` | `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf` (mlx-swift 0.31.4, unchanged) |
| Fixture | `q36-a3b-cat`: target `3fed776d…`, MTP `fa01beec…`, tokenizer `87a7830d…` |
| Isolation | Isolated, no coordinator join, lab lock held for the whole window |

Before the window, the fork's executable harnesses passed on the Studio
(`fork-harness/`): the fused-MoE harness from the #1832 qualification, 133/133,
and a GDN harness, 96/96. The GDN harness checks that the checkpointed
recurrence is bit-identical to the split one (outputs, checkpoint, and final
state) at every split, masked and unmasked, including the A3B head layout at
verify widths 2, 3, and 7 and batch 1, 2, and 8.

The window ran the following in order: `native-mtp-hardware-e2e` (serve path,
PASS, so 0 ordinary/native mismatches), then `native-mtp-bench --phase matrix`
(exit 0, 133 records), then `--phase sustained` (exit 0, 201 records in
total). Raw JSONL, logs, and the run script stay on the lab host under
`~/mtp-r015-step-overhead-26a434-20261006/`. Their SHA-256 values are in
`raw-sha256.txt`; the final JSONL is `72e1e5bb…`. `analysis.json` and
`analysis.md` are the unmodified output of `scripts/native_mtp_r015_analyze.py`
on that file and policy (exit 1).

## Result against 2026-10-06

Corrected bounds are Holm-corrected, as fractions of the ordinary arm. Bold
marks a failed gate.

| Cell | Gate | 10-06 (`2c8a2344`) | This run | Threshold |
| --- | --- | ---: | ---: | ---: |
| s1-p1536-o128 | decode LB | **+13.5%** | **-0.6%** | ≥ +15% |
| | TTFT p95 UB | +4.5% | +4.3% | ≤ +10% |
| | ITL p95 UB | **+56.3%** | **+38.2%** | ≤ 0 |
| s1-p1536-o512 | decode LB | **+13.6%** | +27.6% | ≥ +15% |
| | TTFT p95 UB | +4.3% | +4.4% | ≤ +10% |
| | ITL p95 UB | **+53.6%** | **+37.2%** | ≤ 0 |
| s1-p4096-o128 | decode LB | **+11.0%** | +25.3% | ≥ +15% |
| | TTFT p95 UB | +5.4% | +5.4% | ≤ +10% |
| | ITL p95 UB | **+56.6%** | **+40.3%** | ≤ 0 |
| s1-p4096-o512 | decode LB | **+10.0%** | **+13.3%** | ≥ +15% |
| | TTFT p95 UB | +5.2% | +6.5% | ≤ +10% |
| | ITL p95 UB | **+55.3%** | **+41.9%** | ≤ 0 |
| s2-p1536-o512 (gated) | decode LB | **-8.2%** | **-8.6%** | ≥ -5% |
| | TTFT p95 UB | +2.8% | +4.0% | ≤ +5% |
| | ITL p95 UB | **+104.0%** | **+108.3%** | ≤ +5% |
| s8-p1536-o512 (gated) + sustained | decode LB | -3.1% | **-5.9%** | ≥ -5% |
| | TTFT p95 UB | +1.2% | **+7.7%** | ≤ +5% |
| | ITL p95 UB | +2.6% | **+40.2%** | ≤ +5% |

Capacity-rejection UB is 0 in every cell. Parity mismatches, fallbacks, and
errors are 0 in all 200 run records. Every cell fails, including s8, which
passed on 10-06.

Medians (decode tok/s, inter-token p95 ms):

| Cell | Ordinary decode 10-06 / now | Native decode 10-06 / now | Native ITL p95 10-06 / now | Ordinary ITL p95 10-06 / now | Acceptance | Tokens per target forward |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| s1-p1536-o128 | 110.4 / 86.5 | 127.5 / 113.0 | 14.98 / 16.78 | 9.99 / 12.24 | 0.888 / 0.888 | 1.90 / 1.90 |
| s1-p1536-o512 | 93.7 / 86.0 | 107.0 / 111.2 | 17.50 / 16.80 | 11.45 / 12.37 | 0.855 / 0.855 | 1.86 / 1.86 |
| s1-p4096-o128 | 91.1 / 84.4 | 103.7 / 108.1 | 18.64 / 17.94 | 12.05 / 12.96 | 0.917 / 0.917 | 1.92 / 1.92 |
| s1-p4096-o512 | 91.1 / 84.1 | 99.9 / 103.6 | 18.61 / 18.00 | 12.01 / 12.91 | 0.843 / 0.843 | 1.85 / 1.85 |
| s2-p1536-o512 | 121.1 / 112.2 | 120.6 / 111.8 | 17.83 / 19.38 | 17.32 / 19.12 | n/a | n/a |
| s8-p1536-o512 | 178.7 / 174.3 | 182.4 / 168.1 | 45.21 / 64.74 | 44.57 / 46.88 | n/a | n/a |

Acceptance and tokens per target forward are identical to 10-06 in every
one-slot cell, as expected for bit-identical verification.

Gate evidence in the native runs (every hold ended clean, none unresolved):

| Cell | Native admissions | Load-gate downgrades | Depth-zero rounds | Hold episodes | Held to clean finish |
| --- | ---: | ---: | ---: | ---: | ---: |
| s2-p1536-o512 | 11 | 11 | 374 | 11 | 11 |
| s8-p1536-o512 | 11 | 77 | 433 | 11 | 11 |
| s8 sustained (34 blocks) | 34 | 238 | 1364 | 34 | 34 |

(Counts include the warmup run.) Sustained window: 1852 s, 68 runs. Thermal
state was nominal at the start and end. The minimum available memory fraction
was 0.585. Peak physical footprint was 43.2 GB.

## Contamination and the same-window control

The live Malibu provider on the same Studio was not paused (by rule). The
antseed seller relay kept it serving the whole time: GPU utilization was 96–100%
for 20 minutes before the window, and sampled GPU utilization in
`contamination.log` has a median of 99% (that figure includes the bench). The
live process's CPU distribution matches 10-06 (mostly 70–110%). Steady-state
gaps on both arms were slower than on 10-06: ordinary one-slot p95 was 12.2 ms,
not 10.0 ms. Isolated contaminated blocks show up on both arms. Examples are
native s1-p1536-o128 blocks 1 and 5 (85 and 75 tok/s, p95 gap 46–47 ms) and
ordinary s1-p4096-o512 blocks 0–2 (73–76 tok/s, p95 gap 32–33 ms).

To separate code from load, an exploratory control (not a gate; exploratory
policy schema, which the R015 analyzer refuses) ran 06:43–07:17Z, under the
same lab lock as the window. It alternated the 10-06 binary (`b96c5ebc…`, `280f0e95d`,
`b1811029`) and this binary in the order old, new, new, old. Each run covered
s1 and s8 at p1536/o512 with 5 blocks, for 10 blocks per binary per arm.
Medians:

| Cell, arm | 10-06 binary | This binary |
| --- | ---: | ---: |
| s1 ordinary decode tok/s, gap p50 | 86.1, 11.55 ms | 86.8, 11.53 ms |
| s1 native decode tok/s, gap p50 | 99.4, 18.18 ms | 111.0, 16.15 ms |
| s8 ordinary decode tok/s, gap p95 | 170.6, 47.1 ms | 169.7, 50.7 ms |
| s8 native decode tok/s, gap p95 | 174.2, 48.1 ms | 173.0, 48.2 ms |

Parity mismatches, errors, and fallbacks were 0 in all 96 control run records
(80 measured, 16 warmup). Raw files and hashes are under
`control/` in `raw-sha256.txt`.

## Diagnosis

- **The step-overhead cut works.** Under identical load, a native step fell
  from 18.2 ms to 16.2 ms (-2.0 ms, -11%). One-slot native decode rose 11.7%,
  and the native/ordinary ratio went from 1.15 to 1.28. In the formal run, the
  median decode ratio is 1.24–1.31 in every one-slot cell, against 1.11–1.16 on
  10-06. Ordinary decode is unchanged by the code (86.1 vs 86.8 tok/s). The
  lower absolute numbers than 10-06 are load, not code.
- **One-slot throughput is close but fails in 2 of 4 cells.** s1-p1536-o512
  (+27.6%) and s1-p4096-o128 (+25.3%) pass. s1-p4096-o512 misses at +13.3%: its
  median ratio is 1.241, and three ordinary blocks inflated by load widen the
  interval. s1-p1536-o128 misses at -0.6%: two of ten native blocks hit live
  bursts (ratios 0.99 and 0.86), and with 10 blocks the Holm-corrected
  bootstrap bound reaches them. The other eight blocks are at 1.29–1.37.
- **The ITL gate is still structural.** Native emits one chunk per verify
  step, so its p95 gap is one native step (16.8–18.0 ms) against one ordinary
  token (12.2–13.0 ms). The upper bound improved from +54..57% to +37..42%, but
  the `<= 0` gate cannot pass at any acceptance rate while native emits
  accepted tokens as one chunk (same finding as 10-06).
- **The gated cells fail on load noise, not code.** s2 medians are at parity
  (decode ratio 0.996, gaps 19.4 vs 19.1 ms). Its LB and ITL UB come from 3
  native and 2 ordinary blocks with live-burst gaps of 30–44 ms, as on 10-06.
  At s8, both arms show a bimodal p95 gap (about 47 ms, or 54–66 ms during live
  bursts). In the formal matrix, more native blocks happened to land on bursts
  (7 of 10, against 2 of 10 ordinary). The same-window control shows no
  eight-slot difference between the binaries (native p95 48.1 vs 48.2 ms,
  decode 174.2 vs 173.0 tok/s), and the change only removes work from native
  verify rounds (an extra kernel pass, a mask, and a GPU wait). The s8
  flip from PASS to FAIL is therefore attributed to heavier live contamination
  in this window, not a regression. That attribution rests on an exploratory
  control and does not change the frozen verdict.

## Run history

The frozen policy was used once, with no reruns, exclusions, or partial
cells. No threshold, cell, or field changed after measurement. The first
control attempt was refused by the bench before any request ran because its
exploratory policy had no matrix cell for `sustained_cell_id`. The policy was
corrected (adding s8), and the control ran once.
