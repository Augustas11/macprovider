# gpt-oss-20b continuous batching on Apple M5 32 GB, campaign builds 067d8a32f and 37dacde22 (2026-11-06)

Lab legs for #2200 and #2223 on the `gpt_oss` mixed cache class from SPEC-039 v0.1.29.
Three lab windows ran on 2026-11-06: 13:10Z to 14:04Z (build, self-check, msb cells),
14:04Z to 14:06Z (self-check rerun) and 14:18Z to 14:43Z (re-measure on 37dacde22). For each window the live provider was paused, drained
to 0 in-flight and booted out. After each window it was restored to `serving_buyers`, with
the same binary version, model, binary SHA-256 and decode-path digest as before the window
(snapshot compare `SNAPSHOT_OK` both times). Local paths in the JSON records are written as
`<lab>` and `<models>`.

Result on 067d8a32f: the scheduler path is correct, and its 4-row gain matches #2202. The
serve path does not attach paged KV for gpt-oss-20b on this commit, so the FR-CB10
self-check never runs. The cause is described under "Serve-path attach" below.

Result on 37dacde22 (third window, see "Re-measure on 37dacde22"): paged KV attaches on
the serve path, and the self-check runs with every rung exact. The decision is
`no_net_gain`, with gains of 1.06 to 1.08 against the 1.2 floor. The 1-row ratio is 0.937x
over 5 runs.

## Identity

| Item | Value |
| --- | --- |
| Source | `067d8a32fe528fdbc18a8271e94ec69ab5041da0` (SPEC-039 v0.1.29, gpt-oss-20b allowlisted) |
| Build | `swift build -c release -Xswiftc -DMACPROVIDER_LAB_HARNESS`, Swift 6.4.2, built inside the first window |
| Lab binary | sha256 `85ae7234c37101cb6239a5d45c291a9a964ae588c6a896c23a2f20400efee2f5`, ad hoc CDHash `3cd44bb60d14f90d07038f49bb0f1658e7429289` (not a release identity) |
| Embedded decode-path digest | `69c234adde7ca835c635ef8b0a935328cd22725e868a6583403dc47ef7bc16a1` (the regenerated digest in this commit) |
| `mlx.metallib` beside the binary | `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`, from the signed 1.8.281 tarball |
| `mlx-swift_Cmlx.bundle/.../default.metallib` | `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`, from the signed 1.8.281 tarball. The SwiftPM build's own copy (`7b903840…`) was replaced before any run |
| Model | `mlx-community/gpt-oss-20b-MXFP4-Q8` @ `773a7da77e569019bb0fd17a554b263738d669a3`, 12 files, 12104218243 bytes. Snapshot manifest `f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1`, recomputed from the downloaded files. It equals the signed catalog row, and every LFS file matches its Hugging Face SHA-256 |
| Tokenizer / chat template | `8be1c585…` / `d66fa69c…` |
| Hardware | `apple-silicon:Apple M5:ram-32gb`, macOS 27.0.1 (26A434) |

Before each leg, the driver waited until no `swift-build`, `swift-frontend` or `xctest`
process was running. The check recorded "none" before every leg.

## msb-throughput (scheduler engine, the #2202 cells)

Command per cell: `msb-throughput --model <models>/gpt-oss-20b --engine scheduler
--no-compile --prompt-tokens 1536 --decode-tokens 256 --runs 1 --mlx-cache-limit-mb 512
--stdout-only --rows N`. The 4-row correctness cell adds `--scenario leftovers
--parity-tokens 256`. Each cell measured aggregate and serial in the same process. The 8-row
cell ran because the projected peak (17.3 GiB) plus a 3 GiB margin fitted the available
memory.

| Rows | Aggregate tok/s | Production serial tok/s | Paged single row tok/s | Aggregate / serial | #2202 | Scheduler TTFT per row (s) | Peak footprint |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 34.39 | 36.60 | 34.55 | **0.939** | 0.86 | 2.08 | 13.3 GiB |
| 2 | 32.33 | 27.30 | 25.87 | **1.184** | | 5.32 / 5.32 | 14.0 GiB |
| 4 | 32.88 | 24.74 | 23.47 | **1.329** | 1.34 | 12.22 for each of the 4 rows | 15.0 GiB |
| 8 | 27.51 | 23.61 | 21.64 | 1.165 | | 15.99 to 35.64 | 15.4 GiB |

4-row leftovers (`leftovers.json`):

| Check | Result |
| --- | --- |
| Parity, 4 rows, 256 tokens | 4/4 batched rows and 4/4 standalone rows match serial exactly (token SHA-256 `0d059932…` on both sides); the 1-row match also passes |
| Isolation (one row cancelled) | pass; the healthy row completes and the cancelled row does not settle |
| Replay | pass; the first run is `eligible_owner`, the replay is `non_settling_replay`, and the tokens match |
| Drain | pass; the permit is valid, active rows complete, and queued and post-drain work is rejected |
| Usage attribution | `usagePass=true` in every scenario |

This harness runs the paged engine directly with fp16 KV. It does not go through the
serve-path attach gate.

## Serve-path attach and FR-CB10 self-check

The isolated serve ran with `--no-join` on its own loopback port, with its own home and
config. It was owner-pinned to 4 slots with a queue limit of 8 and `max_context 8192`, the
same settings the Llama row used. The signed policy resolved `absent_empty_off_fallback`.

| Run | `model` binding | Attach decision | Self-check |
| --- | --- | --- | --- |
| 1 (`self-check-run-path-binding.json`) | snapshot directory path | `fallback_paged_fallback_cache_class` | none |
| 2 (`self-check-run-catalog-binding.json`) | `openai/gpt-oss-20b`, `model_artifact_path` = snapshot directory, artifact SHA set | `fallback_paged_fallback_quantized` | none |

Run 1 used the harness binding from the Llama row, where `model` is a filesystem path. The
v0.1.29 allowlist keys on the exact identity and admits no path alias, so the cache-class
fallback in run 1 is expected and is not a code finding.

Run 2 uses the production binding and gets past the cache-class gate. It then falls back for
a different reason. `serve` derives `effectiveKVBits = kvBitsOverride ??
KVQuantRecommendation.recommendedKVBits(for: model)`. That function returns 8 for any model
id containing `gpt-oss`. `PagedKVAttachGate.decide` then rejects any non-nil `kvBits` with
`paged_fallback_quantized`, which it checks before the identity and cache-class gates. The
`kv_bits` key accepts only 4 or 8, so a provider cannot clear this in config. On this commit,
gpt-oss-20b (and gpt-oss-120b, which uses the same default) cannot attach paged KV on the
serve path. Because paged KV never attaches, no FR-CB10 self-check runs.

## Bars

| Bar | Required | Measured | Result |
| --- | --- | --- | --- |
| Serve-path paged KV attach, no `paged_fallback_*` | attached | `paged_fallback_quantized` (production binding) | FAIL |
| Serve-path isolation `crossRowDivergences=0` | 0 | not reached (no attach) | FAIL (not run) |
| FR-CB10 decision granted, every rung exact, gain >= 1.2 | granted | not reached (no attach) | FAIL (not run) |
| 1-row scheduler path vs serial | >= 0.95x | 0.939x (#2202: 0.86x) | FAIL |
| 4-row parity | exact | 4/4 exact over 256 tokens | PASS |
| 4-row leftovers (parity, isolation, replay, drain) | all pass | all pass | PASS |
| 4-row aggregate vs serial | reported | 1.329x (#2202: 1.34x) | reported |

## Re-measure on 37dacde22 (SPEC-039 v0.1.30, KV-quant default kept off the paged gate)

The third lab window ran 14:18Z to 14:43Z on the same Mac, with the same pause, drain,
bootout and restore steps as the first two. The restore compare was `SNAPSHOT_OK`, and the
provider was back at `serving_buyers` on 1.8.281 with the same model, binary SHA-256 and
decode-path digest. The binary was rebuilt inside the window with the same lab-harness
command and Swift 6.4.2.

| Item | Value |
| --- | --- |
| Source | `37dacde22` |
| Lab binary | sha256 `30ed009719bbae2f14e78ec287d76a07119abad9e801958455ded5fcb0d11206`, ad hoc CDHash `212cc552ab1cac6c61a5cb1ae11492c7021304b5` |
| Embedded decode-path digest | `4238316b966a9ab792b8dca649c1a5a6f40c618d4540236f6545fcc60974b860` |
| Both staged metallibs | `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b` (the build's own bundle copy `7b903840…` was replaced) |

### Serve-path self-check, production binding

The serve config bound `model: openai/gpt-oss-20b` with `model_artifact_path` set to the
snapshot directory and the artifact SHA-256 set. All other settings matched the runs above
(`fix-self-check-run.json`, `fix-cb-self-check.json`). The serve log contains no
`paged_fallback_*` line, and `/v1/status` reports `paged_kv_decision: attached` with cache
class `mixed`.

- Parity probe: `established=true`, 24 layers, 1536 gather-kernel calls as expected,
  non-identity block permutation.
- Batched isolation: `requiresMoE=true proven=true rowsDecoded=2 rowFailures=0
  crossRowDivergences=0`.
- Runtime identity: the model SHA-256 is `f2559286…`, and the metallib is the release
  `3d9b4a74…`.

| Slots | Aggregate tok/s | Serial tok/s | Gain over serial | Token parity |
| --- | --- | --- | --- | --- |
| 2 | 19.6 | 18.4 | 1.06 | conformant, no divergent rows |
| 3 | 17.1 | 15.9 | 1.08 | conformant, no divergent rows |
| 4 | 14.1 | 13.2 | 1.07 | conformant, no divergent rows |

The decision is `no_net_gain` (verified slots 4, decided slots 1, deferrals 0, policy
`self_check_refused_no_net_gain`). Every rung is exact, but no rung reaches the 1.2 gain
floor, so CB stays off for this tuple on this machine. The record's SHA-256 is
`4f6c0990e9aa0236b8da9ac5556b87a98cfed89517b703f9359f886773dfe403`.

### 1-row msb-throughput, 5 runs

| Engine | Aggregate tok/s runs (p50) | Production serial tok/s runs (p50) | Ratio | File |
| --- | --- | --- | --- | --- |
| scheduler | 21.34, 19.35, 20.73, 20.49, 20.16 (20.49) | 21.34, 21.85, 22.19, 21.38, 21.95 (21.85) | **0.937** | `fix-msb-rows1-runs5-scheduler.json` |
| paged | 18.46, 18.82, 18.80, 18.88, 18.97 (18.82) | 17.87, 22.65, 21.23, 20.62, 21.76 (21.23) | **0.887** | `fix-msb-rows1-runs5-paged.json` |

The absolute rates in this window are about 40% below the first window, where the 1-row
serial rate was 36.6 tok/s. The cause was not found. The guard samples show no thermal or
performance warning, a minimum memory-pressure free of 45 to 46%, and kernel pressure
level 1. The Mac was on AC with low-power mode off. Each ratio is still measured in one
process, so its aggregate and serial rates ran under the same conditions.

### Bars on 37dacde22

| Bar | Required | Measured | Result |
| --- | --- | --- | --- |
| Paged KV attaches, no `paged_fallback_*` | attached | attached, cache class `mixed`, no fallback line | PASS |
| Parity probe | established | established, 1536/1536 gather calls | PASS |
| Serve-path isolation `crossRowDivergences=0` | 0 | 0 (2 rows, 0 failures) | PASS |
| Every self-check rung exact | conformant | 3/3 rungs conformant | PASS |
| Self-check gain >= 1.2 and decision granted | granted | 1.06 / 1.08 / 1.07, `no_net_gain` | FAIL |
| 1-row scheduler vs serial, 5 runs | >= 0.95x | 0.937x | FAIL |
| 1-row paged engine vs serial, 5 runs | recorded | 0.887x | recorded |

## Files

- `fix-self-check-run.json`, `fix-cb-self-check.json`: the 37dacde22 serve self-check run
  and its record, byte-identical to what the serve wrote.
- `fix-msb-rows1-runs5-scheduler.json`, `fix-msb-rows1-runs5-paged.json`: the 37dacde22
  1-row cells.
- `msb-rows{1,2,4,8}.json`: the throughput cell reports and their commands.
- `leftovers.json`: the 4-row isolation, replay, drain and parity report.
- `msb-summary.json`: the driver summary (binary SHA-256, 4-row ratio, 8-row memory
  projection, leftovers verdict).
- `self-check-run-path-binding.json` and `self-check-run-catalog-binding.json`: the serve
  command, exit reason and final `/v1/status` CB block for each binding.

The driver ended run 1 by hand after it had sat 25 minutes with a fallback decision and no
self-check, to shorten the paused window. That run's exit code is therefore 143. The rerun
driver stops by itself when it sees a fallback decision.
