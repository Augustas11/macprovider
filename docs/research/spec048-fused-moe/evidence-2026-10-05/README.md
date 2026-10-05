# Fused A3B MoE: eight-slot parity root cause and chunked fix

Exploratory Mac Studio evidence for SPEC-048 0.1.23 (#1770). It explains the
eight-slot parity failure in the fused-baseline R015 run (policy `de99e85c…`)
and qualifies the chunked fused envelope at fork revision
`9c1cd900287de58ec6577ec0da7aa3ee61781200`. It is not R015 evidence, and the
analyzer refuses it because the policy schema is
`macprovider.native-mtp-exploratory-policy.v1`.

## Setup

- Host: designated `Mac15,14` M3 Ultra 256 GB Mac Studio, macOS 27.0.1 build
  `26A434`. The frozen R015 policies record build `25E253`, and the bench
  refuses them on this build, so `exploratory-policy.json` is the 10-03 policy
  with schema, matrix, block count, sustained window, and `os_build` changed.
- Cell: `s8-p1536-o512` only, 3 paired blocks per run plus one warmup, 250 ms
  staggered arrivals, `max_native_active_rows` 1 (row 0 native, rows 1-7
  ordinary).
- Runs alternate kernel settings (fused, stock, fused, stock) so drift cannot
  pose as a kernel effect. The live signed provider kept serving during every
  run, so throughput is indicative only; parity and determinism are not
  timing-sensitive in the stock path.
- Binaries: lab build of provider commit `bcf7acccf` with
  `-DMACPROVIDER_LAB_HARNESS`; the old runs use fork `ca29e954…`, the chunked
  runs use the same tree with `mlx-swift-lm` edited to `9c1cd900…`. Raw JSONL
  stays on the lab host; `summary.json` lists each raw file's SHA-256.

## Findings

Per-request `content_sha256` comparison (`summary.json`):

| Build and setting | Parity mismatch blocks | Run-to-run (ordinary / native) | Ordinary s8 decode tok/s |
| --- | --- | --- | --- |
| `ca29e954` fused | 1 of 6 (rows 0-4) | identical / **differs** | 179.1-187.9 |
| `ca29e954` stock | 0 of 6 | identical / identical | 176.3-185.9 |
| `9c1cd900` chunked fused | 0 of 6 | identical / identical | 144.3, 177.5-184.1 |
| `9c1cd900` stock | 0 of 6 | identical / identical | 179.4-185.8 |

Fused and stock outputs differ on nearly every row, while each kernel is
batch-invariant on its own. At `ca29e954` a call switched to stock at eight
flattened tokens. The native arm's batch is one token wider than the ordinary
arm's (verification carries two tokens for the native row), so the two arms
crossed the switch at different steps and timing decided which steps. In the
two blocks where the last-arriving row 7 decoded only at eight or more
tokens, its output matched stock exactly. The 10-03 formal run hit the same
mechanism in 8 of 10 blocks.

At `9c1cd900` every call whose rows carry at most seven tokens stays fused at
any batch size, in chunks of at most seven tokens; prefill-shaped rows keep
stock. Eight-slot parity and run-to-run determinism are clean, and eight-slot
ordinary throughput matches stock (the 144.3 block is a single outlier with
the live provider active).

## Kernel harness

`fused-harness-main.swift` mirrors the fork's
`Tests/MLXLMTests/Qwen35FusedMoETests.swift` as an executable, because the
Studio has Command Line Tools without XCTest. Built against `9c1cd900` with
`mlx-swift` 0.31.4 and the provider's `mlx.metallib` (SHA-256
`84e48718…fdbaf`), it passed 129 checks (`fused-harness-9c1cd900.log`): the
8-token-row stock fallback, default fused path, one- and two-stream overlap
safety, T=2/4/7 batch invariance and agreement with stock within 2%, and the
new chunked decode (8, 9, 16 rows × 1 token) and verify (4, 5, 8 rows × 2
tokens) batches bit-identical to per-token evaluation.

## Follow-up

The final pin `b1811029` (this envelope plus exact tensor-layout validation
from the freeze audit) was qualified on the branch build in
`qualification-7d55924eb/`, including one-, two-, and eight-slot ordinary
throughput against stock. No native-MTP R015 result exists for the chunked
envelope.
