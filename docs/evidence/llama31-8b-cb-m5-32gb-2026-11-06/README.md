# Llama-3.1-8B continuous batching on Apple M5 32 GB, signed 1.8.281 metallib (2026-11-06)

This re-records the #2202 qualification against the signed CLI 1.8.281 identity. #2202
(merged `7f7d6aa98`) qualified this tuple with a lab-built `mlx.metallib` (`3f7e879b…`). A CB
policy entry binds the exact metallib, and 1.8.281 ships `3d9b4a74…`, so that evidence cannot
sign an entry. This run follows the 1.8.280 native-MTP bank precedent
(`docs/evidence/glm53-abliterated-2026-11-01/`): a lab-harness build of the release source,
run with the signed release metallib.

One lab window on 2026-11-06, 12:14Z to 12:46Z. The live provider was paused, drained and
booted out for the window. It was restored afterwards and was back at `serving_buyers` on
1.8.281 with the same model, binary SHA-256 and decode-path digest as before the window. Local
paths in the JSON records are written as `<lab>` and `<models>`.

## Identity

| Item | Value |
| --- | --- |
| Source | `8898508c1f74b98c09a3d7e992d070cef0ffcf0f` (the 1.8.281 stage commit) |
| Build | `swift build -c release -Xswiftc -DMACPROVIDER_LAB_HARNESS` (the #2202 build), Swift 6.4.2 |
| Lab binary | sha256 `dc74db4d494f870c1db266f09a8d9c8d4637c8e44169c4f6325a68d6ab36b60f`, ad hoc CDHash `8ef95c7f0d165739904ac5a7d42ddd641e19524a` (not a release identity) |
| Embedded decode-path digest | `dbadff54f38923c3fbcbe8858135788b2b2d731eaea5af61c81e3ae7899db21d`, the same as the signed 1.8.281 provider |
| mlx-swift-lm | `da8f1932f8e2a46477a1a35663955267bc6fcd04` (the 1.8.281 pin) |
| Signed release binary | 1.8.281 standalone darwin-arm64 tarball (sha256 `fd7666e6…`): `macprovider-cli` sha256 `a54ac19b7a165ef5386417e1b5b5cefe50b419f57db355b22f1c593cb9608132`, CDHash `2eb43b9d94ad9999caf161e15e1322a7989bbe2a`, Developer ID signed |
| `mlx.metallib` beside the binary | `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`, copied from the signed tarball |
| `mlx-swift_Cmlx.bundle/.../default.metallib` | `3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b`, copied from the signed tarball. The SwiftPM build's own bundle copy (`7b903840…`) was replaced before any run |
| Model | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` @ `241a666dad6cb93c8ff213d39a7f34a36bf26db4`. Snapshot manifest `67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f`, recomputed from the downloaded files; every file's SHA-256 matches the Hugging Face LFS hash |
| Tokenizer / chat template | `5ddc2e84…` / `f32396c4…`, the same as #2202 |
| Hardware | `apple-silicon:Apple M5:ram-32gb`, macOS 27.0.1 (26A434) |

The self-check record's key carries metallib `3d9b4a74…`, so the runtime loaded the release
metallib.

Before each measurement leg the driver waited until no `swift-build`, `swift-frontend` or
`xctest` process was running on the machine. The check recorded "none" before the 1-row
cell, before every later cell and before the self-check. The lab build finished before
the legs started. Another session's test build was also running during that build, and it
had ended before the first cell.

## msb-throughput (scheduler engine, the #2202 cells)

Command per cell, unchanged from #2202: `msb-throughput --model <models>/llama-3.1-8b
--engine scheduler --no-compile --prompt-tokens 1536 --decode-tokens 256 --runs 1
--mlx-cache-limit-mb 512 --stdout-only --rows N`. The 4-row correctness cell adds
`--scenario leftovers --parity-tokens 256`. Aggregate and serial were measured in the same
process.

| Rows | Aggregate tok/s | Production serial tok/s | Paged single row tok/s | Aggregate / serial | #2202 lab metallib | Scheduler TTFT per row (s) | Peak footprint |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 17.26 | 17.78 | 16.03 | **0.971** | 1.01 | 3.78 | 5.5 GiB |
| 2 | 26.98 | 17.72 | 17.57 | **1.522** | 1.70 | 7.64 / 7.64 | 6.2 GiB |
| 4 | 35.00 | 18.29 | 18.41 | **1.913** | 1.68 | 13.90 for each of the 4 rows | 7.1 GiB |
| 8 | 31.42 | 19.53 | 18.46 | 1.609 | 1.82 | 18.05 to 35.74 | 8.8 GiB |

4-row leftovers (`leftovers.json`):

| Check | Result |
| --- | --- |
| Parity, 4 rows, 256 tokens | 4/4 batched rows match serial exactly; the 1-row match also passes |
| Isolation (one row cancelled) | pass; the healthy row completes, the cancelled row does not settle |
| Replay | pass; the first run is `eligible_owner`, the replay is `non_settling_replay`, and the tokens match |
| Drain | pass; the permit is valid, active rows complete, and queued and post-drain work is rejected |
| Usage attribution | `usagePass=true` in every scenario |

## FR-CB10 serve-path self-check

The isolated serve ran with `--no-join` on its own loopback port, with its own home and config,
owner-pinned to 4 slots and a queue limit of 8 (the #2202 settings). The signed policy
resolved `absent_empty_off_fallback`, and the self-check ran at load (`cb-self-check.json`,
schema `macprovider.cb-self-check.v6`).

| Slots | Aggregate tok/s | Gain over serial | Token parity |
| --- | --- | --- | --- |
| 2 | 26.2 | 1.324 | conformant, 0 near-tie rows |
| 3 | 18.6 | 1.243 | conformant, 0 near-tie rows |
| 4 | 16.1 | 1.272 | conformant, 0 near-tie rows |

The decision is `granted` (verified slots 4, served slots 4, deferrals 0). The #2202 lab
metallib run measured 1.32 / 1.33 / 1.27.

## Bars

| Bar | Required | Measured | Result |
| --- | --- | --- | --- |
| FR-CB10 aggregate gain with exact parity | >= 1.2 (`ContinuousBatchingSelfCheck.minimumAggregateGain`) | 1.24 to 1.32 at every rung, all conformant, granted | PASS |
| 1-row scheduler path vs serial | >= 0.95x | 0.971x | PASS |
| 4-row parity | exact | 4/4 exact over 256 tokens | PASS |

## Policy entry

The entry in `phase3-binary/catalog/autotune/continuous-batching-policy-source.json` carries
the #2202 draft fields with these changes:

- `metallib_sha256` is the release `3d9b4a74…`.
- `provider_cli_version` is `1.8.281`.
- `live_executable_cdhash` is the signed 1.8.281 CDHash `2eb43b9d…`.
- `package_manifest_sha256` is the signed 1.8.281 binary `a54ac19b…`.
- `studio_campaign_sha256` is the SHA-256 of `cb-self-check.json` here
  (`88c2cb0369baf7b565cfe65281a2ff80aaca9ce9d6be5680536ede7d1cd192f2`).
- `evidence_id` is new.

The entry goes live only with a signed catalog release.

## Files

- `msb-rows{1,2,4,8}.json`: the throughput cell reports and their commands.
- `leftovers.json`: the 4-row isolation, replay, drain and parity report.
- `cb-self-check.json`: the self-check record, byte-identical to what the serve wrote.
- `self-check-run.json`: the serve command, exit reason and final `/v1/status` CB block.

A first window earlier the same day (12:03Z to 12:14Z) built the binary but measured nothing.
The driver could not find its sandbox profile, so every leg exited before loading a model.
The provider was restored after that window too (snapshot match), and the second window
reused the same build (no-op rebuild, identical binary SHA-256).
