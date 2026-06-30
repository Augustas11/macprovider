# MLX Upgrade Feasibility Report — Phase 1 of perf/mlx-compile-bf16

**Date:** 2026-06-30
**Branch:** `perf/mlx-compile-bf16`
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`

## Upstream state

| Package | Latest tag | Released | Our pin (before) | Our pin (after) |
|---|---|---|---|---|
| `ml-explore/mlx-swift-examples` | **2.29.1** | 2025-10-16 | exact: `2.29.1` | exact: `2.29.1` (unchanged) |
| `ml-explore/mlx-swift` | **0.31.4** | 2026-06-01 | transitive `0.29.1` | transitive `0.29.1` (unchanged) |

Source: `gh release list -R ml-explore/mlx-swift-examples --limit 10` and
`gh release list -R ml-explore/mlx-swift --limit 10`, both run 2026-06-30.

## Path chosen: **C (stay)**

### Why not A (clean bump)
We are already pinned at `mlx-swift-examples 2.29.1`, which IS the latest
release. There is no newer `mlx-swift-examples` to bump to. A is N/A.

### Why not B (override)
`mlx-swift-examples` 2.29.1's `Package.swift` declares its dependency on
`mlx-swift` as `.upToNextMinor(from: "0.29.1")` — i.e. `[0.29.1, 0.30.0)`.
This excludes the two minor releases that have shipped since
(0.30.x in 2026-01/02, 0.31.x in 2026-03 through 2026-06).

We attempted Path B per the spec by adding an explicit root-level
override:

```swift
.package(
    url: "https://github.com/ml-explore/mlx-swift.git",
    from: "0.31.0"
),
```

`swift package resolve` rejected this immediately:

```
error: Dependencies could not be resolved because root depends on
'mlx-swift' 0.31.0..<1.0.0.
'mlx-swift' 0.29.1..<0.30.0 is required because 'mlx-swift-examples'
2.29.1 depends on 'mlx-swift' 0.29.1..<0.30.0 and root depends on
'mlx-swift-examples' 2.29.1.
```

SwiftPM cannot intersect `[0.31.0, 1.0.0)` with `[0.29.1, 0.30.0)`.
Version-range overrides do not bypass intersection — only
`branch:` / `revision:` pins do, and pulling an untagged commit of
`mlx-swift` would (a) be unstable, (b) almost certainly break MLXLLM
source compilation since MLXLLM in 2.29.1 was authored against the
0.29.x API surface.

The spec explicitly anticipates this failure mode and authorizes the
fallback: *"If MLXLLM API drift breaks the build (likely since MLXLLM
is sourced from mlx-swift-examples which was tested against the older
mlx-swift), revert the override and fall back to Path C."* In our case
resolution failed before we even reached the source-compile step, which
is a stronger signal in the same direction. Override reverted in this
PR.

### Why C is acceptable for our perf work
The two perf primitives we want — `compile()` graph wrapper and bf16
weight cast — both exist in `mlx-swift` 0.29.x:

- `compile(_:)` and `compiled(_:)` shipped well before 0.29.x (functional
  graph compile is a longstanding MLX feature).
- `bfloat16` dtype + `astype(.bfloat16)` likewise long-standing.

So Path C does not block Phase 2/3/4 from landing the perf win. The
"newer MLX" angle is essentially about future improvements to compile
fusion / kernel selection that may have shipped in 0.30/0.31 — those are
upside, not blockers.

## What it would take to actually upgrade

The blocking constraint is upstream: `mlx-swift-examples` needs to cut
a release that updates its own `.upToNextMinor(from:)` floor on
`mlx-swift`. Until then, the only ways to pull a newer `mlx-swift` into
our build are:

1. **Wait for `mlx-swift-examples` ≥ 2.30** to ship — passive.
2. **Fork `mlx-swift-examples`**, bump the floor, and source MLXLLM from
   the fork — explicitly out of scope per the spec ("Do NOT switch
   dependency to `Layr-Labs/mlx-swift-lm`. Stay on `mlx-swift-examples`.
   Do NOT vendor MLX or patch upstream.").
3. **Reimplement MLXLLM-equivalent runtime locally** against the newer
   `mlx-swift` directly — well out of scope.

(1) is the right answer. Track new `mlx-swift-examples` releases and
re-run this Phase 1 evaluation when one lands.

## Outcome

- Pin: unchanged at `mlx-swift-examples 2.29.1` (mlx-swift 0.29.1
  transitively).
- Proceed to Phase 2 (baseline) on this pin.
- File a follow-up note: re-check upstream when next
  `mlx-swift-examples` release drops; if it pins `mlx-swift ≥ 0.30`,
  re-run Phase 1 and bump.
