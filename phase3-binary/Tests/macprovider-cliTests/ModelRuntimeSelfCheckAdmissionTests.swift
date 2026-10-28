import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// Exercises the production self-check wrapper with the runtime's actual serial
/// gate and scheduler. The injected backend uses no model or GPU resources.
final class ModelRuntimeSelfCheckAdmissionTests: XCTestCase {
    func testSerialBuyerWaitsForThreeRowSelfCheckDespiteOneServedSlot() async throws {
        let backend = SelfCheckRetirementBackend()
        let runtime = makeRuntime(backend: backend)
        let applied = await runtime.applyServedSlots(1)
        XCTAssertTrue(applied)
        let gate = await runtime.serialInferenceGate
        let buyerState = SelfCheckBuyerState()
        let probe = Task {
            try await runtime.runContinuousBatchingSelfCheckBatch(
                prompts: [[11], [12], [13]], maxOutputTokens: 2,
                idPrefix: "exclusive-success", cohort: true)
        }
        defer { Task { await backend.allowCompletionAndAcknowledgeCancellation() } }
        try await eventually { await backend.decodeRowCount == 3 }
        let buyer = Task {
            try await gate.withPermit {
                await buyerState.enter(nativeRows: await backend.residentRowCount)
            }
        }
        try await eventually { await gate.queuedWaiterCount() == 1 }
        let enteredWhileCohortActive = await buyerState.entered
        XCTAssertFalse(enteredWhileCohortActive)
        let activeNativeRows = await backend.residentRowCount
        XCTAssertEqual(activeNativeRows, 3)
        await backend.allowCompletionAndAcknowledgeCancellation()
        let result = try await probe.value
        try await buyer.value
        XCTAssertEqual(result.outputs.count, 3)
        XCTAssertEqual(result.outputs, [[1, 1], [1, 1], [1, 1]])
        let nativeRowsAtBuyerEntry = await buyerState.nativeRowsAtEntry
        XCTAssertEqual(nativeRowsAtBuyerEntry, 0, "serial admission follows actual probe retirement")
        let servedSlots = await gate.currentLimit()
        XCTAssertEqual(servedSlots, 1, "three probe rows do not require three buyer permits")
    }

    func testCanceledSelfCheckKeepsSerialBuyerBlockedUntilNativeCancellationAcknowledged() async throws {
        let backend = SelfCheckRetirementBackend()
        let runtime = makeRuntime(backend: backend)
        _ = await runtime.applyServedSlots(1)
        let gate = await runtime.serialInferenceGate
        let buyerState = SelfCheckBuyerState()
        let probeState = SelfCheckProbeState()
        let probe = Task {
            do {
                let result = try await runtime.runContinuousBatchingSelfCheckBatch(
                    prompts: [[21], [22], [23]], maxOutputTokens: 2,
                    idPrefix: "exclusive-cancel", cohort: true)
                await probeState.markReturned()
                return result
            } catch {
                await probeState.markReturned()
                throw error
            }
        }
        defer { Task { await backend.allowCompletionAndAcknowledgeCancellation() } }
        try await eventually { await backend.decodeRowCount == 3 }
        let buyer = Task {
            try await gate.withPermit {
                await buyerState.enter(nativeRows: await backend.residentRowCount)
            }
        }
        try await eventually { await gate.queuedWaiterCount() == 1 }
        probe.cancel()
        // submit cancellation can complete before this backend acknowledges
        // retirement; the wrapper must await its shielded cleanup barrier.
        try await eventually { await backend.cancellationRequested }
        let beforeAcknowledgment = await buyerState.entered
        let probeReturnedBeforeAcknowledgment = await probeState.returned
        let unretiredRows = await backend.residentRowCount
        XCTAssertFalse(beforeAcknowledgment)
        XCTAssertFalse(probeReturnedBeforeAcknowledgment)
        XCTAssertEqual(unretiredRows, 3)
        await backend.allowCompletionAndAcknowledgeCancellation()
        do {
            _ = try await probe.value
            XCTFail("canceled self-check must not return qualification evidence")
        } catch is CancellationError {
            // Expected; exclusivity survives the cancellation until retirement.
        }
        try await buyer.value
        let nativeRowsAtBuyerEntry = await buyerState.nativeRowsAtEntry
        XCTAssertEqual(nativeRowsAtBuyerEntry, 0)
        // Cleanup leaves ordinary admission usable rather than draining it.
        try await gate.withPermit { }
    }

    func testSelfCheckRejectsRowsAboveRuntimeBudgetBeforeNativePreparation() async throws {
        let backend = SelfCheckRetirementBackend()
        let runtime = makeRuntime(backend: backend)
        do {
            _ = try await runtime.runContinuousBatchingSelfCheckBatch(
                prompts: [[1], [2], [3], [4]], maxOutputTokens: 2,
                idPrefix: "exclusive-overflow", cohort: true)
            XCTFail("four rows exceed the runtime's three-row envelope")
        } catch ContinuousBatchSchedulerError.requestFailed(let reason) {
            XCTAssertEqual(reason, "self_check_row_cap_exceeded")
        }
        let prepared = await backend.prefillRowCount
        XCTAssertEqual(prepared, 0, "overflow must be rejected before preparing native rows")
        let gate = await runtime.serialInferenceGate
        try await gate.withPermit { }
    }

    func testSerialAndDivergenceEntriesQueueExclusivelyBeforeModelAccess() async throws {
        let runtime = makeRuntime(backend: SelfCheckRetirementBackend())
        _ = await runtime.applyServedSlots(3)
        let gate = await runtime.serialInferenceGate
        let buyerEntered = SelfCheckAdmissionLatch()
        let releaseBuyer = SelfCheckAdmissionLatch()
        defer { Task { await releaseBuyer.open() } }
        let buyer = Task {
            try await gate.withPermit {
                await buyerEntered.open()
                await releaseBuyer.wait()
            }
        }
        await buyerEntered.wait()
        // This fixture has no container: reaching model access before exclusive
        // admission would return immediately instead of joining the gate queue.
        let serial = Task { try await runtime.continuousBatchingSelfCheckSerialTPS(prompts: [[1]], maxTokens: 2) }
        try await eventually { await gate.queuedWaiterCount() == 1 }
        let divergence = Task {
            try await runtime.continuousBatchingSelfCheckDivergence(
                prompt: [1], sharedPrefix: [], aloneToken: 1, batchedToken: 2, otherRowsAloneTokens: [])
        }
        try await eventually { await gate.queuedWaiterCount() == 2 }
        serial.cancel()
        divergence.cancel()
        do { _ = try await serial.value; XCTFail("queued serial probe must cancel before model access") }
        catch is CancellationError {}
        do { _ = try await divergence.value; XCTFail("queued divergence probe must cancel before model access") }
        catch is CancellationError {}
        let queued = await gate.queuedWaiterCount()
        XCTAssertEqual(queued, 0)
        await releaseBuyer.open()
        try await buyer.value
    }

    func testCanceledSerialProbeAdmissionBlocksBuyerPathsUntilNativeBodyRetires() async throws {
        let runtime = makeRuntime(backend: SelfCheckRetirementBackend())
        _ = await runtime.applyServedSlots(3)
        let gate = await runtime.serialInferenceGate
        let nativeEntered = SelfCheckAdmissionLatch()
        let releaseNative = SelfCheckAdmissionLatch()
        let cancellationObserved = SelfCheckAdmissionLatch()
        let probeState = SelfCheckProbeState()
        defer { Task { await releaseNative.open() } }
        let probe = Task {
            do {
                try await runtime.withExclusiveContinuousBatchingSelfCheck { _ in
                    await nativeEntered.open()
                    // Like the blocking executor's continuation, this native
                    // body acknowledges cancellation before it actually retires.
                    await withTaskCancellationHandler {
                        await releaseNative.wait()
                    } onCancel: {
                        Task { await cancellationObserved.open() }
                    }
                }
                await probeState.markReturned()
            } catch {
                await probeState.markReturned()
                throw error
            }
        }
        await nativeEntered.wait()
        let serialBuyer = SelfCheckBuyerState()
        let batchBuyer = SelfCheckBuyerState()
        // Serial and attached-CB buyers both acquire this same shared gate.
        let serial = Task { try await gate.withPermit { await serialBuyer.enter(nativeRows: 0) } }
        try await eventually { await gate.queuedWaiterCount() == 1 }
        let batch = Task { try await gate.withPermit { await batchBuyer.enter(nativeRows: 0) } }
        try await eventually { await gate.queuedWaiterCount() == 2 }
        let nextProbeEntered = SelfCheckProbeState()
        let nextProbe = Task {
            try await runtime.withExclusiveContinuousBatchingSelfCheck { _ in
                await nextProbeEntered.markReturned()
            }
        }
        try await eventually { await gate.queuedWaiterCount() == 3 }
        probe.cancel()
        await cancellationObserved.wait()
        let serialStarted = await serialBuyer.entered
        let batchStarted = await batchBuyer.entered
        let nextProbeStarted = await nextProbeEntered.returned
        let returnedBeforeRetirement = await probeState.returned
        XCTAssertFalse(serialStarted)
        XCTAssertFalse(batchStarted)
        XCTAssertFalse(nextProbeStarted)
        XCTAssertFalse(returnedBeforeRetirement)
        await releaseNative.open()
        do { try await probe.value; XCTFail("canceled native probe must not publish evidence") }
        catch is CancellationError {}
        try await serial.value
        try await batch.value
        try await nextProbe.value
        try await gate.withPermit { }
    }

    func testQueuedSelfCheckRejectsChangedModelGenerationBeforeNativeBody() async throws {
        let runtime = makeRuntime(backend: SelfCheckRetirementBackend(), warmSwapEnabled: true)
        let gate = await runtime.serialInferenceGate
        let buyerEntered = SelfCheckAdmissionLatch()
        let releaseBuyer = SelfCheckAdmissionLatch()
        let nativeEntered = SelfCheckProbeState()
        defer { Task { await releaseBuyer.open() } }
        let buyer = Task {
            try await gate.withPermit {
                await buyerEntered.open()
                await releaseBuyer.wait()
            }
        }
        await buyerEntered.wait()
        let probe = Task {
            try await runtime.withExclusiveContinuousBatchingSelfCheck { _ in
                await nativeEntered.markReturned()
            }
        }
        try await eventually { await gate.queuedWaiterCount() == 1 }
        // The existing test loader changes the actual self-check generation;
        // no new production test hook or fabricated generation is involved.
        let swap = try await runtime.beginSwap(targetModelID: "mlx-community/Qwen-Replacement")
        try await swap.value
        let swapped = await runtime.currentSnapshot()
        XCTAssertEqual(swapped.state, .ready)
        XCTAssertEqual(swapped.modelID, "mlx-community/Qwen-Replacement")
        await releaseBuyer.open()
        try await buyer.value
        do { try await probe.value; XCTFail("old-generation probe must reject before native preparation") }
        catch is CancellationError {}
        let prepared = await nativeEntered.returned
        XCTAssertFalse(prepared)
        try await runtime.withExclusiveContinuousBatchingSelfCheck { _ in }
    }

    private func makeRuntime(backend: SelfCheckRetirementBackend, warmSwapEnabled: Bool = false) -> ModelRuntime {
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID, modelSHA256: modelSHA,
            tokenizerSHA256: nil, chatTemplateSHA256: nil,
            modelFamily: "qwen", hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32, maxPhysicalBlocks: 64,
            maxResidentTokens: 2048, parityLabel: "sdpa-parity-v1")
        let identity = PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass, metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier, parityLabel: proof.parityLabel,
            moeDispatchProven: false, poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement)
        return ModelRuntime(
            modelID: modelID, modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 3, continuousBatchingMode: .on,
            continuousBatchingDurableReplayAuthorityAvailable: true,
            warmSwapEnabled: warmSwapEnabled,
            pagedKVObservedRuntimeIdentity: identity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            continuousBatchingBackend: backend,
            loader: { _ in throw SelfCheckAdmissionTestError.unexpectedLoad },
            testLoader: warmSwapEnabled ? { target in (target, modelSHA) } : nil)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("self-check admission condition not met")
        throw SelfCheckAdmissionTestError.timedOut
    }
}

private enum SelfCheckAdmissionTestError: Error { case unexpectedLoad, timedOut }

private actor SelfCheckBuyerState {
    private(set) var entered = false
    private(set) var nativeRowsAtEntry: Int?
    func enter(nativeRows: Int) {
        nativeRowsAtEntry = nativeRows
        entered = true
    }
}

private actor SelfCheckProbeState {
    private(set) var returned = false
    func markReturned() { returned = true }
}

private actor SelfCheckRetirementBackend: ContinuousBatchSchedulerBackend {
    private let decodeRelease = SelfCheckAdmissionLatch()
    private let decodeFinished = SelfCheckAdmissionLatch()
    private let cancellationAcknowledgment = SelfCheckAdmissionLatch()
    private var residentIDs = Set<String>()
    private(set) var decodeRowCount = 0
    private(set) var prefillRowCount = 0
    private(set) var cancellationRequested = false
    var residentRowCount: Int { residentIDs.count }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        prefillRowCount += rows.count
        residentIDs.formUnion(rows.map(\.requestID))
        return rows.map {
            ContinuousBatchPrefillOutput(requestID: $0.requestID, sampledToken: $0.sampleFirstToken ? 1 : nil)
        }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeRowCount = rows.count
        await decodeRelease.wait()
        residentIDs.subtract(rows.map(\.requestID))
        await decodeFinished.open()
        return rows.map { .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: 1)) }
    }

    func cancelInFlight() async {
        cancellationRequested = true
        await cancellationAcknowledgment.wait()
        await decodeRelease.open()
        await decodeFinished.wait()
    }

    func allowCompletionAndAcknowledgeCancellation() async {
        await cancellationAcknowledgment.open()
        await decodeRelease.open()
    }
}

private actor SelfCheckAdmissionLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
