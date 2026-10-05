# SPEC-048 R015 fused-baseline preregistration

This directory preregisters the fresh formal R015 run for the Qwen3.6 A3B
native-MTP tuple after the ordinary path moved to the exact fused MLX fork
revision `ca29e9544777068a0b53aad87310ff1cfaf3fd1d`.

The frozen byte-exact `policy.json` has SHA-256
`de99e85c4b68dac589ea2b8fa33f1d8ee8a7371c254e233e3d3081e01e89b60b`.
It binds the lab binary to provider commit
`bcf7acccf8cac842eadb5305bc5b88390c5846f8`, built on the designated
`Mac15,14` Studio with `-DMACPROVIDER_LAB_HARNESS` and used only in an
isolated, no-join hardware window.

Status: **FAIL** (2026-10-03). The matrix completed all 10 paired blocks in
all 6 cells (133 JSONL records, matrix-only raw SHA-256
`b6a3cdf9360afd1d3780f3ca75d1b92362d032d45c55ad6958cf4121d2444910`). Raw
JSONL, analyzer output, and contamination logs remain on the lab host under
`~/mtp-r015-a3b-fused-formal/`; this policy was not modified.

| Cell | Result | Blocking evidence |
| --- | --- | --- |
| `s1-p1536-o128` | FAIL | throughput corrected LB `+10.96%`; ITL corrected UB `+59.55%` |
| `s1-p1536-o512` | FAIL | throughput corrected LB `+9.75%`; ITL corrected UB `+58.92%` |
| `s1-p4096-o128` | FAIL | throughput corrected LB `+7.57%`; ITL corrected UB `+62.06%` |
| `s1-p4096-o512` | FAIL | throughput corrected LB `+5.18%`; ITL corrected UB `+61.53%` |
| `s2-p1536-o512` | FAIL | TTFT corrected UB `+7.16%` |
| `s8-p1536-o512` | FAIL | ordinary/native parity mismatch in 8 of 10 blocks |

The sustained window and every later gate were not run. The eight-slot parity
failure is traced to the fused/stock switch at eight flattened tokens in
`../../spec048-fused-moe/evidence-2026-10-05/`; the fork envelope that policy
binds is retired by SPEC-048 0.1.23.
