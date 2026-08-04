import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelRuntimeSwapTests: XCTestCase {
    func testRuntimeNeverInfersCanonicalAlgorithmFromHashPresence() async {
        let hash = String(repeating: "a", count: 64)
        let legacy = makeRuntime(modelID: "model-a", modelHash: hash, warmSwapEnabled: false)
        let canonical = makeRuntime(
            modelID: "model-a",
            modelHash: hash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            warmSwapEnabled: false
        )

        let legacySnapshot = await legacy.currentSnapshot()
        let canonicalSnapshot = await canonical.currentSnapshot()
        XCTAssertNil(legacySnapshot.modelHashAlgorithm)
        XCTAssertEqual(canonicalSnapshot.modelHashAlgorithm, ModelArtifactIdentity.snapshotManifestV1)
    }

    func testDisabledModeRejectsSwap() async throws {
        let runtime = try await ModelRuntime(modelID: nil, warmSwapEnabled: false)

        do {
            _ = try await runtime.beginSwap(targetModelID: "new-model")
            XCTFail("Expected warm-swap disabled error")
        } catch let error as WarmSwapDisabledError {
            XCTAssertEqual(error.description, "warm swap is not enabled (start serve with --enable-warm-swap)")
        }
    }

    func testEnabledModeAcceptsSwap() async throws {
        let runtime = makeRuntime(modelID: nil, warmSwapEnabled: true) { target in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (target, "new-hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "new-model")
        XCTAssertEqual(snapshot.modelHash, "new-hash")
    }

    func testProviderStatusIdentityFollowsSuccessfulWarmSwap() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value

        let runtimeSnapshot = await runtime.currentSnapshot()
        let statusSnapshot = await providerStatus.snapshot()
        XCTAssertEqual(runtimeSnapshot.modelID, "new-model")
        XCTAssertEqual(statusSnapshot.modelID, "new-model")
        XCTAssertEqual(statusSnapshot.modelHash, "new-hash")
        XCTAssertFalse(statusSnapshot.specDecodeEnabled)
        XCTAssertEqual(statusSnapshot.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(statusSnapshot.specDecodeAcceptedTokensSinceLast, 0)
    }

    func testProviderStatusBecomesLoadedAfterSuccessfulWarmSwapFromIdle() async throws {
        let providerStatus = ProviderStatus(
            modelID: nil,
            modelLoaded: false,
            capacity: ProviderCapacity(maxContextOverride: 1024, maxConcurrencyOverride: 1)
        )
        let runtime = makeRuntime(modelID: nil, warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value

        let statusSnapshot = await providerStatus.snapshot()
        XCTAssertEqual(statusSnapshot.status, .ready)
        XCTAssertEqual(statusSnapshot.modelID, "new-model")
        XCTAssertTrue(statusSnapshot.modelLoaded)
    }

    func testInFlightInferenceUsesOldSnapshot() async throws {
        let probe = InFlightProbe()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true, loader: { target in
            (target, "new-hash")
        }, completion: { snapshot, _ in
            await probe.markStarted(modelID: snapshot.modelID)
            while await !probe.canFinish {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        })
        await runtime.setProviderStatus(providerStatus)

        let request = try makeRequest(model: "old-model")
        let completionTask = Task {
            try await runtime.complete(request)
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }

        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        await probe.allowFinish()
        try await swapTask.value
        let postSwap = await runtime.currentSnapshot()
        let completion = try await completionTask.value
        let startedModelID = await probe.startedModelID

        XCTAssertEqual(startedModelID, "old-model")
        XCTAssertEqual(postSwap.modelID, "new-model")
        XCTAssertEqual(completion.content, "old-model")
    }

    func testInFlightInferenceUsesOldSnapshotAndDraftPair() async throws {
        let probe = InFlightProbe()
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            draftModelID: "old-draft",
            warmSwapEnabled: true,
            loader: { target in
                try await Task.sleep(nanoseconds: 50_000_000)
                return (target, "new-hash")
            },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID, draftModelID: snapshot.draftModelID)
                while await !probe.canFinish {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return CompletionResult(content: "\(snapshot.modelID ?? "<nil>"):\(snapshot.draftModelID ?? "<nil>")", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )

        let request = try makeRequest(model: "old-model")
        let completionTask = Task {
            try await runtime.complete(request)
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }
        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        try await swapTask.value
        let postSwap = await runtime.currentSnapshot()
        await probe.allowFinish()
        let completion = try await completionTask.value
        let startedModelID = await probe.startedModelID
        let startedDraftModelID = await probe.startedDraftModelID

        XCTAssertEqual(startedModelID, "old-model")
        XCTAssertEqual(startedDraftModelID, "old-draft")
        XCTAssertEqual(postSwap.modelID, "new-model")
        XCTAssertEqual(postSwap.draftModelID, "old-draft")
        XCTAssertEqual(postSwap.draftTargetModelID, "new-model")
        XCTAssertEqual(completion.content, "old-model:old-draft")
    }

    func testLoadFailureRollsBack() async throws {
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            throw TestError.loadFailed
        }
        var signals = await runtime.swapSignals().makeAsyncIterator()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let snapshot = await runtime.currentSnapshot()
        let signal = await signals.next()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "old-model")
        XCTAssertEqual(snapshot.modelHash, "old-hash")
        guard case let .failed(reason) = signal?.outcome else {
            XCTFail("Expected failed signal")
            return
        }
        XCTAssertTrue(reason.contains("loadFailed"))
    }

    func testNoStarveSnapshotRespondsDuringLoad() async throws {
        let runtime = makeRuntime(modelID: "old-model", warmSwapEnabled: true) { target in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (target, "new-hash")
        }

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        for _ in 0 ..< 20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await runtime.currentSnapshot()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertLessThan(elapsed, 10_000_000)
        }
        try await task.value
    }

    func testServingDecodeRunsThroughBlockingInferenceExecutor() throws {
        let source = try String(contentsOfFile: "Sources/macprovider-cli/ModelRuntime.swift", encoding: .utf8)
        let pattern = #"let result: BlockingGenerateResult = try await blockingInferenceExecutor\.run \{ inferenceCancellation in\s+BlockingGenerateResult\(generate\(input: iteratorInput, context: generationContext, iterator: iterator\)"#
        let matches = try NSRegularExpression(pattern: pattern).numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )

        XCTAssertGreaterThanOrEqual(matches, 2, "non-streaming and streaming serving decode must not block Swift cooperative tasks")
        XCTAssertFalse(source.contains("let result: GenerateResult = generate(input: iteratorInput"))
        XCTAssertTrue(source.contains("return try await blockingInferenceExecutor.run { inferenceCancellation in\n                    let draftCache = draftContext.model.newCache(parameters: parameters)"))
        XCTAssertTrue(source.contains("SpeculativeTokenIterator("), "speculative decode must use the blocking iterator route")
        XCTAssertFalse(source.contains("let stream = try generate(\n                    input: input,\n                    cache: cache"))
        XCTAssertFalse(source.contains("generateTokens("), "raw speculative startup/canary generation must not use AsyncStream token generation")
        XCTAssertTrue(source.contains("Thread.detachNewThread"), "blocking inference executor must use dedicated OS threads")
        XCTAssertTrue(source.contains("inferenceCancellation.isCancelled"), "blocking inference callbacks must observe task cancellation")
    }

    func testGenerationConfigStopStringFilterMatchesStreamingHoldback() {
        var filter = GenerationConfigStopStringFilter(stopStrings: ["STOP"])

        let first = filter.process("hello ST")
        XCTAssertEqual(first.text, "hello ")
        XCTAssertFalse(first.stopped)

        let second = filter.process("OP hidden")
        XCTAssertNil(second.text)
        XCTAssertTrue(second.stopped)
        XCTAssertNil(filter.finish())
    }

    func testGenerationConfigStopStringFilterUsesEarliestStop() {
        var filter = GenerationConfigStopStringFilter(stopStrings: ["STOP", "HALT"])

        let result = filter.process("abcHALTdefSTOP")

        XCTAssertEqual(result.text, "abc")
        XCTAssertTrue(result.stopped)
    }

    func testBlockingInferenceExecutorDoesNotStarveRuntimeActor() async throws {
        let runtime = makeRuntime(modelID: "model-a", warmSwapEnabled: false)
        let task = Task {
            try await runtime.runBlockingInferenceProbeForTest(milliseconds: 250)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        for _ in 0 ..< 10 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await runtime.currentSnapshot()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertLessThan(elapsed, 50_000_000)
        }
        try await task.value
    }

    func testBlockingInferenceExecutorObservesTaskCancellation() async throws {
        let runtime = makeRuntime(modelID: "model-a", warmSwapEnabled: false)
        let task = Task {
            try await runtime.runBlockingInferenceProbeForTest(milliseconds: 5_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected blocking inference probe to observe cancellation")
        } catch is CancellationError {
        }
    }

    func testBootPathDoesNotPassThroughLoading() async throws {
        let runtime = try await ModelRuntime(modelID: nil)

        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertNil(snapshot.container)
        XCTAssertNil(snapshot.modelID)
    }

    func testSwapDrainTimeoutSurvivesPlumbing() {
        let runtime = makeRuntime(modelID: nil, warmSwapEnabled: true, swapDrainTimeoutSeconds: 42)

        XCTAssertEqual(runtime.swapDrainTimeoutForTest(), 42)
    }

    func testDrainWaitsForRequestsInFlightBeforeAtomicSwap() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)
        var signals = await runtime.swapSignals().makeAsyncIterator()
        let requestStartedAt = await providerStatus.beginRequest()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        let loadSignal = await signals.next()
        try await Task.sleep(nanoseconds: 120_000_000)
        let drainingSnapshot = await runtime.currentSnapshot()

        guard case .loadFinished = loadSignal?.outcome else {
            XCTFail("Expected loadFinished signal")
            return
        }
        XCTAssertEqual(drainingSnapshot.state, .draining)
        XCTAssertEqual(drainingSnapshot.modelID, "old-model")
        XCTAssertEqual(drainingSnapshot.modelHash, "old-hash")

        await providerStatus.finishRequest(startedAt: requestStartedAt, completion: nil, failed: false)
        try await task.value
        let completedSignal = await signals.next()
        let finalSnapshot = await runtime.currentSnapshot()

        guard case let .completed(newModelID, newModelHash) = completedSignal?.outcome else {
            XCTFail("Expected completed signal")
            return
        }
        XCTAssertEqual(newModelID, "new-model")
        XCTAssertEqual(newModelHash, "new-hash")
        XCTAssertEqual(finalSnapshot.state, .ready)
        XCTAssertEqual(finalSnapshot.modelID, "new-model")
        XCTAssertEqual(finalSnapshot.modelHash, "new-hash")
    }

    func testDrainWithNoRequestsInFlightCompletesImmediately() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { target in
            (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)
        var signals = await runtime.swapSignals().makeAsyncIterator()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let loadSignal = await signals.next()
        let completedSignal = await signals.next()
        let finalSnapshot = await runtime.currentSnapshot()

        guard case .loadFinished = loadSignal?.outcome else {
            XCTFail("Expected loadFinished signal")
            return
        }
        guard case .completed = completedSignal?.outcome else {
            XCTFail("Expected completed signal")
            return
        }
        XCTAssertEqual(finalSnapshot.state, .ready)
        XCTAssertEqual(finalSnapshot.modelID, "new-model")
    }

    func testDrainTimeoutFailsSwapAndKeepsOldGeneration() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            swapDrainTimeoutSeconds: 0
        ) { target in
            (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)
        _ = await providerStatus.beginRequest()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "old-model")
        XCTAssertEqual(snapshot.modelHash, "old-hash")
    }

    func testDrainTimeoutCancelsInFlightRequests() async throws {
        let probe = InFlightProbe()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            swapDrainTimeoutSeconds: 5,
            loader: { target in (target, "new-hash") },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID)
                try await Task.sleep(nanoseconds: 15_000_000_000)
                return CompletionResult(content: "too-late", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        await runtime.setProviderStatus(providerStatus)
        let startedAt = await providerStatus.beginRequest()
        let request = try makeRequest(model: "old-model")
        let completionTask = Task {
            do {
                let completion = try await runtime.complete(request)
                await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                return completion
            } catch {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                throw error
            }
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }

        let began = Date()
        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        try await swapTask.value

        do {
            _ = try await completionTask.value
            XCTFail("Expected drain-timeout cancellation")
        } catch is DrainCancelledError {
            XCTAssertLessThan(Date().timeIntervalSince(began), 5.4)
        }
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "old-model")
        XCTAssertEqual(snapshot.modelHash, "old-hash")
    }

    func testInFlightCompletesIfWithinDrainWindow() async throws {
        let probe = InFlightProbe()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            swapDrainTimeoutSeconds: 5,
            loader: { target in (target, "new-hash") },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        await runtime.setProviderStatus(providerStatus)
        let startedAt = await providerStatus.beginRequest()
        let request = try makeRequest(model: "old-model")
        let completionTask = Task {
            do {
                let completion = try await runtime.complete(request)
                await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                return completion
            } catch {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                throw error
            }
        }
        try await waitUntil {
            await probe.startedModelID != nil
        }

        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        let completion = try await completionTask.value
        try await swapTask.value
        let snapshot = await runtime.currentSnapshot()

        XCTAssertEqual(completion.content, "old-model")
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.modelID, "new-model")
        XCTAssertEqual(snapshot.modelHash, "new-hash")
    }

    func testHandleAcquiredInReadyStateSurvivesSwapToLoading() async throws {
        let probe = InFlightProbe()
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            loader: { target in
                try await Task.sleep(nanoseconds: 150_000_000)
                return (target, "new-hash")
            },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID)
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let request = try makeRequest(model: "old-model")
        let handle = try await runtime.acquireRequestHandle(request)

        do {
            let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
            let loadingSnapshot = await runtime.currentSnapshot()
            XCTAssertEqual(loadingSnapshot.state, .loading)

            try await runtime.preflight(request, with: handle)
            let completion = try await runtime.stream(request, with: handle) { _ in }
            let startedModelID = await probe.startedModelID

            await runtime.unregisterInFlight(handle.registrationID)
            try await swapTask.value
            XCTAssertEqual(startedModelID, "old-model")
            XCTAssertEqual(completion.content, "old-model")
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
    }

    func testHandleAcquiredInLoadingStateUsesOldTargetWithoutDraft() async throws {
        let speculativeCalls = LockedCounter()
        let fallbackCalls = LockedCounter()
        let runtime = ModelRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            draftModelID: "old-draft",
            warmSwapEnabled: true,
            loader: { _ in throw TestError.unexpectedContainerLoader },
            testLoader: { target in
                try await Task.sleep(nanoseconds: target == "new-model" ? 100_000_000 : 0)
                return (target, "new-hash")
            },
            testCompletion: { snapshot, _ in
                fallbackCalls.increment()
                return CompletionResult(content: "\(snapshot.modelID ?? "<nil>"):\(snapshot.draftModelID ?? "<nil>")", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            },
            testSpeculativeCompletion: { _, _ in
                speculativeCalls.increment()
                return CompletionResult(content: "speculative", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
        let loadingSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(loadingSnapshot.state, .loading)

        let request = try makeRequest(model: "old-model")
        let handle = try await runtime.acquireRequestHandle(request)
        do {
            let completion = try await runtime.stream(request, with: handle) { _ in }
            await runtime.unregisterInFlight(handle.registrationID)
            XCTAssertEqual(completion.content, "old-model:<nil>")
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        XCTAssertEqual(fallbackCalls.value, 1)
        XCTAssertEqual(speculativeCalls.value, 0)

        try await swapTask.value
    }

    func testDraftLoadFailureDuringTargetSwapDoesNotRollBackTarget() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            draftModelID: "failing-draft",
            warmSwapEnabled: true,
            loader: { target in
                if target == "failing-draft" {
                    throw TestError.loadFailed
                }
                return (target, "new-hash")
            }
        )
        await runtime.setProviderStatus(providerStatus)

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let runtimeSnapshot = await runtime.currentSnapshot()
        let statusSnapshot = await providerStatus.snapshot()

        XCTAssertEqual(runtimeSnapshot.state, .ready)
        XCTAssertEqual(runtimeSnapshot.modelID, "new-model")
        XCTAssertEqual(runtimeSnapshot.modelHash, "new-hash")
        XCTAssertNil(runtimeSnapshot.draftModelID)
        XCTAssertNil(runtimeSnapshot.draftTargetModelID)
        XCTAssertFalse(statusSnapshot.specDecodeEnabled)
        XCTAssertNil(statusSnapshot.specDecodeDraftModelID)
        XCTAssertNil(statusSnapshot.specDecodeNumDraftTokens)
    }

    func testSuccessfulTargetSwapEnablesVerifiedDraftForNewTarget() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            draftModelID: "mlx-community/configured-draft",
            warmSwapEnabled: true,
            loader: { target in (target, target == "mlx-community/configured-draft" ? "draft-hash" : "new-hash") }
        )
        await runtime.setProviderStatus(providerStatus)

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        try await task.value
        let runtimeSnapshot = await runtime.currentSnapshot()
        let statusSnapshot = await providerStatus.snapshot()

        XCTAssertEqual(runtimeSnapshot.modelID, "new-model")
        XCTAssertEqual(runtimeSnapshot.draftModelID, "mlx-community/configured-draft")
        XCTAssertEqual(runtimeSnapshot.draftTargetModelID, "new-model")
        XCTAssertTrue(statusSnapshot.specDecodeEnabled)
        XCTAssertEqual(statusSnapshot.specDecodeDraftModelID, "mlx-community/configured-draft")
        XCTAssertEqual(statusSnapshot.specDecodeNumDraftTokens, 3)
    }

    func testHandleDrainCancellationStillFiresEvenIfStateAlreadyChanged() async throws {
        let probe = InFlightProbe()
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(
            modelID: "old-model",
            modelHash: "old-hash",
            warmSwapEnabled: true,
            swapDrainTimeoutSeconds: 0,
            loader: { target in (target, "new-hash") },
            completion: { snapshot, _ in
                await probe.markStarted(modelID: snapshot.modelID)
                try await Task.sleep(nanoseconds: 15_000_000_000)
                return CompletionResult(content: "too-late", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        await runtime.setProviderStatus(providerStatus)
        let startedAt = await providerStatus.beginRequest()
        let request = try makeRequest(model: "old-model")
        let handle = try await runtime.acquireRequestHandle(request)
        let streamTask = Task {
            try await runtime.stream(request, with: handle) { _ in }
        }

        do {
            try await waitUntil {
                await probe.startedModelID != nil
            }
            let swapTask = try await runtime.beginSwap(targetModelID: "new-model")
            try await swapTask.value

            do {
                _ = try await streamTask.value
                XCTFail("Expected drain-timeout cancellation")
            } catch is DrainCancelledError {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
            }

            await runtime.unregisterInFlight(handle.registrationID)
            let snapshot = await runtime.currentSnapshot()
            XCTAssertEqual(snapshot.state, .ready)
            XCTAssertEqual(snapshot.modelID, "old-model")
            XCTAssertEqual(snapshot.modelHash, "old-hash")
        } catch {
            await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
            await runtime.unregisterInFlight(handle.registrationID)
            streamTask.cancel()
            throw error
        }
    }

    func testConcurrentSnapshotsDoNotObserveMixedSwapState() async throws {
        let providerStatus = makeProviderStatus(modelID: "old-model", modelHash: "old-hash")
        let runtime = makeRuntime(modelID: "old-model", modelHash: "old-hash", warmSwapEnabled: true) { target in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (target, "new-hash")
        }
        await runtime.setProviderStatus(providerStatus)
        let requestStartedAt = await providerStatus.beginRequest()

        let task = try await runtime.beginSwap(targetModelID: "new-model")
        var observedMixedSnapshots: [RuntimeSnapshot] = []
        for _ in 0 ..< 1000 {
            let snapshot = await runtime.currentSnapshot()
            if snapshot.state != .ready && snapshot.modelID == "new-model" {
                observedMixedSnapshots.append(snapshot)
            }
            if snapshot.state == .ready && snapshot.modelID == "old-model" {
                observedMixedSnapshots.append(snapshot)
            }
        }

        await providerStatus.finishRequest(startedAt: requestStartedAt, completion: nil, failed: false)
        try await task.value
        let finalSnapshot = await runtime.currentSnapshot()

        XCTAssertTrue(observedMixedSnapshots.isEmpty)
        XCTAssertEqual(finalSnapshot.state, .ready)
        XCTAssertEqual(finalSnapshot.modelID, "new-model")
    }

    func testWarmSwapConfigUsesCLIOverEnvironmentOverYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(enableWarmSwap: false, swapDrainTimeoutSeconds: 44),
            environment: [
                "MACPROVIDER_ENABLE_WARM_SWAP": "true",
                "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S": "33",
            ],
            fileExists: { _ in true },
            readFile: { _ in "enable_warm_swap: false\nswap_drain_timeout_s: 22\n" }
        )

        XCTAssertEqual(config.enableWarmSwap, false)
        XCTAssertEqual(config.swapDrainTimeoutSeconds, 44)
    }

    func testWarmSwapConfigReadsEnvironmentBeforeYAML() throws {
        let config = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: [
                "MACPROVIDER_ENABLE_WARM_SWAP": "true",
                "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S": "33",
            ],
            fileExists: { _ in true },
            readFile: { _ in "enable_warm_swap: false\nswap_drain_timeout_s: 22\n" }
        )

        XCTAssertEqual(config.enableWarmSwap, true)
        XCTAssertEqual(config.swapDrainTimeoutSeconds, 33)
    }

    private func makeRuntime(
        modelID: String?,
        modelHash: String? = nil,
        modelHashAlgorithm: String? = nil,
        draftModelID: String? = nil,
        warmSwapEnabled: Bool,
        swapDrainTimeoutSeconds: Int = 30,
        loader: @escaping @Sendable (String) async throws -> (String, String?) = { target in (target, nil) },
        completion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil,
        speculativeCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            modelHash: modelHash,
            modelHashAlgorithm: modelHashAlgorithm,
            draftModelID: draftModelID,
            warmSwapEnabled: warmSwapEnabled,
            swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
            loader: { _ in throw TestError.unexpectedContainerLoader },
            testLoader: loader,
            testCompletion: completion,
            testSpeculativeCompletion: speculativeCompletion
        )
    }

    private func makeRequest(model: String) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ]
            ],
            "temperature": 0,
            "top_p": 1.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }

    private func makeProviderStatus(modelID: String?, modelHash: String?) -> ProviderStatus {
        ProviderStatus(
            modelID: modelID,
            modelLoaded: modelID != nil,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1),
            modelHash: modelHash
        )
    }
}

private actor InFlightProbe {
    private var _startedModelID: String?
    private var _startedDraftModelID: String?
    private var _canFinish = false

    var startedModelID: String? { _startedModelID }
    var startedDraftModelID: String? { _startedDraftModelID }
    var canFinish: Bool { _canFinish }

    func markStarted(modelID: String?, draftModelID: String? = nil) {
        _startedModelID = modelID
        _startedDraftModelID = draftModelID
    }

    func allowFinish() {
        _canFinish = true
    }
}

private enum TestError: Error {
    case unexpectedContainerLoader
    case loadFailed
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ predicate: () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition")
}
