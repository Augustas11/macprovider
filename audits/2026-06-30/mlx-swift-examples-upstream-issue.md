**Problem.** `mlx-swift-examples` 2.29.1's `Package.swift` pins `mlx-swift` via `.upToNextMinor(from: "0.29.1")` (resolves to `[0.29.1, 0.30.0)`). This means consumers (apps that depend on `mlx-swift-examples` for `MLXLLM` / `MLXLMCommon`) cannot pull `mlx-swift` ≥ 0.30 even if they would like to:

- `mlx-swift` 0.30.x shipped in 2026-01 / 2026-02
- `mlx-swift` 0.31.x shipped 2026-03 through 2026-06 (latest 0.31.4, 2026-06-01)

An attempt to override at the consumer's root manifest with e.g.

```swift
.package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0"),
```

fails resolution because SwiftPM cannot intersect `[0.31.0, 1.0.0)` with `[0.29.1, 0.30.0)`:

```
error: Dependencies could not be resolved because root depends on
'mlx-swift' 0.31.0..<1.0.0.
'mlx-swift' 0.29.1..<0.30.0 is required because 'mlx-swift-examples'
2.29.1 depends on 'mlx-swift' 0.29.1..<0.30.0 and root depends on
'mlx-swift-examples' 2.29.1.
```

The only consumer-side escape is a `branch:` / `revision:` pin of `mlx-swift`, which is unstable and likely breaks `MLXLLM` source compilation since the in-tree code was written against the 0.29.x API.

**Concrete impact.** As of today (2026-06-30), `mlx-swift-examples` 2.29.1 remains the latest tagged release (~8.5 months old). Consumers who want to pick up perf improvements, kernel updates, or bug fixes that shipped in `mlx-swift` 0.30.x / 0.31.x have no path forward without forking.

**Request.** Either:

1. **Cut a 2.30.0 release** that updates the `mlx-swift` pin to allow 0.30.x / 0.31.x (and bumps in-tree `MLXLLM` / `MLXLMCommon` for any API drift), OR
2. **Loosen the constraint** in the next patch release to e.g. `.upToNextMajor(from: "0.29.1")` so consumers can opt into newer minors without waiting for a coordinated release. (`upToNextMinor` is conservative for a library this widely consumed; `upToNextMajor` is the SwiftPM-idiomatic default.)

Either path unblocks downstream consumers. I'm happy to send a PR to do (2) if that's the preferred path — let me know.

**Context.** Discovered this while landing a perf branch in our own provider runtime (compile()-wrapped decode + bf16 weight cast on dense Qwen/Llama). Both features work fine on `mlx-swift` 0.29.1, so this is not a blocker for us today; we're staying on 2.29.1 and tracking releases. But the constraint is a real friction surface for the community — wanted to surface it.

Thanks for the great library work.
