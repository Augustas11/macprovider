import Foundation
import MLX
import MLXLMCommon
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

final class PagedKVRuntimeBridgeTests: XCTestCase {
    private func requireMLXMetalLibrary() throws {
        let binaryURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let binaryDirectory = binaryURL.deletingLastPathComponent()
        let candidates = [
            binaryDirectory.appendingPathComponent("mlx.metallib"),
            binaryDirectory.appendingPathComponent("default.metallib"),
            binaryDirectory.appendingPathComponent("Resources/mlx.metallib"),
            binaryDirectory.appendingPathComponent("Resources/default.metallib"),
            binaryDirectory.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"),
            binaryDirectory.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"),
        ]
        guard candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("MLX default metallib is not present in the test bundle")
        }
    }

    private let modelID = "mlx-community/Qwen-Bridge-Test"
    private let modelHash = String(repeating: "a", count: 64)
    private let tokenizerHash = String(repeating: "b", count: 64)
    private let templateHash = String(repeating: "c", count: 64)
    private let metallibHash = String(repeating: "d", count: 64)

    private func config() -> PagedKVConfig {
        PagedKVConfig(enabled: true, blockSizeTokens: 4, maxPhysicalBlocks: 4)
    }

    private func observation(
        parityLabel: String = "sdpa-parity-v1",
        poolEpoch: Int = 1
    ) -> PagedKVRuntimeObservation {
        let proof = PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelHash,
            tokenizerSHA256: tokenizerHash,
            chatTemplateSHA256: templateHash,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: metallibHash,
            kernelIdentifier: PagedKVGatherKernel.registeredKernelName,
            blockSizeTokens: 4,
            maxPhysicalBlocks: 4,
            maxResidentTokens: 16,
            poolEpoch: poolEpoch,
            parityLabel: parityLabel
        )
        return PagedKVRuntimeObservation(
            modelID: modelID,
            modelSHA256: modelHash,
            tokenizerSHA256: tokenizerHash,
            chatTemplateSHA256: templateHash,
            modelFamily: "qwen",
            cacheClass: "KVCacheSimple",
            requiresMoEDispatch: false,
            hardwareClass: "apple-silicon-test",
            metallibSHA256: metallibHash,
            kernelIdentifier: PagedKVGatherKernel.registeredKernelName,
            parityLabel: parityLabel,
            poolEpoch: poolEpoch,
            metallibAvailable: true,
            kernelRegistered: true,
            parityEstablished: true,
            hardwareSizingProof: proof,
            moeDispatchProven: false
        )
    }

    private func descriptor(for observation: PagedKVRuntimeObservation) throws -> PagedKVDescriptor {
        let decision = PagedKVAttachGate.decide(
            config: config(),
            runtimeCacheClass: observation.cacheClass,
            kvBits: nil,
            modelID: observation.modelID,
            modelSHA256: observation.modelSHA256,
            tokenizerSHA256: observation.tokenizerSHA256,
            chatTemplateSHA256: observation.chatTemplateSHA256,
            modelFamily: observation.modelFamily,
            requiresMoEDispatch: observation.requiresMoEDispatch,
            gates: observation.gates(config: config(), bridgeAvailable: true)
        )
        return try XCTUnwrap(decision.descriptor)
    }

    private func fp16Bytes(_ values: [Float16]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    func testObservedIdentityIsRequiredForAttachAndBatchCapability() async throws {
        let good = observation()
        let bad = observation(parityLabel: "unproven")
        let trustedDescriptor = try descriptor(for: good)
        XCTAssertTrue(good.matches(config: config()))
        XCTAssertTrue(bad.matches(config: config()))
        XCTAssertTrue(bad.gates(config: config(), bridgeAvailable: true).engineBridgeAvailable)

        let badDecision = PagedKVAttachGate.decide(
            config: config(),
            runtimeCacheClass: bad.cacheClass,
            kvBits: nil,
            modelID: bad.modelID,
            modelSHA256: bad.modelSHA256,
            tokenizerSHA256: bad.tokenizerSHA256,
            chatTemplateSHA256: bad.chatTemplateSHA256,
            modelFamily: bad.modelFamily,
            requiresMoEDispatch: bad.requiresMoEDispatch,
            gates: bad.gates(config: config(), bridgeAvailable: true)
        )
        XCTAssertNotEqual(badDecision.descriptor, trustedDescriptor)

        struct NoopDriver: PagedKVSharedForwardDriver {
            func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
                rows.map { ContinuousBatchPrefillOutput(requestID: $0.requestID) }
            }

            func decode(
                batch: PagedKVSharedForwardBatch,
                rows: [ContinuousBatchDecodeInput]
            ) async throws -> [ContinuousBatchDecodeOutcome] {
                XCTAssertEqual(batch.shape, [rows.count, 1])
                return rows.map {
                    .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: $0.currentToken))
                }
            }

            func cancelInFlight() async {}
        }

        let mismatchedRuntime = ModelRuntime(
            modelID: bad.modelID,
            modelHash: bad.modelSHA256,
            pagedKVConfig: config(),
            maxBatch: 2,
            continuousBatchingMode: .canary,
            pagedKVRuntimeObservation: bad,
            pagedKVTrustedDescriptor: trustedDescriptor,
            pagedKVSharedForwardDriver: NoopDriver(),
            warmSwapEnabled: false,
            loader: { _ in throw NSError(domain: "test", code: 1) }
        )
        let mismatchDecision = await mismatchedRuntime.pagedKVDecisionForTest()
        XCTAssertNil(mismatchDecision.descriptor)

        let untrustedRuntime = ModelRuntime(
            modelID: good.modelID,
            modelHash: good.modelSHA256,
            pagedKVConfig: config(),
            maxBatch: 2,
            continuousBatchingMode: .canary,
            pagedKVRuntimeObservation: good,
            pagedKVSharedForwardDriver: NoopDriver(),
            warmSwapEnabled: false,
            loader: { _ in throw NSError(domain: "test", code: 1) }
        )
        let untrustedDecision = await untrustedRuntime.pagedKVDecisionForTest()
        XCTAssertNil(untrustedDecision.descriptor)

        let runtime = ModelRuntime(
            modelID: good.modelID,
            modelHash: good.modelSHA256,
            pagedKVConfig: config(),
            maxBatch: 2,
            continuousBatchingMode: .canary,
            pagedKVRuntimeObservation: good,
            pagedKVTrustedDescriptor: trustedDescriptor,
            pagedKVSharedForwardDriver: NoopDriver(),
            warmSwapEnabled: false,
            loader: { _ in throw NSError(domain: "test", code: 1) }
        )
        let capability = await runtime.continuousBatchingCapabilityForTest()
        XCTAssertNotNil(capability.descriptor)
        XCTAssertNil(capability.unsupportedReason)

        let serialOnlyRuntime = ModelRuntime(
            modelID: good.modelID,
            modelHash: good.modelSHA256,
            pagedKVConfig: config(),
            maxBatch: 2,
            continuousBatchingMode: .canary,
            pagedKVRuntimeObservation: good,
            pagedKVTrustedDescriptor: trustedDescriptor,
            warmSwapEnabled: false,
            loader: { _ in throw NSError(domain: "test", code: 1) }
        )
        let serialCapability = await serialOnlyRuntime.continuousBatchingCapabilityForTest()
        XCTAssertEqual(serialCapability.unsupportedReason, .localCapabilityUnavailable)
    }

    func testLiveContiguousRoundTripRetainReattachAndTrimMidBlock() async throws {
        try requireMLXMetalLibrary()
        let observation = observation()
        let descriptor = try descriptor(for: observation)
        let bridge = try PagedKVRuntimeBridge(
            config: config(), observation: observation, descriptor: descriptor
        )
        let attachment = try await bridge.reserve(
            requestID: "bridge-test",
            maxTokens: 16
        )
        let layers = try attachment.makeCacheLayers(count: 1)

        let shape = [1, 1, 7, 2]
        let keyValues = (0 ..< 14).map { Float16($0 + 1) }
        let valueValues = (0 ..< 14).map { Float16(100 + $0) }
        let source = PagedKVMaterializedByteLayer(
            layerIndex: 0,
            keyShape: shape,
            valueShape: shape,
            dtype: .fp16,
            logicalTokenCount: 7,
            keyBytes: fp16Bytes(keyValues),
            valueBytes: fp16Bytes(valueValues)
        )
        try layers[0].inject(materialized: source)

        let snapshot = try await attachment.checkpoint()
        XCTAssertEqual(snapshot.blockTable.logicalTokenCount, 7)
        XCTAssertEqual(snapshot.blockTable.tailValidTokenCount, 3)
        let contiguous = try await bridge.materializeContiguousKVCache(handle: attachment.handle)
        let contiguousState = try XCTUnwrap(contiguous.first?.state)
        XCTAssertEqual(contiguous.first?.offset, 7)
        XCTAssertEqual(contiguousState[0].asData().data, source.keyBytes)
        XCTAssertEqual(contiguousState[1].asData().data, source.valueBytes)

        let retained = try await attachment.retain()
        let (reattached, reattachedLayers) = try await bridge.reattach(
            retained,
            conversationKey: "bridge-test",
            layerCount: 1
        )
        XCTAssertEqual(reattachedLayers[0].offset, 7)

        // Trim two tokens from a seven-token sequence: the allocator and live
        // KVCache must agree on the five-token mid-block boundary.
        XCTAssertEqual(reattachedLayers[0].trim(2), 2)
        let trimmed = try await reattached.checkpoint()
        XCTAssertEqual(trimmed.blockTable.logicalTokenCount, 5)
        XCTAssertEqual(trimmed.blockTable.tailValidTokenCount, 1)
        XCTAssertEqual(trimmed.layers[0].keyShape[2], 5)
        XCTAssertEqual(trimmed.layers[0].keyBytes.count, 5 * 2 * MemoryLayout<Float16>.size)

        try await reattached.release()
    }

    func testSharedForwardBackendCarriesOneTokenPerActiveRow() async throws {
        struct Recorder: PagedKVSharedForwardDriver {
            func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] { [] }

            func decode(
                batch: PagedKVSharedForwardBatch,
                rows: [ContinuousBatchDecodeInput]
            ) async throws -> [ContinuousBatchDecodeOutcome] {
                XCTAssertEqual(batch.tokens, rows.map(\.currentToken))
                XCTAssertEqual(batch.shape, [2, 1])
                return rows.map {
                    .output(ContinuousBatchDecodeOutput(requestID: $0.requestID, token: $0.currentToken))
                }
            }

            func cancelInFlight() async {}
        }

        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "batch", poolEpoch: 1)
        let table = PagedKVBlockTable(
            handleID: handle.handleID,
            blockSizeTokens: 4,
            logicalTokenCount: 1,
            physicalBlocks: [0],
            tailValidTokenCount: 1,
            poolEpoch: 1
        )
        let binding = PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: 4,
            maxLogicalTokens: 8,
            currentTable: table,
            poolEpoch: 1
        )
        let rows = [
            ContinuousBatchDecodeInput(
                requestID: "a", currentToken: 11, generatedTokens: [], promptTokens: [1],
                samplerSeed: 0, temperature: 0, topP: 1, presencePenalty: 0, frequencyPenalty: 0,
                blockTable: table, committedKVTokenCount: 1, targetKVTokenCount: 2, samplerStep: 0
            ),
            ContinuousBatchDecodeInput(
                requestID: "b", currentToken: 22, generatedTokens: [], promptTokens: [2],
                samplerSeed: 0, temperature: 0, topP: 1, presencePenalty: 0, frequencyPenalty: 0,
                blockTable: table, committedKVTokenCount: 1, targetKVTokenCount: 2, samplerStep: 0
            ),
        ]
        let backend = PagedKVSharedForwardBackend(driver: Recorder())
        let outcomes = try await backend.decode(rows: rows)
        XCTAssertEqual(outcomes.count, 2)
        _ = binding
    }
}
