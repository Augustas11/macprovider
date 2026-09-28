# SPEC-048 Phase-0 Upstream Gate - 2026-09-28

Status: BLOCKED for production native MTP serving under SPEC-048-R003.

## Verdict

MacProvider must not wire native MTP into the production decode scheduler yet.
The pinned public dependency exposes a serial MTP surface, but the required
Qwen-family MTP and exact row/position-mapped cache transaction work is either
post-release or still open upstream. The stable public API available to
MacProvider is therefore insufficient for a provider-safe propose/verify/
commit/discard integration.

## Current Pins

Source of truth: `phase3-binary/Package.swift` and
`phase3-binary/Package.resolved`.

- `mlx-swift-lm`: exact `3.31.4`, resolved revision
  `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`.
- `mlx-swift`: resolved `0.31.4`, revision
  `dc43e62d7055353c7f99fa071a4e71d29dfddc44`.
- `swift-transformers`: exact/resolved `1.3.4`, revision
  `c21fdcde390313a6d98d8e33a346f2c3486c3ab0`.
- `swift-jinja`: resolved `2.4.2`, revision
  `7d0b8880ef8e567dd4e0089f8b99fb354129017c`.

Latest `mlx-swift-lm` release observed by the upstream watcher is still
`3.31.4`, published 2026-06-30:
https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4

## What Compiles Today

The pinned release provides public serial MTP symbols in `MLXLMCommon`:

- `MTPDrafterModel`
- `MTPSpeculativeTokenIterator`
- `MTPDrafterModelFactory`

The pinned `mlx-swift` also exposes `QuantizationMode.mxfp8`.
`phase3-binary/Tests/mlx-stage-spikeTests/NativeMTPUpstreamQualificationTests.swift`
keeps these as compile-level qualification signals.

This is useful but not sufficient: it proves public symbols exist, not that
MacProvider can safely share provider cache rows with a multi-request scheduler.

## Missing Stable Production API

SPEC-048 requires a stable public upstream surface for explicit row/position
transactions: propose, verify, stage, commit, discard, rewind, and exact cache
ownership across wrapped sliding windows and recurrent/hybrid caches.

The relevant upstream transaction work is visible on `main`, but remains
package-scoped. For example, upstream `KVCacheRound.swift` declares
`package protocol KVCacheRoundStrategy`, `package final class KVCacheRound`,
and `package struct KVCacheRoundCommit`:
https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/KVCacheRound.swift

That scope is a hard integration boundary for MacProvider. We cannot depend on
those transaction types from the provider package without forking, floating on
private implementation details, or collapsing SPEC-048's cache safety gate.

## Upstream Watch Items

Issue tracker mapping: MacProvider native MTP umbrella
https://github.com/Augustas11/macprovider/issues/1770

Required or relevant upstream rows now tracked by
`beta/throughput-engineering/UPSTREAM_WATCH.json`:

- ml-explore/mlx-swift-lm#351, "Add Qwen3.5 MTP speculative decoding":
  merged 2026-08-13, merge commit
  `01472a78fca830689ff78246a82c6d31ab111a78`, not in release `3.31.4`.
  https://github.com/ml-explore/mlx-swift-lm/pull/351
- ml-explore/mlx-swift-lm#516, "Speculate past the sliding window in MTP":
  merged 2026-08-11, merge commit
  `2af378b3557384f6c6ce936fab8e9748a1e8d61a`, not in release `3.31.4`.
  https://github.com/ml-explore/mlx-swift-lm/pull/516
- ml-explore/mlx-swift-lm#505, MTP sliding-window crash:
  closed 2026-08-05, retained as historical root-cause evidence.
  https://github.com/ml-explore/mlx-swift-lm/issues/505
- ml-explore/mlx-swift-lm#510, Mamba/hybrid rewind:
  open as of this gate.
  https://github.com/ml-explore/mlx-swift-lm/pull/510
- ml-explore/mlx-swift-lm#545, Qwen 3.8 text/VLM/MTP support:
  open as of this gate.
  https://github.com/ml-explore/mlx-swift-lm/pull/545
- ml-explore/mlx-swift-lm#581, resumable Qwen MTP in ChatSession:
  open as of this gate.
  https://github.com/ml-explore/mlx-swift-lm/pull/581
- ml-explore/mlx-swift-lm#584, wrap-aware rotating-cache trimming:
  merged 2026-09-11, merge commit
  `604fae710a4e3324346fc59e3845952350acd4b7`, not in release `3.31.4`.
  https://github.com/ml-explore/mlx-swift-lm/pull/584
- ml-explore/mlx-swift-lm#622, exact rotating-cache prefix rewinds:
  open as of this gate.
  https://github.com/ml-explore/mlx-swift-lm/pull/622

## Build Direction

Allowed now:

- Keep `native_mtp` fail-closed and default-off.
- Keep selector/config/status scaffolding isolated from production generation.
- Keep upstream watch automation and compile probes current.
- Re-run the upstream gate when `mlx-swift-lm` publishes a newer release.

Blocked now:

- No production native MTP scheduler path.
- No package-private upstream API usage.
- No floating pin to upstream `main`.
- No forked transaction API hidden inside MacProvider.
- No claim that MXFP8 support alone satisfies SPEC-048.

The next implementation phase starts only after a tagged public upstream release
contains the required MTP commits and exposes a reviewed public row/position
transaction API suitable for MacProvider's cache ownership model.
