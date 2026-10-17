# GLM-5.3-Flash T4 provider wiring and native MTP windows (epic #2029)

Studio windows from 2026-10-17 for the native-engine campaign: the SPEC-039
AC-20 paged-MLA fixture, msb-throughput at rows 1/2/4, the SPEC-038 FR-CB10
on-device self-check, and native MTP. Every window ran with the live provider
paused and drained (0 in flight) and the lab serve no-join on its own port,
config directory and self-check store. Paths are written as `<lab>` and
`<models>`; per-instance lab configs are not committed.

## Identity

| Item | Value |
| --- | --- |
| Artifact | `Jundot/GLM-5.3-Flash-oQ4e-mtp` @ `36defc5042d92a992a7948e83d6f110b8df69329`, snapshot-manifest `7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9` (accepted by serve's startup hash check in every serve window below) |
| Hardware | Mac Studio M3 Ultra, 256 GB, macOS 27.0.1 (26A434) |
| Runtime tuple | mlx-swift-lm `7d8dbf56e0e25b50f90d80edb9e0d8d721406679`, mlx-swift `29d3b933`, MLX core `v0.32.4-macprovider.4` kernels: `mlx.metallib` `589e56e0794dcf6fcebf7f7edbda562404653e606d6ac9bb9bdf7025a608a094` in every window |
| Lab serve binary | lab-harness release build (`-DMACPROVIDER_LAB_HARNESS`, version pinned to live 1.8.250); per-window SHA-256 in each `identity.sha256` |

| Directory | Build | Content |
| --- | --- | --- |
| `window-20261017T022259Z-ac20-msb/` | `f0160dbc…` (campaign at the `7d8dbf5` pin) | AC-20 fixture, msb rows 1/2/4 |
| `selfcheck-20261017T032317Z-end-to-end/` | `5569486c…` (`6dec90cc0`) | FR-CB10 self-check, end-to-end gain (before SPEC-038 v0.3.21) |
| `selfcheck-20261017T041102Z/` | `dfc06c92…` (`0a3cf6de3`; its glm5_next measurement is the one `df7a00ddb` keeps) | FR-CB10 self-check, decode-only gain (SPEC-038 v0.3.21) |
| `mtp-20261017T013154Z/` | GLMBench on fork `fa72942` | MTP oracle parity 1k/8k (superseded pin) |
| `mtp-20261017T025000Z/` | GLMBench on fork `7d8dbf5` (pinned) | MTP oracle and varied-text parity 1k/8k, profile, kernel census |
| `mtp-short-20261017T033515Z/` | GLMBench on fork `5a2b4ee` (not pinned; profiling only) | MTP profile, census, varied 1k |

## AC-20 / FR-PKV4 fixture (`window-…022259Z-ac20-msb/leg1-fixture.log`)

`GLM5NextPagedMLAParityTests` on the admitted artifact, through the xctest
host: PASS (1 test, 0 failures, 470 s). Paged MLA against the stock cache,
48 exact greedy tokens at a 2,800-token prompt, 11 sparse layers, 1,166
gather calls, non-identity block tables, pending window byte-equal
(`pending=[3 x 11]`, `stateMismatches=0`); attach probe established over 11
layers in 36 forwards. The window's self-check leg did not run its ladder
(`deferred`): the serve KV cap error fixed in `54a9888f7`/`6dec90cc0`.

## msb-throughput, paged engine, block 256, 1,024 prompt / 128 decode tokens per row, 3 runs

| Rows | Aggregate tok/s p50 | Production serial tok/s p50 | Aggregate / serial | Peak footprint |
| --- | --- | --- | --- | --- |
| 1 | 35.38 | 39.90 | 0.89 | 181.3 GB |
| 2 | 46.90 | 39.79 | 1.18 | 181.8 GB |
| 4 | 55.92 | 39.85 | 1.40 | 182.7 GB |

Aggregate is total decoded tokens over the common wall-clock (FR-CB14);
prefill is outside the timed span.

## FR-CB10 self-check (`selfcheck-20261017T041102Z/`): PASS

Lab serve with CB `canary`, 4 scheduler rows, queue limit 4, 64k served
context, decode window 16, flattened-token cap 8. Exactness probe at k = 2, 3,
4 (unequal prompts across the 1,024-key route boundary): every row equal to
its lone run, `divergent_rows=none`, 47 cohort decode tokens per row (bar 16).

| k | Batched decode tok/s | Serial decode tok/s | Median gain | Batch wall (end to end) |
| --- | --- | --- | --- | --- |
| 2 | 47.9 | 43.2 | 1.11 | 3.1 s |
| 3 | 53.0 | 43.1 | 1.23 | 6.2 s |
| 4 | 56.6 | 42.8 | 1.32 | 10.9 s |

Decision `granted`, served slots 3, `verified_k` 4. The rule picks the lowest
k within 15% of the best gain (1.32 x 0.85 = 1.12): k = 3. The stored key
(`cb-self-check.json`) carries `…+cb-isolation-v1/decode8/verify8+cb-probe-v3/route1024+flat8`.

The per-pass `action=pass` lines in `serve.log` keep both rates. Serial
decode is flat at about 43 tok/s across k while serial end-to-end falls
(27.8, 20.5, 15.9 tok/s), and the batch prefills its short rows one at a
time (wall 3.1 / 6.2 / 10.9 s against 2.0 / 2.7 / 3.3 s of cohort decode).
That prefill share is why the same ladder measured end to end
(`selfcheck-20261017T032317Z-end-to-end/`: gains 1.05 / 1.06 / 1.04,
`no_net_gain`, serves 1 slot) never reached the 1.2x bar, and why SPEC-038
v0.3.21 times decode only for glm5_next.

## Native MTP (GLMBench, `checkpoint_mtp` drafter, greedy, 256 tokens)

At the pinned `7d8dbf5` (`mtp-20261017T025000Z/`), MTP output equals plain
greedy token for token in every round (`mtp_equals_plain=true`), and both
equal the T2 reference oracle 256/256 at 1k and 8k.

| Prompt | Text | Acceptance | Plain decode tok/s | MTP decode tok/s |
| --- | --- | --- | --- | --- |
| 1,024 | oracle (code) | 1.000 | 39.5 / 41.1 | 41.1 / 45.1 |
| 8,192 | oracle (code) | 1.000 | 34.3 | 35.4 |
| 1,024 | varied | 0.789 | 41.2 / 41.3 | 39.3 / 40.3 |
| 8,192 | varied | 0.716 | 34.4 | 31.0 |

Two values are rounds 0 / 1. On varied text MTP-1 does not beat plain decode
at this pin. A round (two-column verify plus drafter commit) costs about
45 ms in these runs against about 24 ms per plain token, so a round must
average about 1.85 tokens, i.e. acceptance near 0.85, to break even
(`profile-1024.log`: verify 42.1 ms, plain step 28.8-30.0 ms in isolation).
`census-1024.log` attributes GPU time per step by kernel family for one- and
two-token forwards (fused MoE 35% and 34%). `mtp-short-…/` repeats the profile
on the unpinned `5a2b4ee` (verify 41.7 ms) and adds a census of the verify
step itself (fused MoE 42%, KDA multi-QMV 24%), with the same varied-text
result (1k: acceptance 0.789, 40.0 vs 41.0 tok/s). `mtp-20261017T013154Z/` is
the same parity at the superseded `fa72942` pin.

## SPEC-039 FR-PKV12 record for the GLM-5.3-Flash entry (v0.1.20)

| Requirement | Record |
| --- | --- |
| AC-20 fixture | `window-20261017T022259Z-ac20-msb/leg1-fixture.log` |
| Attach proof (parity, gather coverage) | `selfcheck-20261017T041102Z/serve.log`: `parity … established=true nLayers=11 nForwards=36 gatherKernelCalls=792` |
| Row isolation | same log: MoE expert-dispatch isolation on first decode and on rejoin, `batched-isolation … proven=true crossRowDivergences=0`; FR-CB10 rows exact at k = 2..4 |
| Replay and drain | `leftovers/` (`glm53-t4-window.sh run-leftovers`: scheduler leftovers harness, isolation / replay / drain / parity `pass=true`). **Not yet recorded; required before the campaign PR merges.** |
