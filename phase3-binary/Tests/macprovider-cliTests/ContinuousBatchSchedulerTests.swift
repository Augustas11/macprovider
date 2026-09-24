import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class ContinuousBatchSchedulerTests: XCTestCase {
    func testDescriptorDrivenLocalCapabilityRejectsUnsupportedTuple() {
        let descriptor = Self.descriptor(supportsMoE: false)
        var tuple = Self.tuple()
        tuple = ContinuousBatchingRequestedTuple(
            modelID: tuple.modelID,
            modelSHA256: "different",
            tokenizerSHA256: tuple.tokenizerSHA256,
            chatTemplateSHA256: tuple.chatTemplateSHA256,
            cacheClass: tuple.cacheClass,
            kvDType: tuple.kvDType,
            requiresMoE: tuple.requiresMoE,
            hardwareClass: tuple.hardwareClass,
            metallibSHA256: tuple.metallibSHA256,
            kernelIdentifier: tuple.kernelIdentifier,
            parityLabel: tuple.parityLabel,
            poolEpoch: tuple.poolEpoch
        )

        XCTAssertEqual(
            ContinuousBatchScheduler.localCapabilityReason(descriptor: descriptor, tuple: tuple),
            "local_paged_kv_descriptor_mismatch"
        )
    }

    func testMoETupleRequiresSeparatePromotionEvidenceAtSchedulerAdmission() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(
            descriptor: Self.descriptor(supportsMoE: true),
            tuple: Self.tuple(requiresMoE: true),
            maxActiveRows: 2,
            backend: backend
        )

        do {
            _ = try await scheduler.submit(.init(
                id: "moe-without-evidence",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1
            ))
            XCTFail("expected the independent MoE promotion-evidence gate")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "moe_promotion_evidence_unavailable")
        }

        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertEqual(decodeCalls, 0)
    }

    func testMoETupleAdmitsWhenPromotionEvidenceIsAvailable() {
        let descriptor = Self.descriptor(supportsMoE: true)
        let tuple = Self.tuple(requiresMoE: true)
        XCTAssertNil(
            ContinuousBatchScheduler.localCapabilityReason(
                descriptor: descriptor,
                tuple: tuple,
                moePromotionEvidenceAvailable: true
            )
        )
        XCTAssertEqual(
            ContinuousBatchScheduler.localCapabilityReason(
                descriptor: descriptor,
                tuple: tuple,
                moePromotionEvidenceAvailable: false
            ),
            "moe_promotion_evidence_unavailable"
        )
    }

    func testCachedPromptTokensRequireRetainedPagedKVHandoff() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        do {
            _ = try await scheduler.submit(.init(
                id: "sticky",
                conversationKey: "conversation-1",
                promptTokens: [1, 2],
                maxOutputTokens: 1,
                cachedPromptTokens: 1
            ))
            XCTFail("expected retained FR-PKV10 handoff evidence")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_paged_kv_handoff_unavailable")
        }

        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        let metrics = await scheduler.metrics()
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertEqual(decodeCalls, 0)
        XCTAssertTrue(metrics.diagnostics.contains(.stickyCacheUnsupported))
    }

    func testConversationKeyWithoutReusableStateBatchesAsFreshRequest() async throws {
        let backend = ScriptedBackend(scripts: ["keyed": [7]])
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "keyed",
            conversationKey: "conversation-1",
            promptTokens: [1, 2],
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0
        ))

        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.conversationKey, "conversation-1")
        XCTAssertEqual(result.cachedPromptTokens, 0)
        XCTAssertEqual(result.outputTokens, [7])
        XCTAssertEqual(prefillCalls, 1)
        XCTAssertEqual(decodeCalls, 1)
    }

    func testKeyedHybridRowSplitsPrefillAtCheckpointsAndDeliversSerialCache() async throws {
        let backend = ScriptedBackend(scripts: ["hybrid": [7, 8]], recurrentCheckpointBackend: true)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )
        let request = ContinuousBatchSchedulerRequest(
            id: "hybrid",
            conversationKey: "conv:hybrid",
            promptTokens: Array(1...12),
            maxOutputTokens: 2,
            temperature: 0.0,
            recurrentCheckpointPositions: [5, 9]
        )

        let result = try await scheduler.submit(request)

        let events = await backend.events().filter { !$0.hasPrefix("decode:") }
        XCTAssertEqual(events, [
            "prefill:hybrid:4",
            "prefill:hybrid:1",
            "snapshot:hybrid:5",
            "prefill:hybrid:4",
            "snapshot:hybrid:9",
            "prefill:hybrid:2",
        ], "chunks end exactly on each checkpoint and the snapshot follows that chunk")
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.generatedTokens, [7, 8])
        XCTAssertNil(result.retainedCache)
        let serialCache = try XCTUnwrap(result.serialConversationCache)
        XCTAssertEqual(serialCache.recurrentCheckpoints.map(\.tokenCount), [5, 9])
        XCTAssertEqual(serialCache.tokenCount, 13, "prompt + generated - the last sampled token, never fed back")
        let materialized = await backend.serialMaterializations()
        XCTAssertEqual(materialized["hybrid"], [13, 13], "materialized once, before the row's blocks are released")
        try await eventually { await allocator.freeBlockCount() == 16 }

        let replay = try await scheduler.submit(request)
        XCTAssertEqual(replay.settlementDisposition, .nonSettlingReplay)
        XCTAssertNil(replay.serialConversationCache, "only the settlement owner receives the cache")
    }

    func testKeylessOrPositionlessHybridRowCapturesNothing() async throws {
        let backend = ScriptedBackend(
            scripts: ["keyless": [7], "positionless": [7]],
            recurrentCheckpointBackend: true
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )

        let keyless = try await scheduler.submit(.init(
            id: "keyless",
            conversationKey: "",
            promptTokens: Array(1...12),
            maxOutputTokens: 1,
            temperature: 0.0,
            recurrentCheckpointPositions: [5, 9]
        ))
        let positionless = try await scheduler.submit(.init(
            id: "positionless",
            conversationKey: "conv:hybrid",
            promptTokens: Array(1...12),
            maxOutputTokens: 1,
            temperature: 0.0
        ))

        let events = await backend.events().filter { !$0.hasPrefix("decode:") }
        XCTAssertEqual(events, [
            "prefill:keyless:4", "prefill:keyless:4", "prefill:keyless:3",
            "prefill:positionless:4", "prefill:positionless:4", "prefill:positionless:3",
        ])
        XCTAssertNil(keyless.serialConversationCache)
        XCTAssertNil(positionless.serialConversationCache)
        let materialized = await backend.serialMaterializations()
        XCTAssertTrue(materialized.isEmpty)
        try await eventually { await allocator.freeBlockCount() == 16 }
    }

    func testCancelledHybridRowDeliversNoSerialCacheAndReleasesBlocks() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["hybrid": [7, 8, 9]],
            decodeGate: decodeGate,
            recurrentCheckpointBackend: true
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )
        let task = Task {
            try await scheduler.submit(.init(
                id: "hybrid",
                conversationKey: "conv:hybrid",
                promptTokens: Array(1...12),
                maxOutputTokens: 3,
                temperature: 0.0,
                recurrentCheckpointPositions: [5, 9]
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        await scheduler.cancel(requestID: "hybrid")
        await decodeGate.open()

        let result = try await task.value
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertNil(result.serialConversationCache)
        let snapshots = await backend.recurrentSnapshots()
        XCTAssertEqual(snapshots["hybrid"], [5, 9])
        let materialized = await backend.serialMaterializations()
        XCTAssertTrue(materialized.isEmpty)
        try await eventually { await allocator.freeBlockCount() == 16 }
    }

    // Codex M4 R1 (MEDIUM): a cancel that lands while the row is suspended in
    // `snapshotRecurrentState` must still cancel it, before it can materialize
    // a cache or join decode.
    func testCancelDuringRecurrentSnapshotCancelsWithoutMaterializing() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["hybrid": [7, 8]],
            recurrentCheckpointBackend: true,
            snapshotGate: gate
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )
        let task = Task {
            try await scheduler.submit(.init(
                id: "hybrid",
                conversationKey: "conv:hybrid",
                promptTokens: Array(1...12),
                maxOutputTokens: 0,
                temperature: 0.0,
                recurrentCheckpointPositions: [11]
            ))
        }
        try await eventually { await backend.recurrentSnapshots()["hybrid"] == [11] }
        await scheduler.cancel(requestID: "hybrid")
        await gate.open()

        let result = try await task.value
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertNil(result.serialConversationCache)
        let materialized = await backend.serialMaterializations()
        XCTAssertTrue(materialized.isEmpty)
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(decodeCalls, 0)
        try await eventually { await allocator.freeBlockCount() == 16 }
    }

    // Codex M4 R2 (MEDIUM): a cancel that lands while a finished row is
    // suspended in terminal materialization must win: the request finishes
    // cancelled and no conversation cache is published.
    func testCancelDuringTerminalMaterializeSuppressesTheCache() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["hybrid": [7, 8]],
            recurrentCheckpointBackend: true,
            materializeGate: gate
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )
        let task = Task {
            try await scheduler.submit(.init(
                id: "hybrid",
                conversationKey: "conv:hybrid",
                promptTokens: Array(1...12),
                maxOutputTokens: 0,
                temperature: 0.0,
                recurrentCheckpointPositions: [5]
            ))
        }
        try await eventually { await backend.serialMaterializations()["hybrid"] != nil }
        await scheduler.cancel(requestID: "hybrid")
        await gate.open()

        let result = try await task.value
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertNil(result.serialConversationCache)
        try await eventually { await allocator.freeBlockCount() == 16 }
    }

    func testFailedHybridRowDeliversNoSerialCacheAndReleasesBlocks() async throws {
        let backend = ScriptedBackend(
            scripts: ["hybrid": [7, 8]],
            failDecodeCall: 1,
            recurrentCheckpointBackend: true
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator
        )

        let result = try await scheduler.submit(.init(
            id: "hybrid",
            conversationKey: "conv:hybrid",
            promptTokens: Array(1...12),
            maxOutputTokens: 2,
            temperature: 0.0,
            recurrentCheckpointPositions: [5, 9]
        ))

        XCTAssertEqual(result.terminalStatus, .batchFailed)
        XCTAssertNil(result.serialConversationCache)
        let materialized = await backend.serialMaterializations()
        XCTAssertTrue(materialized.isEmpty)
        try await eventually { await allocator.freeBlockCount() == 16 }
    }

    func testPrefillBackendFailureFailsClosedWithReasonCodedTelemetry() async throws {
        let backend = ScriptedBackend(
            scripts: [:],
            prefillError: ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        )
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "prefill-fail",
            conversationKey: "",
            promptTokens: [1, 2, 3, 4],
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0
        ))

        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_prefill_failed")
        let metrics = await scheduler.metrics()
        XCTAssertTrue(metrics.diagnostics.contains(.prefillFailed))
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(decodeCalls, 0)
        XCTAssertEqual(
            ContinuousBatchingPolicy.prefillFailureTelemetryLine(
                ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
            ),
            "event=batching_prefill_failed action=fail_closed reason=continuous_batching_invalid_cache_layout\n"
        )
    }

    func testTerminalRetainFailureReleasesFreshHandleWithoutFailClosing() async throws {
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            contiguousCacheBridge: bridge
        )
        let backend = ScriptedBackend(scripts: ["keyed": [7], "unkeyed": [8]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )

        let keyedResult = try await scheduler.submit(.init(
            id: "keyed",
            conversationKey: "conversation-1",
            promptTokens: [1, 2],
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0
        ))

        XCTAssertEqual(keyedResult.terminalStatus, .length)
        XCTAssertNil(keyedResult.retainedCache)
        let freeBlockCount = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlockCount, 16)

        let nextResult = try await scheduler.submit(.init(
            id: "unkeyed",
            conversationKey: "",
            promptTokens: [3],
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0
        ))
        XCTAssertEqual(nextResult.terminalStatus, .length)
        XCTAssertEqual(nextResult.outputTokens, [8])
    }

    func testRetainedPagedKVHandoffResumesPrefillAtStickyLCP() async throws {
        let fixture = try await makeRetainedSchedulerFixture(cachedTokens: 34, promptCount: 40)

        let result = try await fixture.scheduler.submit(.init(
            id: "sticky-hit",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<40),
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0,
            cachedPromptTokens: 34,
            retainedPagedKVSequence: fixture.retained
        ))

        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.cachedPromptTokens, 34)
        XCTAssertNotNil(result.retainedCache)
        let retainedInstalls = await fixture.backend.retainedInstalls()
        let prefillCommitted = await fixture.backend.prefillCommittedCounts()
        let prefillTargets = await fixture.backend.prefillTargetCounts()
        let decodeCommitted = await fixture.backend.decodeCommittedCounts()
        XCTAssertEqual(retainedInstalls, ["sticky-hit": 34])
        XCTAssertEqual(prefillCommitted.first, ["sticky-hit": 34])
        XCTAssertEqual(prefillTargets.first, ["sticky-hit": 36])
        XCTAssertEqual(decodeCommitted.last, ["sticky-hit": 39])
        XCTAssertEqual(result.retainedCache?.retainedSequence.logicalTokenCount, 41)
        let terminalCommitTargets = await fixture.backend.terminalCommitTargets()
        XCTAssertEqual(terminalCommitTargets, ["sticky-hit": 41])
        if let retainedCache = result.retainedCache {
            await fixture.scheduler.cancelRetainedCacheDelivery(
                retainedCache,
                conversationKey: result.conversationKey
            )
        }
    }

    func testRetainedReattachExpandsMaxLogicalTokensForContinuation() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let handle = try await allocator.allocate(
            conversationKey: "conversation-1",
            initialCapacityTokens: 34,
            maxLogicalTokens: 34,
            initialTokens: 34
        )
        let retained = try await allocator.retain(handle)

        let reattached = try await allocator.reattach(
            retained,
            conversationKey: "conversation-1",
            trimToLogicalTokens: 34,
            maxLogicalTokens: 48
        )
        _ = try await allocator.extend(reattached, by: 7)
        let binding = try await allocator.binding(for: reattached)

        XCTAssertEqual(binding.currentTable.logicalTokenCount, 41)
        XCTAssertEqual(binding.maxLogicalTokens, 48)
        try await allocator.release(reattached)
    }

    func testCrossConversationRetainedHandoffFailureDiscardsOwner() async throws {
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(
            conversationKey: "conversation-a",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 6
        )
        let retained = try await allocator.retain(handle)
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )

        let result = try await scheduler.submit(.init(
            id: "cross-key",
            conversationKey: "conversation-b",
            promptTokens: Array(0..<8),
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0,
            cachedPromptTokens: 6,
            retainedPagedKVSequence: retained
        ))

        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_admission_failed")
        do {
            _ = try await allocator.reattach(retained, conversationKey: "conversation-a")
            XCTFail("retained sequence should have been discarded after cross-key admission failure")
        } catch PagedKVAllocatorError.unknownHandle {
        } catch {
            XCTFail("unexpected retained sequence error: \(error)")
        }
        let freeBlockCount = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlockCount, 16)
    }

    func testInvalidCachedRangeDiscardsSuppliedRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await makeRetainedSequence(allocator: allocator)
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator
        )

        do {
            _ = try await scheduler.submit(.init(
                id: "invalid-cached-range",
                conversationKey: "conversation-1",
                promptTokens: Array(0..<5),
                maxOutputTokens: 1,
                cachedPromptTokens: 6,
                retainedPagedKVSequence: retained
            ))
            XCTFail("expected invalid cached-token range rejection")
        } catch ContinuousBatchSchedulerError.requestFailed(let reason) {
            XCTAssertEqual(reason, "continuous_batching_invalid_cached_prompt_tokens")
        }

        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 16)
    }

    func testFullPromptCachedRangeDiscardsSuppliedRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await makeRetainedSequence(
            allocator: allocator,
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 5
        )
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator
        )

        do {
            _ = try await scheduler.submit(.init(
                id: "full-prompt-cached-range",
                conversationKey: "conversation-1",
                promptTokens: Array(0..<5),
                maxOutputTokens: 1,
                cachedPromptTokens: 5,
                retainedPagedKVSequence: retained
            ))
            XCTFail("expected full-prompt cached-token range rejection")
        } catch ContinuousBatchSchedulerError.requestFailed(let reason) {
            XCTAssertEqual(reason, "continuous_batching_invalid_cached_prompt_tokens")
        }

        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 16)
    }

    func testTwoRetainedConversationKeysShareDecodeBatchWithoutCrossAttribution() async throws {
        let decodeGate = AsyncGate()
        let bridge = HeadlessRetainedCacheBridge()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retainedA = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-a",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 3
        )
        let retainedB = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-b",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 3
        )
        let backend = ScriptedBackend(
            scripts: ["sticky-a": [10, 11], "sticky-b": [20]],
            decodeGate: decodeGate
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 2,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )

        let first = Task {
            try await scheduler.submit(.init(
                id: "sticky-a",
                conversationKey: "conversation-a",
                promptTokens: Array(0..<5),
                maxOutputTokens: 2,
                samplerSeed: 101,
                temperature: 0.0,
                topP: 1.0,
                cachedPromptTokens: 3,
                retainedPagedKVSequence: retainedA
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let second = Task {
            try await scheduler.submit(.init(
                id: "sticky-b",
                conversationKey: "conversation-b",
                promptTokens: Array(10..<15),
                maxOutputTokens: 1,
                samplerSeed: 202,
                temperature: 0.0,
                topP: 1.0,
                cachedPromptTokens: 3,
                retainedPagedKVSequence: retainedB
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertEqual(firstResult.conversationKey, "conversation-a")
        XCTAssertEqual(secondResult.conversationKey, "conversation-b")
        XCTAssertEqual(firstResult.cachedPromptTokens, 3)
        XCTAssertEqual(secondResult.cachedPromptTokens, 3)
        XCTAssertEqual(firstResult.outputTokens, [10, 11])
        XCTAssertEqual(secondResult.outputTokens, [20])
        XCTAssertEqual(firstResult.settlementDisposition, .eligibleOwner)
        XCTAssertEqual(secondResult.settlementDisposition, .eligibleOwner)

        let retainedInstalls = await backend.retainedInstalls()
        XCTAssertEqual(retainedInstalls, ["sticky-a": 3, "sticky-b": 3])
        let decodeBatches = await backend.decodeBatches()
        guard let sharedBatchIndex = decodeBatches.firstIndex(of: ["sticky-a", "sticky-b"]) else {
            return XCTFail("expected retained sticky rows to share one decode batch; saw \(decodeBatches)")
        }
        let currentTokens = await backend.currentTokensByDecodeBatch()
        let committedCounts = await backend.decodeCommittedCounts()
        let targetCounts = await backend.decodeTargetCounts()
        XCTAssertEqual(currentTokens[sharedBatchIndex], ["sticky-a": 10, "sticky-b": 14])
        XCTAssertEqual(committedCounts[sharedBatchIndex], ["sticky-a": 5, "sticky-b": 4])
        XCTAssertEqual(targetCounts[sharedBatchIndex], ["sticky-a": 6, "sticky-b": 5])
        let samplerSeeds = await backend.observedSamplerSeeds()
        let terminalCommitTargets = await backend.terminalCommitTargets()
        XCTAssertEqual(samplerSeeds, ["sticky-a": [101, 101], "sticky-b": [202]])
        XCTAssertEqual(terminalCommitTargets, ["sticky-a": 7, "sticky-b": 6])

        if let retainedCache = firstResult.retainedCache {
            await scheduler.cancelRetainedCacheDelivery(
                retainedCache,
                conversationKey: firstResult.conversationKey
            )
        }
        if let retainedCache = secondResult.retainedCache {
            await scheduler.cancelRetainedCacheDelivery(
                retainedCache,
                conversationKey: secondResult.conversationKey
            )
        }
    }

    func testDeliveredRetainedCacheCanBeReclaimedAfterCallerCancellationRace() async throws {
        let bridge = HeadlessRetainedCacheBridge()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let originalRetained = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-1",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 6
        )
        let backend = ScriptedBackend(scripts: ["sticky-cancel-race": [777]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxPromptChunkTokens: 4,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )
        let freeBeforeSubmit = await allocator.freeBlockCount()

        let result = try await scheduler.submit(.init(
            id: "sticky-cancel-race",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<8),
            maxOutputTokens: 1,
            cachedPromptTokens: 6,
            retainedPagedKVSequence: originalRetained
        ))

        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.settlementDisposition, .eligibleOwner)
        guard let retainedCache = result.retainedCache else {
            return XCTFail("expected terminal retained cache delivery")
        }
        XCTAssertNotNil(retainedCache.deliveryID)
        let freeAfterSubmit = await allocator.freeBlockCount()
        XCTAssertLessThan(freeAfterSubmit, freeBeforeSubmit)

        await scheduler.cancelRetainedCacheDelivery(retainedCache, conversationKey: result.conversationKey)
        try await eventually {
            await allocator.freeBlockCount() == 16
        }
        do {
            _ = try await allocator.reattach(
                retainedCache.retainedSequence,
                conversationKey: result.conversationKey
            )
            XCTFail("cancelled delivered retained cache should be reclaimed")
        } catch PagedKVAllocatorError.unknownHandle {
        } catch {
            throw error
        }
    }

    func testMissingContiguousBridgeAdmissionFailureDiscardsSuppliedRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await makeRetainedSequence(allocator: allocator)
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator
        )

        let result = try await scheduler.submit(.init(
            id: "missing-bridge",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<8),
            maxOutputTokens: 1,
            cachedPromptTokens: 6,
            retainedPagedKVSequence: retained
        ))

        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_admission_failed")
        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 16)
    }

    func testTerminalReplayDiscardsSuppliedRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let backend = ScriptedBackend(scripts: ["owner": [7]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator
        )
        let original = try await scheduler.submit(.init(
            id: "owner",
            conversationKey: "conversation-1",
            promptTokens: [1],
            maxOutputTokens: 1
        ))
        XCTAssertEqual(original.terminalStatus, .length)

        let retained = try await makeRetainedSequence(allocator: allocator)
        let replay = try await scheduler.submit(.init(
            id: "owner",
            conversationKey: "conversation-1",
            promptTokens: [1],
            maxOutputTokens: 1,
            retainedPagedKVSequence: retained
        ))

        XCTAssertEqual(replay.settlementDisposition, .nonSettlingReplay)
        XCTAssertNil(replay.retainedCache)
        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 16)
    }

    func testPositiveCachedTerminalReplayDiscardsSuppliedRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let bridge = HeadlessRetainedCacheBridge()
        let originalRetained = try await makeRetainedSequence(
            allocator: allocator,
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 6
        )
        let backend = ScriptedBackend(scripts: ["owner-positive": [7]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )
        let original = try await scheduler.submit(.init(
            id: "owner-positive",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<8),
            maxOutputTokens: 1,
            cachedPromptTokens: 6,
            retainedPagedKVSequence: originalRetained
        ))
        XCTAssertEqual(original.terminalStatus, .length)
        XCTAssertEqual(original.cachedPromptTokens, 6)
        XCTAssertEqual(original.retainedCache?.retainedSequence.logicalTokenCount, 9)

        let retained = try await makeRetainedSequence(allocator: allocator)
        let replay = try await scheduler.submit(.init(
            id: "owner-positive",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<8),
            maxOutputTokens: 1,
            cachedPromptTokens: 6,
            retainedPagedKVSequence: retained
        ))

        XCTAssertEqual(replay.settlementDisposition, .nonSettlingReplay)
        XCTAssertEqual(replay.cachedPromptTokens, 6)
        XCTAssertNil(replay.retainedCache)
        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 13)
        if let retainedCache = original.retainedCache {
            await scheduler.cancelRetainedCacheDelivery(
                retainedCache,
                conversationKey: original.conversationKey
            )
        }
    }

    func testQueuedCancellationDiscardsSuppliedRetainedOwner() async throws {
        let gate = AsyncGate()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let backend = ScriptedBackend(scripts: ["active": [7]], prefillGate: gate)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            queueLimit: 1,
            backend: backend,
            allocator: allocator
        )

        let active = Task {
            try await scheduler.submit(.init(
                id: "active",
                conversationKey: "",
                promptTokens: [1, 2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }

        let retained = try await makeRetainedSequence(allocator: allocator)
        let queued = Task {
            try await scheduler.submit(.init(
                id: "queued-retained",
                conversationKey: "conversation-1",
                promptTokens: Array(0..<8),
                maxOutputTokens: 1,
                cachedPromptTokens: 6,
                retainedPagedKVSequence: retained
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await scheduler.cancel(requestID: "queued-retained")
        await gate.open()

        let queuedResult = try await queued.value
        XCTAssertEqual(queuedResult.terminalStatus, .cancelled)
        _ = try await active.value
        try await assertRetainedDiscarded(retained, allocator: allocator, expectedFreeBlockCount: 16)
    }

    func testTimedOutTerminalDeliveryDiscardsRetainedPagedKVOwner() async throws {
        let sinkGate = AsyncGate()
        let fixture = try await makeRetainedSchedulerFixture(
            cachedTokens: 34,
            promptCount: 40,
            tokenDeliveryTimeoutNanoseconds: 20_000_000
        )

        let timedOut = Task {
            try await fixture.scheduler.submit(.init(
                id: "sticky-hit",
                conversationKey: "conversation-1",
                promptTokens: Array(0..<40),
                maxOutputTokens: 1,
                temperature: 0.0,
                topP: 1.0,
                cachedPromptTokens: 34,
                retainedPagedKVSequence: fixture.retained
            ), tokenSink: { _ in
                await sinkGate.wait()
            })
        }

        let result = try await timedOut.value
        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_stream_delivery_timed_out")
        XCTAssertNil(result.retainedCache)
        try await eventually { await fixture.allocator.freeBlockCount() == 32 }
        await sinkGate.open()
    }

    func testConversationCacheRetainedPagedKVHitLeavesTrimToSchedulerHandoff() async throws {
        let fixture = try await makeRetainedSchedulerFixture(
            cachedTokens: 34,
            promptCount: 40,
            retainedTokenCount: 40
        )
        let conversationCache = ConversationCache(
            config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900)
        )
        let seedTokens = Array(0..<40).map(Int32.init)
        let seed = await conversationCache.begin(
            conversationKey: "conversation-1",
            incomingTokens: seedTokens,
            modelID: Self.modelID,
            kvBits: nil
        )
        await conversationCache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [fixture.pagedCache],
                retainedPagedKVSequence: fixture.retained,
                discardRetainedPagedKVSequence: { retained, key in
                    await fixture.scheduler.discardRetainedCache(retained, conversationKey: key)
                }
            ),
            fullTokens: seedTokens
        )

        let incomingTokens = Array(0..<34).map(Int32.init) + Array(100..<106).map(Int32.init)
        let lease = await conversationCache.begin(
            conversationKey: "conversation-1",
            incomingTokens: incomingTokens,
            modelID: Self.modelID,
            kvBits: nil,
            allowRetainedPagedKVHandoff: true
        )

        XCTAssertEqual(lease?.cachedPromptTokens, 34)
        XCTAssertEqual(lease?.trimBy, 6)
        XCTAssertEqual(fixture.pagedCache.offset, 40)

        let result = try await fixture.scheduler.submit(.init(
            id: "sticky-hit",
            conversationKey: "conversation-1",
            promptTokens: Array(0..<34) + Array(100..<106),
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0,
            cachedPromptTokens: lease?.cachedPromptTokens ?? 0,
            retainedPagedKVSequence: lease?.reusableCache?.retainedPagedKVSequence
        ))

        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.cachedPromptTokens, 34)
        XCTAssertNotNil(result.retainedCache)
        let retainedInstalls = await fixture.backend.retainedInstalls()
        let prefillCommitted = await fixture.backend.prefillCommittedCounts()
        let prefillTargets = await fixture.backend.prefillTargetCounts()
        XCTAssertEqual(retainedInstalls, ["sticky-hit": 34])
        XCTAssertEqual(prefillCommitted.first, ["sticky-hit": 34])
        XCTAssertEqual(prefillTargets.first, ["sticky-hit": 36])

        if let lease, let retainedCache = result.retainedCache {
            await conversationCache.commit(
                lease,
                cache: ConversationCacheLayers(
                    retainedCache.layers,
                    retainedPagedKVSequence: retainedCache.retainedSequence,
                    discardRetainedPagedKVSequence: { retained, key in
                        await fixture.scheduler.discardRetainedCache(retained, conversationKey: key)
                    }
                ),
                fullTokens: incomingTokens + result.outputTokens.map(Int32.init)
            )
            await fixture.scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            _ = await conversationCache.purgeHot(conversationKey: "conversation-1")
        } else if let lease {
            await conversationCache.abort(lease)
        }
    }

    func testRetainedStickyStopSequenceCommitsCanonicalGeneratedTokens() async throws {
        let bridge = HeadlessRetainedCacheBridge()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-1",
            initialCapacityTokens: 40,
            maxLogicalTokens: 48,
            initialTokens: 34
        )
        let backend = ScriptedBackend(scripts: ["sticky-hit": [5, 7, 8]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )

        let incomingTokens = Array<Int32>(0..<40)
        let result = try await scheduler.submit(.init(
            id: "sticky-hit",
            conversationKey: "conversation-1",
            promptTokens: incomingTokens.map(Int.init),
            maxOutputTokens: 3,
            stopTokenSequences: [[7, 8]],
            temperature: 0.0,
            topP: 1.0,
            cachedPromptTokens: 34,
            retainedPagedKVSequence: retained
        ))

        XCTAssertEqual(result.terminalStatus, .stop)
        XCTAssertEqual(result.generatedTokens, [5, 7, 8])
        XCTAssertEqual(result.outputTokens, [5])
        XCTAssertEqual(result.completionTokens, 3)
        XCTAssertEqual(result.retainedCache?.retainedSequence.logicalTokenCount, 43)
        let terminalCommitTargets = await backend.terminalCommitTargets()
        XCTAssertEqual(terminalCommitTargets, ["sticky-hit": 43])

        let conversationCache = ConversationCache(
            config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900)
        )
        if let retainedCache = result.retainedCache {
            let lease = await conversationCache.begin(
                conversationKey: "conversation-1",
                incomingTokens: incomingTokens,
                modelID: "model-a",
                kvBits: nil,
                allowRetainedPagedKVHandoff: true
            )
            XCTAssertNotNil(lease)
            await conversationCache.commit(
                lease!,
                cache: ConversationCacheLayers(
                    retainedCache.layers,
                    retainedPagedKVSequence: retainedCache.retainedSequence,
                    discardRetainedPagedKVSequence: { retained, key in
                        await scheduler.discardRetainedCache(retained, conversationKey: key)
                    }
                ),
                fullTokens: incomingTokens + result.generatedTokens.map(Int32.init)
            )
            await scheduler.acknowledgeRetainedCacheDelivery(retainedCache)
            let next = await conversationCache.begin(
                conversationKey: "conversation-1",
                incomingTokens: incomingTokens + result.generatedTokens.map(Int32.init) + [42],
                modelID: "model-a",
                kvBits: nil,
                allowRetainedPagedKVHandoff: true
            )
            XCTAssertEqual(next?.cachedPromptTokens, 43)
            await conversationCache.abort(next!)
            _ = await conversationCache.purgeHot(conversationKey: "conversation-1")
        } else {
            XCTFail("expected retained sticky cache")
        }
    }

    func testCachedPromptTokensCannotExceedPromptLengthEvenWithRetainedHandoff() async throws {
        let fixture = try await makeRetainedSchedulerFixture(cachedTokens: 6, promptCount: 6)

        do {
            _ = try await fixture.scheduler.submit(.init(
                id: "invalid-cached-range",
                conversationKey: "conversation-1",
                promptTokens: Array(0..<5),
                maxOutputTokens: 1,
                cachedPromptTokens: 6,
                retainedPagedKVSequence: fixture.retained
            ))
            XCTFail("expected invalid cached-token range rejection")
        } catch ContinuousBatchSchedulerError.requestFailed(let reason) {
            XCTAssertEqual(reason, "continuous_batching_invalid_cached_prompt_tokens")
        }
        let retainedInstalls = await fixture.backend.retainedInstalls()
        XCTAssertEqual(retainedInstalls, [:])
    }

    func testNonSettlingReplayResultDropsRetainedCacheOwnership() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let handle = try await allocator.allocate(
            conversationKey: "conversation-1",
            initialCapacityTokens: 1,
            maxLogicalTokens: 4,
            initialTokens: 1
        )
        let retained = try await allocator.retain(handle)
        let retainedCache = ContinuousBatchRetainedCache(retainedSequence: retained, layers: [])
        let result = ContinuousBatchSchedulerResult(
            requestID: "sticky-owner",
            conversationKey: "conversation-1",
            generatedTokens: [7],
            outputTokens: [7],
            promptTokens: 2,
            completionTokens: 1,
            emittedTokens: 1,
            cachedPromptTokens: 1,
            terminalStatus: .length,
            errorCode: nil,
            snapshot: nil,
            settlementDisposition: .eligibleOwner,
            retainedCache: retainedCache
        )

        let replay = result.withSettlementDisposition(.nonSettlingReplay)

        XCTAssertEqual(replay.settlementDisposition, .nonSettlingReplay)
        XCTAssertNil(replay.retainedCache)
        try await allocator.discardRetained(retained, conversationKey: "conversation-1")
    }

    func testAC24AdmissionPoolCapacityRejectsWithoutRunningInference() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 1, maxPhysicalBlocks: 1)
        let scheduler = ContinuousBatchScheduler(
            configuration: Self.configuration(
                descriptor: Self.descriptor(blockSizeTokens: 1, maxPhysicalBlocks: 1),
                maxActiveRows: 1,
                decodeHeadroomTokens: 2
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let result = try await scheduler.submit(.init(
            id: "too-large",
            conversationKey: "",
            promptTokens: [1, 2],
            maxOutputTokens: 2
        ))

        XCTAssertEqual(result.terminalStatus, .rejected)
        XCTAssertEqual(result.errorCode, "continuous_batching_pool_capacity_exhausted")
        XCTAssertEqual(result.promptTokens, 0)
        XCTAssertEqual(result.completionTokens, 0)
        XCTAssertEqual(result.emittedTokens, 0)
        XCTAssertEqual(result.cachedPromptTokens, 0)
        let freeBlocks = await allocator.freeBlockCount()
        let prefillCalls = await backend.prefillCallCount()
        let metrics = await scheduler.metrics()
        XCTAssertEqual(freeBlocks, 1)
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertTrue(metrics.diagnostics.contains(.poolCapacityRejected))
    }

    func testAC20DuplicateRequestMismatchIsRejectedAfterTerminalResult() async throws {
        let backend = ScriptedBackend(scripts: ["same-id": [7]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
        _ = try await scheduler.submit(.init(
            id: "same-id",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 1
        ))

        do {
            _ = try await scheduler.submit(.init(
                id: "same-id",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
            XCTFail("expected duplicate request mismatch")
        } catch ContinuousBatchSchedulerError.duplicateRequestMismatch {
            // expected
        }
    }

    func testCancellingDuplicateWaiterDoesNotCancelSharedRequest() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["shared": [7]], decodeGate: decodeGate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
        let request = ContinuousBatchSchedulerRequest(
            id: "shared",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 1
        )

        let original = Task { try await scheduler.submit(request) }
        try await eventually { await scheduler.metrics().activeDecodeRows == 1 }
        let duplicate = Task { try await scheduler.submit(request) }
        try await eventually { await scheduler.metrics().attachedWaiters == 2 }
        duplicate.cancel()

        do {
            _ = try await duplicate.value
            XCTFail("expected duplicate waiter cancellation")
        } catch is CancellationError {
            // Only the cancelling attachment is detached.
        }
        await decodeGate.open()
        let result = try await original.value
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.outputTokens, [7])
        XCTAssertEqual(decodeCalls, 1)
    }

    /// Studio soak 2026-09-24: ~1 in 400 non-streaming batched requests never
    /// returned. The drain task saw an empty queue and released the lock before
    /// clearing `draining`; an `offer()` in that gap appended a token and
    /// started no drain, so the terminal `finish(afterDraining:)` waited on a
    /// drain that would never run, and the timeout could not fire because
    /// `drainGeneration` was already nil. The seam lands the offer in that gap
    /// deterministically.
    func testOfferRacingDrainExitIsDeliveredAndTerminalCompletes() async throws {
        let delivered = DeliveredTokenLog()
        let delivery = ContinuousBatchTokenDelivery(
            bufferLimit: 16,
            timeoutNanoseconds: 60_000_000_000,
            capacity: ContinuousBatchTokenDeliveryCapacity(limit: 4),
            sink: { event in delivered.append(event.token) }
        )
        let raced = DeliveredTokenLog()
        delivery.afterDrainSawEmptyQueueForTest = { [delivery] in
            guard raced.isEmpty else { return }
            raced.append(1)
            XCTAssertTrue(delivery.offer(Self.deliveryEvent(token: 1)))
        }

        XCTAssertTrue(delivery.offer(Self.deliveryEvent(token: 0)))
        try await eventually { raced.isEmpty == false }

        // An expectation, not a task-group race: a stranded completion never
        // resumes, and a task group would wait on it forever.
        let terminal = expectation(description: "terminal drain completion fires")
        let outcome = DeliveredTokenLog()
        delivery.finish(afterDraining: { completedBeforeTimeout in
            outcome.append(completedBeforeTimeout ? 1 : 0)
            terminal.fulfill()
        })
        await fulfillment(of: [terminal], timeout: 2)
        XCTAssertEqual(outcome.tokens, [1], "the terminal drain completion must fire before its timeout")
        XCTAssertEqual(delivered.tokens, [0, 1], "the racing offer must be delivered, in order")
    }

    private static func deliveryEvent(token: Int) -> ContinuousBatchSchedulerTokenEvent {
        ContinuousBatchSchedulerTokenEvent(
            requestID: "race",
            tokenIndex: token,
            token: token,
            replayTokens: nil,
            snapshot: ContinuousBatchSchedulerSnapshot(modelID: "m", modelSHA256: "h", weightsGeneration: 0)
        )
    }

    func testDuplicateSuccessfulWaitersHaveExactlyOneSettlementOwner() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["settlement": [7]], decodeGate: decodeGate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
        let request = ContinuousBatchSchedulerRequest(
            id: "settlement",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 1
        )

        let original = Task { try await scheduler.submit(request) }
        try await eventually { await scheduler.metrics().activeDecodeRows == 1 }
        let duplicate = Task { try await scheduler.submit(request) }
        try await eventually { await scheduler.metrics().attachedWaiters == 2 }
        await decodeGate.open()

        let results = try await [original.value, duplicate.value]
        XCTAssertEqual(
            results.filter { $0.settlementDisposition == .eligibleOwner }.count,
            1
        )
        XCTAssertEqual(
            results.filter { $0.settlementDisposition == .nonSettlingReplay }.count,
            1
        )
        let replay = try await scheduler.submit(request)
        XCTAssertEqual(replay.terminalStatus, .length)
        XCTAssertEqual(replay.settlementDisposition, .nonSettlingReplay)
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(decodeCalls, 1)
    }

    func testRequestRetentionAndQueueTokenBudgetsRejectBeforeBackendWork() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                queueLimit: 4,
                decodeHeadroomTokens: 1,
                maxRequestIDBytes: 8,
                maxRequestTokens: 8,
                maxQueuedTokens: 8,
                maxStopSequences: 2,
                maxStopSequenceTokens: 2,
                maxTotalStopTokens: 3,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let invalidRequests = [
            ContinuousBatchSchedulerRequest(
                id: "123456789",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1
            ),
            ContinuousBatchSchedulerRequest(
                id: "stops",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1,
                stopTokenSequences: [[2], [3], [4]]
            ),
            ContinuousBatchSchedulerRequest(
                id: "longstop",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1,
                stopTokenSequences: [[2, 3, 4]]
            ),
            ContinuousBatchSchedulerRequest(
                id: "context",
                conversationKey: "",
                promptTokens: Array(repeating: 1, count: 8),
                maxOutputTokens: 1
            ),
        ]

        for request in invalidRequests {
            do {
                _ = try await scheduler.submit(request)
                XCTFail("expected request retention bound rejection for \(request.id)")
            } catch ContinuousBatchSchedulerError.requestFailed("continuous_batching_invalid_request") {
                // Rejected before admission or replay retention.
            }
        }
        let metrics = await scheduler.metrics()
        XCTAssertEqual(metrics.waitingCount, 0)
        XCTAssertEqual(metrics.retainedTerminalResults, 0)
        XCTAssertEqual(metrics.retainedDedupeTombstones, 0)
        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertEqual(decodeCalls, 0)
    }

    func testAggregateQueuedTokenBudgetBackpressuresBeforeRetention() async throws {
        let prefillGate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["active": [1], "queued1": [2], "overflow": [3]],
            prefillGate: prefillGate
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                queueLimit: 4,
                decodeHeadroomTokens: 1,
                maxRequestTokens: 8,
                maxQueuedTokens: 8,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        func request(_ id: String, promptCount: Int) -> ContinuousBatchSchedulerRequest {
            .init(
                id: id,
                conversationKey: "",
                promptTokens: Array(repeating: 1, count: promptCount),
                maxOutputTokens: 1
            )
        }

        let active = Task { try await scheduler.submit(request("active", promptCount: 2)) }
        try await eventually { await backend.prefillCallCount() == 1 }
        let queued1 = Task { try await scheduler.submit(request("queued1", promptCount: 7)) }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        let overflow = Task { () -> Error? in
            do {
                _ = try await scheduler.submit(request("overflow", promptCount: 2))
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        await prefillGate.open()
        let overflowError = await overflow.value
        guard case ContinuousBatchSchedulerError.backpressure? = overflowError else {
            XCTFail("expected aggregate queue-token backpressure, got \(String(describing: overflowError))")
            _ = try? await active.value
            _ = try? await queued1.value
            return
        }
        // Count capacity remains, but retained token capacity is exhausted.
        _ = try await active.value
        _ = try await queued1.value
        try await eventually { await scheduler.metrics().retainedTerminalResults == 2 }
    }

    func testTokenSinkStreamsDeltasAndFailureRetainsEmittedAccounting() async throws {
        let recorder = TokenEventRecorder()
        let backend = ScriptedBackend(scripts: ["stream": [7, 8]], failDecodeCall: 2)
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let result = try await scheduler.submit(
            .init(
                id: "stream",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 2
            ),
            tokenSink: { recorder.append($0) }
        )

        try await eventually { recorder.events().count == 1 }
        let events = recorder.events()
        XCTAssertEqual(events.map(\.tokenIndex), [0])
        XCTAssertEqual(events.map(\.token), [7])
        XCTAssertEqual(events.map(\.replayTokens), [nil])
        XCTAssertEqual(events.first?.snapshot.modelSHA256, Self.modelSHA)
        XCTAssertEqual(result.terminalStatus, .batchFailed)
        XCTAssertEqual(result.outputTokens, [])
        XCTAssertEqual(result.completionTokens, 0)
        XCTAssertEqual(result.emittedTokens, 1)
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
    }

    func testTerminalResultWaitsForAcceptedTokenDelivery() async throws {
        let sinkGate = AsyncGate()
        let recorder = TokenEventRecorder()
        let completion = CompletionFlag()
        let duplicateRecorder = TokenEventRecorder()
        let duplicateCompletion = CompletionFlag()
        let backend = ScriptedBackend(scripts: ["ordered": [7]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let submission = Task {
            let result = try await scheduler.submit(
                .init(
                    id: "ordered",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: 1
                ),
                tokenSink: { event in
                    recorder.append(event)
                    await sinkGate.wait()
                }
            )
            await completion.markComplete()
            return result
        }

        try await eventually { recorder.events().count == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        let completedBeforeDelivery = await completion.isComplete
        XCTAssertFalse(completedBeforeDelivery)

        let duplicate = Task {
            let result = try await scheduler.submit(
                .init(
                    id: "ordered",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: 1
                ),
                tokenSink: { duplicateRecorder.append($0) }
            )
            await duplicateCompletion.markComplete()
            return result
        }
        try await eventually { duplicateRecorder.events().count == 1 }
        XCTAssertEqual(duplicateRecorder.events().first?.replayTokens, [7])
        duplicate.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        let duplicateCompletedBeforeOriginalDelivery = await duplicateCompletion.isComplete
        XCTAssertFalse(duplicateCompletedBeforeOriginalDelivery)

        await sinkGate.open()
        let result = try await submission.value
        let duplicateResult = try await duplicate.value
        let completedAfterDelivery = await completion.isComplete
        XCTAssertTrue(completedAfterDelivery)
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.outputTokens, [7])
        XCTAssertEqual(duplicateResult.terminalStatus, .length)
        XCTAssertEqual(duplicateResult.settlementDisposition, .nonSettlingReplay)
    }

    func testDrainWaitsForPendingTerminalTokenDelivery() async throws {
        let sinkGate = AsyncGate()
        let recorder = TokenEventRecorder()
        let drainCompletion = CompletionFlag()
        let backend = ScriptedBackend(scripts: ["drain-delivery": [7]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let submission = Task {
            try await scheduler.submit(
                .init(
                    id: "drain-delivery",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: 1
                ),
                tokenSink: { event in
                    recorder.append(event)
                    await sinkGate.wait()
                }
            )
        }
        try await eventually { recorder.events().count == 1 }

        let drain = Task {
            let permit = try await scheduler.drain()
            await drainCompletion.markComplete()
            return permit
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let completedWhileDeliveryBlocked = await drainCompletion.isComplete
        XCTAssertFalse(completedWhileDeliveryBlocked)

        await sinkGate.open()
        let result = try await submission.value
        let permit = try await drain.value
        let permitIsValid = await scheduler.validatesQuiescentDrainPermit(permit)
        let completedAfterDelivery = await drainCompletion.isComplete
        XCTAssertTrue(completedAfterDelivery)
        XCTAssertTrue(permitIsValid)
        XCTAssertEqual(result.terminalStatus, .length)
    }

    func testForcedDrainStopsPendingTerminalDeliveryBeforeReturningTimeout() async throws {
        let sinkGate = AsyncGate()
        let recorder = TokenEventRecorder()
        let backend = ScriptedBackend(scripts: ["forced-drain-delivery": [7]])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                drainTimeoutNanoseconds: 20_000_000,
                drainCancellationGraceNanoseconds: 200_000_000,
                tokenDeliveryTimeoutNanoseconds: 5_000_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let submission = Task {
            try await scheduler.submit(
                .init(
                    id: "forced-drain-delivery",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: 1
                ),
                tokenSink: { event in
                    recorder.append(event)
                    await sinkGate.wait()
                }
            )
        }
        try await eventually { recorder.events().count == 1 }
        let drain = Task { try await scheduler.drain() }
        try await eventually {
            await scheduler.metrics().diagnostics.contains(.forcedDrainStarted)
        }

        do {
            _ = try await scheduler.drain()
            XCTFail("a concurrent drain must not mint a permit after forced cancellation starts")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_scheduler_failed_closed")
        }
        await sinkGate.open()

        do {
            _ = try await submission.value
            XCTFail("expected forced drain to cancel the pending terminal waiter")
        } catch is CancellationError {
            // The terminal waiter is exposed only after its sink stops.
        }
        do {
            _ = try await drain.value
            XCTFail("forced drain must not issue a quiescent permit")
        } catch ContinuousBatchSchedulerError.drainTimedOut {
            // A forced drain never authorizes a generation swap.
        }
        let metrics = await scheduler.metrics()
        XCTAssertEqual(metrics.attachedWaiters, 0)
        XCTAssertEqual(metrics.activeDecodeRows, 0)
        XCTAssertEqual(metrics.activePromptRows, 0)
    }

    func testForcedDrainPreservesDeliveredDuplicateAsSettlementOwner() async throws {
        let decodeGate = AsyncGate()
        let blockedSinkGate = AsyncGate()
        let fastSinkReturned = CompletionFlag()
        let fastRecorder = TokenEventRecorder()
        let blockedRecorder = TokenEventRecorder()
        let backend = ScriptedBackend(
            scripts: ["mixed-drain-duplicates": [7]],
            decodeGate: decodeGate
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                drainTimeoutNanoseconds: 20_000_000,
                drainCancellationGraceNanoseconds: 200_000_000,
                tokenDeliveryTimeoutNanoseconds: 5_000_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        let request = ContinuousBatchSchedulerRequest(
            id: "mixed-drain-duplicates",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 1
        )
        let fast = Task {
            try await scheduler.submit(request, tokenSink: { event in
                fastRecorder.append(event)
                await fastSinkReturned.markComplete()
            })
        }
        try await eventually { await scheduler.metrics().activeDecodeRows == 1 }
        let blocked = Task {
            try await scheduler.submit(request, tokenSink: { event in
                blockedRecorder.append(event)
                await blockedSinkGate.wait()
            })
        }
        try await eventually { await scheduler.metrics().attachedWaiters == 2 }
        await decodeGate.open()
        try await eventually {
            await fastSinkReturned.isComplete && blockedRecorder.events().count == 1
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let drain = Task { try await scheduler.drain() }
        try await Task.sleep(nanoseconds: 40_000_000)
        await blockedSinkGate.open()

        let fastResult = try await fast.value
        XCTAssertEqual(fastRecorder.events().map(\.token), [7])
        XCTAssertEqual(fastResult.terminalStatus, .length)
        XCTAssertEqual(fastResult.settlementDisposition, .eligibleOwner)
        do {
            _ = try await blocked.value
            XCTFail("expected forced drain to cancel only the blocked duplicate")
        } catch is CancellationError {
            // Its already-accepted sink call is acknowledged before cancellation.
        }
        do {
            _ = try await drain.value
            XCTFail("forced drain must not issue a quiescent permit")
        } catch ContinuousBatchSchedulerError.drainTimedOut {
            // The delivered duplicate remains the sole settlement owner.
        }
        do {
            _ = try await scheduler.submit(request)
            XCTFail("forced drain timeout must reject even a terminal replay")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_scheduler_failed_closed")
        }
    }

    func testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded() async throws {
        let sinkGate = AsyncGate()
        let sinkExited = CompletionFlag()
        let terminalCompletion = CompletionFlag()
        let backend = ScriptedBackend(scripts: [
            "hung": [7],
            "bounded": [8],
            "recovered": [9],
        ])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                tokenDeliveryTaskLimit: 1,
                tokenDeliveryTimeoutNanoseconds: 20_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let timedOutSubmission = Task {
            let result = try await scheduler.submit(
                .init(id: "hung", conversationKey: "", promptTokens: [1], maxOutputTokens: 1),
                tokenSink: { _ in
                    await sinkGate.wait()
                    await sinkExited.markComplete()
                }
            )
            await terminalCompletion.markComplete()
            return result
        }
        try await eventually { await terminalCompletion.isComplete }
        let timedOut = try await timedOutSubmission.value
        XCTAssertEqual(timedOut.terminalStatus, .requestFailed)
        XCTAssertEqual(timedOut.errorCode, "continuous_batching_stream_delivery_timed_out")
        XCTAssertEqual(timedOut.outputTokens, [])
        XCTAssertEqual(timedOut.completionTokens, 0)

        do {
            _ = try await scheduler.submit(
                .init(id: "bounded", conversationKey: "", promptTokens: [1], maxOutputTokens: 1),
                tokenSink: { _ in }
            )
            XCTFail("expected the still-live sink task to retain the global delivery slot")
        } catch ContinuousBatchSchedulerError.deliveryBackpressure {
            // Scheduler state completed at the hard deadline, but the actual
            // live task remains counted until the cancellation-insensitive sink exits.
            // Post-token, not pre-admission: this request was admitted and
            // decoded, and the refusal came from the pump trying to hand its
            // first token to a delivery with no task slot left. Inference ran
            // and burned a slot, so it is not blind-retryable.
        }
        try await eventually { await scheduler.metrics().slotsFree == 1 }
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 16)
        await sinkGate.open()
        try await eventually { await sinkExited.isComplete }
        try await Task.sleep(nanoseconds: 5_000_000)
        let recovered = try await scheduler.submit(
            .init(id: "recovered", conversationKey: "", promptTokens: [1], maxOutputTokens: 1),
            tokenSink: { _ in }
        )
        XCTAssertEqual(recovered.outputTokens, [9])
    }

    func testDuplicateDuringDeferredTerminalCompletionIsNotStranded() async throws {
        let sinkGate = AsyncGate()
        let secondDecodeGate = AsyncGate()
        let stopObserved = CompletionFlag()
        let tokenObserved = CompletionFlag()
        let duplicateCompleted = CompletionFlag()
        let backend = SecondDecodeGateBackend(secondDecodeGate: secondDecodeGate)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                tokenDeliveryTimeoutNanoseconds: 5_000_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        let request = ContinuousBatchSchedulerRequest(
            id: "deferred-duplicate",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 2,
            stopTokenSequences: [[8]]
        )

        let original = Task {
            try await scheduler.submit(request, tokenSink: { _ in
                await tokenObserved.markComplete()
                while !Task.isCancelled { await Task.yield() }
                await stopObserved.markComplete()
                await sinkGate.wait()
            })
        }
        try await eventually { await tokenObserved.isComplete }
        try await eventually { await backend.decodeCallCount() == 2 }
        original.cancel()
        try await eventually { await stopObserved.isComplete }

        await secondDecodeGate.open()
        try await eventually { await scheduler.metrics().slotsFree == 1 }
        let duplicate = Task {
            let result = try await scheduler.submit(request)
            await duplicateCompleted.markComplete()
            return result
        }
        defer { duplicate.cancel() }
        try await eventually { await scheduler.metrics().attachedWaiters == 2 }
        await sinkGate.open()
        try await eventually { await duplicateCompleted.isComplete }

        let duplicateResult = try await duplicate.value
        XCTAssertEqual(duplicateResult.outputTokens, [])
        XCTAssertEqual(duplicateResult.terminalStatus, .requestFailed)
        XCTAssertEqual(
            duplicateResult.errorCode,
            ContinuousBatchSchedulerError.deliveryBackpressureCode
        )
        XCTAssertEqual(duplicateResult.settlementDisposition, .notEligible)
        do {
            _ = try await original.value
            XCTFail("expected the cancelled original waiter to fail")
        } catch is CancellationError {
            // The duplicate receives the deferred terminal result instead of
            // being stranded; the stopped original remains non-settling.
        }
    }

    func testCancelledHangingTokenSinkHardTimeoutReleasesSchedulerState() async throws {
        let sinkGate = AsyncGate()
        let secondDecodeGate = AsyncGate()
        let stopObserved = CompletionFlag()
        let tokenObserved = CompletionFlag()
        let originalCompleted = CompletionFlag()
        let backend = SecondDecodeGateBackend(secondDecodeGate: secondDecodeGate)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                tokenDeliveryTaskLimit: 1,
                tokenDeliveryTimeoutNanoseconds: 20_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let original = Task {
            do {
                _ = try await scheduler.submit(.init(
                    id: "cancelled-hung",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: 2
                ), tokenSink: { _ in
                    await tokenObserved.markComplete()
                    while !Task.isCancelled { await Task.yield() }
                    await stopObserved.markComplete()
                    await sinkGate.wait()
                })
                await originalCompleted.markComplete()
                return false
            } catch is CancellationError {
                await originalCompleted.markComplete()
                return true
            } catch {
                await originalCompleted.markComplete()
                return false
            }
        }
        try await eventually { await tokenObserved.isComplete }
        try await eventually { await backend.decodeCallCount() == 2 }
        original.cancel()
        try await eventually { await stopObserved.isComplete }
        try await eventually { await originalCompleted.isComplete }

        let cancelledAsExpected = await original.value
        XCTAssertTrue(cancelledAsExpected)
        await secondDecodeGate.open()
        await sinkGate.open()
        try await eventually { await scheduler.metrics().slotsFree == 1 }

        let recovered = try await scheduler.submit(.init(
            id: "after-cancelled-hung",
            conversationKey: "",
            promptTokens: [2],
            maxOutputTokens: 1
        ))
        XCTAssertEqual(recovered.outputTokens, [8])
    }

    func testSchedulerContractSharedForwardIsolatesUsageStopsAndSamplers() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(scripts: [
            "r1": [10, 11, 12],
            "r2": [20, 21, 22],
        ], decodeGate: decodeGate)
        let scheduler = try await makeScheduler(
            maxActiveRows: 2,
            decodeHeadroomTokens: 4,
            maxPromptChunkTokens: 2,
            backend: backend
        )

        let first = Task {
            try await scheduler.submit(.init(
                id: "r1",
                conversationKey: "",
                promptTokens: [1, 2, 3],
                maxOutputTokens: 3,
                samplerSeed: 101
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let second = Task {
            try await scheduler.submit(.init(
                id: "r2",
                conversationKey: "",
                promptTokens: [7],
                maxOutputTokens: 5,
                stopTokenSequences: [[21]],
                samplerSeed: 202,
                cachedPromptTokens: 0
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let r1 = try await first.value
        let r2 = try await second.value

        XCTAssertEqual(r1.outputTokens, [10, 11, 12])
        XCTAssertEqual(r1.promptTokens, 3)
        XCTAssertEqual(r1.completionTokens, 3)
        XCTAssertEqual(r1.terminalStatus, .length)
        XCTAssertEqual(r2.outputTokens, [20])
        XCTAssertEqual(r2.promptTokens, 1)
        XCTAssertEqual(r2.completionTokens, 2)
        XCTAssertEqual(r2.emittedTokens, 1)
        XCTAssertEqual(r2.terminalStatus, .stop)

        let decodeBatches = await backend.decodeBatches()
        XCTAssertTrue(decodeBatches.contains(["r1", "r2"]))
        let samplerSeeds = await backend.observedSamplerSeeds()
        XCTAssertEqual(samplerSeeds, ["r1": [101, 101, 101], "r2": [202, 202]])
        let samplerSteps = await backend.observedSamplerSteps()
        XCTAssertEqual(samplerSteps, ["r1": [0, 1, 2], "r2": [0, 1]])
        let maxPrefillChunk = await backend.maxObservedPrefillChunkSize()
        XCTAssertEqual(maxPrefillChunk, 2)
        let blockTableLengths = await backend.blockTableLengthsByDecodeBatch()
        XCTAssertEqual(blockTableLengths.first?["r1"], 3)

        let metrics = await scheduler.metrics()
        XCTAssertEqual(metrics.maxObservedBatchDepth, 2)
        XCTAssertTrue(metrics.diagnostics.contains(.decodeFirstStep))
        XCTAssertTrue(metrics.diagnostics.contains(.joinedDecode))
        XCTAssertEqual(metrics.slotsTotal, 2)
        XCTAssertEqual(metrics.slotsFree, 2)
    }

    func testSchedulerContractMatchesReferenceSerialTokenUsageAndStops() async throws {
        func referenceSerial(
            script: [Int],
            maxOutputTokens: Int,
            stops: [[Int]]
        ) -> (output: [Int], completion: Int, status: ContinuousBatchSchedulerTerminalStatus) {
            var sampled: [Int] = []
            for token in script.prefix(maxOutputTokens) {
                sampled.append(token)
                if let stop = stops.first(where: {
                    $0.count <= sampled.count && Array(sampled.suffix($0.count)) == $0
                }) {
                    return (Array(sampled.dropLast(stop.count)), sampled.count, .stop)
                }
            }
            return (sampled, sampled.count, .length)
        }

        let decodeGate = AsyncGate()
        let scripts = ["serial-a": [4, 5, 6], "serial-b": [7, 8]]
        let backend = ScriptedBackend(scripts: scripts, decodeGate: decodeGate)
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)
        let a = Task {
            try await scheduler.submit(.init(
                id: "serial-a",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 3,
                stopTokenSequences: [[5, 6]],
                samplerSeed: 11
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let b = Task {
            try await scheduler.submit(.init(
                id: "serial-b",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 2,
                samplerSeed: 22
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let aResult = try await a.value
        let bResult = try await b.value
        let aReference = referenceSerial(script: scripts["serial-a"]!, maxOutputTokens: 3, stops: [[5, 6]])
        let bReference = referenceSerial(script: scripts["serial-b"]!, maxOutputTokens: 2, stops: [])
        XCTAssertEqual(aResult.outputTokens, aReference.output)
        XCTAssertEqual(aResult.completionTokens, aReference.completion)
        XCTAssertEqual(aResult.emittedTokens, aReference.output.count)
        XCTAssertEqual(aResult.terminalStatus, aReference.status)
        XCTAssertEqual(bResult.outputTokens, bReference.output)
        XCTAssertEqual(bResult.completionTokens, bReference.completion)
        XCTAssertEqual(bResult.emittedTokens, bReference.output.count)
        XCTAssertEqual(bResult.terminalStatus, bReference.status)
        XCTAssertEqual(aResult.snapshot?.modelSHA256, bResult.snapshot?.modelSHA256)
        let batches = await backend.decodeBatches()
        XCTAssertTrue(batches.contains(["serial-a", "serial-b"]))
    }

    // MARK: - SPEC-038 AC-25 API lifecycle

    // One shared scheduler-error map, asserted case by case so the streaming
    // and non-streaming serve paths cannot drift apart again.
    func testAC25SchedulerErrorAPIMappingIsExhaustiveAndNonSettling() {
        let expected: [(ContinuousBatchSchedulerError, Int, String)] = [
            (.backpressure, 503, "continuous_batching_stream_backpressure"),
            (.queueWaitTimedOut, 503, "continuous_batching_queue_wait_timeout"),
            (.duplicateRequestMismatch, 409, "continuous_batching_duplicate_request_mismatch"),
            (.idempotencyWindowExpired, 409, "continuous_batching_idempotency_window_expired"),
            (
                .idempotencyAuthorityUnavailable,
                503,
                "continuous_batching_idempotency_authority_unavailable"
            ),
        ]
        for (error, status, code) in expected {
            guard let apiError = error.asAPIError() else {
                return XCTFail("expected an API mapping for \(error)")
            }
            XCTAssertEqual(apiError.status, status, code)
            XCTAssertEqual(apiError.code, code)
            // Every mapped case rejects before inference, so no receipt.
            XCTAssertFalse(apiError.inferenceRan, code)
            XCTAssertFalse(apiError.settlementRan, code)
        }
        // A queue-wait expiry must never read as queue-full at submit.
        XCTAssertNotEqual(
            ContinuousBatchSchedulerError.queueWaitTimedOut.asAPIError()?.code,
            ContinuousBatchSchedulerError.backpressure.asAPIError()?.code
        )
    }

    // `.backpressure` covers only the pre-admission sites — the submit-time
    // and enqueue-time queue/duplicate-waiter guards, none of which has
    // offered its caller an event. The decode pump's post-token failure is
    // `.deliveryBackpressure`: inference ran, partial output may already be
    // with the buyer, so it is a distinct code and not retryable.
    func testAC25DeliveryBackpressureIsAPostTokenNonRetryableOutcome() throws {
        let apiError = try XCTUnwrap(ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError())
        XCTAssertEqual(apiError.status, 503)
        XCTAssertEqual(apiError.code, "continuous_batching_stream_delivery_backpressure")
        XCTAssertTrue(apiError.inferenceRan)
        XCTAssertFalse(apiError.settlementRan)

        let envelope = apiError.envelope["error"] as? [String: Any]
        XCTAssertEqual(envelope?["retryable"] as? Bool, false)
        XCTAssertEqual(envelope?["inference_ran"] as? Bool, true)
        XCTAssertEqual(envelope?["settlement_ran"] as? Bool, false)

        // Pinned false at the call site, so adding the code to
        // `APIError.retryableByCode` later cannot silently flip it.
        XCTAssertEqual(
            APIError(
                status: 503,
                message: "m",
                type: "server_error",
                code: ContinuousBatchSchedulerError.deliveryBackpressureCode
            ).envelope["error"].flatMap { ($0 as? [String: Any])?["retryable"] as? Bool },
            false
        )
    }

    // `.drained` / `.drainTimedOut` are harness-only: reachable solely through
    // `drain()`, whose only `Sources/` caller is the MSB benchmark command. A
    // buyer-visible mapping for them would be unreachable code.
    func testAC25UnmappedSchedulerErrorsRethrowUnchanged() {
        let unmapped: [ContinuousBatchSchedulerError] = [
            .drained,
            .drainTimedOut,
        ]
        for error in unmapped {
            XCTAssertNil(error.asAPIError(), "\(error) must not carry an API mapping")
        }
    }

    // `.unsupported` / `.requestFailed` already carry a well-formed code
    // string; the mapping keeps that string verbatim and only decides the
    // status. Codes `ContinuousBatchingUnsupportedReason` already publishes
    // must agree with that reason's status.
    func testAC25CarriedSchedulerCodesMapToStatusByShape() {
        let expected: [(ContinuousBatchSchedulerError, Int, String)] = [
            // Exact `apiCode` of `.stickyCacheHandoffUnavailable`, which the
            // preflight surface publishes as 400.
            (.unsupported("continuous_batching_paged_kv_handoff_unavailable"), 400, "invalid_request_error"),
            // `localCapabilityReason` reports these two without the API
            // prefix; they mirror `.tupleNotAdvertised` /
            // `.moePromotionEvidenceUnavailable`, both 400.
            (.unsupported("local_paged_kv_descriptor_mismatch"), 400, "invalid_request_error"),
            (.unsupported("moe_promotion_evidence_unavailable"), 400, "invalid_request_error"),
            (.unsupported("continuous_batching_cached_tokens_require_conversation_key"), 400, "invalid_request_error"),
            (.requestFailed("continuous_batching_invalid_cached_prompt_tokens"), 400, "invalid_request_error"),
            (.requestFailed("continuous_batching_invalid_request"), 400, "invalid_request_error"),
            (.requestFailed("continuous_batching_request_fingerprint_failed"), 400, "invalid_request_error"),
            (.unsupported("continuous_batching_scheduler_failed_closed"), 503, "server_error"),
            (.unsupported("continuous_batching_admission_sequence_exhausted"), 503, "server_error"),
            (.unsupported("continuous_batching_local_binding_mismatch"), 503, "server_error"),
            // Unknown/future codes fail to a provider-side status rather than
            // blaming the buyer.
            (.unsupported("continuous_batching_some_unseen_code"), 503, "server_error"),
        ]
        for (error, status, type) in expected {
            guard let apiError = error.asAPIError() else {
                return XCTFail("expected an API mapping for \(error)")
            }
            XCTAssertEqual(apiError.status, status, apiError.code)
            XCTAssertEqual(apiError.type, type, apiError.code)
            // Neither case can escape `submit()` after inference ran: the
            // decode/prefill-structure `.requestFailed` codes are converted
            // into a terminal result by the pump and never thrown to a caller.
            XCTAssertFalse(apiError.inferenceRan, apiError.code)
            XCTAssertFalse(apiError.settlementRan, apiError.code)
        }
        XCTAssertEqual(
            ContinuousBatchSchedulerError
                .unsupported("continuous_batching_paged_kv_handoff_unavailable")
                .asAPIError()?.code,
            "continuous_batching_paged_kv_handoff_unavailable"
        )
        XCTAssertEqual(
            ContinuousBatchSchedulerError
                .unsupported("continuous_batching_paged_kv_handoff_unavailable")
                .asAPIError()?.status,
            ContinuousBatchingUnsupportedReason.stickyCacheHandoffUnavailable.status
        )
    }

    // SPEC-038 `:614`: a queue-pressure rejection must carry bounded retry
    // guidance. Both queue-pressure codes therefore serialize `retryable:
    // true`; the other AC-25 codes stay non-retryable.
    func testAC25QueuePressureCodesSerializeAsRetryable() {
        for error in [ContinuousBatchSchedulerError.backpressure, .queueWaitTimedOut] {
            let envelope = try? XCTUnwrap(error.asAPIError()?.envelope["error"] as? [String: Any])
            XCTAssertEqual(envelope?["retryable"] as? Bool, true, "\(error)")
            XCTAssertEqual(envelope?["inference_ran"] as? Bool, false, "\(error)")
            XCTAssertEqual(envelope?["settlement_ran"] as? Bool, false, "\(error)")
        }
        let mismatch = ContinuousBatchSchedulerError.duplicateRequestMismatch.asAPIError()?.envelope["error"] as? [String: Any]
        XCTAssertEqual(mismatch?["retryable"] as? Bool, false)
    }

    // A request that is admitted to the queue but never reaches a slot inside
    // the deadline is rejected pre-admission: distinct error, non-settling, no
    // retained terminal result, no leaked waiter.
    func testAC25QueueWaitDeadlineRejectsUnadmittedRequestAndLeavesNoState() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["held": [1], "late": [2]], prefillGate: gate)
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            queueLimit: 4,
            queueWaitTimeoutNanoseconds: 150_000_000,
            backend: backend
        )

        let held = Task {
            try await scheduler.submit(.init(
                id: "held",
                conversationKey: "",
                promptTokens: [1, 11],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }

        do {
            _ = try await scheduler.submit(.init(
                id: "late",
                conversationKey: "",
                promptTokens: [2, 22],
                maxOutputTokens: 1
            ))
            XCTFail("expected queue-wait timeout")
        } catch ContinuousBatchSchedulerError.queueWaitTimedOut {
            // expected — and specifically not `.backpressure`: the queue had room.
        }

        let afterTimeout = await scheduler.metrics()
        XCTAssertTrue(afterTimeout.diagnostics.contains(.queueWaitTimedOut))
        XCTAssertFalse(afterTimeout.diagnostics.contains(.backpressureRejected))
        XCTAssertEqual(afterTimeout.waitingCount, 0)
        // Only the still-running held row keeps a waiter; the expired one is gone.
        XCTAssertEqual(afterTimeout.attachedWaiters, 1)
        // Non-settling: the expired request produced no terminal result at all,
        // so it can never be replayed or settled.
        XCTAssertEqual(afterTimeout.retainedTerminalResults, 0)
        let prefillCalls = await backend.prefillCallCount()
        XCTAssertEqual(prefillCalls, 1)

        await gate.open()
        let heldResult = try await held.value
        XCTAssertEqual(heldResult.terminalStatus, .length)
        // The expired request never occupied a slot, so the held row keeps the
        // only reservation and releases it normally.
        let afterDrain = await scheduler.metrics()
        XCTAssertEqual(afterDrain.slotsFree, afterDrain.slotsTotal)
    }

    // The deadline bounds queue wait only: a request that reaches a slot in
    // time is unaffected by a short timeout.
    func testAC25QueueWaitDeadlineDoesNotExpireAdmittedRows() async throws {
        let backend = ScriptedBackend(scripts: ["admitted": [7, 8]])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            queueLimit: 2,
            queueWaitTimeoutNanoseconds: 100_000_000,
            backend: backend
        )

        let result = try await scheduler.submit(.init(
            id: "admitted",
            conversationKey: "",
            promptTokens: [1, 2],
            maxOutputTokens: 2
        ))
        XCTAssertEqual(result.outputTokens, [7, 8])
        let metrics = await scheduler.metrics()
        XCTAssertFalse(metrics.diagnostics.contains(.queueWaitTimedOut))
    }

    // A timeout task that wakes while its request is out of `waiting` for an
    // admission attempt must not consume the deadline. `late` is parked inside
    // the backend's retained-cache install — removed from `waiting`, present
    // in `admittingRequests` — while its deadline passes; admission then fails
    // `capacityExceeded` and re-queues it. The original absolute deadline has
    // to survive that round trip and expire the request, or the bounded wait
    // silently becomes unbounded again.
    func testAC25StaleQueueWaitTimeoutDuringAdmissionKeepsTheDeadline() async throws {
        let holdInstall = AsyncGate()
        let lateInstall = AsyncGate()
        let bridge = HeadlessRetainedCacheBridge()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retainedHold = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-hold",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 3
        )
        let retainedLate = try await makeRetainedSequence(
            allocator: allocator,
            conversationKey: "conversation-late",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 3
        )
        let backend = ScriptedBackend(
            scripts: ["hold": [10, 11, 12, 13, 14, 15], "late": [20]],
            retainedInstallGates: ["hold": holdInstall, "late": lateInstall],
            // Raised on every admission attempt for `late`, so the request is
            // re-queued rather than admitted however often the pump retries.
            retainedInstallErrors: [
                "late": PagedKVAllocatorError.capacityExceeded(requiredBlocks: 2, availableBlocks: 0) as any Error,
            ]
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 2,
            maxPromptChunkTokens: 4,
            queueWaitTimeoutNanoseconds: 600_000_000,
            maxPrefillRowsPerIteration: 2,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )

        let hold = Task {
            try await scheduler.submit(.init(
                id: "hold",
                conversationKey: "conversation-hold",
                promptTokens: Array(0..<5),
                maxOutputTokens: 6,
                temperature: 0.0,
                topP: 1.0,
                cachedPromptTokens: 3,
                retainedPagedKVSequence: retainedHold
            ))
        }
        try await eventually { await backend.retainedInstallAttempts()["hold"] == 1 }

        let late = Task {
            try await scheduler.submit(.init(
                id: "late",
                conversationKey: "conversation-late",
                promptTokens: Array(10..<15),
                maxOutputTokens: 1,
                temperature: 0.0,
                topP: 1.0,
                cachedPromptTokens: 3,
                retainedPagedKVSequence: retainedLate
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }

        // Releasing `hold` lets the same admit loop reach `late`, which then
        // parks inside its own install.
        await holdInstall.open()
        try await eventually { await backend.retainedInstallAttempts()["late"] == 1 }
        let duringAdmission = await scheduler.metrics()
        XCTAssertEqual(duringAdmission.waitingCount, 0, "`late` must be out of `waiting`, mid-admission")

        // The deadline elapses here, with `late` mid-admission. The armed
        // timeout task cancels out, so drive the stale wake explicitly: this
        // is the timeout task that already woke when `suspendQueueWaitTimeout`
        // cancelled it, reaching the actor with the request no longer queued.
        try await Task.sleep(nanoseconds: 900_000_000)
        await scheduler.expireQueueWait(requestID: "late")

        // Admission now fails `capacityExceeded` and re-queues `late`.
        await lateInstall.open()

        do {
            _ = try await late.value
            XCTFail("expected the original queue-wait deadline to still expire the request")
        } catch ContinuousBatchSchedulerError.queueWaitTimedOut {
            // expected: the re-queued request kept its absolute deadline.
        }

        let metrics = await scheduler.metrics()
        XCTAssertTrue(metrics.diagnostics.contains(.queueWaitTimedOut))
        XCTAssertEqual(metrics.waitingCount, 0)

        let heldResult = try await hold.value
        XCTAssertEqual(heldResult.outputTokens, [10, 11, 12, 13, 14, 15])
    }

    // SPEC-038 AC-25: a queue-wait expiry runs nothing and settles nothing, so
    // the durable replay claim taken at submit is released. A client that
    // honours `retryable: true` and re-sends the same `X-Request-ID` must be
    // able to run, not collect a 409 for work that never happened.
    // SPEC-038 AC-25: an overdue request must never be admitted, even when its
    // timeout task has not run yet. The hook cancels the timer but keeps the
    // absolute deadline, so admission itself has to expire the request.
    func testAC25OverdueRequestIsExpiredAtAdmissionEvenIfItsTimerHasNotRun() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["held": [1], "late": [2]],
            prefillGate: gate
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            queueLimit: 4,
            queueWaitTimeoutNanoseconds: 150_000_000,
            backend: backend
        )
        let held = Task {
            try await scheduler.submit(.init(id: "held", conversationKey: "", promptTokens: [1, 11], maxOutputTokens: 1))
        }
        try await eventually { await backend.prefillCallCount() == 1 }
        let late = Task {
            try await scheduler.submit(.init(id: "late", conversationKey: "", promptTokens: [2, 22], maxOutputTokens: 1))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }

        await scheduler.cancelQueueWaitTimerForTest(requestID: "late")
        try await Task.sleep(nanoseconds: 300_000_000)
        let queued = await scheduler.metrics().waitingCount
        XCTAssertEqual(queued, 1, "with its timer cancelled, `late` is still queued and now overdue")

        // Freeing the slot sends the pump to admission with `late` overdue.
        await gate.open()
        _ = try await held.value
        do {
            _ = try await late.value
            XCTFail("an overdue request must not be admitted")
        } catch ContinuousBatchSchedulerError.queueWaitTimedOut {
            // expected
        }
        let prefills = await backend.prefillCallCount()
        XCTAssertEqual(prefills, 1, "`late` must never reach prefill")
    }

    func testAC25QueueWaitTimeoutReleasesTheReplayClaimSoTheSameIDCanRetry() async throws {
        let gate = AsyncGate()
        let authority = TestReplayAuthority()
        let backend = ScriptedBackend(
            scripts: ["held": [1], "late": [2]],
            prefillGate: gate
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            queueLimit: 4,
            queueWaitTimeoutNanoseconds: 150_000_000,
            backend: backend,
            replayAuthority: authority
        )

        let held = Task {
            try await scheduler.submit(.init(
                id: "held",
                conversationKey: "",
                promptTokens: [1, 11],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }

        do {
            _ = try await scheduler.submit(.init(
                id: "late",
                conversationKey: "",
                promptTokens: [2, 22],
                maxOutputTokens: 1
            ))
            XCTFail("expected queue-wait timeout")
        } catch ContinuousBatchSchedulerError.queueWaitTimedOut {
            // expected
        }
        XCTAssertEqual(authority.released(), ["late"])

        await gate.open()
        _ = try await held.value

        // The same request ID, same body: the retry the 503 advertised.
        let retry = try await scheduler.submit(.init(
            id: "late",
            conversationKey: "",
            promptTokens: [2, 22],
            maxOutputTokens: 1
        ))
        XCTAssertEqual(retry.outputTokens, [2])
        XCTAssertEqual(retry.terminalStatus, .length)
    }

    // SPEC-038 AC-25 (F-5): the 503 fallback in `carriedCodeStatus` is a
    // runtime safety net, not the classification. Every code the scheduler
    // can carry to the buyer is listed explicitly, so a new serve-path code
    // fails this test instead of silently inheriting 503.
    func testEveryCarriedSchedulerCodeIsClassified() throws {
        let source = try String(contentsOf: Self.schedulerSourceURL, encoding: .utf8)
        let pattern = "ContinuousBatchSchedulerError\\s*\\.\\s*(?:unsupported|requestFailed)\\s*\\(\\s*\"([a-z0-9_]+)\"\\s*\\)"
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        let codes = Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
        XCTAssertFalse(codes.isEmpty, "the code-literal scan matched nothing; the pattern has rotted")
        for code in codes.sorted() {
            XCTAssertNotNil(
                ContinuousBatchSchedulerError.carriedCodeStatuses[code],
                "\(code) is thrown by the scheduler but has no explicit status classification"
            )
        }
        // Codes carried through a variable (`localCapabilityReason`) are not
        // literals at the throw site, so they are asserted by name here.
        for code in ["local_paged_kv_descriptor_mismatch", "moe_promotion_evidence_unavailable"] {
            XCTAssertNotNil(ContinuousBatchSchedulerError.carriedCodeStatuses[code], code)
        }
    }

    private static var schedulerSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // macprovider-cliTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // phase3-binary
            .appendingPathComponent("Sources/macprovider-cli/ContinuousBatchScheduler.swift")
    }

    func testSchedulerContractBoundedFCFSQueueRejectsAtBackpressureLimit() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["r1": [1], "r2": [2]], prefillGate: gate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, queueLimit: 1, backend: backend)

        let first = Task {
            try await scheduler.submit(.init(id: "r1", conversationKey: "", promptTokens: [1, 11], maxOutputTokens: 1))
        }
        try await eventually { await backend.prefillCallCount() == 1 }
        let second = Task {
            try await scheduler.submit(.init(id: "r2", conversationKey: "", promptTokens: [2, 22], maxOutputTokens: 1))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }

        do {
            _ = try await scheduler.submit(.init(id: "r3", conversationKey: "", promptTokens: [3], maxOutputTokens: 1))
            XCTFail("expected queue backpressure")
        } catch ContinuousBatchSchedulerError.backpressure {
            // expected
        }

        await gate.open()
        _ = try await first.value
        _ = try await second.value
        let prefillOrder = await backend.prefillOrder()
        XCTAssertEqual(prefillOrder, [["r1"], ["r2"]])
        let metrics = await scheduler.metrics()
        XCTAssertTrue(metrics.diagnostics.contains(.backpressureRejected))
    }

    func testAC3CancellationIsIdempotentAndLeavesHealthyRowRunning() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(scripts: [
            "cancel": [1, 2, 3],
            "healthy": [8, 9],
        ], decodeGate: decodeGate)
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        let cancelled = Task {
            try await scheduler.submit(.init(id: "cancel", conversationKey: "", promptTokens: [1], maxOutputTokens: 3))
        }
        let healthy = Task {
            try await scheduler.submit(.init(id: "healthy", conversationKey: "", promptTokens: [2], maxOutputTokens: 2))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        await scheduler.cancel(requestID: "cancel")
        await scheduler.cancel(requestID: "cancel")
        await decodeGate.open()

        let cancelledResult = try await cancelled.value
        let healthyResult = try await healthy.value

        XCTAssertEqual(cancelledResult.terminalStatus, .cancelled)
        XCTAssertEqual(cancelledResult.completionTokens, 0)
        XCTAssertEqual(cancelledResult.outputTokens, [])
        XCTAssertEqual(healthyResult.outputTokens, [8, 9])
        XCTAssertEqual(healthyResult.terminalStatus, .length)
    }

    func testAC17AC24MidDecodeAllocatorExtensionFailureFailsOnlyThatRowAndReleasesBlocks() async throws {
        let backend = ScriptedBackend(scripts: [
            "a-healthy": [8, 9, 10, 11],
            "z-fail": [2, 3, 4, 5],
        ])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 2)
        let scheduler = ContinuousBatchScheduler(
            configuration: Self.configuration(
                descriptor: Self.descriptor(blockSizeTokens: 4, maxPhysicalBlocks: 2),
                maxActiveRows: 2,
                decodeHeadroomTokens: 1
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let healthy = Task {
            try await scheduler.submit(.init(
                id: "a-healthy",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 4
            ))
        }
        let failing = Task {
            try await scheduler.submit(.init(
                id: "z-fail",
                conversationKey: "",
                promptTokens: [2, 3, 4],
                maxOutputTokens: 4
            ))
        }

        let firstResult = try await healthy.value
        let secondResult = try await failing.value
        let results = [firstResult, secondResult]

        XCTAssertEqual(results.filter { $0.terminalStatus == .length }.count, 1)
        XCTAssertEqual(results.filter { $0.terminalStatus == .requestFailed }.count, 1)
        XCTAssertEqual(
            results.first { $0.terminalStatus == .requestFailed }?.errorCode,
            "continuous_batching_block_extension_failed"
        )
        XCTAssertFalse(results.first { $0.terminalStatus == .length }?.outputTokens.isEmpty ?? false)
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 2)
        let metrics = await scheduler.metrics()
        XCTAssertTrue(metrics.diagnostics.contains(.localExtensionFailed))
    }

    func testAC11BatchForwardFailureCleansEveryParticipatingRow() async throws {
        let backend = ScriptedBackend(
            scripts: ["a": [1, 3], "b": [2, 4]],
            failDecodeCall: 2
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let scheduler = ContinuousBatchScheduler(
            configuration: Self.configuration(
                descriptor: Self.descriptor(blockSizeTokens: 4, maxPhysicalBlocks: 4),
                maxActiveRows: 2,
                decodeHeadroomTokens: 1
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let a = Task {
            try await scheduler.submit(.init(id: "a", conversationKey: "", promptTokens: [1], maxOutputTokens: 2))
        }
        let b = Task {
            try await scheduler.submit(.init(id: "b", conversationKey: "", promptTokens: [2], maxOutputTokens: 2))
        }

        let aResult = try await a.value
        let bResult = try await b.value
        XCTAssertEqual(aResult.terminalStatus, .batchFailed)
        XCTAssertEqual(bResult.terminalStatus, .batchFailed)
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 4)
        let metrics = await scheduler.metrics()
        XCTAssertTrue(metrics.diagnostics.contains(.batchForwardFailed))
    }

    func testAC20AC10DrainRejectsQueuedWorkAndDuplicateSubmitReturnsSameTerminal() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["active": [7]], prefillGate: gate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, queueLimit: 2, backend: backend)

        let active = Task {
            try await scheduler.submit(.init(id: "active", conversationKey: "", promptTokens: [1, 11], maxOutputTokens: 1))
        }
        try await eventually { await backend.prefillCallCount() == 1 }
        let queued = Task {
            try await scheduler.submit(.init(id: "queued", conversationKey: "", promptTokens: [2], maxOutputTokens: 1))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }

        let drainTask = Task {
            try await scheduler.drain()
        }
        try await eventually { await scheduler.metrics().diagnostics.contains(.drained) }
        await gate.open()
        _ = try await drainTask.value

        let queuedResult = try await queued.value
        XCTAssertEqual(queuedResult.terminalStatus, .rejected)
        XCTAssertEqual(queuedResult.snapshot, nil)
        XCTAssertEqual(queuedResult.promptTokens, 0)
        XCTAssertEqual(queuedResult.completionTokens, 0)
        XCTAssertEqual(queuedResult.emittedTokens, 0)
        XCTAssertEqual(queuedResult.cachedPromptTokens, 0)

        let activeResult = try await active.value
        let duplicate = try await scheduler.submit(.init(id: "active", conversationKey: "", promptTokens: [1, 11], maxOutputTokens: 1))
        XCTAssertEqual(duplicate.outputTokens, activeResult.outputTokens)
        XCTAssertEqual(duplicate.terminalStatus, activeResult.terminalStatus)
        XCTAssertEqual(activeResult.settlementDisposition, .eligibleOwner)
        XCTAssertEqual(duplicate.settlementDisposition, .nonSettlingReplay)
        XCTAssertEqual(activeResult.snapshot?.modelSHA256, Self.modelSHA)
    }

    func testAC10DrainTimeoutFailsClosedAndLeavesOldWorkOnItsSnapshot() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["active": [7]], prefillGate: gate)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let config = ContinuousBatchSchedulerConfiguration(
            descriptor: Self.descriptor(),
            tuple: Self.tuple(),
            maxActiveRows: 1,
            decodeHeadroomTokens: 2,
            drainTimeoutNanoseconds: 1_000_000,
            drainCancellationGraceNanoseconds: 1_000_000_000,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            )
        )
        let scheduler = ContinuousBatchScheduler(
            configuration: config,
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        let active = Task {
            try await scheduler.submit(.init(
                id: "active",
                conversationKey: "",
                promptTokens: [1, 2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }

        do {
            _ = try await scheduler.drain()
            XCTFail("expected bounded drain timeout")
        } catch ContinuousBatchSchedulerError.drainTimedOut {
            // The caller must abort the swap; the timed-out request is cancelled
            // and its bindings are released before drain returns.
        }

        let result = try await active.value
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
        XCTAssertEqual(freeBlocks, 16)

        do {
            _ = try await scheduler.drain()
            XCTFail("a forced-cancellation timeout must permanently reject drain permits")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_scheduler_failed_closed")
        }
    }

    func testDrainGraceDeadlineDoesNotAwaitWedgedBackendCancellation() async throws {
        let backend = WedgedCancellationBackend()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                drainTimeoutNanoseconds: 5_000_000,
                drainCancellationGraceNanoseconds: 10_000_000,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        let active = Task {
            try await scheduler.submit(.init(
                id: "wedged",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await scheduler.drain()
            XCTFail("expected drain timeout while cancellation acknowledgement is wedged")
        } catch ContinuousBatchSchedulerError.drainTimedOut {
            // The grace deadline is authoritative even though the backend has
            // not yet acknowledged that it stopped touching row bindings.
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        XCTAssertLessThan(elapsed, 500_000_000)
        let timedOutMetrics = await scheduler.metrics()
        XCTAssertEqual(timedOutMetrics.activeDecodeRows, 1)

        await backend.acknowledgeCancellation()
        let result = try await active.value
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
        let freeBlocksAfterAcknowledgement = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocksAfterAcknowledgement, 16)

        do {
            _ = try await scheduler.drain()
            XCTFail("a timed-out scheduler must never mint a later drain permit")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_scheduler_failed_closed")
        }
    }

    func testSlowTokenSinkCannotBlockSchedulerAndIsBoundedPerWaiter() async throws {
        let sinkGate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["slow": [1, 2, 3, 4]])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 1,
                decodeHeadroomTokens: 1,
                tokenDeliveryBufferLimit: 1,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let slow = Task {
            try await scheduler.submit(
                .init(id: "slow", conversationKey: "", promptTokens: [1], maxOutputTokens: 4),
                tokenSink: { _ in await sinkGate.wait() }
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await sinkGate.open()
        do {
            _ = try await slow.value
            XCTFail("expected bounded stream-delivery backpressure")
        } catch ContinuousBatchSchedulerError.deliveryBackpressure {
            // Only this waiter/request fails; the scheduler actor never awaits
            // the consumer callback.
        }
        try await eventually { await scheduler.metrics().slotsFree == 1 }
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 16)
    }

    func testLockstepWindowOverflowsDefaultDeliveryBufferWhenSinkCannotDrain() async throws {
        XCTAssertGreaterThan(
            ContinuousBatchSchedulerConfiguration.productionTokenDeliveryBufferLimit,
            ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow
        )
        let sinkGate = AsyncGate()
        let tokens = Array(1...32)
        let backend = ScriptedBackend(scripts: ["lockstep-stream": tokens])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            tokenDeliveryTimeoutNanoseconds: 50_000_000,
            tokenDeliveryBufferLimit: 16,
            maxDecodeLockstepWindow: ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow,
            backend: backend
        )

        let blocked = Task {
            try await scheduler.submit(
                .init(
                    id: "lockstep-stream",
                    conversationKey: "",
                    promptTokens: [1],
                    maxOutputTokens: tokens.count
                ),
                tokenSink: { _ in await sinkGate.wait() }
            )
        }
        do {
            _ = try await blocked.value
            XCTFail("expected lockstep hop 2 to overflow a 16-token delivery buffer")
        } catch ContinuousBatchSchedulerError.deliveryBackpressure {
            // Same fail-closed as live canary: first hop fills the buffer,
            // the waiter is still in sink work, hop 2 cannot offer.
        }
        await sinkGate.open()
        try await eventually { await scheduler.metrics().slotsFree == 1 }
    }

    func testProductionDeliveryBufferAbsorbsLockstepWhileSinkDrains() async throws {
        let tokens = Array(1...32)
        let backend = ScriptedBackend(scripts: ["lockstep-stream": tokens])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            tokenDeliveryBufferLimit: ContinuousBatchSchedulerConfiguration.productionTokenDeliveryBufferLimit,
            maxDecodeLockstepWindow: ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow,
            backend: backend
        )

        let recorder = TokenEventRecorder()
        let result = try await scheduler.submit(
            .init(
                id: "lockstep-stream",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: tokens.count
            ),
            tokenSink: { event in
                recorder.append(event)
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        )
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.outputTokens, tokens)
        XCTAssertEqual(recorder.events().count, tokens.count)
    }

    func testCancellingDrainKeepsSchedulerFailedClosedUntilOldWorkFinishes() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: ["active": [7]], prefillGate: gate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
        let active = Task {
            try await scheduler.submit(.init(
                id: "active",
                conversationKey: "",
                promptTokens: [1, 2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }

        let drainTask = Task { try await scheduler.drain() }
        try await eventually { await scheduler.metrics().diagnostics.contains(.drained) }
        drainTask.cancel()
        do {
            _ = try await drainTask.value
            XCTFail("expected drain cancellation")
        } catch is CancellationError {
            // A cancelled swap remains fail-closed; it is not an admission reset.
        }

        do {
            _ = try await scheduler.submit(.init(
                id: "new",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
            XCTFail("expected scheduler to remain failed closed")
        } catch ContinuousBatchSchedulerError.drained {
            // Drain cancellation only stops this waiter; scheduler admission
            // remains closed while the old snapshot completes.
        }

        await gate.open()
        let activeResult = try await active.value
        XCTAssertEqual(activeResult.terminalStatus, .length)
    }

    func testLongPrefillIsActuallyChunkedAndDecodeRunsBetweenChunks() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["active": [11, 12, 13, 14], "long": [21]],
            decodeGate: decodeGate
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 2,
            maxPromptChunkTokens: 2,
            backend: backend
        )
        let active = Task {
            try await scheduler.submit(.init(
                id: "active",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 4
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let long = Task {
            try await scheduler.submit(.init(
                id: "long",
                conversationKey: "",
                promptTokens: [2, 3, 4, 5, 6, 7],
                maxOutputTokens: 1
            ))
        }
        await decodeGate.open()

        _ = try await active.value
        _ = try await long.value
        let events = await backend.events()
        let longPrefills = events.enumerated().filter { $0.element.hasPrefix("prefill:long:") }
        XCTAssertEqual(longPrefills.map(\.element), ["prefill:long:2", "prefill:long:2", "prefill:long:1"])
        XCTAssertTrue(events[(longPrefills[0].offset + 1)..<longPrefills[1].offset].contains("decode:active"))
        XCTAssertTrue(events[(longPrefills[1].offset + 1)..<longPrefills[2].offset].contains("decode:active"))
    }

    func testCancellationDuringPrefillWinsForZeroOutputRequest() async throws {
        let gate = AsyncGate()
        let backend = ScriptedBackend(scripts: [:], prefillGate: gate)
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)
        let request = Task {
            try await scheduler.submit(.init(
                id: "cancel-prefill",
                conversationKey: "",
                promptTokens: [1, 2],
                maxOutputTokens: 0
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }
        await scheduler.cancel(requestID: "cancel-prefill")
        await gate.open()

        let result = try await request.value
        XCTAssertEqual(result.terminalStatus, .cancelled)
        XCTAssertEqual(result.outputTokens, [])
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
    }

    func testMalformedBackendTokenFailsRowWithoutReturningPartialOutput() async throws {
        let backend = ScriptedBackend(scripts: ["bad": [-1]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "bad",
            conversationKey: "",
            promptTokens: [1, 2],
            maxOutputTokens: 1
        ))

        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_invalid_decode_token")
        XCTAssertEqual(result.outputTokens, [])
        XCTAssertEqual(result.completionTokens, 0)
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)
    }

    func testPrefillLeavesFinalPromptTokenForFirstDecodeKVSlot() async throws {
        let backend = ScriptedBackend(scripts: ["cursor": [31]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "cursor",
            conversationKey: "",
            promptTokens: [11, 22, 33],
            maxOutputTokens: 1
        ))

        let prefillCommitted = await backend.prefillCommittedCounts()
        let prefillTargets = await backend.prefillTargetCounts()
        let decodeCommitted = await backend.decodeCommittedCounts()
        let decodeTargets = await backend.decodeTargetCounts()
        let decodeCurrentTokens = await backend.currentTokensByDecodeBatch()
        XCTAssertEqual(result.outputTokens, [31])
        XCTAssertEqual(prefillCommitted, [["cursor": 0]])
        XCTAssertEqual(prefillTargets, [["cursor": 2]])
        XCTAssertEqual(decodeCommitted, [["cursor": 2]])
        XCTAssertEqual(decodeTargets, [["cursor": 3]])
        XCTAssertEqual(decodeCurrentTokens, [["cursor": 33]])
    }

    func testMalformedBackendTokenFailsOnlyItsRow() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: ["a-healthy": [9, 10], "z-bad": [-1]],
            decodeGate: decodeGate
        )
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        let healthy = Task { try await scheduler.submit(.init(
            id: "a-healthy",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 2
        )) }
        try await eventually { await backend.decodeCallCount() == 1 }
        let bad = Task { try await scheduler.submit(.init(
            id: "z-bad",
            conversationKey: "",
            promptTokens: [2],
            maxOutputTokens: 1
        )) }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let results = try await [healthy.value, bad.value]
        XCTAssertEqual(results.first { $0.requestID == "z-bad" }?.terminalStatus, .requestFailed)
        XCTAssertEqual(results.first { $0.requestID == "a-healthy" }?.outputTokens, [9, 10])
        XCTAssertEqual(results.first { $0.requestID == "a-healthy" }?.terminalStatus, .length)
        let batches = await backend.decodeBatches()
        XCTAssertTrue(batches.contains(["a-healthy", "z-bad"]))
    }

    func testRowLocalSamplerFailureDoesNotFailHealthyRows() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(
            scripts: [
                "sampler-failed": [7],
                "healthy": [9, 10],
            ],
            decodeGate: decodeGate,
            rowFailures: ["sampler-failed"]
        )
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)
        let healthy = Task {
            try await scheduler.submit(.init(
                id: "healthy",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 2
            ))
        }
        try await eventually { await scheduler.metrics().activeDecodeRows == 1 }
        let failed = Task {
            try await scheduler.submit(.init(
                id: "sampler-failed",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let results = try await [failed.value, healthy.value]
        XCTAssertEqual(
            results.first { $0.requestID == "sampler-failed" }?.terminalStatus,
            .requestFailed
        )
        XCTAssertEqual(
            results.first { $0.requestID == "sampler-failed" }?.errorCode,
            "continuous_batching_row_sampling_failed"
        )
        XCTAssertEqual(results.first { $0.requestID == "healthy" }?.outputTokens, [9, 10])
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(decodeCalls, 2)
    }

    func testStopSequenceWinsWhenItAlsoReachesOutputLimit() async throws {
        let backend = ScriptedBackend(scripts: ["boundary": [7]])
        let scheduler = try await makeScheduler(maxActiveRows: 1, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "boundary",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 1,
            stopTokenSequences: [[7]]
        ))

        XCTAssertEqual(result.outputTokens, [])
        XCTAssertEqual(result.completionTokens, 1)
        XCTAssertEqual(result.emittedTokens, 0)
        XCTAssertEqual(result.terminalStatus, .stop)
    }

    func testMultiTokenStopPrefixIsHeldBackUntilMatchedOrDisproved() async throws {
        let stoppedBackend = ScriptedBackend(scripts: ["stopped": [5, 7, 8]])
        let stoppedScheduler = try await makeScheduler(maxActiveRows: 1, backend: stoppedBackend)
        let stopped = try await stoppedScheduler.submit(.init(
            id: "stopped",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 3,
            stopTokenSequences: [[7, 8]]
        ))
        XCTAssertEqual(stopped.outputTokens, [5])
        XCTAssertEqual(stopped.completionTokens, 3)
        XCTAssertEqual(stopped.terminalStatus, .stop)

        let disprovedBackend = ScriptedBackend(scripts: ["disproved": [5, 7, 9]])
        let disprovedScheduler = try await makeScheduler(maxActiveRows: 1, backend: disprovedBackend)
        let disproved = try await disprovedScheduler.submit(.init(
            id: "disproved",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 3,
            stopTokenSequences: [[7, 8]]
        ))
        XCTAssertEqual(disproved.outputTokens, [5, 7, 9])
        XCTAssertEqual(disproved.terminalStatus, .length)
    }

    func testCleanupFailureCannotProduceSuccessAndFailsSchedulerClosed() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let backend = PrefillReleaseSabotagingBackend(allocator: allocator)
        let scheduler = ContinuousBatchScheduler(
            configuration: Self.configuration(maxActiveRows: 1),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let result = try await scheduler.submit(.init(
            id: "cleanup",
            conversationKey: "",
            promptTokens: [1, 2],
            maxOutputTokens: 0
        ))
        XCTAssertEqual(result.terminalStatus, .requestFailed)
        XCTAssertEqual(result.errorCode, "continuous_batching_cleanup_failed")
        XCTAssertEqual(result.outputTokens, [])
        XCTAssertEqual(result.snapshot?.modelSHA256, Self.modelSHA)

        do {
            _ = try await scheduler.submit(.init(
                id: "after-cleanup",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
            XCTFail("expected cleanup failure to close the scheduler")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "continuous_batching_scheduler_failed_closed")
        }
    }

    func testCleanupFailureStopsCurrentPumpBeforeAdmittingAnotherRow() async throws {
        let gate = AsyncGate()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let backend = PrefillReleaseSabotagingBackend(allocator: allocator, gate: gate)
        let scheduler = ContinuousBatchScheduler(
            configuration: Self.configuration(maxActiveRows: 1, queueLimit: 2),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        let sabotaged = Task {
            try await scheduler.submit(.init(
                id: "cleanup-first",
                conversationKey: "",
                promptTokens: [1, 2],
                maxOutputTokens: 0
            ))
        }
        try await eventually { await backend.prefillCallCount() == 1 }
        let queued = Task {
            try await scheduler.submit(.init(
                id: "cleanup-second",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await gate.open()

        let first = try await sabotaged.value
        let second = try await queued.value
        XCTAssertEqual(first.terminalStatus, .requestFailed)
        XCTAssertEqual(first.errorCode, "continuous_batching_cleanup_failed")
        XCTAssertEqual(second.terminalStatus, .requestFailed)
        XCTAssertEqual(second.errorCode, "continuous_batching_scheduler_failed_closed")
        let prefillCalls = await backend.prefillCallCount()
        XCTAssertEqual(prefillCalls, 1)
    }

    func testPartialDecodeLeaseCleanupFailureStillUnwindsEveryPreparedRow() async throws {
        let firstDecodeGate = AsyncGate()
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let backend = DecodeLeaseSabotagingBackend(
            allocator: allocator,
            sabotagedRequestID: "sabotaged",
            firstDecodeGate: firstDecodeGate
        )
        let scheduler = ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: Self.descriptor(),
                tuple: Self.tuple(),
                maxActiveRows: 2,
                decodeHeadroomTokens: 1,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: Self.modelID,
                    modelSHA256: Self.modelSHA,
                    weightsGeneration: 3
                )
            ),
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
        let first = Task {
            try await scheduler.submit(.init(
                id: "sabotaged",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 2
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let second = Task {
            try await scheduler.submit(.init(
                id: "healthy-lease",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await firstDecodeGate.open()
        try await eventually {
            await backend.decodeBatches().contains(["sabotaged", "healthy-lease"])
        }

        let results = try await [first.value, second.value]
        XCTAssertTrue(results.allSatisfy { $0.terminalStatus == .requestFailed })
        XCTAssertTrue(results.allSatisfy { $0.settlementDisposition == .notEligible })
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 16)
    }

    func testTerminalAndDiagnosticRetentionAreBounded() async throws {
        let backend = ScriptedBackend(scripts: ["one": [1], "two": [2]])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let config = ContinuousBatchSchedulerConfiguration(
            descriptor: Self.descriptor(),
            tuple: Self.tuple(),
            maxActiveRows: 1,
            decodeHeadroomTokens: 1,
            terminalResultLimit: 1,
            diagnosticLimit: 3,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            )
        )
        let scheduler = ContinuousBatchScheduler(
            configuration: config,
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )

        _ = try await scheduler.submit(.init(id: "one", conversationKey: "", promptTokens: [1], maxOutputTokens: 1))
        _ = try await scheduler.submit(.init(id: "two", conversationKey: "", promptTokens: [2], maxOutputTokens: 1))

        do {
            _ = try await scheduler.submit(.init(
                id: "one",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1
            ))
            XCTFail("expected compact dedupe tombstone to prevent re-execution")
        } catch ContinuousBatchSchedulerError.idempotencyWindowExpired {
            // The full replay payload was evicted, but duplicate execution is
            // still rejected within the configured compact tombstone horizon.
        }

        let metrics = await scheduler.metrics()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(metrics.retainedTerminalResults, 1)
        XCTAssertEqual(metrics.retainedDedupeTombstones, 1)
        XCTAssertLessThanOrEqual(metrics.retainedDiagnostics, 3)
        XCTAssertEqual(decodeCalls, 2)
    }

    func testDurableReplayAuthorityAllowsLocalRetentionToRollWithoutReexecution() async throws {
        let backend = ScriptedBackend(scripts: ["one": [1], "two": [2], "three": [3], "four": [4]])
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let replayAuthority = TestReplayAuthority()
        let config = ContinuousBatchSchedulerConfiguration(
            descriptor: Self.descriptor(),
            tuple: Self.tuple(),
            maxActiveRows: 1,
            decodeHeadroomTokens: 1,
            terminalResultLimit: 1,
            dedupeTombstoneLimit: 1,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            )
        )
        let scheduler = ContinuousBatchScheduler(
            configuration: config,
            allocator: allocator,
            backend: backend,
            replayAuthority: replayAuthority
        )

        _ = try await scheduler.submit(.init(id: "one", conversationKey: "", promptTokens: [1], maxOutputTokens: 1))
        _ = try await scheduler.submit(.init(id: "two", conversationKey: "", promptTokens: [2], maxOutputTokens: 1))
        _ = try await scheduler.submit(.init(id: "three", conversationKey: "", promptTokens: [3], maxOutputTokens: 1))
        _ = try await scheduler.submit(.init(id: "four", conversationKey: "", promptTokens: [4], maxOutputTokens: 1))
        do {
            _ = try await scheduler.submit(.init(id: "one", conversationKey: "", promptTokens: [1], maxOutputTokens: 1))
            XCTFail("expected durable authority to reject the locally evicted request ID")
        } catch ContinuousBatchSchedulerError.idempotencyWindowExpired {
            // Local result and tombstone retention rolled, but durable authority
            // still prevents duplicate inference and settlement work.
        }
        let decodeCalls = await backend.decodeCallCount()
        let metrics = await scheduler.metrics()
        XCTAssertEqual(decodeCalls, 4)
        XCTAssertEqual(metrics.retainedTerminalResults, 1)
        XCTAssertEqual(metrics.retainedDedupeTombstones, 1)
    }

    func testSchedulerContractMoERowsFeedTheirOwnCurrentTokenAndTelemetryStaysPerRow() async throws {
        let decodeGate = AsyncGate()
        let backend = ScriptedBackend(scripts: [
            "moe-a": [31, 32],
            "moe-b": [41],
        ], decodeGate: decodeGate)
        let scheduler = try await makeScheduler(
            descriptor: Self.descriptor(supportsMoE: true),
            tuple: Self.tuple(requiresMoE: true),
            moePromotionEvidenceAvailable: true,
            maxActiveRows: 2,
            backend: backend
        )

        let aTask = Task {
            try await scheduler.submit(.init(
                id: "moe-a",
                conversationKey: "",
                promptTokens: [30],
                maxOutputTokens: 2
            ))
        }
        try await eventually { await backend.decodeCallCount() == 1 }
        let bTask = Task {
            try await scheduler.submit(.init(
                id: "moe-b",
                conversationKey: "",
                promptTokens: [40],
                maxOutputTokens: 1
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        try await eventually {
            await backend.decodeBatches().contains(["moe-a", "moe-b"])
        }

        let a = try await aTask.value
        let b = try await bTask.value
        XCTAssertEqual(a.outputTokens, [31, 32])
        XCTAssertEqual(b.outputTokens, [41])
        let currentTokens = await backend.currentTokensByDecodeBatch()
        XCTAssertTrue(currentTokens.contains(["moe-a": 31, "moe-b": 40]))
    }

    func testIdleDecodeUsesLockstepWindowAndAppliesEveryToken() async throws {
        let backend = WindowRecordingBackend(scripts: [
            "solo": [11, 12, 13, 14],
        ])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxDecodeLockstepWindow: 8,
            backend: backend
        )
        let result = try await scheduler.submit(.init(
            id: "solo",
            conversationKey: "",
            promptTokens: [1],
            maxOutputTokens: 4,
            temperature: 0.0,
            topP: 1.0
        ))
        XCTAssertEqual(result.outputTokens, [11, 12, 13, 14])
        XCTAssertEqual(result.terminalStatus, .length)
        let windows = await backend.windowCalls()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].ids, ["solo"])
        XCTAssertEqual(windows[0].steps, 4)
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(decodeCalls, 0)
        let metrics = await scheduler.metrics()
        XCTAssertEqual(metrics.sharedForwardCalls, 1)
    }

    func testQueuedJoinForcesOneTokenDecodeThenWindowResumes() async throws {
        let decodeGate = AsyncGate()
        let backend = WindowRecordingBackend(
            scripts: [
                "active": [11, 12, 13, 14],
                "queued": [21, 22],
            ],
            decodeGate: decodeGate
        )
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxDecodeLockstepWindow: 2,
            backend: backend
        )

        let active = Task {
            try await scheduler.submit(.init(
                id: "active",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 4,
                temperature: 0.0,
                topP: 1.0
            ))
        }
        try await eventually { await backend.windowCallCount() == 1 }
        let queued = Task {
            try await scheduler.submit(.init(
                id: "queued",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 2,
                temperature: 0.0,
                topP: 1.0
            ))
        }
        try await eventually { await scheduler.metrics().waitingCount == 1 }
        await decodeGate.open()

        let activeResult = try await active.value
        let queuedResult = try await queued.value
        XCTAssertEqual(activeResult.outputTokens, [11, 12, 13, 14])
        XCTAssertEqual(queuedResult.outputTokens, [21, 22])

        let windows = await backend.windowCalls()
        XCTAssertGreaterThanOrEqual(windows.count, 3)
        XCTAssertEqual(windows[0].ids, ["active"])
        XCTAssertEqual(windows[0].steps, 2)
        XCTAssertTrue(windows.dropFirst().contains { $0.ids == ["active"] && $0.steps == 1 })
        XCTAssertEqual(windows.last?.ids, ["queued"])
        XCTAssertEqual(windows.last?.steps, 2)
    }

    func testLockstepWindowStopSequenceAppliesTokensSequentially() async throws {
        let backend = WindowRecordingBackend(scripts: [
            "stopped": [1, 2, 5, 6, 9],
        ])
        let scheduler = try await makeScheduler(
            maxActiveRows: 1,
            maxDecodeLockstepWindow: 5,
            backend: backend
        )
        let result = try await scheduler.submit(.init(
            id: "stopped",
            conversationKey: "",
            promptTokens: [10],
            maxOutputTokens: 5,
            stopTokenSequences: [[5, 6]],
            temperature: 0.0,
            topP: 1.0
        ))
        XCTAssertEqual(result.terminalStatus, .stop)
        XCTAssertEqual(result.outputTokens, [1, 2])
        XCTAssertEqual(result.generatedTokens, [1, 2, 5, 6])
        let windows = await backend.windowCalls()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].steps, 5)
    }

    private static let modelID = "mlx-community/Qwen-Test"
    private static let modelSHA = String(repeating: "a", count: 64)
    private static let tokenizerSHA = String(repeating: "b", count: 64)
    private static let chatTemplateSHA = String(repeating: "c", count: 64)
    private static let metallibSHA = String(repeating: "d", count: 64)

    private static func descriptor(
        supportsMoE: Bool = false,
        blockSizeTokens: Int = 4,
        maxPhysicalBlocks: Int = 16
    ) -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: tokenizerSHA,
            chatTemplateSHA256: chatTemplateSHA,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: supportsMoE,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: metallibSHA,
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1"
        )
    }

    private static func tuple(requiresMoE: Bool = false) -> ContinuousBatchingRequestedTuple {
        ContinuousBatchingRequestedTuple(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: tokenizerSHA,
            chatTemplateSHA256: chatTemplateSHA,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: requiresMoE,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: metallibSHA,
            kernelIdentifier: "paged_attention_v1",
            parityLabel: "sdpa-parity-v1",
            poolEpoch: 1
        )
    }

    func testOversizedQueueWaitIsClampedNotTurnedIntoAnUnboundedWait() {
        let configuration = ContinuousBatchSchedulerConfiguration(
            descriptor: Self.descriptor(),
            tuple: Self.tuple(),
            maxActiveRows: 1,
            decodeHeadroomTokens: 1,
            queueWaitTimeoutNanoseconds: UInt64.max,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            )
        )
        XCTAssertEqual(
            configuration.queueWaitTimeoutNanoseconds,
            ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutNanoseconds
        )
    }

    private static func configuration(
        descriptor: PagedKVDescriptor = descriptor(),
        tuple: ContinuousBatchingRequestedTuple = tuple(),
        maxActiveRows: Int,
        queueLimit: Int? = nil,
        decodeHeadroomTokens: Int = 2
    ) -> ContinuousBatchSchedulerConfiguration {
        ContinuousBatchSchedulerConfiguration(
            descriptor: descriptor,
            tuple: tuple,
            maxActiveRows: maxActiveRows,
            queueLimit: queueLimit,
            decodeHeadroomTokens: decodeHeadroomTokens,
            maxPrefillRowsPerIteration: 1,
            maxPromptChunkTokens: 2,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: modelID,
                modelSHA256: modelSHA,
                weightsGeneration: 3
            )
        )
    }

    private func makeScheduler(
        descriptor: PagedKVDescriptor = descriptor(),
        tuple: ContinuousBatchingRequestedTuple = tuple(),
        moePromotionEvidenceAvailable: Bool = false,
        maxActiveRows: Int,
        queueLimit: Int? = nil,
        decodeHeadroomTokens: Int = 2,
        maxPromptChunkTokens: Int = 2,
        tokenDeliveryTimeoutNanoseconds: UInt64 = 5_000_000_000,
        queueWaitTimeoutNanoseconds: UInt64 = ContinuousBatchSchedulerConfiguration
            .defaultQueueWaitTimeoutNanoseconds,
        tokenDeliveryBufferLimit: Int = 16,
        maxDecodeLockstepWindow: Int = 1,
        maxPrefillRowsPerIteration: Int = 1,
        backend: any ContinuousBatchSchedulerBackend,
        allocator: PagedKVBlockAllocator? = nil,
        contiguousCacheBridge: (any ContinuousBatchRetainedCacheBridge)? = nil,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority = TestReplayAuthority()
    ) async throws -> ContinuousBatchScheduler {
        let allocator = try allocator ?? PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let config = ContinuousBatchSchedulerConfiguration(
            descriptor: descriptor,
            tuple: tuple,
            moePromotionEvidenceAvailable: moePromotionEvidenceAvailable,
            maxActiveRows: maxActiveRows,
            queueLimit: queueLimit,
            decodeHeadroomTokens: decodeHeadroomTokens,
            maxPrefillRowsPerIteration: maxPrefillRowsPerIteration,
            maxPromptChunkTokens: maxPromptChunkTokens,
            tokenDeliveryBufferLimit: tokenDeliveryBufferLimit,
            tokenDeliveryTimeoutNanoseconds: tokenDeliveryTimeoutNanoseconds,
            queueWaitTimeoutNanoseconds: queueWaitTimeoutNanoseconds,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            ),
            maxDecodeLockstepWindow: maxDecodeLockstepWindow
        )
        return ContinuousBatchScheduler(
            configuration: config,
            allocator: allocator,
            backend: backend,
            replayAuthority: replayAuthority,
            contiguousCacheBridge: contiguousCacheBridge
        )
    }

    private func makeRetainedSequence(
        allocator: PagedKVBlockAllocator,
        conversationKey: String = "conversation-1",
        initialCapacityTokens: Int = 8,
        maxLogicalTokens: Int = 8,
        initialTokens: Int = 6
    ) async throws -> PagedKVRetainedSequence {
        let handle = try await allocator.allocate(
            conversationKey: conversationKey,
            initialCapacityTokens: initialCapacityTokens,
            maxLogicalTokens: maxLogicalTokens,
            initialTokens: initialTokens
        )
        return try await allocator.retain(handle)
    }

    private func assertRetainedDiscarded(
        _ retained: PagedKVRetainedSequence,
        allocator: PagedKVBlockAllocator,
        expectedFreeBlockCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await eventually(file: file, line: line) {
            await allocator.freeBlockCount() == expectedFreeBlockCount
        }
        do {
            _ = try await allocator.reattach(retained, conversationKey: retained.conversationKey)
            XCTFail("retained sequence should have been discarded", file: file, line: line)
        } catch PagedKVAllocatorError.unknownHandle {
        } catch {
            XCTFail("unexpected retained sequence error: \(error)", file: file, line: line)
        }
    }

    private func makeRetainedSchedulerFixture(
        cachedTokens: Int,
        promptCount: Int,
        retainedTokenCount: Int? = nil,
        scripts: [String: [Int]] = ["sticky-hit": [777]],
        tokenDeliveryTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> (
        scheduler: ContinuousBatchScheduler,
        backend: ScriptedBackend,
        retained: PagedKVRetainedSequence,
        pagedCache: PagedKVCache,
        allocator: PagedKVBlockAllocator
    ) {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let descriptor = Self.descriptor(blockSizeTokens: 4, maxPhysicalBlocks: 32)
        let retainedTokenCount = retainedTokenCount ?? cachedTokens
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            physicalBlockOrder: [2, 5, 1, 0, 4, 3, 6, 7],
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(
            conversationKey: "conversation-1",
            initialCapacityTokens: max(promptCount, retainedTokenCount),
            maxLogicalTokens: max(promptCount, retainedTokenCount) + 8,
            initialTokens: retainedTokenCount
        )
        let binding = try await allocator.binding(for: handle)
        let keyBytes = Self.fp16Bytes((1...UInt16(retainedTokenCount)).map { $0 })
        let valueBytes = Self.fp16Bytes((1...UInt16(retainedTokenCount)).map { $0 + 100 })
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)
        paged.state = [
            MLXArray(keyBytes, [1, 1, retainedTokenCount, 1], dtype: .float16),
            MLXArray(valueBytes, [1, 1, retainedTokenCount, 1], dtype: .float16),
        ]
        try bridge.record(caches: [paged], binding: binding)
        let retained = try await allocator.retain(handle)
        let backend = ScriptedBackend(
            scripts: scripts,
            terminalCommitBridge: bridge,
            terminalCommitCaches: [paged]
        )
        let scheduler = try await makeScheduler(
            descriptor: descriptor,
            tuple: Self.tuple(),
            maxActiveRows: 1,
            tokenDeliveryTimeoutNanoseconds: tokenDeliveryTimeoutNanoseconds,
            backend: backend,
            allocator: allocator,
            contiguousCacheBridge: bridge
        )
        return (scheduler, backend, retained, paged, allocator)
    }

    private static func fp16Bytes(_ values: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 2)
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}

private final class TestReplayAuthority: ContinuousBatchSchedulerReplayAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: [String: Data] = [:]

    func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim {
        lock.lock()
        defer { lock.unlock() }
        if let existing = fingerprints[key.requestID] {
            return existing == key.fingerprintSHA256 ? .duplicateSameRequest : .duplicateMismatchedRequest
        }
        fingerprints[key.requestID] = key.fingerprintSHA256
        return .claimed
    }

    func release(_ key: ContinuousBatchSchedulerReplayKey) {
        lock.lock()
        defer { lock.unlock() }
        guard fingerprints[key.requestID] == key.fingerprintSHA256 else { return }
        fingerprints.removeValue(forKey: key.requestID)
        releasedIDs.append(key.requestID)
    }

    /// Release log, so a test can distinguish "claim dropped" from "claim
    /// never taken".
    private(set) var releasedIDs: [String] = []

    func released() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return releasedIDs
    }
}

private final class TokenEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ContinuousBatchSchedulerTokenEvent] = []

    func append(_ event: ContinuousBatchSchedulerTokenEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    func events() -> [ContinuousBatchSchedulerTokenEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor SecondDecodeGateBackend: ContinuousBatchSchedulerBackend {
    private let secondDecodeGate: AsyncGate
    private var decodeCalls = 0

    init(secondDecodeGate: AsyncGate) {
        self.secondDecodeGate = secondDecodeGate
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        if decodeCalls == 2 {
            await secondDecodeGate.wait()
        }
        return rows.map {
            .output(ContinuousBatchDecodeOutput(
                requestID: $0.requestID,
                token: decodeCalls == 1 ? 7 : 8
            ))
        }
    }

    func cancelInFlight() async {}
    func decodeCallCount() -> Int { decodeCalls }
}

private actor WindowRecordingBackend: ContinuousBatchSchedulerBackend {
    private let scripts: [String: [Int]]
    private let decodeGate: AsyncGate?
    private var windowLog: [(ids: [String], steps: Int)] = []
    private var decodeCalls = 0

    init(scripts: [String: [Int]], decodeGate: AsyncGate? = nil) {
        self.scripts = scripts
        self.decodeGate = decodeGate
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        return rows.map { row in
            .output(ContinuousBatchDecodeOutput(
                requestID: row.requestID,
                token: Self.nextToken(script: scripts[row.requestID] ?? [], generated: row.generatedTokens.count)
            ))
        }
    }

    func decodeLockstepWindow(
        rows: [ContinuousBatchDecodeInput],
        steps: Int
    ) async throws -> [ContinuousBatchDecodeOutcome] {
        windowLog.append((rows.map(\.requestID), steps))
        if let decodeGate {
            await decodeGate.wait()
        }
        return rows.map { row in
            let script = scripts[row.requestID] ?? []
            let start = row.generatedTokens.count
            let end = min(start + steps, script.count)
            let tokens = start < end ? Array(script[start..<end]) : []
            if tokens.isEmpty {
                return .rowFailure(requestID: row.requestID)
            }
            return .output(ContinuousBatchDecodeOutput(requestID: row.requestID, tokens: tokens))
        }
    }

    func cancelInFlight() async {
        await decodeGate?.open()
    }

    func windowCalls() -> [(ids: [String], steps: Int)] { windowLog }
    func windowCallCount() -> Int { windowLog.count }
    func decodeCallCount() -> Int { decodeCalls }

    private static func nextToken(script: [Int], generated: Int) -> Int {
        script[min(generated, max(0, script.count - 1))]
    }
}

private struct HeadlessRetainedCacheBridge: ContinuousBatchRetainedCacheBridge {
    func reattachPagedKVCache(
        handle: PagedKVBlockTableHandle,
        table: PagedKVBlockTable
    ) throws -> PagedKVPagedCacheHandoff {
        PagedKVPagedCacheHandoff(handle: handle, blockTable: table, caches: [])
    }
}

private actor ScriptedBackend: ContinuousBatchSchedulerBackend {
    private let scripts: [String: [Int]]
    private let prefillGate: AsyncGate?
    private let decodeGate: AsyncGate?
    private let failDecodeCall: Int?
    private let prefillError: (any Error)?
    private let rowFailures: Set<String>
    private let terminalCommitBridge: PagedKVRuntimeContiguousCacheBridge?
    private let terminalCommitCaches: [PagedKVCache]
    /// Per-request hold on the retained-cache install, so a test can park a
    /// request inside admission — out of `waiting`, in `admittingRequests` —
    /// for as long as it needs.
    private let retainedInstallGates: [String: AsyncGate]
    /// Per-request install failure, raised on every attempt for that request.
    private let retainedInstallErrors: [String: any Error]
    /// Acts as a hybrid backend: snapshots and materializes the serial cache.
    private let recurrentCheckpointBackend: Bool
    private var recurrentSnapshotLog: [String: [Int]] = [:]
    private let snapshotGate: AsyncGate?
    private let materializeGate: AsyncGate?
    private var serialMaterializeLog: [String: [Int]] = [:]
    private var retainedInstallAttemptLog: [String: Int] = [:]
    private var prefillRowsLog: [[String]] = []
    private var decodeRowsLog: [[String]] = []
    private var currentTokenLog: [[String: Int]] = []
    private var prefillCommittedLog: [[String: Int]] = []
    private var prefillTargetLog: [[String: Int]] = []
    private var decodeCommittedLog: [[String: Int]] = []
    private var decodeTargetLog: [[String: Int]] = []
    private var blockTableLengthLog: [[String: Int]] = []
    private var samplerSeedLog: [String: [Int]] = [:]
    private var samplerStepLog: [String: [Int]] = [:]
    private var retainedInstallLog: [String: Int] = [:]
    private var terminalCommitLog: [String: Int] = [:]
    private var promptChunks: [[Int]] = []
    private var eventLog: [String] = []
    private var decodeCalls = 0

    init(
        scripts: [String: [Int]],
        prefillGate: AsyncGate? = nil,
        decodeGate: AsyncGate? = nil,
        failDecodeCall: Int? = nil,
        prefillError: (any Error)? = nil,
        rowFailures: Set<String> = [],
        terminalCommitBridge: PagedKVRuntimeContiguousCacheBridge? = nil,
        terminalCommitCaches: [PagedKVCache] = [],
        retainedInstallGates: [String: AsyncGate] = [:],
        retainedInstallErrors: [String: any Error] = [:],
        recurrentCheckpointBackend: Bool = false,
        snapshotGate: AsyncGate? = nil,
        materializeGate: AsyncGate? = nil
    ) {
        self.materializeGate = materializeGate
        self.recurrentCheckpointBackend = recurrentCheckpointBackend
        self.snapshotGate = snapshotGate
        self.scripts = scripts
        self.prefillGate = prefillGate
        self.decodeGate = decodeGate
        self.failDecodeCall = failDecodeCall
        self.prefillError = prefillError
        self.rowFailures = rowFailures
        self.terminalCommitBridge = terminalCommitBridge
        self.terminalCommitCaches = terminalCommitCaches
        self.retainedInstallGates = retainedInstallGates
        self.retainedInstallErrors = retainedInstallErrors
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        prefillRowsLog.append(rows.map(\.requestID))
        prefillCommittedLog.append(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.requestID, $0.committedKVTokenCount)
        }))
        prefillTargetLog.append(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.requestID, $0.targetKVTokenCount)
        }))
        promptChunks.append(contentsOf: rows.map(\.promptTokens))
        eventLog.append(contentsOf: rows.map { "prefill:\($0.requestID):\($0.promptTokens.count)" })
        if let prefillGate {
            await prefillGate.wait()
        }
        if let prefillError {
            throw prefillError
        }
        return rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding
    ) async throws {
        XCTAssertEqual(handoff.handle, binding.handle)
        XCTAssertEqual(handoff.blockTable, binding.currentTable)
        retainedInstallAttemptLog[requestID, default: 0] += 1
        if let gate = retainedInstallGates[requestID] {
            await gate.wait()
        }
        if let error = retainedInstallErrors[requestID] {
            throw error
        }
        retainedInstallLog[requestID] = handoff.logicalTokenCount
    }

    func retainedInstallAttempts() -> [String: Int] {
        retainedInstallAttemptLog
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        eventLog.append(contentsOf: rows.map { "decode:\($0.requestID)" })
        if let decodeGate {
            await decodeGate.wait()
        }
        if failDecodeCall == decodeCalls {
            throw BackendFailure()
        }
        decodeRowsLog.append(rows.map(\.requestID))
        currentTokenLog.append(Dictionary(uniqueKeysWithValues: rows.map { ($0.requestID, $0.currentToken) }))
        decodeCommittedLog.append(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.requestID, $0.committedKVTokenCount)
        }))
        decodeTargetLog.append(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.requestID, $0.targetKVTokenCount)
        }))
        blockTableLengthLog.append(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.requestID, $0.blockTable.logicalTokenCount)
        }))
        for row in rows {
            samplerSeedLog[row.requestID, default: []].append(row.samplerSeed)
            samplerStepLog[row.requestID, default: []].append(row.samplerStep)
        }
        return rows.map { row in
            if rowFailures.contains(row.requestID) {
                return .rowFailure(requestID: row.requestID)
            }
            let script = scripts[row.requestID] ?? []
            let index = min(row.generatedTokens.count, max(0, script.count - 1))
            return .output(ContinuousBatchDecodeOutput(requestID: row.requestID, token: script[index]))
        }
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        terminalCommitLog[input.requestID] = input.targetKVTokenCount
        guard let terminalCommitBridge else { return }
        for (layerIndex, cache) in terminalCommitCaches.enumerated() {
            let tokenCount = input.targetKVTokenCount
            let keyBytes = Self.fp16Bytes((0..<tokenCount).map {
                UInt16(truncatingIfNeeded: $0 + 1 + layerIndex * 1_000)
            })
            let valueBytes = Self.fp16Bytes((0..<tokenCount).map {
                UInt16(truncatingIfNeeded: $0 + 101 + layerIndex * 1_000)
            })
            cache.state = [
                MLXArray(keyBytes, [1, 1, tokenCount, 1], dtype: .float16),
                MLXArray(valueBytes, [1, 1, tokenCount, 1], dtype: .float16),
            ]
        }
        try terminalCommitBridge.record(caches: terminalCommitCaches, binding: input.binding)
    }

    func snapshotRecurrentState(requestID: String, tokenCount: Int) async -> RecurrentStateCheckpoint? {
        guard recurrentCheckpointBackend else { return nil }
        recurrentSnapshotLog[requestID, default: []].append(tokenCount)
        await snapshotGate?.wait()
        eventLog.append("snapshot:\(requestID):\(tokenCount)")
        return RecurrentStateCheckpoint(tokenCount: tokenCount, states: [1: []])
    }

    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache? {
        guard recurrentCheckpointBackend else { return nil }
        serialMaterializeLog[requestID] = [tokenCount, binding.currentTable.logicalTokenCount]
        await materializeGate?.wait()
        return ContinuousBatchSerialConversationCache(
            layers: [KVCacheSimple(), MambaCache()],
            recurrentCheckpoints: recurrentCheckpoints,
            tokenCount: tokenCount
        )
    }

    func cancelInFlight() async {
        await prefillGate?.open()
        await decodeGate?.open()
    }

    func recurrentSnapshots() -> [String: [Int]] { recurrentSnapshotLog }
    func serialMaterializations() -> [String: [Int]] { serialMaterializeLog }
    func prefillCallCount() -> Int { prefillRowsLog.count }
    func decodeCallCount() -> Int { decodeCalls }
    func decodeBatches() -> [[String]] { decodeRowsLog }
    func prefillOrder() -> [[String]] { prefillRowsLog }
    func observedSamplerSeeds() -> [String: [Int]] { samplerSeedLog }
    func observedSamplerSteps() -> [String: [Int]] { samplerStepLog }
    func currentTokensByDecodeBatch() -> [[String: Int]] { currentTokenLog }
    func prefillCommittedCounts() -> [[String: Int]] { prefillCommittedLog }
    func prefillTargetCounts() -> [[String: Int]] { prefillTargetLog }
    func decodeCommittedCounts() -> [[String: Int]] { decodeCommittedLog }
    func decodeTargetCounts() -> [[String: Int]] { decodeTargetLog }
    func blockTableLengthsByDecodeBatch() -> [[String: Int]] { blockTableLengthLog }
    func maxObservedPrefillChunkSize() -> Int? { promptChunks.map(\.count).max() }
    func events() -> [String] { eventLog }
    func retainedInstalls() -> [String: Int] { retainedInstallLog }
    func terminalCommitTargets() -> [String: Int] { terminalCommitLog }

    private static func fp16Bytes(_ values: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 2)
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private struct BackendFailure: Error {}

private actor WedgedCancellationBackend: ContinuousBatchSchedulerBackend {
    private let decodeRelease = AsyncGate()
    private let decodeFinished = AsyncGate()
    private let cancellationAcknowledgement = AsyncGate()
    private var decodeCalls = 0

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        await decodeRelease.wait()
        await decodeFinished.open()
        return rows.map {
            .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: 1))
        }
    }

    func cancelInFlight() async {
        await cancellationAcknowledgement.wait()
        await decodeRelease.open()
        await decodeFinished.wait()
    }

    func acknowledgeCancellation() async {
        await cancellationAcknowledgement.open()
    }

    func decodeCallCount() -> Int { decodeCalls }
}

private actor DecodeLeaseSabotagingBackend: ContinuousBatchSchedulerBackend {
    let allocator: PagedKVBlockAllocator
    let sabotagedRequestID: String
    let firstDecodeGate: AsyncGate?
    private var decodeCalls = 0
    private var decodeRowsLog: [[String]] = []

    init(
        allocator: PagedKVBlockAllocator,
        sabotagedRequestID: String,
        firstDecodeGate: AsyncGate? = nil
    ) {
        self.allocator = allocator
        self.sabotagedRequestID = sabotagedRequestID
        self.firstDecodeGate = firstDecodeGate
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        decodeRowsLog.append(rows.map(\.requestID))
        if decodeCalls == 1 {
            await firstDecodeGate?.wait()
        }
        if rows.count > 1, let row = rows.first(where: { $0.requestID == sabotagedRequestID }) {
            let handle = PagedKVBlockTableHandle(
                id: row.blockTable.handleID,
                conversationKey: "continuous-batching:\(row.requestID)",
                poolEpoch: row.blockTable.poolEpoch
            )
            try await allocator.endDecodeStep(handle)
        }
        return rows.map {
            .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: 1))
        }
    }

    func decodeCallCount() -> Int { decodeCalls }
    func decodeBatches() -> [[String]] { decodeRowsLog }

    func cancelInFlight() async {}
}

private actor PrefillReleaseSabotagingBackend: ContinuousBatchSchedulerBackend {
    let allocator: PagedKVBlockAllocator
    let gate: AsyncGate?
    private var prefillCalls = 0

    init(allocator: PagedKVBlockAllocator, gate: AsyncGate? = nil) {
        self.allocator = allocator
        self.gate = gate
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        prefillCalls += 1
        await gate?.wait()
        for row in rows {
            try await allocator.release(row.binding.handle)
        }
        return rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        []
    }

    func cancelInFlight() async {
        await gate?.open()
    }

    func prefillCallCount() -> Int { prefillCalls }
}

private func eventually(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition was not met before timeout", file: file, line: line)
}

private final class DeliveredTokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var tokens: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var isEmpty: Bool { tokens.isEmpty }
}
