import Foundation
import MLX
import MacProviderCore

/// One reading for the SPEC-038 FR-CB2 (v0.3.36) memory-limit admission check.
struct MLXMemoryAdmissionSample: Sendable, Equatable {
    /// MLX's effective process memory limit.
    let limitBytes: Int
    /// MLX's active (non-cache) memory now: weights, live KV, temporaries.
    let activeBytes: Int
    /// KV bytes per token of the loaded model, 0 when unknown.
    let kvBytesPerToken: Int
}

/// Live source for the admission check. `.system` reads the limit the
/// runtime applied; before any limit is applied (tests, non-Metal hosts) it
/// returns nil and admission is unchanged.
struct MLXMemoryAdmissionProbe: Sendable, Equatable {
    let identity: String
    private let sampleProvider: @Sendable () -> MLXMemoryAdmissionSample?

    init(identity: String, sampleProvider: @escaping @Sendable () -> MLXMemoryAdmissionSample?) {
        self.identity = identity
        self.sampleProvider = sampleProvider
    }

    func sample() -> MLXMemoryAdmissionSample? { sampleProvider() }

    static let system = MLXMemoryAdmissionProbe(identity: "system") { MLXMemoryLimit.admissionSample() }

    static func == (lhs: MLXMemoryAdmissionProbe, rhs: MLXMemoryAdmissionProbe) -> Bool {
        lhs.identity == rhs.identity
    }
}

/// Applies `MLXMemoryBudget.limitBytes` to MLX and remembers it for admission.
enum MLXMemoryLimit {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var limitBytes: Int?
        var kvBytesPerToken = 0
    }

    private static let state = State()

    /// Sets MLX's memory limit for this process and logs the effective value.
    /// `stage` is `startup` before the model loads and `model_loaded` after,
    /// when MLX's active memory is the resident model (the small-Mac floor).
    @discardableResult
    static func apply(stage: String, kvBytesPerToken: Int?) -> Int? {
        let workingSet = GPU.maxRecommendedWorkingSetBytes()
        let physical = ProcessInfo.processInfo.physicalMemory
        let resident = Memory.activeMemory
        guard let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: physical, residentBytes: resident
        ) else {
            FileHandle.standardError.write(Data("event=mlx_memory_limit stage=\(stage) applied=false reason=working_set_unavailable\n".utf8))
            return nil
        }
        Memory.memoryLimit = limit
        let perToken = max(0, kvBytesPerToken ?? 0)
        state.lock.lock()
        state.limitBytes = limit
        state.kvBytesPerToken = perToken
        state.lock.unlock()
        let line = [
            "event=mlx_memory_limit stage=\(stage) applied=true limit_bytes=\(limit) ",
            "working_set_bytes=\(workingSet ?? 0) physical_bytes=\(physical) resident_bytes=\(resident) ",
            "kv_bytes_per_token=\(perToken)\n",
        ].joined()
        FileHandle.standardError.write(Data(line.utf8))
        return limit
    }

    static func admissionSample() -> MLXMemoryAdmissionSample? {
        state.lock.lock()
        let limit = state.limitBytes
        let perToken = state.kvBytesPerToken
        state.lock.unlock()
        guard let limit else { return nil }
        return MLXMemoryAdmissionSample(limitBytes: limit, activeBytes: Memory.activeMemory, kvBytesPerToken: perToken)
    }

    /// SPEC-038 FR-CB2 (v0.3.36): the MLX buffer-cache bound serve applies to
    /// `modelID` for a configured `mlx_cache_limit_mb` (nil when unset), in
    /// bytes. Built from the same two functions `ModelRuntime` loads with, so
    /// commands that load outside it cannot drift from serve. Nil only for an
    /// out-of-range configured value, which startup rejects first.
    static func serveCacheLimitBytes(
        modelID: String?,
        configuredMB: Int?,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int? {
        guard let megabytes = ModelRuntime.resolvedMLXCacheLimitMB(
                  configured: configuredMB, physicalMemoryBytes: physicalMemoryBytes),
              ModelRuntime.isValidMLXCacheLimitMB(megabytes)
        else { return nil }
        return ModelRuntime.modelScopedMLXCacheLimitBytes(modelID: modelID, baselineBytes: megabytes * 1024 * 1024)
    }

    /// Serve's MLX cache bound and memory limit for a model loaded outside
    /// `ModelRuntime` (shard stages, the native-MTP lab runner, shard-bench).
    /// Call it with `stage: "startup"` before the load and `"model_loaded"` after.
    @discardableResult
    static func applyServeLimits(
        stage: String, modelID: String?, configuredCacheLimitMB: Int?, modelDirectory: URL?
    ) -> (cacheLimitBytes: Int?, memoryLimitBytes: Int?) {
        let cache = serveCacheLimitBytes(modelID: modelID, configuredMB: configuredCacheLimitMB)
        if let cache {
            Memory.cacheLimit = cache
            FileHandle.standardError.write(Data("mlx_cache_limit_bytes=\(cache) stage=\(stage)\n".utf8))
        }
        let limit = apply(
            stage: stage, kvBytesPerToken: stage == "startup" ? nil : kvBytesPerToken(modelDirectory: modelDirectory))
        return (cache, limit)
    }

    /// KV bytes per token from a model directory's `config.json`, nil when
    /// the directory or its attention geometry is unreadable.
    static func kvBytesPerToken(modelDirectory: URL?) -> Int? {
        guard let modelDirectory,
              let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        else { return nil }
        return AutotuneModelContextCap.kvCacheBytesPerToken(configData: data)
    }
}
