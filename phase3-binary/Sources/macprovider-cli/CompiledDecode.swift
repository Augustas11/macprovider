import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Per-token decode forward wrapped in `MLX.compile()`, gated by
/// `MACPROVIDER_COMPILED_DECODE`. Scaffolded for Phase 4 of
/// `specs/perf-mlx-compile-bf16-upgrade.md` and the upstream
/// reference work in Layr-Labs/d-inference#482.
///
/// This file ships the wrapper and a static factory in this PR so the
/// integration surface is reviewable. The wire-in to `ModelRuntime`'s
/// decode path lands together with live correctness measurement — the
/// flag is OFF by default in this branch per spec, so the runtime path
/// continues to call the uncompiled forward.
///
/// Compile-with-state correctness rules followed here:
///   * Per-token input shape is fixed at `[1, 1]` (B=1). The compiler
///     traces the graph for this shape; prefill (variable input length)
///     is NOT wrapped.
///   * `[KVCache]` is passed as `inputs:` AND `outputs:` to compile() so
///     the in-place mutations performed by `cache.update(keys:values:)`
///     are threaded through the compiled function rather than captured
///     at trace time. `KVCacheSimple.innerState()` returns its
///     `[keys, values]` MLXArrays; the `Updatable` conformance carries
///     that mutation across calls.
///   * Model weights are read-only inside the compiled function. We do
///     NOT pass `model` in `inputs:` — MLX traces module parameters as
///     constants on first call, which is exactly what we want for
///     decode (weights don't change per step).
enum CompiledDecode {
    /// `1`, `true`, or `yes` (case-insensitive) enables compile()-wrapped
    /// decode forward.
    static let envFlag = "MACPROVIDER_COMPILED_DECODE"

    static func isEnabledByEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env[envFlag]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }
}

/// `Updatable` adapter that forwards to a `KVCache`'s `innerState()`.
///
/// `KVCache` conforms to `Evaluatable` (same shape as `Updatable`), but
/// the two protocols are distinct in mlx-swift's type system. Rather
/// than declare retroactive `Updatable` conformance on the upstream
/// `BaseKVCache` (which the strict-concurrency build setting would flag),
/// we wrap each cache in this lightweight adapter at the compile() call
/// site. The adapter holds the cache by reference, so subsequent
/// `cache.update(keys:values:)` mutations are visible to MLX through
/// `innerState()` on the next compiled-function call.
private final class KVCacheUpdatableAdapter: Updatable {
    private let cache: KVCache
    init(_ cache: KVCache) { self.cache = cache }
    func innerState() -> [MLXArray] { cache.innerState() }
}

/// A compiled per-token decode step bound to a specific `(model, cache)`
/// pair. Construction is cheap (no compile work yet); the first invocation
/// triggers the MLX trace + compile. Subsequent calls reuse the compiled
/// graph as long as the input shape is unchanged.
///
/// Lifetime: a single `CompiledDecodeStep` belongs to one generation
/// request. The compiled closure captures the specific cache array
/// identity, so do not reuse one step across two different KV caches.
/// Discard at end-of-request.
///
/// **Cache-state precondition (when `enabled: true`):** construct AFTER
/// prefill has populated the KV cache. `KVCacheSimple.innerState()`
/// returns `[]` for an empty cache and `[keys, values]` once
/// `update(...)` has run. `MLX.compile()` reads the `inputs:` /
/// `outputs:` state on every call; a step constructed against an empty
/// cache and then used after prefill would see the state-array count
/// change between calls, which risks silent recompile or — worse —
/// reuse of a traced graph that never threaded the cache (decode
/// reads stale KV state, producing wrong tokens). The initializer
/// asserts this when `enabled == true`. The runtime wire-in (deferred
/// to a follow-up PR) must construct the step AFTER prefill, not
/// before. See `audits/2026-06-30/perf-mlx-compile-bf16-audit.md`
/// ADV-1 for the underlying concern.
final class CompiledDecodeStep {
    /// The original (uncompiled) per-token forward. Used (a) for
    /// correctness comparison in tests, and (b) as the no-op fallback
    /// when compile is disabled.
    private let uncompiled: (MLXArray) -> MLXArray

    /// The compiled wrapper; `nil` when `enabled == false`.
    private let compiled: ((MLXArray) -> MLXArray)?

    let enabled: Bool

    /// - Parameters:
    ///   - model: the loaded `LanguageModel`. Treated as having
    ///     read-only weights for the duration of generation.
    ///   - cache: the `[KVCache]` for the in-flight request. The same
    ///     instances must be reused across every call to `step(_:)`
    ///     — the compiled graph threads their `innerState()` through.
    ///   - enabled: when `false`, `step(_:)` invokes the uncompiled
    ///     forward directly. When `true`, the compiled wrapper is used.
    init(
        model: any LanguageModel,
        cache: [KVCache],
        enabled: Bool
    ) {
        let forward: (MLXArray) -> MLXArray = { token in
            // `[1,1]` shape: token IDs for B=1 decode. The model's
            // `callAsFunction(_ inputs: MLXArray, cache: [KVCache]?)`
            // overload (see LanguageModel.swift) returns the next-step
            // logits as `[1, 1, vocab]`.
            model(token, cache: cache.isEmpty ? nil : cache)
        }
        self.uncompiled = forward
        self.enabled = enabled

        if enabled {
            // Precondition (ADV-1): cache MUST have populated state when
            // we construct the compiled wrapper. An empty `innerState()`
            // would cause `MLX.compile()` to trace with a zero-length
            // state array; once prefill populates `[keys, values]`, the
            // compiled graph's state shape no longer matches subsequent
            // calls, risking silent recompile or stale-state reads.
            precondition(
                cache.allSatisfy { !$0.innerState().isEmpty },
                "CompiledDecodeStep requires a populated KV cache — construct AFTER prefill, not before. See `audits/2026-06-30/perf-mlx-compile-bf16-audit.md` ADV-1."
            )
            let updatables: [any Updatable] = cache.map { KVCacheUpdatableAdapter($0) }
            // Same KV-cache arrays are read from AND written to by
            // `cache.update(...)` inside the model's attention layer.
            // Passing them in both `inputs:` and `outputs:` is the
            // canonical compile-with-mutable-state pattern.
            self.compiled = MLX.compile(
                inputs: updatables,
                outputs: updatables,
                shapeless: false,
                forward
            )
        } else {
            self.compiled = nil
        }
    }

    /// Run one decode step. `token` is the previous-token ID as a
    /// `[1, 1]` MLXArray.
    func step(_ token: MLXArray) -> MLXArray {
        if let compiled {
            return compiled(token)
        }
        return uncompiled(token)
    }
}
