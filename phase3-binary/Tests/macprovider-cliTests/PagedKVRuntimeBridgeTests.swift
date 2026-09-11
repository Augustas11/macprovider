import Foundation
import MLX
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

private enum PagedKVRuntimeBridgeTestError: Error {
    case notExpected
}

private final class RuntimeBridgeChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StreamChunk] = []

    func append(_ chunk: StreamChunk) {
        lock.lock()
        defer { lock.unlock() }
        values.append(chunk)
    }

    func chunks() -> [StreamChunk] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class PagedKVRuntimeBridgeTests: XCTestCase {
    func testRuntimeCapabilityRequiresMeasuredObservedIdentityAndBackend() async throws {
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
        let observedIdentity = Self.observedIdentity(from: proof)

        let attached = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observedIdentity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            continuousBatchingBackend: RuntimeBridgeScriptedBackend(scripts: [:]),
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let attachedDecision = await attached.pagedKVDecisionForTest()
        let attachedCapability = await attached.continuousBatchingCapabilityForTest()
        XCTAssertNotNil(attachedDecision.descriptor)
        XCTAssertNil(attachedCapability.unsupportedReason)

        let nilObservation = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let nilObservationDecision = await nilObservation.pagedKVDecisionForTest()
        let nilObservationCapability = await nilObservation.continuousBatchingCapabilityForTest()
        XCTAssertNil(nilObservationDecision.descriptor)
        XCTAssertNotNil(nilObservationCapability.unsupportedReason)

        let advertisedObservation = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof, source: .advertisedDescriptor),
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let advertisedDecision = await advertisedObservation.pagedKVDecisionForTest()
        let advertisedCapability = await advertisedObservation.continuousBatchingCapabilityForTest()
        XCTAssertNil(advertisedDecision.descriptor)
        XCTAssertNotNil(advertisedCapability.unsupportedReason)

        let noBackend = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observedIdentity,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: false,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let noBackendDecision = await noBackend.pagedKVDecisionForTest()
        let noBackendCapability = await noBackend.continuousBatchingCapabilityForTest()
        XCTAssertNil(noBackendDecision.descriptor)
        XCTAssertNotNil(noBackendCapability.unsupportedReason)
    }

    func testSharedForwardGreedyMatchesSerialLoneAndFullBatchWithUsageAndStops() async throws {
        let gate = RuntimeBridgeTestGate()
        let scripts = [
            "serial-a": [4, 5, 6],
            "serial-b": [7, 8],
            "lone": [9, 10],
        ]
        let backend = RuntimeBridgeScriptedBackend(scripts: scripts, decodeGate: gate)
        let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: backend)

        let aTask = Task {
            try await scheduler.submit(.init(
                id: "serial-a",
                conversationKey: "",
                promptTokens: [1],
                maxOutputTokens: 3,
                stopTokenSequences: [[5, 6]],
                temperature: 0.0,
                topP: 1.0
            ))
        }
        try await Self.eventually { await backend.decodeCallCount() == 1 }
        let bTask = Task {
            try await scheduler.submit(.init(
                id: "serial-b",
                conversationKey: "",
                promptTokens: [2],
                maxOutputTokens: 2,
                temperature: 0.0,
                topP: 1.0
            ))
        }
        await gate.open()

        let a = try await aTask.value
        let b = try await bTask.value
        XCTAssertEqual(a.outputTokens, [4])
        XCTAssertEqual(a.completionTokens, 3)
        XCTAssertEqual(a.emittedTokens, 1)
        XCTAssertEqual(a.terminalStatus, .stop)
        XCTAssertEqual(b.outputTokens, [7, 8])
        XCTAssertEqual(b.completionTokens, 2)
        XCTAssertEqual(b.emittedTokens, 2)
        XCTAssertEqual(b.terminalStatus, .length)
        let decodeBatches = await backend.decodeBatches()
        let metrics = await scheduler.metrics()
        XCTAssertTrue(decodeBatches.contains(["serial-a", "serial-b"]))
        XCTAssertEqual(metrics.maxObservedBatchDepth, 2)

        let loneBackend = RuntimeBridgeScriptedBackend(scripts: scripts)
        let loneScheduler = try Self.makeScheduler(maxActiveRows: 2, backend: loneBackend)
        let lone = try await loneScheduler.submit(.init(
            id: "lone",
            conversationKey: "",
            promptTokens: [3],
            maxOutputTokens: 2,
            temperature: 0.0,
            topP: 1.0
        ))
        XCTAssertEqual(lone.outputTokens, [9, 10])
        XCTAssertEqual(lone.completionTokens, 2)
        XCTAssertEqual(lone.emittedTokens, 2)
        XCTAssertEqual(lone.terminalStatus, .length)
    }

    func testRealSharedForwardBackendGreedyMatchesLoneAndMixedOffsetBatch() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: descriptor.modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [
                1: 4,
                4: 5,
                12: 7,
                7: 8,
            ]),
            processor: StandInUserInputProcessor(),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        let backend = PagedKVSharedForwardBackend(container: container, descriptor: descriptor, layerCount: 1)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)

        let aHandle = try await allocator.allocate(conversationKey: "row-a", maxTokens: 8)
        let bHandle = try await allocator.allocate(conversationKey: "row-b", maxTokens: 8)
        _ = try await allocator.extend(bHandle, by: 2)
        let bPrefillBinding = try await allocator.binding(for: bHandle)
        _ = try await backend.prefill(rows: [
            ContinuousBatchPrefillInput(
                requestID: "row-b",
                promptTokens: [10, 11],
                binding: bPrefillBinding,
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 2,
                isFinalChunk: true
            ),
        ])

        let aInput = try await Self.decodeInput(
            requestID: "row-a",
            currentToken: 1,
            handle: aHandle,
            allocator: allocator,
            committedKVTokenCount: 0
        )
        let bInput = try await Self.decodeInput(
            requestID: "row-b",
            currentToken: 12,
            handle: bHandle,
            allocator: allocator,
            committedKVTokenCount: 2
        )
        let batched = try await backend.decode(rows: [aInput, bInput])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)
        XCTAssertEqual(Self.tokens(from: batched), ["row-a": 4, "row-b": 7])
        XCTAssertEqual(backend.retainedRowCountForTest(), 2)
        backend.finish(requestID: "row-a")
        backend.finish(requestID: "row-b")
        XCTAssertEqual(backend.retainedRowCountForTest(), 0)

        let loneBackend = PagedKVSharedForwardBackend(container: container, descriptor: descriptor, layerCount: 1)
        let loneAllocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)
        let loneHandle = try await loneAllocator.allocate(conversationKey: "lone", maxTokens: 8)
        let loneInput = try await Self.decodeInput(
            requestID: "lone",
            currentToken: 1,
            handle: loneHandle,
            allocator: loneAllocator,
            committedKVTokenCount: 0
        )
        let lone = try await loneBackend.decode(rows: [loneInput])
        try await loneAllocator.endDecodeStep(loneHandle)
        XCTAssertEqual(Self.tokens(from: lone), ["lone": 4])
    }

    func testRealSharedForwardBackendCancelWaitsForActivePrefill() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor()
        let modelGate = RuntimeBridgeBlockingModelGate()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: descriptor.modelID),
            model: RuntimeBridgeBlockingModel(gate: modelGate),
            processor: StandInUserInputProcessor(),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        let backend = PagedKVSharedForwardBackend(container: container, descriptor: descriptor, layerCount: 1)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)
        let handle = try await allocator.allocate(conversationKey: "cancel-row", maxTokens: 8)
        _ = try await allocator.extend(handle, by: 1)
        let binding = try await allocator.binding(for: handle)

        let prefill = Task {
            try await backend.prefill(rows: [
                ContinuousBatchPrefillInput(
                    requestID: "cancel-row",
                    promptTokens: [1],
                    binding: binding,
                    promptTokenOffset: 0,
                    committedKVTokenCount: 0,
                    targetKVTokenCount: 1,
                    isFinalChunk: true
                ),
            ])
        }
        XCTAssertTrue(modelGate.waitUntilEntered(), "prefill should enter the fake model before cancellation")

        let cancellation = RuntimeBridgeCancellationMarker()
        let cancel = Task {
            await backend.cancelInFlight()
            cancellation.markReturned()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(cancellation.returned(), "cancelInFlight must wait for the active container.perform call")
        modelGate.release()
        _ = try await prefill.value
        await cancel.value
        XCTAssertTrue(cancellation.returned())
        XCTAssertEqual(backend.retainedRowCountForTest(), 0)
    }

    func testAttachedModelRuntimeServesFreshGreedyRequestsThroughScheduler() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
        let backend = RuntimeBridgeScriptedBackend(scripts: [:])
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: RuntimeBridgePromptProcessor(tokens: [3]),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        let runtime = ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            container: container,
            continuousBatchingBackend: backend,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)

        let completion = try await runtime.complete(request)
        XCTAssertEqual(completion.content, "3 3")
        XCTAssertEqual(completion.finishReason, "length")
        XCTAssertEqual(completion.promptTokens, 1)
        XCTAssertEqual(completion.completionTokens, 2)
        let completionDecodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(completionDecodeCalls, 2)

        let chunkRecorder = RuntimeBridgeChunkRecorder()
        let handle = try await runtime.acquireRequestHandle(request)
        let streamed = try await runtime.stream(
            request,
            with: handle,
            onChunk: { chunkRecorder.append($0) }
        )
        await runtime.unregisterInFlight(handle.registrationID)
        XCTAssertEqual(streamed.content, "3 3")
        let chunks = chunkRecorder.chunks()
        XCTAssertEqual(chunks.count, 2)
        let chunkText = chunks.compactMap { chunk -> String? in
            if case .content(let text) = chunk { return text }
            return nil
        }
        XCTAssertEqual(chunkText, ["3", " 3"])
        let streamedDecodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(streamedDecodeCalls, 4)
    }

    func testAttachedModelRuntimeCancelsBlockedCompletionSubmit() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let gate = RuntimeBridgeTestGate()
        let backend = RuntimeBridgeScriptedBackend(scripts: [:], decodeGate: gate)
        let modelID = "mlx-community/Qwen-Test"
        let runtime = Self.attachedRuntime(modelID: modelID, backend: backend)
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)
        let cancellation = RuntimeBridgeCancellationFlag()

        let task = Task {
            try await runtime.complete(request, shouldCancel: { cancellation.isCancelled() })
        }
        try await Self.eventually { await backend.decodeCallCount() == 1 }
        cancellation.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("attached completion should cancel while scheduler submit is blocked")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testAttachedModelRuntimeCancelsBlockedStreamingSubmit() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let gate = RuntimeBridgeTestGate()
        let backend = RuntimeBridgeScriptedBackend(scripts: [:], decodeGate: gate)
        let modelID = "mlx-community/Qwen-Test"
        let runtime = Self.attachedRuntime(modelID: modelID, backend: backend)
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)
        let cancellation = RuntimeBridgeCancellationFlag()
        let chunks = RuntimeBridgeChunkRecorder()
        let handle = try await runtime.acquireRequestHandle(request)

        let task = Task {
            try await runtime.stream(
                request,
                with: handle,
                shouldCancel: { cancellation.isCancelled() },
                onChunk: { chunks.append($0) }
            )
        }
        try await Self.eventually { await backend.decodeCallCount() == 1 }
        cancellation.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("attached streaming should cancel while scheduler submit is blocked")
        } catch is CancellationError {
            // Expected.
        }
        await runtime.unregisterInFlight(handle.registrationID)
        XCTAssertTrue(chunks.chunks().isEmpty)
    }

    func testStickyRequestsRemainRejectedBeforeFRPKV10CacheBridge() async throws {
        let backend = RuntimeBridgeScriptedBackend(scripts: [:])
        let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: backend)

        do {
            _ = try await scheduler.submit(.init(
                id: "sticky",
                conversationKey: "conversation-1",
                promptTokens: [1],
                maxOutputTokens: 1,
                temperature: 0.0,
                topP: 1.0
            ))
            XCTFail("sticky requests must not enter the Increment 1 batch path")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge")
        }
        let decodeCallCount = await backend.decodeCallCount()
        XCTAssertEqual(decodeCallCount, 0)
    }

    private static func makeScheduler(
        maxActiveRows: Int,
        backend: any ContinuousBatchSchedulerBackend
    ) throws -> ContinuousBatchScheduler {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
        let tuple = ContinuousBatchingRequestedTuple(
            modelID: descriptor.modelID,
            modelSHA256: descriptor.modelSHA256,
            tokenizerSHA256: descriptor.tokenizerSHA256,
            chatTemplateSHA256: descriptor.chatTemplateSHA256,
            cacheClass: "KVCacheSimple",
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: descriptor.metallibSHA256,
            kernelIdentifier: descriptor.kernelIdentifier,
            parityLabel: descriptor.parityLabel,
            poolEpoch: descriptor.poolEpoch
        )
        return ContinuousBatchScheduler(
            configuration: ContinuousBatchSchedulerConfiguration(
                descriptor: descriptor,
                tuple: tuple,
                maxActiveRows: maxActiveRows,
                decodeHeadroomTokens: 4,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: descriptor.modelID,
                    modelSHA256: descriptor.modelSHA256,
                    weightsGeneration: 1
                )
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16),
            backend: backend,
            replayAuthority: RuntimeBridgeReplayAuthority()
        )
    }

    private static func bridgeDescriptor() -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: 4,
            maxPhysicalBlocks: 16,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            supportedModelFamilies: ["qwen"],
            supportsMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "sdpa-parity-v1"
        )
    }

    private static func decodeInput(
        requestID: String,
        currentToken: Int,
        handle: PagedKVBlockTableHandle,
        allocator: PagedKVBlockAllocator,
        committedKVTokenCount: Int
    ) async throws -> ContinuousBatchDecodeInput {
        let targetKVTokenCount = committedKVTokenCount + 1
        _ = try await allocator.extend(handle, by: 1)
        try await allocator.beginDecodeStep(handle)
        let binding = try await allocator.binding(for: handle)
        return ContinuousBatchDecodeInput(
            requestID: requestID,
            currentToken: currentToken,
            generatedTokens: [],
            promptTokens: [currentToken],
            samplerSeed: 0,
            temperature: 0.0,
            topP: 1.0,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            binding: binding,
            blockTable: binding.currentTable,
            committedKVTokenCount: committedKVTokenCount,
            targetKVTokenCount: targetKVTokenCount,
            samplerStep: 0
        )
    }

    private static func tokens(from outcomes: [ContinuousBatchDecodeOutcome]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome in
            guard case .output(let output) = outcome else { return nil }
            return (output.requestID, output.token)
        })
    }

    private static func chatRequest(modelID: String, maxTokens: Int) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "top_p": 1.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }

    private static func attachedRuntime(
        modelID: String,
        backend: RuntimeBridgeScriptedBackend
    ) -> ModelRuntime {
        let modelSHA = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: RuntimeBridgePromptProcessor(tokens: [3]),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        return ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            container: container,
            continuousBatchingBackend: backend,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
    }

    private static func sizingProof(modelID: String, modelSHA: String) -> PagedKVHardwareSizingProof {
        PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: 64,
            maxResidentTokens: 2048,
            parityLabel: "sdpa-parity-v1"
        )
    }

    private static func observedIdentity(
        from proof: PagedKVHardwareSizingProof,
        source: PagedKVObservedRuntimeIdentitySource = .runtimeMeasurement
    ) -> PagedKVObservedRuntimeIdentity {
        PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass,
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            moeDispatchProven: false,
            poolEpoch: proof.poolEpoch,
            source: source
        )
    }

    private static func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true before timeout")
    }
}

private final class RuntimeBridgeFakeModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1]
    private let vocabularySize: Int
    private let nextTokenByInput: [Int: Int]

    init(vocabularySize: Int = 32, nextTokenByInput: [Int: Int]) {
        self.vocabularySize = vocabularySize
        self.nextTokenByInput = nextTokenByInput
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let batch = input.tokens.dim(0)
        let sequenceLength = input.tokens.dim(1)
        let flatTokens = input.tokens.asArray(Int.self)
        if let cache {
            let keys = MLXArray(flatTokens.map(Float.init), [batch, 1, sequenceLength, 1])
            let values = MLXArray(flatTokens.map { Float($0 + 100) }, [batch, 1, sequenceLength, 1])
            for layer in cache {
                let updated = layer.update(keys: keys, values: values)
                eval(updated.0, updated.1)
            }
        }

        var logits = Array(repeating: Float(-1_000), count: batch * sequenceLength * vocabularySize)
        for row in 0 ..< batch {
            for position in 0 ..< sequenceLength {
                let token = flatTokens[row * sequenceLength + position]
                let next = nextTokenByInput[token] ?? token
                logits[(row * sequenceLength + position) * vocabularySize + next] = 1_000
            }
        }
        return LMOutput(logits: MLXArray(logits, [batch, sequenceLength, vocabularySize]))
    }
}

private final class RuntimeBridgeBlockingModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1]
    private let gate: RuntimeBridgeBlockingModelGate

    init(gate: RuntimeBridgeBlockingModelGate) {
        self.gate = gate
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        gate.enterAndWaitUntilReleased()
        let batch = input.tokens.dim(0)
        let sequenceLength = input.tokens.dim(1)
        if let cache {
            let flatTokens = input.tokens.asArray(Int.self)
            let keys = MLXArray(flatTokens.map(Float.init), [batch, 1, sequenceLength, 1])
            let values = MLXArray(flatTokens.map { Float($0 + 100) }, [batch, 1, sequenceLength, 1])
            for layer in cache {
                let updated = layer.update(keys: keys, values: values)
                eval(updated.0, updated.1)
            }
        }
        var logits = Array(repeating: Float(-1_000), count: batch * sequenceLength * 32)
        for index in 0 ..< batch * sequenceLength {
            logits[index * 32 + 1] = 1_000
        }
        return LMOutput(logits: MLXArray(logits, [batch, sequenceLength, 32]))
    }
}

private final class RuntimeBridgeBlockingModelGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWaitUntilReleased() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !entered {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class RuntimeBridgeCancellationMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var returnedValue = false

    func markReturned() {
        lock.lock()
        returnedValue = true
        lock.unlock()
    }

    func returned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return returnedValue
    }
}

private final class RuntimeBridgeCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct RuntimeBridgeFakeTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}

private struct RuntimeBridgePromptProcessor: UserInputProcessor {
    let tokens: [Int32]

    func prepare(input: UserInput) throws -> LMInput {
        LMInput(tokens: MLXArray(tokens).reshaped(1, tokens.count))
    }
}

private actor RuntimeBridgeScriptedBackend: ContinuousBatchSchedulerBackend {
    private let scripts: [String: [Int]]
    private let decodeGate: RuntimeBridgeTestGate?
    private var decodeCalls = 0
    private var batches: [[String]] = []

    init(scripts: [String: [Int]], decodeGate: RuntimeBridgeTestGate? = nil) {
        self.scripts = scripts
        self.decodeGate = decodeGate
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        decodeCalls += 1
        batches.append(rows.map(\.requestID))
        if decodeCalls == 1, let decodeGate {
            await decodeGate.wait()
        }
        return rows.map { row in
            let script = scripts[row.requestID] ?? []
            let index = min(row.generatedTokens.count, max(script.count - 1, 0))
            return .output(ContinuousBatchDecodeOutput(
                requestID: row.requestID,
                token: script.isEmpty ? row.currentToken : script[index]
            ))
        }
    }

    func cancelInFlight() async {}

    func decodeCallCount() -> Int {
        decodeCalls
    }

    func decodeBatches() -> [[String]] {
        batches
    }
}

private actor RuntimeBridgeTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class RuntimeBridgeReplayAuthority: ContinuousBatchSchedulerReplayAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func claim(_ key: ContinuousBatchSchedulerReplayKey) throws -> ContinuousBatchSchedulerReplayClaim {
        lock.lock()
        defer { lock.unlock() }
        let storageKey = "\(key.requestID):\(key.fingerprintSHA256.base64EncodedString())"
        return keys.insert(storageKey).inserted ? .claimed : .duplicateSameRequest
    }
}
