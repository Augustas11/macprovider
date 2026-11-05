# GLM-5.3-Flash native MTP above the 4096 prompt cap (#2198)

Exploratory Studio window `window-20261104T132643Z` on 2026-11-04, 13:27Z to 15:21Z.
One row, proposal depth 1, outputs 128 and 512. Not an admission verdict:
the analyzer status is `EXPLORATORY_NO_VERDICT`. The signed prompt cap stays 4096.

The live provider was paused, drained to zero in-flight requests, and booted out.
It was restored at 15:34:45Z. Before and after snapshots match: CLI 1.8.280,
binary `66a4876ec8888e93f5e1d8621a902893c6432b3c34c11a5825597a06b2c79f5f`,
decode-path digest `65094a61dae7aecafc51e3a4d310ae6ed580326a68dd0f7e4e1813e7debff917`,
model `zai-org/glm-5.3-flash`, state `serving_buyers`.

Lab harness sha256 `a7a4fc47994a88a0052adfdeb140f12d2350ddd634d5b862ee252c40d49a87dd`,
provider commit `b609a589d8eeba60c913b2c797a5689c871b7f7b`, mlx-swift-lm
`ae6aa7826eb2ab276837c950dca6b1aaf9f344e4`, release metallib `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`.
Policy sha256 `1e5edc2dfc8206759f5b85d6d07f5845d4708cefb4605e4d0458615a6dbc6705`.
Model weights are the lab fixture whose target sha256 is
`7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9`.

| Cell | Native tok/s | Ordinary tok/s | Throughput lower bound | Cell gate |
|---|---:|---:|---:|---|
| s1-p8192-o128 | 44.89 | 37.21 | +18.0% | pass |
| s1-p8192-o512 | 45.10 | 37.26 | +19.3% | pass |
| s1-p32768-o128 | 42.04 | 36.39 | +14.65% | fail (throughput) |
| s1-p32768-o512 | 42.50 | 36.46 | +14.07% | fail (throughput) |

The floor is +15%. Acceptance was 80.1% to 80.9%. Every cell had zero errors and
zero parity mismatches. Native time to first token was about 4% slower (22.8 s
against 21.9 s at 8192; 91.5 s against 87.7 s at 32768). End-to-end throughput
at 32768 was slower on the native path. The 60 tok/s goal is unmet.

Do not rerun these four cells for this harness. Do not sign a 32768 prompt cap
from this window.

Related: #2198
