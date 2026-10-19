# Preregistration: R015 for the GLM-5.3-Flash native-MTP tuple on CLI 1.8.256

Frozen before any warmup or measured request of this run. `policy.json` is not
modified after it is committed; a changed policy is a new preregistration.

- Policy: `policy.json`, SHA-256
  `14741db03be1fc6ac4e1c9009b1747e6259f9c82881ac00ff12654692737904c`.
- Tuple: `zai-org/glm-5.3-flash`, target and MTP `7299b6a7…` (embedded
  `checkpoint_mtp`), tokenizer `19e77364…`, depth 1, `qualified_slots` 4,
  `max_native_active_rows` 1, prompt cap 4096, greedy rows.
- Matrix: the four one-slot cells (prompts 1536 and 4096, outputs 128 and
  512), gated `s2-p1536-o512` and `s4-p1536-o512` with 250 ms staggered
  arrivals, and a 1800 s sustained window on `s4-p1536-o512`. Ten blocks, one
  warmup, seed `20261018`. Methodology and thresholds are the SPEC-048 0.1.25
  set the bench and analyzer require.
- Environment, read on the Studio before freezing: `Mac15,14`, Apple M3 Ultra,
  256 GB, macOS build `26A434`, Swift 6.3.3 from the Command Line Tools (no
  Xcode override, so `xcode_build_version` is `unknown`).
- Binary: a lab-harness release build of the `v1.8.256` tag source
  (`provider_commit` `2a575c45…`), with the signed 1.8.256 `mlx.metallib`
  (`3d9b4a74…`). The build also carries the lab-only journey options of this
  branch (`NativeMTPJourneyE2ECommand.swift`); `native-mtp-bench` does not
  call that code.

## Decision rule

`scripts/native_mtp_r015_analyze.py` on the run's JSONL and this policy gives
the verdict: PASS only when every cell passes every gate. The admission entry
binds the resulting `analysis.json`; a FAIL leaves GLM on ordinary decode.
