# SPEC-048 Phase-0 Upstream Gate - 2026-09-28

Status: PUBLIC TRANSACTION BOUNDARY QUALIFIED by a narrow immutable-dependency
exception; production native MTP serving remains default-off and unqualified.

## Verdict

MacProvider may now implement and test the default-off scheduler path against
one reviewed, immutable fork revision. That revision exposes the row-owned
cache transaction boundary that the released dependency lacked. This clears
the API-access portion of SPEC-048-R003 only; it does not clear artifact,
parity, multi-row, signed-evidence, hardware, audit, release, or production
enablement gates.

## Current Pins

Source of truth: `phase3-binary/Package.swift` and
`phase3-binary/Package.resolved`.

- `mlx-swift-lm`: fork `Augustas11/mlx-swift-lm`, exact revision
  `3c977326bd0ec2c5160c6b2ec48ba6ede1cc11db`, based on upstream
  `ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb`.
- `mlx-swift`: resolved `0.31.6`, revision
  `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`.
- `swift-transformers`: exact/resolved `1.3.4`, revision
  `c21fdcde390313a6d98d8e33a346f2c3486c3ab0`.
- `swift-jinja`: resolved `2.4.2`, revision
  `7d0b8880ef8e567dd4e0089f8b99fb354129017c`.

The latest tagged upstream `mlx-swift-lm` release observed by the watcher is
still `3.31.4`, published 2026-06-30:
https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4

## Qualified Public Surface

The pinned fork provides the existing public serial MTP symbols in
`MLXLMCommon`:

- `MTPDrafterModel`
- `MTPSpeculativeTokenIterator`
- `MTPDrafterModelFactory`

It additionally exposes the reviewed transaction facade:

- `MTPKVCacheStorage`
- `MTPKVCacheTransaction`
- `MTPKVCacheTransactionPosition`
- `MTPKVCacheTransactionCommit`
- `reconcileMTPSharedKVState`

The facade provides row/position metadata, isolated staging for stageable
attention caches, bounded native rewind for admitted attention/Mamba hybrids,
contiguous-prefix commit, rejected-tail discard, exact rollback, and shared-KV
reconciliation. The pinned `mlx-swift` also exposes
`QuantizationMode.mxfp8`.

The MacProvider qualification test exercises the facade as an external package
consumer. Upstream focused coverage passed 25 tests across two suites; seven
existing shared-KV reconciliation tests also passed. The complete facade diff
received an independent adversarial review with 0 Critical, 0 High, and 0
Medium findings. Two broader Qwen checkpoint-equivalence failures reproduced
unchanged on pristine upstream base and are recorded as baseline, not attributed
to the facade.

## Immutable-Dependency Exception

SPEC-048 v0.1.1 permits exactly the fork and revision above. The facade keeps
the underlying `KVCacheRound` strategies package-scoped and exposes only the
narrow ownership/transaction operations required by an external scheduler.
All other fork URLs, revisions, and source substitutions remain rejected.
The exception must be re-reviewed no later than `2026-12-27` if it has not
already been removed.

The exception is temporary. It must be removed in favor of the first reviewed
upstream tag that contains an equivalent public surface and passes this same
qualification. Closure of upstream issue #645 by itself is not sufficient;
the replacement tag and resolved revision must be checked independently.

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
- ml-explore/mlx-swift-lm#645, public transactional MTP step API for
  cached/batched callers: opened from this qualification because no existing
  tracker covered the external scheduler boundary. It requests a narrow stable
  facade for target-authoritative propose/verify/stage/commit/discard/rewind
  semantics without requiring package-private cache internals to become public.
  https://github.com/ml-explore/mlx-swift-lm/issues/645

## Build Direction

Allowed now:

- Keep `native_mtp` fail-closed and default-off.
- Implement the row-owned cache transaction, allocator transaction, and serial
  oracle needed by the production adapter.
- Prototype packed verification only behind the default-off gate; it cannot
  satisfy the Phase-2 exit gate until an external-consumer qualification proves
  explicit ragged row maps and one shared target forward.
- Keep upstream watch automation and compile probes current.
- Re-run the upstream replacement gate when `mlx-swift-lm` publishes a newer
  release.

Still blocked from production enablement:

- No package-private upstream API usage.
- No floating pin to upstream `main`.
- No fork revision other than the reviewed exact SHA.
- No claim that MXFP8 support alone satisfies SPEC-048.
- No tuple enablement before artifact, parity, multi-row, signed journey,
  hardware, audit, and release gates pass.
- No Phase-2 completion claim from the cache facade alone; the packed target
  verification boundary remains a separate required proof.

Upstream issue #645 remains the replacement tracker. MacProvider issue #1770
and the campaign PR remain open until the full multi-row and production-evidence
contract is complete; qualifying the fork is not issue completion.
