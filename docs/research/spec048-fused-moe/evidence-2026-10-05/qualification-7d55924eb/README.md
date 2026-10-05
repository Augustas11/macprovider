# Fused A3B MoE ordinary-path qualification (SPEC-048-R003)

Ordinary-path qualification of fork pin
`b181102984a4d1875efbd9e0eab3a7dfd1c012c5` for the SPEC-048 0.1.23 R003
review gate, run on 2026-10-05 against provider commit
`7d55924eb94907a09759c3e0263f374d9fec3dfc` (PR #1832 head with origin/main
merged). Later commits change no Swift source; one restores
`phase3-binary/Package.resolved` to the full Xcode 16.4 pin set after a local
Swift 6.3 resolve had pruned unused transitive pins. The lab build resolved
`mlx-swift` 0.31.4 and the fork pin exactly as the release build does.

## Setup

- Host: designated `Mac15,14` M3 Ultra 256 GB Mac Studio, macOS 27.0.1 build
  `26A434`, under the lab-window lock. The live signed provider kept serving
  throughout; the lab binary never joined a coordinator.
- Binary: `swift build -c release -Xswiftc -DMACPROVIDER_LAB_HARNESS` of the
  exported tree, with the fork resolved from GitHub at the pin
  (`lab-binary-sha256.txt`).
- Model: `qwen/qwen3.6-35b-a3b` 4-bit, target `3fed776d…`, MTP `fa01beec…`.
- Bench: `native-mtp-bench` with `exploratory-policy.json` (exploratory
  schema; the R015 analyzer refuses it): cells `s1`, `s2`, `s8` at prompt
  1536 / output 512, 3 paired blocks plus one warmup per cell,
  `max_native_active_rows` 1, 250 ms staggered arrivals. Four runs alternate
  kernel settings: fused, `MLX_LM_QWEN35_FUSED_MOE=0`, fused,
  `MLX_LM_QWEN35_FUSED_MOE=0`. Raw JSONL stays on the lab host;
  `summary.json` lists each file's SHA-256.

## Results

| Check | Result |
| --- | --- |
| Fork fused tests (executable harness, `fused-harness-main.swift`) | PASS, 133 checks (`fused-harness-b1811029.log`) |
| `native-mtp-hardware-e2e` (serve path) | PASS (`hardware-e2e-result.json`) |
| Ordinary/native parity, every cell, both kernels | 0 mismatches in 36 paired blocks |
| Run-to-run output, every cell, both paths, both kernels | bit-identical |

Ordinary aggregate decode throughput (tok/s, 6 blocks per kernel; ratio of
medians):

| Cell | Fused | Stock | Fused ÷ stock |
| --- | --- | --- | --- |
| `s1-p1536-o512` | 86.5-94.0 | 65.0-88.7 | **1.253** |
| `s2-p1536-o512` | 111.7-121.7 | 105.1-105.5 | **1.150** |
| `s8-p1536-o512` | 175.1-183.8 | 146.1-185.3 | **0.973** |

Fused is faster at one and two slots and about 2.7% slower at eight slots,
where eight decode rows run as two fused chunks (7 + 1) instead of the stock
sorted-gather kernel. That cost buys a single kernel family per decode row,
which is what makes eight-slot parity and run-to-run output deterministic
(compare `../summary.json`, where the unchunked build diverged). The one-slot
gain is lower than the 2026-10-02 lab figure (about +40%), measured with the
live provider idle; the live provider was serving during these runs.

For context only (not a gate): native MTP at one slot ran 105.4-107.9 tok/s
against 86.5-94.0 fused ordinary, still under the R015 15% bound.

## Gate

With the three-lane freeze audit
(`audits/2026-10-05-native-mtp-fused-freeze/VERDICTS.md`, round 2: 0
Critical, High, or Medium in every lane), this closes the SPEC-048-R003
review gate for the fork pin. Native MTP stays default-off; its activation
still needs a passing R015, signed journeys, and R014.
