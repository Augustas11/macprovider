import Foundation
import MacProviderCore
import MLX
import MLXLMCommon

// SPEC-048-R013 (0.1.51): the production continuous-batching decode path
// configuration — backend construction, compiled-decode mode, cache bridge,
// prefill grouping, decode row and lockstep bounds and text preparation —
// lives in this file so `decode-path-manifest.json` covers it. Moved
// unchanged from ModelRuntime.swift.
extension ModelRuntime {
    /// The serve path's scheduler configuration, shared by initial load and
    /// every rebuild (warm swap, adoption), so the row cap always tracks the
    /// served context.
    nonisolated static func productionContinuousBatchSchedulerConfiguration(
        descriptor: PagedKVDescriptor,
        tuple: ContinuousBatchingRequestedTuple,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String,
        modelSHA256: String,
        weightsGeneration: Int,
        prefillStepSize: Int,
        maxDecodeLockstepWindow: Int,
        nativeMTPRoundByteCapacity: Int?,
        nativeMTPStatusSink: NativeMTPStatusSink?,
        prefillGrouping: ContinuousBatchPrefillGroupingRule,
        allowsRaggedPrefillOffsets: Bool = false,
        nativeMTPPromptRowsJoinRaggedPrefill: Bool = false,
        maxDecodeRowsPerForward: Int = Int.max
    ) -> ContinuousBatchSchedulerConfiguration {
        ContinuousBatchSchedulerConfiguration(
            descriptor: descriptor,
            tuple: tuple,
            moePromotionEvidenceAvailable: ContinuousBatchingPolicy.productionMoEPromotionEvidenceAvailable,
            maxActiveRows: maxBatch,
            queueLimit: queueLimit,
            decodeHeadroomTokens: ContinuousBatchSchedulerConfiguration.defaultDecodeHeadroomTokens,
            maxPrefillRowsPerIteration: min(
                maxBatch,
                ContinuousBatchSchedulerConfiguration.defaultPrefillRowsPerIteration
            ),
            prefillGrouping: prefillGrouping,
            maxPrefillTokensPerIteration: prefillTokensPerIteration
                ?? ContinuousBatchSchedulerConfiguration.defaultPrefillTokensPerIteration,
            maxPromptChunkTokens: min(
                max(1, prefillStepSize),
                ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens
            ),
            allowsRaggedPrefillOffsets: allowsRaggedPrefillOffsets,
            nativeMTPPromptRowsJoinRaggedPrefill: nativeMTPPromptRowsJoinRaggedPrefill,
            tokenDeliveryBufferLimit: ContinuousBatchSchedulerConfiguration.productionTokenDeliveryBufferLimit,
            queueWaitTimeoutNanoseconds: Self.queueWaitTimeoutNanoseconds(queueWaitTimeoutMS),
            // The row cap is the served context, not the scheduler's
            // 131,072 test default: a 200k-context provider must batch
            // what its serial path accepts. `maxQueuedTokens` is lifted
            // to at least this by the configuration.
            maxRequestTokens: maxContextTokens,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration
            ),
            maxDecodeLockstepWindow: maxDecodeLockstepWindow,
            maxDecodeStepsWhilePrefilling: ContinuousBatchSchedulerConfiguration.defaultDecodeStepsWhilePrefilling,
            maxDecodeRowsPerForward: maxDecodeRowsPerForward,
            nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
            nativeMTPStatusSink: nativeMTPStatusSink
        )
    }

    /// The decode row bound every scheduler is built with: the configured
    /// (device) bound capped by the backend's flattened-token bound
    /// (`glm5_next` pagedMLA: 8, SPEC-039 v0.1.19). Applied here, where every
    /// serve, lab and harness scheduler is built, so no construction path can
    /// configure a wider decode forward than its backend runs.
    nonisolated static func schedulerDecodeRowBound(
        configured: Int,
        backend: (any ContinuousBatchSchedulerBackend)?
    ) -> Int {
        guard let cap = (backend as? PagedKVSharedForwardBackend)?.maxDecodeRowsPerForward, cap < configured else {
            return configured
        }
        FileHandle.standardError.write(Data(
            "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(cap) device_bound=\(configured) reason=flattened_token_cap\n".utf8
        ))
        return cap
    }

    /// The scheduler may group a native prompt at a different offset only
    /// when the backend carries a family-specific shared-forward capability,
    /// or when its flattened-token bound already serializes grouped rows.
    nonisolated static func schedulerNativeMTPPromptRowsJoinRaggedPrefill(
        backend: (any ContinuousBatchSchedulerBackend)?,
        prefillGrouping: ContinuousBatchPrefillGroupingRule
    ) -> Bool {
        guard let backend = backend as? PagedKVSharedForwardBackend else { return false }
        return backend.nativeMTPPromptRowsJoinRaggedPrefill
            || PagedKVSharedForwardBackend.prefillsGroupedRowsAlone(
                cacheKinds: backend.cacheKinds,
                minimumGroupedChunkTokens: prefillGrouping.minimumGroupedChunkTokens
            )
    }

    static func makeContinuousBatchTextPreparationLane(
        container: ModelContainer?,
        admissionCapability: NativeMTPAdmissionCapability?,
        nativeVisionProfile: NativeVisionProfile?,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]? = nil
    ) async -> ContinuousBatchTextPreparationLane? {
        guard continuousBatchTextPreparationEligible(
                familyAdapter: admissionCapability?.familyAdapter,
                nativeVisionProfile: nativeVisionProfile
              ),
              let container else {
            return nil
        }
        let resolvedCacheKinds: [PagedKVSharedForwardBackend.CacheKind]?
        if let cacheKinds {
            resolvedCacheKinds = cacheKinds
        } else {
            resolvedCacheKinds = await pagedKVCacheKinds(container: container)
        }
        guard let resolvedCacheKinds else { return nil }
        let processor = await container.processor
        let tokenizer = await container.tokenizer
        let configuration = await container.configuration
        return ContinuousBatchTextPreparationLane(
            processor: processor,
            tokenizer: tokenizer,
            configuration: configuration,
            hasRecurrentLayers: resolvedCacheKinds.contains(.recurrentMamba)
        )
    }

    static func continuousBatchTextPreparationEligible(
        familyAdapter: String?,
        nativeVisionProfile: NativeVisionProfile?
    ) -> Bool {
        familyAdapter == "qwen3_5_mtp_v1" && nativeVisionProfile == nil
    }

    nonisolated static func makeContinuousBatchScheduler(
        decision: PagedKVAttachDecision,
        tuple: ContinuousBatchingRequestedTuple?,
        backend: (any ContinuousBatchSchedulerBackend)?,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String?,
        modelSHA256: String?,
        weightsGeneration: Int,
        prefillStepSize: Int,
        maxDecodeLockstepWindow: Int = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow,
        nativeMTPRoundByteCapacity: Int? = nil,
        nativeMTPStatusSink: NativeMTPStatusSink? = nil,
        prefillGrouping: ContinuousBatchPrefillGroupingRule,
        maxDecodeRowsPerForward: Int = Int.max,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
        contiguousCacheBridge: PagedKVRuntimeContiguousCacheBridge? = nil
    ) -> ContinuousBatchScheduler? {
        guard case .attached(let descriptor) = decision,
              let tuple,
              let backend,
              let modelID,
              let modelSHA256,
              tuple.isAdmitted(by: descriptor)
        else {
            return nil
        }
        guard let allocator = try? PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            contiguousCacheBridge: contiguousCacheBridge
        ) else {
            return nil
        }
        if let event = ContinuousBatchingPolicy.queueLimitClampEvent(configured: queueLimit, maxActiveRows: maxBatch) {
            FileHandle.standardError.write(Data("\(event) stage=scheduler\n".utf8))
        }
        return ContinuousBatchScheduler(
            configuration: productionContinuousBatchSchedulerConfiguration(
                descriptor: descriptor,
                tuple: tuple,
                maxBatch: maxBatch,
                queueLimit: queueLimit,
                queueWaitTimeoutMS: queueWaitTimeoutMS,
                prefillTokensPerIteration: prefillTokensPerIteration,
                maxContextTokens: maxContextTokens,
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration,
                prefillStepSize: prefillStepSize,
                maxDecodeLockstepWindow: maxDecodeLockstepWindow,
                nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
                nativeMTPStatusSink: nativeMTPStatusSink,
                prefillGrouping: prefillGrouping,
                allowsRaggedPrefillOffsets: (backend as? PagedKVSharedForwardBackend)?
                    .supportsRaggedPrefillOffsets ?? false,
                nativeMTPPromptRowsJoinRaggedPrefill: schedulerNativeMTPPromptRowsJoinRaggedPrefill(
                    backend: backend,
                    prefillGrouping: prefillGrouping
                ),
                maxDecodeRowsPerForward: schedulerDecodeRowBound(configured: maxDecodeRowsPerForward, backend: backend)
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: replayAuthority,
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    static func makeContinuousBatchScheduler(
        decision: PagedKVAttachDecision,
        tuple: ContinuousBatchingRequestedTuple?,
        container: ModelContainer?,
        nativeMTPDrafterContainer: MTPDrafterContainer? = nil,
        nativeMTPAdmissionCapability: NativeMTPAdmissionCapability? = nil,
        backendOverride: (any ContinuousBatchSchedulerBackend)?,
        maxBatch: Int,
        queueLimit: Int?,
        queueWaitTimeoutMS: Int?,
        prefillTokensPerIteration: Int?,
        maxContextTokens: Int,
        modelID: String?,
        modelSHA256: String?,
        weightsGeneration: Int,
        kvBitsOverride: Int?,
        prefillStepSize: Int,
        nativeMTPStatusSink: NativeMTPStatusSink? = nil,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority,
        cachedTurns: Bool
    ) async -> ContinuousBatchScheduler? {
        let nativeMTPRoundByteCapacity: Int?
        if nativeMTPDrafterContainer != nil {
            guard let capacity = Self.nativeMTPRoundByteCapacity(from: nativeMTPAdmissionCapability) else {
                return nil
            }
            nativeMTPRoundByteCapacity = capacity
        } else {
            nativeMTPRoundByteCapacity = nil
        }
        if let backendOverride {
            return makeContinuousBatchScheduler(
                decision: decision,
                tuple: tuple,
                backend: backendOverride,
                maxBatch: maxBatch,
                queueLimit: queueLimit,
                queueWaitTimeoutMS: queueWaitTimeoutMS,
                prefillTokensPerIteration: prefillTokensPerIteration,
                maxContextTokens: maxContextTokens,
                modelID: modelID,
                modelSHA256: modelSHA256,
                weightsGeneration: weightsGeneration,
                prefillStepSize: prefillStepSize,
                maxDecodeLockstepWindow: decodeLockstepWindow(backendOverride: backendOverride),
                nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
                nativeMTPStatusSink: nativeMTPStatusSink,
                // Test backends run no MLX kernels.
                prefillGrouping: .unconstrained,
                replayAuthority: replayAuthority
            )
        }
        guard case .attached(let descriptor) = decision,
              let container,
              let cacheKinds = await pagedKVCacheKinds(container: container)
        else {
            return nil
        }
        // A hybrid (Qwen3.6) row retains its paged KV only when cached-turn
        // batching is on (SPEC-038 AC-26): the next turn then restores the
        // recurrent layers from a checkpoint. Off, a keyed hybrid row keeps the
        // serial-format materialize at terminal instead.
        let isHybrid = cacheKinds.contains(.recurrentMamba)
        let contiguousCacheBridge = isHybrid && !cachedTurns ? nil : PagedKVRuntimeContiguousCacheBridge()
        let maxDecodeLockstepWindow = servePathDecodeLockstepWindow(cacheKinds: cacheKinds)
        let prefillGrouping = await continuousBatchPrefillGrouping(container: container, modelID: modelID)
        return makeContinuousBatchScheduler(
            decision: decision,
            tuple: tuple,
            backend: PagedKVSharedForwardBackend(
                container: container,
                descriptor: descriptor,
                layerCount: cacheKinds.count,
                cacheKinds: cacheKinds,
                contiguousCacheBridge: contiguousCacheBridge,
                // Off on the serve path. A replayed `MLX.compile` step never
                // re-runs `KVCacheSimple.update`'s Swift offset/grow logic, so
                // every step after the trace writes the same KV slot at the
                // same RoPE position: greedy rows loop on the prompt within a
                // few tokens and fail `continuous_batching_invalid_cache_layout`
                // once the traced buffer (seed + 256) is full. Measured on
                // Studio 2026-09-24: signed 176, 181 and main all degenerate
                // with this on and are coherent with it off. Applies to
                // hybrid (Qwen3.6) and KV-only layouts alike.
                compiledDecode: false,
                drafterContainer: nativeMTPDrafterContainer,
                nativeMTPFamilyAdapter: nativeMTPAdmissionCapability?.familyAdapter
            ),
            maxBatch: maxBatch,
            queueLimit: queueLimit,
            queueWaitTimeoutMS: queueWaitTimeoutMS,
            prefillTokensPerIteration: prefillTokensPerIteration,
            maxContextTokens: maxContextTokens,
            modelID: modelID,
            modelSHA256: modelSHA256,
            weightsGeneration: weightsGeneration,
            prefillStepSize: prefillStepSize,
            maxDecodeLockstepWindow: maxDecodeLockstepWindow,
            nativeMTPRoundByteCapacity: nativeMTPRoundByteCapacity,
            nativeMTPStatusSink: nativeMTPStatusSink,
            prefillGrouping: prefillGrouping,
            maxDecodeRowsPerForward: continuousBatchDecodeRowBound(cacheKinds: cacheKinds),
            replayAuthority: replayAuthority,
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    /// The runtime identity the FR-CB10 self-check result is stored under:
    /// the MLX pin plus this build's row-isolation policy (SPEC-038 FR-CB2
    /// v0.3.17: per-row attention routes and the decode and verify forward
    /// bounds of this device) and the FR-CB10 probe version and route
    /// boundary (v0.3.19; with the decode window they fix the probe prompts
    /// and completion length, so stored lone outputs always match them). A
    /// result measured before the policy, at other bounds or by an older
    /// probe matches no live key, so the check re-runs; an earlier grant
    /// carries the Mac through the re-run as for an MLX pin change.
    static var continuousBatchingSelfCheckRuntimeBuild: String {
        continuousBatchingSelfCheckRuntimeBuild(forwardBound: PagedKVSharedForwardBackend.deviceVerifyTokenBound)
    }

    /// A backend with a flattened-token cap (`glm5_next`) keys on the bound
    /// it actually serves under plus the cap itself, so a grant measured
    /// under one bound never survives a change to it.
    static func continuousBatchingSelfCheckRuntimeBuild(
        forwardBound deviceBound: Int,
        routeKeyBoundary: Int = ContinuousBatchingSelfCheck.deviceRouteKeyBoundary,
        forwardTokenCap: Int? = nil
    ) -> String {
        let bound = min(deviceBound, forwardTokenCap ?? Int.max)
        let cap = forwardTokenCap.map { "+flat\($0)" } ?? ""
        // glm5_next (the only capped backend) measures a decode-only gain
        // (SPEC-038 v0.3.21) under its own probe version; every other key is
        // unchanged.
        let probe = forwardTokenCap == nil
            ? ContinuousBatchingSelfCheck.probeVersion
            : ContinuousBatchingSelfCheck.glm5NextProbeVersion
        return "\(ContinuousBatchingSelfCheckKey.currentRuntimeBuild)+cb-isolation-v1/decode\(bound)/verify\(bound)"
            + "+\(probe)/route\(routeKeyBoundary)" + cap
    }

    /// Metal architecture name as MLX core reads it (`MLX_METAL_GPU_ARCH`
    /// overrides the device's own).
    static func metalArchitectureForQuantizedRoutes() -> String {
        if let override = ProcessInfo.processInfo.environment["MLX_METAL_GPU_ARCH"], !override.isEmpty {
            return override
        }
        return GPU.deviceInfo().architecture
    }

    /// The decode row bound for this device (`ContinuousBatchDecodeRouteBound`).
    /// The decode row bound for this device, further capped by the backend's
    /// flattened-token bound for `cacheKinds` (`glm5_next`: 8, SPEC-039
    /// v0.1.19), so the logged bound is the one the scheduler splits by.
    static func continuousBatchDecodeRowBound(cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?) -> Int {
        let deviceBound = continuousBatchDecodeRowBound()
        let bound = effectiveDecodeRowBound(deviceBound: deviceBound, cacheKinds: cacheKinds)
        if bound != deviceBound {
            FileHandle.standardError.write(Data(
                "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(bound) device_bound=\(deviceBound) reason=flattened_token_cap\n".utf8
            ))
        }
        return bound
    }

    static func effectiveDecodeRowBound(deviceBound: Int, cacheKinds: [PagedKVSharedForwardBackend.CacheKind]?) -> Int {
        guard let cacheKinds, let cap = PagedKVSharedForwardBackend.maxFlattenedTokensPerForward(cacheKinds: cacheKinds) else {
            return deviceBound
        }
        return min(deviceBound, cap)
    }

    static func continuousBatchDecodeRowBound() -> Int {
        let architecture = metalArchitectureForQuantizedRoutes()
        let deviceBound = ContinuousBatchDecodeRouteBound.maxDecodeRowsPerForward(architecture: architecture)
        #if MACPROVIDER_LAB_HARNESS
        // Lab measurement only: capped vs uncapped decode forwards.
        let bound = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_DECODE_ROW_BOUND"]
            .flatMap { Int($0) }
            .flatMap { $0 >= 1 ? $0 : nil } ?? deviceBound
        #else
        let bound = deviceBound
        #endif
        FileHandle.standardError.write(Data(
            "event=continuous_batch_decode_row_bound max_decode_rows_per_forward=\(bound)\n".utf8
        ))
        return bound
    }

    /// The loaded model's prefill grouping rule, from its own `config.json`.
    /// A container not loaded from a local directory has no readable
    /// configuration and fails safe to `.ungrouped`.
    static func continuousBatchPrefillGrouping(
        container: ModelContainer,
        modelID: String?
    ) async -> ContinuousBatchPrefillGroupingRule {
        guard case .directory(let directory) = await container.configuration.id else {
            return .ungrouped
        }
        let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        let rule = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(configData, modelID: modelID)
        let bound = rule.minimumGroupedChunkTokens == Int.max ? "none" : String(rule.minimumGroupedChunkTokens)
        FileHandle.standardError.write(Data(
            "event=continuous_batch_prefill_grouping min_grouped_chunk_tokens=\(bound)\n".utf8
        ))
        return rule
    }

    /// Every cache layout, hybrid (recurrent + attention) included, decodes
    /// in the 16-step window (SPEC-038 FR-CB2). Hybrid recurrent state is
    /// packed once per window, advances one token per step inside it, and is
    /// split back to rows at the window end; a row that stops mid-window keeps
    /// recurrent checkpoints at its stop boundary. Exactness against one-step
    /// windows: `HybridDecodeWindowExactnessTests` (tiny Qwen3.5, prompts past
    /// the 512-token chunk) and `msb-throughput --scenario hybrid-window` on
    /// the served artifact.
    nonisolated static func servePathDecodeLockstepWindow(
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind]
    ) -> Int {
        #if MACPROVIDER_LAB_HARNESS
        // Lab A/B measurement only (#1906): a smaller hybrid window, down to 1.
        if cacheKinds.contains(.recurrentMamba),
           let raw = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_HYBRID_DECODE_WINDOW"],
           let window = Int(raw), window >= 1 {
            return min(window, ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow)
        }
        #endif
        return ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow
    }

    /// An injected real paged-KV backend (native-MTP bench / hardware E2E)
    /// must decode in the serve path's windows, or its stream cadence and
    /// throughput are not production's. Scripted test backends keep the
    /// default window.
    nonisolated static func decodeLockstepWindow(
        backendOverride: any ContinuousBatchSchedulerBackend
    ) -> Int {
        guard let paged = backendOverride as? PagedKVSharedForwardBackend else {
            return ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow
        }
        return servePathDecodeLockstepWindow(cacheKinds: paged.cacheKinds)
    }
}
