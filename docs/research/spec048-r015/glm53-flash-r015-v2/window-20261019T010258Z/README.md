# R015 v2 run: GLM-5.3-Flash native MTP, window 2026-10-19T01:02Z

Verdict: **PASS** (`analysis.json` `f607170c08d5ec3293cefd1bb7f122ba1fc5698aaccdb171e3e9f455ed29a4d6`,
`scripts/native_mtp_r015_analyze.py` on `r015-glm53.jsonl` and `../policy.json`).

- JSONL `a0acbd83c625f970ef2f3a89fc76ab5315ae61561afe0240447bb708d2768b10`, 169 records.
- Policy `ed775bdbfe8c420b27ae5a814d5f229d89d4b9ee662c19658e74e3e79ea8c13f` (`../PREREGISTRATION.md`).
- Harness `4dedd31495f19ffbcfe4181c1f3810122d876e4a281ac870e02c06ffee496b46`
  (lab-harness build of `cf0571a5f`), `mlx.metallib` `3d9b4a74…` (signed 1.8.256); `identity.sha256`.
- Before R015, in the same window: `ContinuousBatchSchedulerTests` 181/181 and
  `PagedKVRuntimeBridgeTests` 94/94 on Metal (`metal-*.log`).
- Steps and timings: `summary.txt` (R015 01:03:14Z-03:04:00Z).

| Cell | Decode LB | TTFT UB | TPOT p95 UB | vs 1.8.256 run |
| --- | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +17.4% | +4.1% | -14.4% | unchanged |
| s1-p1536-o512 | +20.0% | +4.5% | -16.7% | unchanged |
| s1-p4096-o128 | +19.8% | +5.4% | -16.6% | TTFT UB was +22.3% |
| s1-p4096-o512 | +20.8% | +4.9% | -17.2% | TTFT UB was +22.2% |
| s2-p1536-o512 (gated) | -0.1% | +2.0% | +0.2% | was -6.2% / +10.1% / +5.3% |
| s4-p1536-o512 (gated) | -1.1% | +1.4% | +1.3% | was -9.6% / +13.8% / +7.9% |

Both diagnosed causes held: with native prompt rows in the same prefill
cohorts as ordinary rows, the gated arms match; with prompts sized before the
first timed run, the 4096-token TTFT bound falls to the native path's own
same-position cost.
