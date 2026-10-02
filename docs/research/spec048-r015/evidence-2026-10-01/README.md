# SPEC-048 R015 exploratory evidence, 2026-10-01

Native MTP (#1770, PR #1820) measured on the Studio. These are exploratory
runs, not the formal frozen R015 run: every policy uses the schema
`macprovider.native-mtp-exploratory-policy.v1` and every analysis reports
`EXPLORATORY_NO_VERDICT`. Native MTP stays default-off.

Common setup: Apple M3 Ultra, 256 GB (Mac15,14), seed 20261001, 10
counterbalanced paired blocks per cell, proposal depth 1, paired-block
bootstrap with Holm correction. Raw jsonl and logs are not included; only
`policy*.json` and `analysis*.json/.md` are kept. Policies pin the target,
MTP and tokenizer SHA-256 values.

Provider commits: `eca9d673b` (27B bound 1, A3B bound 2) and `f8a3087b5`
(A3B bound 1). The superseded full-matrix policy commit is `2e6214a3f`.

Columns: decode ratio = native / baseline median decode throughput; LB/UB are
Holm-corrected bounds (fractions, not percent). Acceptance is the draft
acceptance rate. Cells not listed were not run (0/10 paired blocks).

## 27B (qwen/qwen3.6-27b), max_native_active_rows 1 (`27b-bound1/`)

| Cell | Decode ratio | Decode LB | TTFT UB | ITL UB | Acceptance | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | 1.337 | 0.306 | 0.035 | -0.910 | 0.881 | PASS |
| s1-p1536-o512 | 1.330 | 0.317 | 0.034 | -0.911 | 0.879 | PASS |
| s1-p4096-o128 | 1.310 | 0.297 | 0.040 | -0.906 | 0.881 | PASS |
| s1-p4096-o512 | 1.303 | 0.284 | 0.036 | -0.909 | 0.875 | PASS |
| s1-p8192-o128 | 1.240 | 0.233 | 0.036 | -0.897 | 0.896 | PASS |
| s1-p8192-o512 | 1.227 | 0.221 | 0.039 | -0.904 | 0.865 | PASS |
| s2-p1536-o512 (gated) | 0.998 | -0.007 | 0.021 | 0.008 | n/a | PASS |

All six s1 cells pass. Other s2/s8 cells were not run.

## A3B (qwen/qwen3.6-35b-a3b), max_native_active_rows 2 (`a3b-bound2/`)

| Cell | Decode ratio | Decode LB | TTFT UB | ITL UB | Acceptance | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | 1.258 | 0.239 | 0.049 | -0.902 | 0.881 | PASS |
| s1-p1536-o512 | 1.255 | 0.238 | 0.049 | -0.904 | 0.851 | PASS |
| s1-p4096-o128 | 1.275 | 0.252 | 0.056 | -0.900 | 0.931 | PASS |
| s1-p4096-o512 | 1.216 | 0.197 | 0.056 | -0.900 | 0.850 | PASS |
| s1-p8192-o128 | 1.187 | 0.171 | 0.061 | -0.893 | 0.924 | PASS |
| s1-p8192-o512 | 1.141 | 0.126 | 0.064 | -0.893 | 0.851 | FAIL (decode LB < 0.15) |
| s2-p1536-o512 | 1.133 | 0.096 | -0.082 | -0.894 | 0.860 | FAIL (decode LB) |
| s2-p4096-o512 | 1.090 | 0.078 | 0.014 | -0.890 | 0.867 | FAIL (decode LB) |
| s8-p1536-o512 (gated) | 0.978 | -0.046 | 0.078 | 0.004 | 1.000 | FAIL (TTFT UB +7.8% > +5%) |

Bound 2 fails the gated s8 cell on TTFT (+7.8%) and the s2 cells on decode LB.

## A3B, max_native_active_rows 1 (`a3b-bound1/`)

Policy `policy.json` (10 blocks) and `policy-sustained.json` (30-minute
sustained run on s8-p1536-o512). Only the cells below were run.

| Cell | Decode ratio | Decode LB | TTFT UB | ITL UB | Acceptance | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o512 | 1.258 | 0.245 | 0.051 | -0.904 | 0.851 | PASS |
| s1-p8192-o512 | 1.139 | 0.123 | 0.061 | -0.892 | 0.851 | FAIL (decode LB 0.123 < 0.15) |
| s8-p1536-o512 (gated) | 0.998 | -0.023 | 0.011 | 0.010 | n/a | no metric failure; cell status FAIL in this analysis, see note |
| s8-p1536-o512 sustained (gated) | 1.006 | -0.023 | 0.022 | 0.008 | n/a | PASS |

Note: the 10-block s8 cell lists no metric or hard failures and every gated
bound is inside its threshold (decode LB >= -0.05, TTFT UB <= 0.05, ITL UB <=
0.05). The analysis tool still labels the cell FAIL; the cell JSON is kept
unmodified for review.

Sustained run: 1835 s, thermal state nominal throughout, minimum available
memory fraction 0.671, peak phys footprint 43.5 GB, 343 load-gate downgrades.

## Decision

- A3B first tuple: `max_native_active_rows` 1 with `maximumPromptTokens` 4096.
  s1-p8192-o512 has decode LB 0.123 < 0.15 and is not relaxed; prompts above
  4096 tokens stay on the baseline path.
- 27B passes every s1 cell tested at bound 1.
- Gated cells are non-inferior at bound 1 (A3B s8 TTFT UB +1.1%); bound 2
  failed gated TTFT (+7.8%), so bound 1 is the first tuple.

## Reverted experiment

Deferred drafter seeding (`77d14ffee`, `a0bcf4853`) was tried and reverted in
`f8a3087b5`: it cut A3B s1-p8192-o512 decode ratio from 1.14 to 1.02.
