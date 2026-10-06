# Preregistration: R015 on the step-overhead candidate, amended gates, quiet window

Frozen 2026-10-06 before any warmup or measured request of this run.

- Policy: `policy.json`, SHA-256
  `e24cb7bc4599cfb7281f3dc3985efd6c3b7c9a3b61e424bbc0435d8ea756d44a`.
- Copied from the 2026-10-06 step-overhead policy (`0c1b42be…`). Only these
  fields changed: `provider_commit` is now `e1103712d408a0b158ac17dd8834875245874a42`,
  and the threshold set moves to the SPEC-048 0.1.25 gates.
  `itl_p95_upper_bound_max` 0 became `tpot_p95_upper_bound_max` 0 plus
  `chunk_gap_p99_upper_bound_max` 1.0, and `gated_itl_p95_upper_bound_max`
  0.05 became `gated_tpot_p95_upper_bound_max` 0.05. The decode, TTFT,
  rejection, memory, bootstrap, and alpha thresholds are unchanged.
- Unchanged: fork `ca8c384c4fb6bc7d2fbb7c70a18c34b935701805` (mlx-swift 0.31.4),
  fixture digests, tuple (`qualified_slots` 8, `max_native_active_rows` 1,
  cap 4096), matrix (4 one-slot cells plus gated `s2-p1536-o512` and
  `s8-p1536-o512`), 10 blocks, 1 warmup, seed `20261006` (so the run order is
  the preregistered order of both earlier 10-06 runs), staggered 250 ms
  arrivals, and a 1800 s sustained window on `s8-p1536-o512`.
- Environment, verified on the Studio before freezing: `Mac15,14`, Apple M3
  Ultra, 256 GB, macOS build `26A434`, Swift 6.3.3 (Command Line Tools, no
  Xcode, so `xcode_build_version` is `unknown`).
- Lab binary: `swift build -c release --product macprovider-cli
  -Xswiftc -DMACPROVIDER_LAB_HARNESS` of `e1103712d` on the Studio, SHA-256
  `ca12a90c889437acf23ac67e0f74dc765edf29c323c65a5f6e31b2087c531b5f`, with
  `mlx.metallib` `84e48718…` (the identical mlx-swift 0.31.4 library of the
  earlier 10-06 builds). A pre-freeze `native-mtp-hardware-e2e` on this binary
  passed under live load (isolated, no coordinator join, 08:2xZ).

## Window procedure

The operator authorized pausing the live provider (`live.malibu.provider`,
:8080) for this formal run only. The run script takes the lab lock (waiting,
never breaking another holder), then sends a graceful pause over the
control socket so in-flight requests drain. It then boots the job out of the
GUI domain. It records the GPU and process state, runs `native-mtp-hardware-e2e`,
the matrix phase, and the sustained phase, and restores the live job on every
exit path through an `EXIT` trap (bootstrap, then wait for `Provider is
ready`). It records each transition with a UTC timestamp. The production
Trusted Pool M1 member (:18120/:18130) is not touched. Its CPU load is
sampled every 10 s with the JSONL line count, so any overlap maps to
blocks. Per the frozen `exclusion_rules: none`, no block is discarded or
rerun because of it.

## Decision rule

`scripts/native_mtp_r015_analyze.py` on the run's JSONL and this policy gives
the verdict: PASS only when every cell passes every gate. A PASS is lab
evidence only. Native MTP stays default-off, and enabling it remains a
separate operator gate under SPEC-048 R014.
