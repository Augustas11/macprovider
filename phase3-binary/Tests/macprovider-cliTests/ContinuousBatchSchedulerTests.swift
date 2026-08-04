import Foundation
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

    func testHeadUpdateStickyCacheRequestNeverEntersBatch() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        do {
            _ = try await scheduler.submit(.init(
                id: "sticky",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 1,
                cachedPromptTokens: 1
            ))
            XCTFail("expected the deferred contiguous-cache bridge gate")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge")
        }

        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        let metrics = await scheduler.metrics()
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertEqual(decodeCalls, 0)
        XCTAssertTrue(metrics.diagnostics.contains(.stickyCacheUnsupported))
    }

    func testConversationKeyNeverEntersBatchBeforePagedKVCacheBridge() async throws {
        let backend = ScriptedBackend(scripts: [:])
        let scheduler = try await makeScheduler(maxActiveRows: 2, backend: backend)

        do {
            _ = try await scheduler.submit(.init(
                id: "keyed",
                conversationKey: "conversation-1",
                promptTokens: [1],
                maxOutputTokens: 1
            ))
            XCTFail("expected the deferred keyed-cache bridge gate")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge")
        }

        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(prefillCalls, 0)
        XCTAssertEqual(decodeCalls, 0)
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
        } catch ContinuousBatchSchedulerError.backpressure {
            // Scheduler state completed at the hard deadline, but the actual
            // live task remains counted until the cancellation-insensitive sink exits.
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
        XCTAssertEqual(duplicateResult.errorCode, "continuous_batching_stream_backpressure")
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
        } catch ContinuousBatchSchedulerError.backpressure {
            // Only this waiter/request fails; the scheduler actor never awaits
            // the consumer callback.
        }
        try await eventually { await scheduler.metrics().slotsFree == 1 }
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 16)
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
        backend: ScriptedBackend
    ) async throws -> ContinuousBatchScheduler {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let config = ContinuousBatchSchedulerConfiguration(
            descriptor: descriptor,
            tuple: tuple,
            moePromotionEvidenceAvailable: moePromotionEvidenceAvailable,
            maxActiveRows: maxActiveRows,
            queueLimit: queueLimit,
            decodeHeadroomTokens: decodeHeadroomTokens,
            maxPrefillRowsPerIteration: 1,
            maxPromptChunkTokens: maxPromptChunkTokens,
            snapshot: ContinuousBatchSchedulerSnapshot(
                modelID: Self.modelID,
                modelSHA256: Self.modelSHA,
                weightsGeneration: 3
            )
        )
        return ContinuousBatchScheduler(
            configuration: config,
            allocator: allocator,
            backend: backend,
            replayAuthority: TestReplayAuthority()
        )
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

private actor ScriptedBackend: ContinuousBatchSchedulerBackend {
    private let scripts: [String: [Int]]
    private let prefillGate: AsyncGate?
    private let decodeGate: AsyncGate?
    private let failDecodeCall: Int?
    private let rowFailures: Set<String>
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
    private var promptChunks: [[Int]] = []
    private var eventLog: [String] = []
    private var decodeCalls = 0

    init(
        scripts: [String: [Int]],
        prefillGate: AsyncGate? = nil,
        decodeGate: AsyncGate? = nil,
        failDecodeCall: Int? = nil,
        rowFailures: Set<String> = []
    ) {
        self.scripts = scripts
        self.prefillGate = prefillGate
        self.decodeGate = decodeGate
        self.failDecodeCall = failDecodeCall
        self.rowFailures = rowFailures
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
        return rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
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

    func cancelInFlight() async {
        await prefillGate?.open()
        await decodeGate?.open()
    }

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
