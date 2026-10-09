import CryptoKit
import Foundation
import MLX
import MLXLLM
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
    func testQwen3xHybridArchitectureRequiresExactAllowlistedIdentityAndConfigMetadata() {
        let dense = Data(#"{"model_type":"qwen3_5","architectures":["Qwen3_5ForConditionalGeneration"]}"#.utf8)
        let moe = Data(#"{"model_type":"qwen3_5_moe","architectures":["Qwen3_5MoeForConditionalGeneration"]}"#.utf8)
        let unrelated = Data(#"{"model_type":"qwen3_5","architectures":["AnotherDecoder"]}"#.utf8)

        // Every entry is an exact measured identity/architecture pair. Dense
        // identities require the dense architecture and the MoE identities
        // require the MoE architecture.
        for modelID in ["qwen/qwen3.5-27b", "qwen/qwen3.6-27b", "qwen/qwen3.8-27b"] {
            XCTAssertTrue(ModelRuntime.pagedKVModelCapabilities(
                modelID: modelID, configJSONData: dense
            ).hybridDecoderArchitectureVerified)
            XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
                modelID: modelID, configJSONData: moe
            ).hybridDecoderArchitectureVerified)
        }
        for modelID in ["qwen/qwen3.5-35b-a3b", "qwen/qwen3.6-35b-a3b"] {
            XCTAssertTrue(ModelRuntime.pagedKVModelCapabilities(
                modelID: modelID, configJSONData: moe
            ).hybridDecoderArchitectureVerified)
            XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
                modelID: modelID, configJSONData: dense
            ).hybridDecoderArchitectureVerified)
        }

        // Config metadata is still required: missing or mismatched architecture never verifies.
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "qwen/qwen3.6-27b", configJSONData: nil
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "qwen/qwen3.6-27b", configJSONData: unrelated
        ).hybridDecoderArchitectureVerified)

        // Same-architecture identities remain excluded unless individually
        // measured and named; architecture matching alone cannot expand support.
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "qwen/qwen3.5-14b", configJSONData: dense
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "qwen/qwen3.7-35b-a3b", configJSONData: moe
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "qwen/qwen3.8-32b", configJSONData: dense
        ).hybridDecoderArchitectureVerified)
    }

    func testGPTOSS120BMixedArchitectureRequiresExactAllowlistedIdentityAndConfigMetadata() {
        let gptOSS = Data(#"{"model_type":"gpt_oss","architectures":["GptOssForCausalLM"],"num_experts":128}"#.utf8)
        let unrelated = Data(#"{"model_type":"gpt_oss","architectures":["AnotherDecoder"]}"#.utf8)

        let admitted = ModelRuntime.pagedKVModelCapabilities(
            modelID: "openai/gpt-oss-120b",
            configJSONData: gptOSS
        )
        XCTAssertEqual(admitted.modelFamily, "gpt_oss")
        XCTAssertTrue(admitted.requiresMoEDispatch)
        XCTAssertTrue(admitted.hybridDecoderArchitectureVerified)
        XCTAssertTrue(PagedKVAttachGate.supportsCacheClass(
            "mixed",
            hybridDecoderArchitectureVerified: admitted.hybridDecoderArchitectureVerified
        ))

        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "openai/gpt-oss-20b",
            configJSONData: gptOSS
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "openai/gpt-oss-120b",
            configJSONData: unrelated
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/gpt-oss-120b-4bit",
            configJSONData: gptOSS
        ).hybridDecoderArchitectureVerified)
    }

    func testMeasuredMixedPagedKVTopologyIsFamilySpecific() {
        let qwenVerified = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            hybridDecoderArchitectureVerified: true
        )
        let gptOSSVerified = PagedKVRuntimeModelCapabilities(
            modelFamily: "gpt_oss",
            requiresMoEDispatch: true,
            hybridDecoderArchitectureVerified: true
        )

        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(
            [.recurrentMamba, .pagedAttention],
            modelCapabilities: qwenVerified
        ))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            [.recurrentMamba, .pagedAttention],
            modelCapabilities: gptOSSVerified
        ))
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(
            [.slidingWindow(windowTokens: 128), .pagedAttention],
            modelCapabilities: gptOSSVerified
        ))
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(
            [.slidingWindow(windowTokens: 128), .pagedAttention],
            modelCapabilities: qwenVerified
        ))
    }

    func testQwen35HybridArchitectureRequiresExactTupleAndConfigMetadata() {
        let supported = Self.qwen35HybridConfig()
        let wrongLayers = Self.qwen35HybridConfig(
            layerTypes: Array(repeating: "full_attention", count: 32)
        )
        let missingMTP = Self.qwen35HybridConfig(includeMTPMetadata: false)
        let unrelated = Data(#"{"model_type":"qwen3_5","architectures":["AnotherDecoder"]}"#.utf8)

        XCTAssertTrue(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-9B-4bit", configJSONData: supported
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-9B-4bit", configJSONData: nil
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-9B-4bit", configJSONData: unrelated
        ).hybridDecoderArchitectureVerified)

        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-9B-4bit", configJSONData: wrongLayers
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-9B-4bit", configJSONData: missingMTP
        ).hybridDecoderArchitectureVerified)
        XCTAssertFalse(ModelRuntime.pagedKVModelCapabilities(
            modelID: "mlx-community/Qwen3.5-10B-4bit", configJSONData: supported
        ).hybridDecoderArchitectureVerified)
    }

    func testNativeMTPAdmissionCacheClassCanonicalizesOnlyVerifiedPagedRuntime() {
        let verified = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            hybridDecoderArchitectureVerified: true
        )
        let unverified = PagedKVRuntimeModelCapabilities(
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            hybridDecoderArchitectureVerified: false
        )

        XCTAssertEqual(ModelRuntime.nativeMTPAdmissionCacheClass(
            runtimeCacheClass: "KVCacheSimple",
            modelCapabilities: unverified
        ), "paged_kv")
        XCTAssertEqual(ModelRuntime.nativeMTPAdmissionCacheClass(
            runtimeCacheClass: "mixed",
            modelCapabilities: verified
        ), "paged_kv")
        XCTAssertNil(ModelRuntime.nativeMTPAdmissionCacheClass(
            runtimeCacheClass: "mixed",
            modelCapabilities: unverified
        ))
        XCTAssertNil(ModelRuntime.nativeMTPAdmissionCacheClass(
            runtimeCacheClass: "RotatingKVCache",
            modelCapabilities: verified
        ))
    }

    func testProductionRuntimeMeasurementMissingMetallibStaysNil() {
        let measurement = ModelRuntime.measurePagedKVRuntime(
            config: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: Self.establishedParityProbe(),
            moeProbe: nil,
            environment: PagedKVRuntimeMeasurementEnvironment(
                metallibCandidatePaths: { ["/tmp/absent/default.metallib"] },
                fileExists: { _ in false },
                readFileData: { _ in Data("not-used".utf8) },
                hardwareFingerprint: {
                    MachineFingerprint(
                        ramGB: 32,
                        chip: "Apple M-test",
                        osVersion: "macOS test",
                        binaryVersion: "test"
                    )
                },
                registeredKernelIdentifier: { PagedKVGatherKernel.registeredKernelName }
            )
        )

        XCTAssertNil(measurement)
    }

    func testProductionRuntimeMeasurementBuildsLiveIdentityAndSizingProof() throws {
        let metallibBytes = Data("packaged metallib bytes".utf8)
        let expectedMetallibSHA = SHA256.hash(data: metallibBytes).map { String(format: "%02x", $0) }.joined()
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "a", count: 64)
        let tokenizerSHA = String(repeating: "b", count: 64)
        let templateSHA = String(repeating: "c", count: 64)
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let hardwareClass = "apple-silicon:Apple M-test:ram-64gb"
        // Mirrors `measurePagedKVRuntime`'s own tuple-bound label derivation exactly: a
        // SHA256 over every identity-relevant field plus the fixed algorithm tag. This is
        // NOT a scripted stand-in (the old `parityLabel` environment closure the previous
        // version of this test used) — it is the actual formula under test, so a genuine
        // established parity probe is what produces it now.
        let expectedParityLabel = SHA256.hash(data: Data(
            "\(expectedMetallibSHA)|\(PagedKVGatherKernel.registeredKernelName)|\(modelSHA)|\(tokenizerSHA)|\(templateSHA)|\(hardwareClass)|\(modelID)|blk\(config.blockSizeTokens)|max\(config.maxPhysicalBlocks)|sdpa-parity-v1".utf8
        )).map { String(format: "%02x", $0) }.joined()

        let measurement = try XCTUnwrap(ModelRuntime.measurePagedKVRuntime(
            config: config,
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: tokenizerSHA,
            chatTemplateSHA256: templateSHA,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: Self.establishedParityProbe(),
            moeProbe: Self.provenBatchedProbe(),
            environment: PagedKVRuntimeMeasurementEnvironment(
                metallibCandidatePaths: { ["/tmp/present/default.metallib"] },
                fileExists: { $0 == "/tmp/present/default.metallib" },
                readFileData: { _ in metallibBytes },
                hardwareFingerprint: {
                    MachineFingerprint(
                        ramGB: 64,
                        chip: "Apple M-test",
                        osVersion: "macOS test",
                        binaryVersion: "test"
                    )
                },
                registeredKernelIdentifier: { PagedKVGatherKernel.registeredKernelName }
            )
        ))

        XCTAssertEqual(measurement.observedRuntimeIdentity.source, .runtimeMeasurement)
        XCTAssertEqual(measurement.observedRuntimeIdentity.metallibSHA256, expectedMetallibSHA)
        XCTAssertEqual(measurement.observedRuntimeIdentity.kernelIdentifier, PagedKVGatherKernel.registeredKernelName)
        XCTAssertEqual(measurement.observedRuntimeIdentity.parityLabel, expectedParityLabel)
        XCTAssertEqual(measurement.observedRuntimeIdentity.moeDispatchProven, false)
        XCTAssertEqual(measurement.observedRuntimeIdentity.poolEpoch, 1)
        XCTAssertEqual(measurement.observedRuntimeIdentity.hardwareClass, "apple-silicon:Apple M-test:ram-64gb")
        XCTAssertTrue(measurement.hardwareSizingProof.covers(
            config: config,
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: tokenizerSHA,
            chatTemplateSHA256: templateSHA,
            modelFamily: "qwen",
            observedHardwareClass: measurement.observedRuntimeIdentity.hardwareClass,
            observedMetallibSHA256: measurement.observedRuntimeIdentity.metallibSHA256,
            observedKernelIdentifier: measurement.observedRuntimeIdentity.kernelIdentifier,
            observedParityLabel: measurement.observedRuntimeIdentity.parityLabel,
            poolEpoch: measurement.observedRuntimeIdentity.poolEpoch
        ))
    }

    func testProductionRuntimeMeasurementIgnoresAdjacentParitySidecarByDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metallibURL = directory.appendingPathComponent("default.metallib")
        let manifestURL = metallibURL.appendingPathExtension("parity.json")
        let metallibBytes = Data("packaged metallib bytes".utf8)
        try metallibBytes.write(to: metallibURL)
        let metallibSHA = SHA256.hash(data: metallibBytes).map { String(format: "%02x", $0) }.joined()
        let kernelSourceSHA = SHA256.hash(data: Data(PagedKVGatherKernel.source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let modelID = "mlx-community/Qwen-Test"
        let modelSHA = String(repeating: "b", count: 64)
        let tokenizerSHA = String(repeating: "c", count: 64)
        let templateSHA = String(repeating: "d", count: 64)
        let hardwareClass = "apple-silicon:Apple M-test:ram-64gb"

        let body = """
        {
          "version": 1,
          "metallib_sha256": "\(metallibSHA)",
          "kernel_identifier": "\(PagedKVGatherKernel.registeredKernelName)",
          "kernel_source_sha256": "\(kernelSourceSHA)",
          "model_id": "\(modelID)",
          "model_sha256": "\(modelSHA)",
          "tokenizer_sha256": "\(tokenizerSHA)",
          "chat_template_sha256": "\(templateSHA)",
          "hardware_class": "\(hardwareClass)",
          "parity_label": "sdpa-parity-v1"
        }
        """
        try body.data(using: .utf8)?.write(to: manifestURL)

        // No sidecar-reading mechanism exists any more (production derives the parity
        // label only from a genuinely established `parityProbe`), so passing no probe is
        // itself the regression check: an adjacent `.parity.json` manifest sitting next to
        // the metallib must NOT be consulted, by construction, to manufacture a label.
        XCTAssertNil(ModelRuntime.measurePagedKVRuntime(
            config: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: tokenizerSHA,
            chatTemplateSHA256: templateSHA,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: nil,
            moeProbe: nil,
            environment: PagedKVRuntimeMeasurementEnvironment(
                metallibCandidatePaths: { [metallibURL.path] },
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readFileData: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
                hardwareFingerprint: {
                    MachineFingerprint(
                        ramGB: 64,
                        chip: "Apple M-test",
                        osVersion: "macOS test",
                        binaryVersion: "test"
                    )
                },
                registeredKernelIdentifier: { PagedKVGatherKernel.registeredKernelName }
            )
        ))
    }

    func testProductionRuntimeMeasurementRejectsIncompleteLiveInputs() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let baseEnvironment = PagedKVRuntimeMeasurementEnvironment(
            metallibCandidatePaths: { ["/tmp/present/default.metallib"] },
            fileExists: { _ in true },
            readFileData: { _ in Data("metallib".utf8) },
            hardwareFingerprint: {
                MachineFingerprint(
                    ramGB: 64,
                    chip: "Apple M-test",
                    osVersion: "macOS test",
                    binaryVersion: "test"
                )
            },
            registeredKernelIdentifier: { PagedKVGatherKernel.registeredKernelName }
        )

        // Kernel identifier missing: an otherwise-genuine established parity probe must
        // NOT be enough on its own — the kernel-registration gate is independent.
        var noKernel = baseEnvironment
        noKernel.registeredKernelIdentifier = { nil }
        XCTAssertNil(ModelRuntime.measurePagedKVRuntime(
            config: config,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: Self.establishedParityProbe(),
            moeProbe: nil,
            environment: noKernel
        ))

        // Parity probe entirely absent (fail-closed default): even a fully valid
        // environment must not manufacture a label out of nothing.
        XCTAssertNil(ModelRuntime.measurePagedKVRuntime(
            config: config,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: nil,
            moeProbe: nil,
            environment: baseEnvironment
        ))

        var noHardware = baseEnvironment
        noHardware.hardwareFingerprint = {
            MachineFingerprint(ramGB: 64, chip: "unknown", osVersion: "macOS test", binaryVersion: "test")
        }
        XCTAssertNil(ModelRuntime.measurePagedKVRuntime(
            config: config,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: Self.establishedParityProbe(),
            moeProbe: nil,
            environment: noHardware
        ))
    }

    // MARK: - SPEC-039 probe-fed measurement: fail-closed / tuple-bound / MoE gates

    /// (a) A missing parity probe is the production default (`ModelRuntime` only ever
    /// calls the measurement seam with `nil` when paged KV is off or the model family is
    /// unrecognized) and must fail CLOSED at both layers: no measurement is produced, and
    /// a runtime that consequently has no observed identity/proof never attaches.
    func testParityProbeAbsentFailsClosedToNoMeasurementAndNoAttach() async throws {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let measurement = ModelRuntime.measurePagedKVRuntime(
            config: config,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "a", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelCapabilities: PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false),
            parityProbe: nil,
            moeProbe: nil,
            environment: Self.liveMeasurementEnvironment()
        )
        XCTAssertNil(measurement)

        let runtime = ModelRuntime(
            modelID: "mlx-community/Qwen-Test",
            modelHash: String(repeating: "a", count: 64),
            pagedKVConfig: config,
            maxBatch: 1,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: nil,
            pagedKVHardwareSizingProof: nil,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let decision = await runtime.pagedKVDecisionForTest()
        XCTAssertNil(decision.descriptor)
    }

    /// (b)/(c) The parity label is derived from a SHA256 over every identity field
    /// (metallib/kernel/model/tokenizer/template/hardware), so two distinct identity
    /// tuples must produce two distinct labels, and a proof/label established for tuple X
    /// must NOT satisfy the attach gate's `covers()` check — nor the full attach decision
    /// — for a different tuple Y.
    func testParityLabelIsTupleBoundAndRejectsMismatchedIdentity() async throws {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let capabilities = PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: false)

        // tokenizerSHA256/chatTemplateSHA256 are held constant at `nil` across both tuples
        // (rather than varied too) because the `ModelRuntime` test initializer below always
        // computes its attach decision with `tokenizerSHA256: nil, chatTemplateSHA256: nil`
        // regardless of what is passed to it — matching that lets the SAME two
        // measurements feed both the direct `measurePagedKVRuntime`/`covers()` checks AND
        // the end-to-end attach-decision checks. `modelSHA256` alone is varied, which is
        // sufficient to prove the label and gate are tuple-bound.
        func measure(modelSHA: String) throws -> PagedKVRuntimeMeasurement {
            try XCTUnwrap(ModelRuntime.measurePagedKVRuntime(
                config: config,
                modelID: "mlx-community/Qwen-Test",
                modelSHA256: modelSHA,
                tokenizerSHA256: nil,
                chatTemplateSHA256: nil,
                modelCapabilities: capabilities,
                parityProbe: Self.establishedParityProbe(),
                moeProbe: Self.provenBatchedProbe(),
                environment: Self.liveMeasurementEnvironment()
            ))
        }

        let tupleX = try measure(modelSHA: String(repeating: "a", count: 64))
        let tupleY = try measure(modelSHA: String(repeating: "d", count: 64))

        XCTAssertNotEqual(tupleX.observedRuntimeIdentity.parityLabel, tupleY.observedRuntimeIdentity.parityLabel)

        // Tuple X's proof, asked to cover tuple Y's identity fields (even reusing tuple
        // X's own label), must refuse.
        XCTAssertFalse(tupleX.hardwareSizingProof.covers(
            config: config,
            modelID: "mlx-community/Qwen-Test",
            modelSHA256: String(repeating: "d", count: 64),
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            observedHardwareClass: tupleX.observedRuntimeIdentity.hardwareClass,
            observedMetallibSHA256: tupleX.observedRuntimeIdentity.metallibSHA256,
            observedKernelIdentifier: tupleX.observedRuntimeIdentity.kernelIdentifier,
            observedParityLabel: tupleX.observedRuntimeIdentity.parityLabel,
            poolEpoch: tupleX.observedRuntimeIdentity.poolEpoch
        ))

        // End-to-end: a runtime holding tuple X's observed identity/proof but reporting
        // tuple Y's model hash at decision time must not attach.
        let mismatchedRuntime = ModelRuntime(
            modelID: "mlx-community/Qwen-Test",
            modelHash: String(repeating: "d", count: 64),
            pagedKVConfig: config,
            maxBatch: 1,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: tupleX.observedRuntimeIdentity,
            pagedKVHardwareSizingProof: tupleX.hardwareSizingProof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let mismatchedDecision = await mismatchedRuntime.pagedKVDecisionForTest()
        XCTAssertNil(mismatchedDecision.descriptor)

        // Control: tuple X's own identity/proof against its own model hash attaches fine.
        let matchedRuntime = ModelRuntime(
            modelID: "mlx-community/Qwen-Test",
            modelHash: String(repeating: "a", count: 64),
            pagedKVConfig: config,
            maxBatch: 1,
            continuousBatchingMode: .on,
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: tupleX.observedRuntimeIdentity,
            pagedKVHardwareSizingProof: tupleX.hardwareSizingProof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
        )
        let matchedDecision = await matchedRuntime.pagedKVDecisionForTest()
        XCTAssertNotNil(matchedDecision.descriptor)
    }

    /// (d) A model that requires MoE dispatch must only attach when the shared-forward
    /// input-isolation probe is genuinely `proven` (both rows decoded through the real
    /// batched path, zero row failures, zero cross-row divergences). Any degenerate
    /// result — absent, or `proven == false` for any individual reason — fails CLOSED;
    /// `proven == true` establishes the measurement with `moeDispatchProven == true`.
    func testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation() {
        let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
        let moeCapabilities = PagedKVRuntimeModelCapabilities(modelFamily: "qwen", requiresMoEDispatch: true)

        func measure(moeProbe: PagedKVRuntimeMoEProbeResult?) -> PagedKVRuntimeMeasurement? {
            ModelRuntime.measurePagedKVRuntime(
                config: config,
                modelID: "mlx-community/Qwen-Test",
                modelSHA256: String(repeating: "a", count: 64),
                tokenizerSHA256: nil,
                chatTemplateSHA256: nil,
                modelCapabilities: moeCapabilities,
                parityProbe: Self.establishedParityProbe(),
                moeProbe: moeProbe,
                environment: Self.liveMeasurementEnvironment()
            )
        }

        XCTAssertNil(measure(moeProbe: nil), "no MoE probe at all must fail closed")
        XCTAssertNil(measure(moeProbe: .failClosed), "the probe's own fail-closed sentinel must not attach")
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: false,
            rowsDecodedInSharedForward: 1,
            rowFailures: 0,
            crossRowDivergences: 0,
            challengeDistinguishing: true
        )), "only one row decoded through the shared forward is degenerate")
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: false,
            rowsDecodedInSharedForward: 2,
            rowFailures: 1,
            crossRowDivergences: 0,
            challengeDistinguishing: true
        )), "any row failure must refuse")
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: false,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 1,
            challengeDistinguishing: true
        )), "any cross-row divergence must refuse")
        // Inconsistent probe result: `proven` claims success but the raw counters
        // contradict it. The measurement must consume the full shape and refuse, never
        // trust `proven` alone.
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 1,
            rowFailures: 1,
            crossRowDivergences: 1,
            challengeDistinguishing: false
        )), "proven:true with contradicting counters must still fail closed")
        // A non-distinguishing challenge (identical row references) cannot prove
        // isolation even with two clean, matching rows.
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 0,
            challengeDistinguishing: false
        )), "a non-distinguishing challenge must not prove MoE isolation")
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 0,
            sharedForwardParityProven: false,
            parityTokensCompared: PagedKVRuntimeParityProbe.sharedForwardParityTokens,
            challengeDistinguishing: true
        )), "shared-forward isolation without exact serial parity must fail closed")
        XCTAssertNil(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 0,
            sharedForwardParityProven: true,
            parityTokensCompared: PagedKVRuntimeParityProbe.sharedForwardParityTokens - 1,
            challengeDistinguishing: true
        )), "a parity proof shorter than the required window must fail closed")

        let proven = try? XCTUnwrap(measure(moeProbe: PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 0,
            sharedForwardParityProven: true,
            parityTokensCompared: PagedKVRuntimeParityProbe.sharedForwardParityTokens,
            challengeDistinguishing: true
        )))
        XCTAssertEqual(proven?.observedRuntimeIdentity.moeDispatchProven, true)
    }

    func testProductionReplayAuthorityClaimsStableRequestFingerprintOnce() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-replay-\(UUID().uuidString)")
            .appendingPathComponent("claims", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let authority = ContinuousBatchRuntimeReplayAuthority(storeURL: storeURL)
        let same = ContinuousBatchSchedulerReplayKey(
            requestID: "relay-request-1",
            fingerprintSHA256: Data(repeating: 0x01, count: 32)
        )
        let mismatch = ContinuousBatchSchedulerReplayKey(
            requestID: "relay-request-1",
            fingerprintSHA256: Data(repeating: 0x02, count: 32)
        )

        XCTAssertEqual(try authority.claim(same), .claimed)
        XCTAssertEqual(try authority.claim(same), .duplicateSameRequest)
        XCTAssertEqual(try authority.claim(mismatch), .duplicateMismatchedRequest)
        let concurrentInstance = ContinuousBatchRuntimeReplayAuthority(storeURL: storeURL)
        XCTAssertEqual(try concurrentInstance.claim(same), .duplicateSameRequest)
        XCTAssertEqual(try concurrentInstance.claim(mismatch), .duplicateMismatchedRequest)
        let reloaded = ContinuousBatchRuntimeReplayAuthority(storeURL: storeURL)
        XCTAssertTrue(reloaded.durableAvailable)
        XCTAssertEqual(try reloaded.claim(same), .duplicateSameRequest)
        XCTAssertEqual(try reloaded.claim(mismatch), .duplicateMismatchedRequest)
    }

    func testProductionSchedulerRequestIDUsesIngressIdentityWhenPresent() throws {
        let request = try Self.chatRequest(modelID: "mlx-community/Qwen-Test", maxTokens: 1)
            .withRequestID("relay-request-1500")

        XCTAssertEqual(ModelRuntime.schedulerRequestID(for: request), "relay-request-1500")
        XCTAssertNil(ModelRuntime.schedulerRequestID(for: try Self.chatRequest(
            modelID: "mlx-community/Qwen-Test",
            maxTokens: 1
        )))
    }

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
            continuousBatchingDurableReplayAuthorityAvailable: true,
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

    func testQwen35AndQwen36MixedRuntimesAttachOnlyWithVerifiedArchitecture() async {
        for modelID in ["mlx-community/Qwen3.5-9B-4bit", "qwen/qwen3.6-27b"] {
            let modelSHA = String(repeating: "a", count: 64)
            let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
            let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)

            func runtime(verified: Bool) -> ModelRuntime {
                ModelRuntime(
                    modelID: modelID,
                    modelHash: modelSHA,
                    pagedKVConfig: config,
                    maxBatch: 8,
                    continuousBatchingMode: .on,
                    continuousBatchingDurableReplayAuthorityAvailable: true,
                    warmSwapEnabled: false,
                    pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
                    pagedKVHardwareSizingProof: proof,
                    pagedKVRuntimeCacheClass: "mixed",
                    pagedKVSchedulerBackendInstalled: true,
                    pagedKVModelCapabilities: PagedKVRuntimeModelCapabilities(
                        modelFamily: "qwen",
                        requiresMoEDispatch: false,
                        hybridDecoderArchitectureVerified: verified
                    ),
                    continuousBatchingBackend: RuntimeBridgeScriptedBackend(scripts: [:]),
                    loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
                )
            }

            let admitted = runtime(verified: true)
            let admittedDecision = await admitted.pagedKVDecisionForTest()
            let admittedCapability = await admitted.continuousBatchingCapabilityForTest()
            let admittedStatus = await admitted.currentSnapshot().continuousBatching
            XCTAssertNotNil(admittedDecision.descriptor, modelID)
            XCTAssertNil(admittedCapability.unsupportedReason, modelID)
            XCTAssertEqual(admittedStatus?.active, true, modelID)
            XCTAssertEqual(admittedStatus?.cacheClass, "mixed", modelID)
            XCTAssertEqual(admittedStatus?.scheduler?.slotsTotal, 8, modelID)

            let rejected = runtime(verified: false)
            let rejectedDecision = await rejected.pagedKVDecisionForTest()
            let rejectedCapability = await rejected.continuousBatchingCapabilityForTest()
            let rejectedStatus = await rejected.currentSnapshot().continuousBatching
            XCTAssertNil(rejectedDecision.descriptor, modelID)
            XCTAssertNotNil(rejectedCapability.unsupportedReason, modelID)
            XCTAssertEqual(rejectedStatus?.active, false, modelID)
            XCTAssertEqual(
                rejectedStatus?.unsupportedReason,
                rejectedCapability.unsupportedReason?.rawValue,
                modelID
            )
        }
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
        // Creating a Task does not mean its request has reached the scheduler.
        // Keep the first decode blocked until both submit continuations attach,
        // otherwise serial-a can finish before serial-b joins on a busy runner.
        try await Self.eventually { await scheduler.metrics().attachedWaiters == 2 }
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

    func testNativeMTPPromptPrefillUsesBoundedFinalPrefillHiddenWithoutReplay() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let model = RuntimeBridgeFakeModel(
            nextTokenByInput: [12: 13],
            emitsMTPState: true
        )
        let drafter = RuntimeBridgeRecordingMTPDrafter()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: descriptor.modelID),
            model: model,
            processor: StandInUserInputProcessor(),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        let backend = PagedKVSharedForwardBackend(
            container: container,
            descriptor: descriptor,
            layerCount: 1,
            drafterContainer: MTPDrafterContainer(
                context: MTPDrafterContext(
                    configuration: ModelConfiguration(id: "mtp"),
                    model: drafter
                )
            )
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: 16
        )
        let handle = try await allocator.allocate(conversationKey: "native", maxTokens: 8)
        _ = try await allocator.extend(handle, by: 3)

        let output = try await backend.prefill(rows: [
            ContinuousBatchPrefillInput(
                requestID: "native",
                promptTokens: [10, 11, 12],
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 3,
                isFinalChunk: true,
                nativeMTPPromptPrefill: true
            ),
        ])

        XCTAssertEqual(output, [ContinuousBatchPrefillOutput(requestID: "native", sampledToken: 13)])
        XCTAssertEqual(model.forwardCallCount(), 1)
        XCTAssertEqual(drafter.preparedPromptWidths(), [3])
        XCTAssertEqual(drafter.preparedHiddenWidths(), [3])
    }

    /// SPEC-048-R007 / SPEC-038 FR-CB2: a native row in an equal-length
    /// prefill group shares the group's one `[B, L]` target forward; its
    /// drafter is seeded from its own `[1, L]` slice of that forward's hidden
    /// states. Before the fix one native row sent the whole group serial.
    func testNativeRowSharesTheOrdinaryPrefillForwardOfItsGroup() async throws {
        try requireMetal()
        let descriptor = Self.bridgeDescriptor()
        let model = RuntimeBridgeFakeModel(nextTokenByInput: [12: 13, 16: 17, 20: 21], emitsMTPState: true)
        let drafter = RuntimeBridgeRecordingMTPDrafter()
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: model,
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            drafterContainer: MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(id: "mtp"),
                model: drafter
            ))
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)
        var inputs: [ContinuousBatchPrefillInput] = []
        for (id, prompt, native) in [("native", [10, 11, 12], true), ("ord-1", [14, 15, 16], false), ("ord-2", [18, 19, 20], false)] {
            let handle = try await allocator.allocate(conversationKey: id, maxTokens: 8)
            _ = try await allocator.extend(handle, by: 3)
            inputs.append(ContinuousBatchPrefillInput(
                requestID: id,
                promptTokens: prompt,
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 3,
                isFinalChunk: true,
                nativeMTPPromptPrefill: native
            ))
        }
        XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward(inputs))

        let output = try await backend.prefill(rows: inputs)

        XCTAssertEqual(output, [
            ContinuousBatchPrefillOutput(requestID: "native", sampledToken: 13),
            ContinuousBatchPrefillOutput(requestID: "ord-1", sampledToken: 17),
            ContinuousBatchPrefillOutput(requestID: "ord-2", sampledToken: 21),
        ])
        XCTAssertEqual(model.forwardCallCount(), 1, "the group must run one shared forward")
        XCTAssertEqual(drafter.preparedPromptWidths(), [3])
        XCTAssertEqual(drafter.preparedHiddenWidths(), [3])
        XCTAssertEqual(backend.retainedRowCountForTest(), 3)
    }

    /// A native row whose drafter cannot be seeded after the shared forward
    /// fails alone; its peers keep the shared forward's results.
    func testNativeDrafterSeedFailureAfterSharedPrefillFailsOnlyThatRow() async throws {
        try requireMetal()
        let descriptor = Self.bridgeDescriptor()
        let model = RuntimeBridgeFakeModel(nextTokenByInput: [12: 13, 16: 17], emitsMTPState: true)
        let drafter = RuntimeBridgeRecordingMTPDrafter()
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: model,
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            drafterContainer: MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(id: "mtp"),
                model: drafter
            ))
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)
        var inputs: [ContinuousBatchPrefillInput] = []
        for (id, prompt, native) in [("native", [10, 11, 12], true), ("ord", [14, 15, 16], false)] {
            let handle = try await allocator.allocate(conversationKey: id, maxTokens: 8)
            _ = try await allocator.extend(handle, by: 3)
            inputs.append(ContinuousBatchPrefillInput(
                requestID: id,
                promptTokens: prompt,
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 3,
                isFinalChunk: true,
                // A final native chunk without its sampled first token has
                // no tail token to seed the drafter with.
                sampleFirstToken: !native,
                nativeMTPPromptPrefill: native
            ))
        }

        let output = try await backend.prefill(rows: inputs)

        XCTAssertEqual(output, [
            ContinuousBatchPrefillOutput(requestID: "native", failureCode: "continuous_batching_prefill_failed"),
            ContinuousBatchPrefillOutput(requestID: "ord", sampledToken: 17),
        ])
        XCTAssertEqual(model.forwardCallCount(), 1)
        XCTAssertEqual(drafter.preparedPromptWidths(), [])
        XCTAssertEqual(backend.retainedRowCountForTest(), 1)
    }

    /// The R014 mixed-row failure, in miniature: with a real hybrid target,
    /// an equal-length group holding one native row must leave every row,
    /// the native one included, with exactly the target state of the same
    /// group prefilled with MTP off. Greedy decode continued from both
    /// prefills emits identical tokens on every row.
    func testRealQwen35NativeRowInSharedPrefillGroupMatchesMTPDisabledGroup() async throws {
        try requireMetal()
        let prompts = [11, 12, 13].map { Self.tinyPrompt(length: 12, salt: $0) }
        let ids = ["native", "ord-1", "ord-2"]
        let steps = 8

        func run(nativeRow: Bool) async throws -> [String: [Int]] {
            let tiny = try Self.tinyQwen35Native()
            let backend = tiny.backend.base
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
            var handles: [PagedKVBlockTableHandle] = []
            var inputs: [ContinuousBatchPrefillInput] = []
            for (index, id) in ids.enumerated() {
                let handle = try await allocator.allocate(conversationKey: id, maxTokens: 32)
                _ = try await allocator.extend(handle, by: prompts[index].count)
                handles.append(handle)
                inputs.append(ContinuousBatchPrefillInput(
                    requestID: id,
                    promptTokens: prompts[index],
                    binding: try await allocator.binding(for: handle),
                    promptTokenOffset: 0,
                    committedKVTokenCount: 0,
                    targetKVTokenCount: prompts[index].count,
                    isFinalChunk: true,
                    nativeMTPPromptPrefill: nativeRow && index == 0
                ))
            }
            XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward(inputs))
            let prefill = try await backend.prefill(rows: inputs)
            var tokens: [String: [Int]] = [:]
            for output in prefill {
                tokens[output.requestID] = [try XCTUnwrap(output.sampledToken, output.failureCode ?? "")]
            }
            if nativeRow {
                XCTAssertNotNil(backend.nativeMTPDrafterSnapshotForTest(requestID: "native").state)
            }
            for step in 0 ..< steps {
                var decodeInputs: [ContinuousBatchDecodeInput] = []
                for (index, id) in ids.enumerated() {
                    decodeInputs.append(try await Self.decodeInput(
                        requestID: id,
                        currentToken: try XCTUnwrap(tokens[id]?.last),
                        handle: handles[index],
                        allocator: allocator,
                        committedKVTokenCount: prompts[index].count + step
                    ))
                }
                let outcomes = try await backend.decode(rows: decodeInputs)
                for handle in handles {
                    try await allocator.endDecodeStep(handle)
                }
                for (id, token) in Self.tokens(from: outcomes) {
                    tokens[id, default: []].append(token)
                }
            }
            return tokens
        }

        let ordinary = try await run(nativeRow: false)
        let mixed = try await run(nativeRow: true)
        for id in ids {
            XCTAssertEqual(ordinary[id]?.count, steps + 1, id)
            XCTAssertEqual(mixed[id], ordinary[id], "\(id) diverged from the MTP-disabled group")
        }
    }

    /// SPEC-038 FR-CB2 ragged shared prefill on a real (tiny, random-weight)
    /// hybrid Qwen3.5: rows at different prompt offsets share `[B, L]`
    /// forwards, including a group whose length is one row's short final
    /// chunk. Every row must sample the same first token and greedy decode as
    /// when each row is prefilled alone over the identical chunk partition;
    /// the decode phase is the same three-row batch in both runs.
    func testRealQwen35RaggedSharedPrefillMatchesPerRowPrefill() async throws {
        try requireMetal()
        let configuration = try JSONDecoder().decode(
            Qwen35TextConfiguration.self,
            from: Data(Self.tinyQwen35HybridConfiguration.utf8)
        )
        MLXRandom.seed(1906)
        let target = Qwen35TextModel(configuration)
        eval(target)
        let ids = ["a", "b", "c"]
        let prompts = [12, 9, 7].enumerated().map { Self.tinyPrompt(length: $0.element, salt: 40 + $0.offset) }
        typealias Chunk = (row: Int, start: Int, end: Int)
        let plan: [[Chunk]] = [
            [(0, 0, 4)],
            [(0, 4, 8), (1, 0, 4)],
            [(0, 8, 11), (1, 4, 7), (2, 0, 3)],
            [(0, 11, 12), (1, 7, 8), (2, 3, 4)],
            [(1, 8, 9), (2, 4, 5)],
            [(2, 5, 7)],
        ]
        let alone: [[Chunk]] = (0 ..< ids.count).flatMap { row in
            plan.flatMap { $0 }.filter { $0.row == row }.map { [$0] }
        }
        let steps = 6

        func run(_ calls: [[Chunk]]) async throws -> [String: [Int]] {
            let descriptor = Self.bridgeDescriptor(maxPhysicalBlocks: 64)
            let backend = PagedKVSharedForwardBackend(
                container: ModelContainer(context: ModelContext(
                    configuration: ModelConfiguration(id: descriptor.modelID),
                    model: target,
                    processor: StandInUserInputProcessor(),
                    tokenizer: RuntimeBridgeFakeTokenizer()
                )),
                descriptor: descriptor,
                layerCount: 2,
                cacheKinds: [.recurrentMamba, .pagedAttention]
            )
            XCTAssertTrue(backend.supportsRaggedPrefillOffsets)
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
            var handles: [PagedKVBlockTableHandle] = []
            for id in ids {
                handles.append(try await allocator.allocate(conversationKey: id, maxTokens: 32))
            }
            var tokens: [String: [Int]] = [:]
            for call in calls {
                var inputs: [ContinuousBatchPrefillInput] = []
                for chunk in call {
                    _ = try await allocator.extend(handles[chunk.row], by: chunk.end - chunk.start)
                    inputs.append(ContinuousBatchPrefillInput(
                        requestID: ids[chunk.row],
                        promptTokens: Array(prompts[chunk.row][chunk.start ..< chunk.end]),
                        binding: try await allocator.binding(for: handles[chunk.row]),
                        promptTokenOffset: chunk.start,
                        committedKVTokenCount: chunk.start,
                        targetKVTokenCount: chunk.end,
                        isFinalChunk: chunk.end == prompts[chunk.row].count
                    ))
                }
                XCTAssertEqual(PagedKVSharedForwardBackend.canSharePrefillForward(inputs), inputs.count > 1)
                for output in try await backend.prefill(rows: inputs) {
                    XCTAssertNil(output.failureCode, output.requestID)
                    if let token = output.sampledToken {
                        tokens[output.requestID] = [token]
                    }
                }
            }
            for step in 0 ..< steps {
                var decodeInputs: [ContinuousBatchDecodeInput] = []
                for (index, id) in ids.enumerated() {
                    decodeInputs.append(try await Self.decodeInput(
                        requestID: id,
                        currentToken: try XCTUnwrap(tokens[id]?.last, id),
                        handle: handles[index],
                        allocator: allocator,
                        committedKVTokenCount: prompts[index].count + step
                    ))
                }
                let outcomes = try await backend.decode(rows: decodeInputs)
                for handle in handles {
                    try await allocator.endDecodeStep(handle)
                }
                for (id, token) in Self.tokens(from: outcomes) {
                    tokens[id, default: []].append(token)
                }
            }
            return tokens
        }

        let shared = try await run(plan)
        let isolated = try await run(alone)
        for id in ids {
            XCTAssertEqual(shared[id]?.count, steps + 1, id)
            XCTAssertEqual(shared[id], isolated[id], "\(id) ragged shared prefill diverged from per-row prefill")
        }
    }

    func testSharedPrefillCompatibilityAllowsRaggedOffsetsWithOneChunkLength() async throws {
        // Six 16-token handles reserve four 4-token blocks each.
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 32)
        func input(_ id: String, offset: Int, length: Int, native: Bool = false, committed: Int? = nil)
            async throws -> ContinuousBatchPrefillInput
        {
            let handle = try await allocator.allocate(conversationKey: id, maxTokens: 16)
            _ = try await allocator.extend(handle, by: offset + length)
            return ContinuousBatchPrefillInput(
                requestID: id,
                promptTokens: Array(repeating: 1, count: length),
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: offset,
                committedKVTokenCount: committed ?? offset,
                targetKVTokenCount: (committed ?? offset) + length,
                isFinalChunk: false,
                nativeMTPPromptPrefill: native
            )
        }
        let atZero = try await input("a", offset: 0, length: 3)
        let atFour = try await input("b", offset: 4, length: 3)
        let shorter = try await input("c", offset: 4, length: 2)
        let nativeAtFour = try await input("d", offset: 4, length: 3, native: true)
        let nativeAtZero = try await input("e", offset: 0, length: 3, native: true)
        let lagging = try await input("f", offset: 4, length: 3, committed: 2)

        XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, atFour]))
        XCTAssertTrue(PagedKVSharedForwardBackend.hasRaggedPromptOffsets([atZero, atFour]))
        XCTAssertFalse(PagedKVSharedForwardBackend.canSharePrefillForward([atZero]))
        XCTAssertFalse(PagedKVSharedForwardBackend.canSharePrefillForward([atFour, shorter]))
        XCTAssertFalse(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, nativeAtFour]))
        XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, nativeAtZero]))
        XCTAssertFalse(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, lagging]))
    }

    func testRaggedPrefillMaskIsPerRowCausalAndHidesShorterRowPadding() throws {
        try requireMetal()
        let mask = PagedKVRaggedPrefillMask.make(queryTokens: 2, rowOffsets: [0, 3], windowSize: nil)
        XCTAssertEqual(mask.shape, [2, 1, 2, 5])
        XCTAssertEqual(mask.asType(.int32).asArray(Int32.self), [
            // Row 0 holds keys 0..<2; keys 2..<5 are padding.
            1, 0, 0, 0, 0,
            1, 1, 0, 0, 0,
            // Row 1 holds keys 0..<5; query q sits at position 3 + q.
            1, 1, 1, 1, 0,
            1, 1, 1, 1, 1,
        ])
        let windowed = PagedKVRaggedPrefillMask.make(queryTokens: 2, rowOffsets: [0, 3], windowSize: 2)
        XCTAssertEqual(windowed.asType(.int32).asArray(Int32.self), [
            1, 0, 0, 0, 0,
            1, 1, 0, 0, 0,
            0, 0, 1, 1, 0,
            0, 0, 0, 1, 1,
        ])
    }

    /// SPEC-048-R009 (G7): a keyed native row on a hybrid runtime that
    /// commits keyed rows in serial format hands back the same terminal
    /// conversation-cache entry as the ordinary row: same tokens, same token
    /// count, byte-identical attention KV and recurrent checkpoints. Serving
    /// a cache-only miss natively therefore changes no cache outcome.
    func testKeyedNativeRowCommitsTheOrdinarySerialConversationCacheEntry() async throws {
        try requireMetal()
        let prompt = Self.tinyPrompt(length: 12, salt: 21)
        let budget = 10

        func run(_ path: DecodePath) async throws -> ContinuousBatchSchedulerResult {
            let tiny = try Self.tinyQwen35Native(dtype: .bfloat16)
            let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: tiny.backend, maxPhysicalBlocks: 64)
            let result = try await scheduler.submit(ContinuousBatchSchedulerRequest(
                id: "keyed",
                conversationKey: "conv:auto-prefix",
                promptTokens: prompt,
                maxOutputTokens: budget,
                samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: "keyed"),
                temperature: 0,
                topP: 1,
                recurrentCheckpointPositions: [4, 8],
                modelHasRecurrentLayers: true,
                decodePath: path,
                nativeMTPMaximumProposalDepth: path == .nativeMTP ? 1 : 0,
                nativeMTPCompleteWindowBytesByDepth: path == .nativeMTP ? [16, 16] : [],
                nativeMTPTupleFence: path == .nativeMTP ? Self.nativeMTPFence() : nil
            ))
            if path == .nativeMTP {
                XCTAssertTrue(
                    tiny.backend.finalizedRounds().flatMap { $0 }.contains { $0.proposalTokenCount == 1 },
                    "the keyed native row never verified a proposal"
                )
            }
            return result
        }

        let ordinary = try await run(.ordinary)
        let native = try await run(.nativeMTP)
        XCTAssertEqual(native.generatedTokens, ordinary.generatedTokens)
        let ordinaryCache = try XCTUnwrap(ordinary.serialConversationCache, "ordinary row published no entry")
        let nativeCache = try XCTUnwrap(native.serialConversationCache, "native row published no entry")
        XCTAssertEqual(nativeCache.tokenCount, ordinaryCache.tokenCount)
        XCTAssertEqual(nativeCache.layers.count, ordinaryCache.layers.count)
        for (index, (lhs, rhs)) in zip(nativeCache.layers, ordinaryCache.layers).enumerated() {
            XCTAssertEqual(lhs.state.count, rhs.state.count, "layer \(index)")
            for (a, b) in zip(lhs.state, rhs.state) {
                XCTAssertTrue(arrayEqual(a, b).item(Bool.self), "layer \(index) KV differs")
            }
        }
        XCTAssertEqual(
            nativeCache.recurrentCheckpoints.map(\.tokenCount),
            ordinaryCache.recurrentCheckpoints.map(\.tokenCount)
        )
        for (lhs, rhs) in zip(nativeCache.recurrentCheckpoints, ordinaryCache.recurrentCheckpoints) {
            XCTAssertEqual(Set(lhs.states.keys), Set(rhs.states.keys))
            for (layer, arrays) in lhs.states {
                let other = try XCTUnwrap(rhs.states[layer])
                XCTAssertEqual(arrays.count, other.count)
                for (a, b) in zip(arrays, other) {
                    XCTAssertTrue(
                        arrayEqual(a, b).item(Bool.self),
                        "checkpoint \(lhs.tokenCount) layer \(layer) differs"
                    )
                }
            }
        }
    }

    /// End to end through the scheduler with a real (tiny, random-weight)
    /// hybrid Qwen3.5 target and its real MTP drafter: every native round is
    /// one packed verify, one staged target commit, and one packed drafter
    /// advance. Rows with different prompt lengths, depth-one rows beside a
    /// forced depth-zero row and an ordinary row, a row that leaves early, a
    /// row that joins mid-flight, and a row cancelled mid-flight must each
    /// emit exactly the serial ordinary greedy tokens for their own prompt.
    func testRealQwen35PackedNativeMTPRowsMatchSerialOrdinaryGreedy() async throws {
        try requireMetal()

        let configuration = try JSONDecoder().decode(
            Qwen35TextConfiguration.self,
            from: Data(Self.tinyQwen35HybridConfiguration.utf8)
        )
        MLXRandom.seed(1770)
        let target = Qwen35TextModel(configuration)
        let drafter = Qwen35MTPDraftModel(configuration)
        eval(target, drafter)

        func serialGreedy(_ prompt: [Int], count: Int) -> [Int] {
            let cache = target.newCache(parameters: nil)
            var logits = target(MLXArray(prompt.map(Int32.init)).reshaped(1, prompt.count), cache: cache)
            var tokens: [Int] = []
            for _ in 0 ..< count {
                let next = argMax(logits[0, -1], axis: -1).item(Int.self)
                tokens.append(next)
                logits = target(MLXArray([Int32(next)]).reshaped(1, 1), cache: cache)
            }
            return tokens
        }

        let descriptor = Self.bridgeDescriptor(maxPhysicalBlocks: 64)
        let backend = RuntimeBridgeRecordingNativeMTPBackend(PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: target,
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention],
            drafterContainer: MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(id: "mtp"),
                model: drafter
            ))
        ))
        let scheduler = try Self.makeScheduler(maxActiveRows: 6, backend: backend, maxPhysicalBlocks: 64)
        let fence = Self.nativeMTPFence()
        func native(_ id: String, _ prompt: [Int], _ maxTokens: Int, forcedDepthZero: Bool = false)
            -> ContinuousBatchSchedulerRequest
        {
            ContinuousBatchSchedulerRequest(
                id: id,
                conversationKey: "",
                promptTokens: prompt,
                maxOutputTokens: maxTokens,
                samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
                temperature: 0,
                topP: 1,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPCompleteWindowBytesByDepth: [16, 16],
                nativeMTPTupleFence: fence,
                nativeMTPAdaptationDirective: forcedDepthZero
                    ? NativeMTPAdaptationDirective(generation: 1, forcedDepth: 0, runtimeFailureReason: nil)
                    : nil
            )
        }

        let prompts: [String: [Int]] = [
            "long": [1, 5, 2, 7, 3, 6, 4, 0, 2],
            "short": [3, 1],
            "zero": [6, 2, 5, 1],
            "early": [7, 7, 1, 4, 2, 6],
            "ordinary": [2, 4, 6, 1, 3],
            "joiner": [5, 0, 3],
            "cancelled": [4, 6, 0, 2, 5, 1, 7],
        ]
        let budgets = ["long": 14, "short": 12, "zero": 10, "early": 4, "ordinary": 9, "joiner": 10, "cancelled": 14]
        let joinerTask = RuntimeBridgeTaskBox()
        let longTask = Task {
            try await scheduler.submit(native("long", prompts["long"]!, budgets["long"]!)) { event in
                // A native row joins while the first cohort is mid-flight.
                if event.tokenIndex == 3 {
                    joinerTask.start {
                        try await scheduler.submit(native("joiner", prompts["joiner"]!, budgets["joiner"]!))
                    }
                }
            }
        }
        let shortTask = Task { try await scheduler.submit(native("short", prompts["short"]!, budgets["short"]!)) }
        let zeroTask = Task {
            try await scheduler.submit(native("zero", prompts["zero"]!, budgets["zero"]!, forcedDepthZero: true))
        }
        let earlyTask = Task { try await scheduler.submit(native("early", prompts["early"]!, budgets["early"]!)) }
        let ordinaryTask = Task {
            try await scheduler.submit(Self.schedulerRequest(
                id: "ordinary",
                promptTokens: prompts["ordinary"]!,
                maxOutputTokens: budgets["ordinary"]!
            ))
        }
        // Cancel one row while its packed verify is in flight, so the same
        // finalize commits the other rows and aborts this one.
        let cancelArmed = RuntimeBridgeFlag()
        let cancelFired = RuntimeBridgeFlag()
        backend.onVerify = { requestIDs in
            guard requestIDs.contains("cancelled"), requestIDs.count > 1,
                  cancelArmed.isSet, cancelFired.setIfUnset()
            else { return }
            await scheduler.cancel(requestID: "cancelled")
        }
        let cancelledTask = Task {
            try await scheduler.submit(native("cancelled", prompts["cancelled"]!, budgets["cancelled"]!)) { event in
                if event.tokenIndex == 2 {
                    _ = cancelArmed.setIfUnset()
                }
            }
        }

        var results: [String: ContinuousBatchSchedulerResult] = [:]
        results["long"] = try await longTask.value
        // Fallback so a failing run reports instead of waiting forever; the
        // mid-flight join itself is asserted below.
        let joinedMidFlight = joinerTask.isStarted
        joinerTask.start {
            try await scheduler.submit(native("joiner", prompts["joiner"]!, budgets["joiner"]!))
        }
        results["short"] = try await shortTask.value
        results["zero"] = try await zeroTask.value
        results["early"] = try await earlyTask.value
        results["ordinary"] = try await ordinaryTask.value
        results["cancelled"] = try await cancelledTask.value
        results["joiner"] = try await joinerTask.value()

        for id in ["long", "short", "zero", "early", "ordinary", "joiner"] {
            let result = try XCTUnwrap(results[id])
            XCTAssertEqual(result.terminalStatus, .length, id)
            XCTAssertEqual(
                result.generatedTokens,
                serialGreedy(prompts[id]!, count: budgets[id]!),
                "\(id) diverged from serial ordinary greedy"
            )
        }
        XCTAssertTrue(joinedMidFlight, "joiner must be admitted while the first cohort is decoding")
        let cancelled = try XCTUnwrap(results["cancelled"])
        XCTAssertEqual(cancelled.terminalStatus, .cancelled)
        XCTAssertLessThan(cancelled.generatedTokens.count, budgets["cancelled"]!)
        XCTAssertEqual(
            cancelled.generatedTokens,
            Array(serialGreedy(prompts["cancelled"]!, count: budgets["cancelled"]!)
                .prefix(cancelled.generatedTokens.count))
        )

        // The run exercised packed rounds with several native rows, accepted
        // and rejected proposals, and depth-zero rows beside depth-one rows.
        let finalized = backend.finalizedRounds()
        let committed = finalized.flatMap { $0 }.filter(\.shouldCommit)
        XCTAssertGreaterThan(finalized.map(\.count).max() ?? 0, 2)
        XCTAssertTrue(committed.contains { $0.proposalTokenCount == 1 && $0.committedProposalTokenCount == 1 })
        XCTAssertTrue(committed.contains { $0.proposalTokenCount == 1 && $0.committedProposalTokenCount == 0 })
        XCTAssertTrue(finalized.contains { round in
            round.contains { $0.proposalTokenCount == 0 } && round.contains { $0.proposalTokenCount == 1 }
        })
        XCTAssertTrue(cancelFired.isSet)
        XCTAssertTrue(finalized.contains { round in
            round.contains { $0.requestID == "cancelled" && !$0.shouldCommit && $0.acceptedTokenIDs.isEmpty }
                && round.contains { $0.requestID != "cancelled" && $0.shouldCommit }
        }, "cancellation must abort only the cancelled row inside a committing round")
        XCTAssertEqual(backend.base.retainedRowCountForTest(), 0)
    }

    private struct TinyQwen35Native {
        let target: Qwen35TextModel
        let drafter: Qwen35MTPDraftModel
        let backend: RuntimeBridgeRecordingNativeMTPBackend
    }

    /// A tiny random-weight hybrid Qwen3.5 target and its real MTP drafter
    /// behind the production paged backend. The same seed gives the same
    /// weights, so separate instances are independent replicas.
    private static func tinyQwen35Native(
        maxPhysicalBlocks: Int = 64,
        nativeMTPDrafterColumnCap: Int = PagedKVSharedForwardBackend.defaultNativeMTPDrafterColumnCap,
        dtype: DType? = nil
    ) throws -> TinyQwen35Native {
        let configuration = try JSONDecoder().decode(
            Qwen35TextConfiguration.self,
            from: Data(Self.tinyQwen35HybridConfiguration.utf8)
        )
        MLXRandom.seed(1770)
        let target = Qwen35TextModel(configuration)
        let drafter = Qwen35MTPDraftModel(configuration)
        if let dtype {
            // The serial conversation-cache format stores only fp16/bf16 KV.
            target.update(parameters: target.parameters().mapValues { $0.asType(dtype) })
            drafter.update(parameters: drafter.parameters().mapValues { $0.asType(dtype) })
        }
        eval(target, drafter)
        let descriptor = Self.bridgeDescriptor(maxPhysicalBlocks: maxPhysicalBlocks)
        let backend = RuntimeBridgeRecordingNativeMTPBackend(PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: target,
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 2,
            cacheKinds: [.recurrentMamba, .pagedAttention],
            drafterContainer: MTPDrafterContainer(context: MTPDrafterContext(
                configuration: ModelConfiguration(id: "mtp"),
                model: drafter
            )),
            nativeMTPDrafterColumnCap: nativeMTPDrafterColumnCap
        ))
        return TinyQwen35Native(target: target, drafter: drafter, backend: backend)
    }

    private static func tinyNativeRequest(
        _ id: String,
        _ prompt: [Int],
        _ maxTokens: Int,
        decodePath: DecodePath = .nativeMTP,
        temperature: Double = 0,
        topP: Double = 1,
        maximumActiveRows: Int = Int.max
    ) -> ContinuousBatchSchedulerRequest {
        ContinuousBatchSchedulerRequest(
            id: id,
            conversationKey: "",
            promptTokens: prompt,
            maxOutputTokens: maxTokens,
            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
            temperature: temperature,
            topP: topP,
            decodePath: decodePath,
            nativeMTPMaximumProposalDepth: decodePath == .nativeMTP ? 1 : 0,
            nativeMTPCompleteWindowBytesByDepth: decodePath == .nativeMTP ? [16, 16] : [],
            nativeMTPMaximumActiveRows: maximumActiveRows,
            nativeMTPTupleFence: decodePath == .nativeMTP ? Self.nativeMTPFence() : nil
        )
    }

    /// Deterministic pseudo-random prompt over the tiny vocabulary.
    private static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 8)
        }
    }

    /// The drafter's next proposal by definition: single-pass seeding over the
    /// whole committed sequence, with target hidden states from one serial
    /// forward. It never ran a native round, so it never went to depth zero.
    private static func definitionalDrafterSeed(
        target: Qwen35TextModel,
        drafter: Qwen35MTPDraftModel,
        prompt: [Int],
        generated: [Int]
    ) throws -> Int {
        let bonus = try XCTUnwrap(generated.last, "no committed token")
        let committed = prompt + generated.dropLast()
        var emit = LMOutput.State()
        emit[mtpEmitFlagKey] = true
        let output = target(
            LMInput.Text(tokens: MLXArray(committed.map(Int32.init)).reshaped(1, committed.count)),
            cache: target.newCache(parameters: nil),
            state: emit
        )
        var state = drafter.makeState(parameters: nil)
        drafter.prepareDrafterState(
            target: target,
            promptTokens: MLXArray(committed.map(Int32.init)).reshaped(1, committed.count),
            targetHidden: try XCTUnwrap(output.state?[mtpLastHiddenStatesKey], "target emitted no hidden"),
            firstBonus: MLXArray([Int32(bonus)]),
            positionDeltas: nil,
            state: &state,
            sampler: GenerateParameters(temperature: 0).sampler()
        )
        return try XCTUnwrap(state.seedToken, "drafter produced no seed").item(Int.self)
    }

    /// SPEC-048 chunked-prefill seeding: advancing the drafter chunk by chunk
    /// over each chunk's own hidden states (tail = next prompt token, final
    /// tail = sampled token) leaves the same drafter state and proposal as
    /// single-pass seeding of the same prompt. A later chunk with no prior
    /// drafter state at its offset fails closed.
    func testChunkedPromptPrefillSeedsTheDrafterLikeSinglePassPrefill() async throws {
        try requireMetal()
        let tiny = try Self.tinyQwen35Native()
        let backend = tiny.backend.base
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
        let prompt = Self.tinyPrompt(length: 13, salt: 1)

        func prefill(_ id: String, chunks: [Int]) async throws -> [ContinuousBatchPrefillOutput] {
            let handle = try await allocator.allocate(conversationKey: id, maxTokens: 32)
            var outputs: [ContinuousBatchPrefillOutput] = []
            var offset = 0
            for size in chunks {
                let end = offset + size
                _ = try await allocator.extend(handle, by: size)
                outputs += try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                    requestID: id,
                    promptTokens: Array(prompt[offset ..< end]),
                    binding: try await allocator.binding(for: handle),
                    promptTokenOffset: offset,
                    committedKVTokenCount: offset,
                    targetKVTokenCount: end,
                    isFinalChunk: end == prompt.count,
                    nativeMTPPromptPrefill: true,
                    nativeMTPNextPromptToken: end < prompt.count ? prompt[end] : nil
                )])
                offset = end
            }
            return outputs
        }

        let single = try await prefill("single", chunks: [13])
        let chunked = try await prefill("chunked", chunks: [5, 5, 3])
        XCTAssertEqual(single.last?.sampledToken, chunked.last?.sampledToken)
        XCTAssertNotNil(single.last?.sampledToken)

        let reference = backend.nativeMTPDrafterSnapshotForTest(requestID: "single")
        let candidate = backend.nativeMTPDrafterSnapshotForTest(requestID: "chunked")
        let referenceState = try XCTUnwrap(reference.state)
        let candidateState = try XCTUnwrap(candidate.state)
        XCTAssertEqual(candidateState.nextPosition, prompt.count)
        XCTAssertEqual(candidateState.nextPosition, referenceState.nextPosition)
        XCTAssertEqual(candidate.seedToken, reference.seedToken)
        XCTAssertNotNil(candidate.seedToken)
        XCTAssertEqual(candidate.pendingColumns, 0)
        XCTAssertEqual(candidateState.cache.count, referenceState.cache.count)
        for (lhs, rhs) in zip(candidateState.cache, referenceState.cache) {
            XCTAssertEqual(lhs.offset, rhs.offset)
            for (a, b) in zip(lhs.state, rhs.state) {
                XCTAssertEqual(a.shape, b.shape)
                // Documented tolerance: the chunked advance runs the packed
                // drafter kernels (array mask, per-row RoPE offsets) instead
                // of single-pass causal attention; values agree to float32
                // accumulation order.
                let maxDifference = abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
                XCTAssertLessThanOrEqual(maxDifference, 1e-4)
            }
        }

        // A non-initial chunk without the previous chunk's drafter state is
        // refused rather than seeded from a partial prompt.
        let orphan = try await allocator.allocate(conversationKey: "orphan", maxTokens: 32)
        _ = try await allocator.extend(orphan, by: 10)
        let refused = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
            requestID: "orphan",
            promptTokens: Array(prompt[5 ..< 10]),
            binding: try await allocator.binding(for: orphan),
            promptTokenOffset: 5,
            committedKVTokenCount: 5,
            targetKVTokenCount: 10,
            isFinalChunk: false,
            nativeMTPPromptPrefill: true,
            nativeMTPNextPromptToken: prompt[10]
        )])
        XCTAssertEqual(refused.first?.failureCode, "continuous_batching_prefill_failed")
    }

    /// Native prompts longer than one prefill chunk are served natively and
    /// emit exactly the ordinary path's greedy tokens at 1.5k, 4k, and 8k.
    func testChunkedNativePromptsKeepGreedyParityWithOrdinaryAtLongLengths() async throws {
        try requireMetal()
        let tiny = try Self.tinyQwen35Native(maxPhysicalBlocks: 8192)
        let scheduler = try Self.makeScheduler(
            maxActiveRows: 6,
            backend: tiny.backend,
            maxPhysicalBlocks: 8192,
            maxPromptChunkTokens: 512
        )
        let lengths = [1536, 4096, 8192]
        var tasks: [String: Task<ContinuousBatchSchedulerResult, any Error>] = [:]
        for length in lengths {
            let prompt = Self.tinyPrompt(length: length, salt: length)
            tasks["native-\(length)"] = Task {
                try await scheduler.submit(Self.tinyNativeRequest("native-\(length)", prompt, 12))
            }
            tasks["ordinary-\(length)"] = Task {
                try await scheduler.submit(Self.tinyNativeRequest(
                    "ordinary-\(length)", prompt, 12, decodePath: .ordinary
                ))
            }
        }
        var results: [String: ContinuousBatchSchedulerResult] = [:]
        for (id, task) in tasks {
            results[id] = try await task.value
        }
        let committed = tiny.backend.finalizedRounds().flatMap { $0 }.filter(\.shouldCommit)
        for length in lengths {
            let native = try XCTUnwrap(results["native-\(length)"])
            let ordinary = try XCTUnwrap(results["ordinary-\(length)"])
            XCTAssertEqual(native.terminalStatus, .length, "\(length)")
            XCTAssertEqual(native.generatedTokens.count, 12, "\(length)")
            XCTAssertEqual(native.generatedTokens, ordinary.generatedTokens, "native \(length) diverged from ordinary")
            XCTAssertTrue(
                committed.contains { $0.requestID == "native-\(length)" && $0.proposalTokenCount == 1 },
                "native-\(length) never verified a drafter proposal"
            )
        }
        XCTAssertEqual(tiny.backend.base.retainedRowCountForTest(), 0)
    }

    /// SPEC-048-R007 load gate: while an ordinary row holds the runtime above
    /// a native row's bound, the native row rides the ordinary lockstep
    /// forward (no native verify at depth zero), emits the ordinary tokens,
    /// and on restore its drafter has consumed every committed column: each
    /// proposal equals the definitional single-pass seed for its prefix, as
    /// it does in a run that never went to depth zero.
    func testLoadGatedNativeRowRidesOrdinaryForwardAndRestoresDrafterState() async throws {
        try requireMetal()
        let prompt = Self.tinyPrompt(length: 11, salt: 7)
        let budget = 40

        // Reference: the same row alone, never gated.
        let reference = try Self.tinyQwen35Native()
        let referenceScheduler = try Self.makeScheduler(maxActiveRows: 2, backend: reference.backend, maxPhysicalBlocks: 64)
        // Sampling keeps this tiny random model's stream from collapsing to
        // one repeated token, so proposals vary across steps.
        let referenceResult = try await referenceScheduler.submit(
            Self.tinyNativeRequest("a", prompt, budget, temperature: 0.8)
        )
        XCTAssertTrue(reference.backend.capturedDecodeStepsByRow().isEmpty)

        let gated = try Self.tinyQwen35Native()
        let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: gated.backend, maxPhysicalBlocks: 64)
        let peerPrompt = Self.tinyPrompt(length: 6, salt: 9)
        let peer = RuntimeBridgeTaskBox()
        let gatedResult = try await scheduler.submit(
            Self.tinyNativeRequest("a", prompt, budget, temperature: 0.8, maximumActiveRows: 1)
        ) { event in
            if event.tokenIndex == 3 {
                peer.start {
                    try await scheduler.submit(Self.tinyNativeRequest(
                        "peer", peerPrompt, 6, decodePath: .ordinary
                    ))
                }
            }
        }
        let peerResult = try await peer.value()

        XCTAssertEqual(gatedResult.terminalStatus, .length, gatedResult.errorCode ?? "")
        XCTAssertEqual(peerResult.terminalStatus, .length, peerResult.errorCode ?? "")
        XCTAssertEqual(gatedResult.generatedTokens, referenceResult.generatedTokens)
        XCTAssertEqual(peerResult.generatedTokens.count, 6)
        let ordinary = try Self.tinyQwen35Native()
        let ordinaryResult = try await Self.makeScheduler(
            maxActiveRows: 2, backend: ordinary.backend, maxPhysicalBlocks: 64
        ).submit(Self.tinyNativeRequest("a", prompt, budget, decodePath: .ordinary, temperature: 0.8))
        XCTAssertEqual(gatedResult.generatedTokens, ordinaryResult.generatedTokens)

        let fusedSteps = gated.backend.capturedDecodeStepsByRow()["a"] ?? []
        XCTAssertGreaterThanOrEqual(
            fusedSteps.count,
            ContinuousBatchScheduler.nativeMTPLoadGateReleaseRounds + 1,
            "gate never held the native row on the ordinary forward"
        )
        let lastFusedStep = try XCTUnwrap(fusedSteps.max())
        // No native round verified at depth zero while gated: the only
        // depth-zero verifies are the budget-bound tail rounds the never-gated
        // run also has.
        func depthZeroVerifies(_ backend: RuntimeBridgeRecordingNativeMTPBackend) -> Int {
            backend.finalizedRounds().flatMap { $0 }
                .filter { $0.requestID == "a" && $0.proposalTokenCount == 0 }.count
        }
        XCTAssertLessThanOrEqual(depthZeroVerifies(gated.backend), depthZeroVerifies(reference.backend))

        let tokens = gatedResult.generatedTokens
        XCTAssertGreaterThan(Set(tokens).count, 2, "degenerate stream: \(tokens)")
        func definitional(_ step: Int) throws -> Int {
            try Self.definitionalDrafterSeed(
                target: gated.target,
                drafter: gated.drafter,
                prompt: prompt,
                generated: Array(tokens.prefix(step))
            )
        }
        let gatedProposals = gated.backend.proposalsByStep()["a"] ?? [:]
        let restored = gatedProposals.filter { $0.key > lastFusedStep }
        XCTAssertGreaterThanOrEqual(restored.count, 5, "native proposals did not resume: \(gatedProposals)")
        XCTAssertGreaterThan(Set(restored.values.map { $0 }).count, 1, "degenerate proposals: \(restored)")
        for (step, proposal) in gatedProposals.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(proposal, [try definitional(step)], "gated run proposal at step \(step)")
        }
        for (step, proposal) in (reference.backend.proposalsByStep()["a"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(proposal, [try definitional(step)], "reference proposal at step \(step)")
            if let gatedProposal = gatedProposals[step] {
                XCTAssertEqual(gatedProposal, proposal, "restored proposal differs from never-gated at step \(step)")
            }
        }
        XCTAssertEqual(gated.backend.base.retainedRowCountForTest(), 0)
    }

    /// SPEC-048 R015 gated cells: a native row the load gate holds until it
    /// finishes never advances its drafter while it rides the ordinary
    /// forward, however many rounds it is held, so the gate adds no drafter
    /// forward to the shared rounds. Its columns stay buffered for a restore
    /// that never comes, and its tokens are the ordinary path's.
    func testHeldNativeRowBuffersColumnsWithoutAdvancingItsDrafter() async throws {
        try requireMetal()
        let prompt = Self.tinyPrompt(length: 11, salt: 7)
        let budget = 90
        let gated = try Self.tinyQwen35Native(maxPhysicalBlocks: 256)
        let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: gated.backend, maxPhysicalBlocks: 256)
        let peer = RuntimeBridgeTaskBox()
        let pendingAtStep = RuntimeBridgePendingColumnsBox()
        let gatedResult = try await scheduler.submit(
            Self.tinyNativeRequest("a", prompt, budget, temperature: 0.8, maximumActiveRows: 1)
        ) { event in
            if event.tokenIndex == 3 {
                peer.start {
                    try await scheduler.submit(Self.tinyNativeRequest(
                        "peer", Self.tinyPrompt(length: 6, salt: 9), budget + 20, decodePath: .ordinary
                    ))
                }
            }
            if event.tokenIndex == budget - 5 {
                pendingAtStep.record(gated.backend.base.nativeMTPDrafterSnapshotForTest(requestID: "a").pendingColumns)
            }
        }
        let peerResult = try await peer.value()
        XCTAssertEqual(gatedResult.terminalStatus, .length, gatedResult.errorCode ?? "")
        XCTAssertEqual(peerResult.terminalStatus, .length, peerResult.errorCode ?? "")

        let fusedSteps = gated.backend.capturedDecodeStepsByRow()["a"] ?? []
        XCTAssertGreaterThan(fusedSteps.count, 64, "row was not held past the old flush threshold")
        // Every held column is still buffered: none was fed to the drafter.
        let pending = try XCTUnwrap(pendingAtStep.value())
        XCTAssertGreaterThan(pending, 64)
        XCTAssertLessThanOrEqual(pending, fusedSteps.count)

        let ordinary = try Self.tinyQwen35Native(maxPhysicalBlocks: 256)
        let ordinaryResult = try await Self.makeScheduler(
            maxActiveRows: 2, backend: ordinary.backend, maxPhysicalBlocks: 256
        ).submit(Self.tinyNativeRequest("a", prompt, budget, decodePath: .ordinary, temperature: 0.8))
        XCTAssertEqual(gatedResult.generatedTokens, ordinaryResult.generatedTokens)
        XCTAssertEqual(gated.backend.base.retainedRowCountForTest(), 0)
        XCTAssertEqual(gated.backend.base.nativeMTPDrafterSnapshotForTest(requestID: "a").pendingColumns, 0)
    }

    /// A held row's buffer never passes the column cap: a row about to pass
    /// it catches its drafter up early, inside the ordinary round. The early
    /// catch-up changes nothing the row commits or proposes: its tokens are
    /// the ordinary path's and the uncapped run's, and every proposal after
    /// it restores is the drafter's definitional seed for that prefix.
    func testHeldNativeRowCatchesUpItsDrafterAtTheColumnCap() async throws {
        try requireMetal()
        let prompt = Self.tinyPrompt(length: 11, salt: 7)
        let budget = 90
        let cap = 8
        func heldRun(cap: Int) async throws -> (TinyQwen35Native, ContinuousBatchSchedulerResult, Int) {
            let gated = try Self.tinyQwen35Native(maxPhysicalBlocks: 256, nativeMTPDrafterColumnCap: cap)
            let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: gated.backend, maxPhysicalBlocks: 256)
            let peer = RuntimeBridgeTaskBox()
            let maxPending = RuntimeBridgePendingColumnsBox()
            let result = try await scheduler.submit(
                Self.tinyNativeRequest("a", prompt, budget, temperature: 0.8, maximumActiveRows: 1)
            ) { event in
                if event.tokenIndex == 3 {
                    peer.start {
                        try await scheduler.submit(Self.tinyNativeRequest(
                            "peer", Self.tinyPrompt(length: 6, salt: 9), 50, decodePath: .ordinary
                        ))
                    }
                }
                let pending = gated.backend.base.nativeMTPDrafterSnapshotForTest(requestID: "a").pendingColumns
                maxPending.record(max(maxPending.value() ?? 0, pending))
            }
            let peerResult = try await peer.value()
            XCTAssertEqual(result.terminalStatus, .length, result.errorCode ?? "")
            XCTAssertEqual(peerResult.terminalStatus, .length, peerResult.errorCode ?? "")
            return (gated, result, maxPending.value() ?? 0)
        }

        let (capped, cappedResult, cappedMaxPending) = try await heldRun(cap: cap)
        let fusedSteps = capped.backend.capturedDecodeStepsByRow()["a"] ?? []
        XCTAssertGreaterThan(fusedSteps.count, 3 * cap, "row was not held long enough to reach the cap")
        XCTAssertLessThanOrEqual(cappedMaxPending, cap)
        XCTAssertGreaterThanOrEqual(cappedMaxPending, cap / 2, "buffer never filled toward the cap")

        let (_, uncappedResult, uncappedMaxPending) = try await heldRun(
            cap: PagedKVSharedForwardBackend.defaultNativeMTPDrafterColumnCap
        )
        XCTAssertGreaterThan(uncappedMaxPending, cap, "uncapped run did not exceed the test cap")
        XCTAssertEqual(cappedResult.generatedTokens, uncappedResult.generatedTokens)

        let ordinary = try Self.tinyQwen35Native(maxPhysicalBlocks: 256)
        let ordinaryResult = try await Self.makeScheduler(
            maxActiveRows: 2, backend: ordinary.backend, maxPhysicalBlocks: 256
        ).submit(Self.tinyNativeRequest("a", prompt, budget, decodePath: .ordinary, temperature: 0.8))
        XCTAssertEqual(cappedResult.generatedTokens, ordinaryResult.generatedTokens)

        let tokens = cappedResult.generatedTokens
        let lastFusedStep = try XCTUnwrap(fusedSteps.max())
        let proposals = capped.backend.proposalsByStep()["a"] ?? [:]
        let restored = proposals.filter { $0.key > lastFusedStep }
        XCTAssertGreaterThanOrEqual(restored.count, 5, "native proposals did not resume: \(proposals)")
        for (step, proposal) in restored.sorted(by: { $0.key < $1.key }) {
            let seed = try Self.definitionalDrafterSeed(
                target: capped.target,
                drafter: capped.drafter,
                prompt: prompt,
                generated: Array(tokens.prefix(step))
            )
            XCTAssertEqual(proposal, [seed], "restored proposal at step \(step)")
        }
        XCTAssertEqual(capped.backend.base.retainedRowCountForTest(), 0)
        XCTAssertEqual(capped.backend.base.nativeMTPDrafterSnapshotForTest(requestID: "a").pendingColumns, 0)
    }

    /// A buffered column owns its `[1, 1, hidden]` row: once evaluated, it
    /// does not keep the `[B, 1, hidden]` batch output alive, as a slice
    /// would.
    func testDetachedHiddenColumnDoesNotPinTheBatchOutput() throws {
        try requireMetal()
        let rows = 64
        let width = 2048
        let batches = 16
        let batchBytes = rows * width * 4
        func retainedBytes(_ column: (MLXArray, Int) -> MLXArray) -> (Int, [MLXArray]) {
            Stream().synchronize()
            let before = Memory.activeMemory
            var held: [MLXArray] = []
            for batch in 0 ..< batches {
                let output = (MLXArray(0 ..< (rows * width)).asType(.float32) + Float(batch))
                    .reshaped([rows, 1, width])
                let kept = column(output, 37)
                eval(kept)
                held.append(kept)
            }
            Stream().synchronize()
            return (Memory.activeMemory - before, held)
        }
        let (sliceBytes, slices) = retainedBytes { hidden, row in hidden[row ..< row + 1, (-1)..., 0...] }
        XCTAssertGreaterThanOrEqual(sliceBytes, batches * batchBytes, "the slice control no longer pins its batch")
        let (copyBytes, copies) = retainedBytes(PagedKVSharedForwardBackend.detachedHiddenColumn)
        XCTAssertLessThan(copyBytes, batchBytes, "copied columns still pin their batch outputs")
        for (copy, slice) in zip(copies, slices) {
            XCTAssertEqual(copy.shape, [1, 1, width])
            XCTAssertEqual(copy.asArray(Float.self), slice.asArray(Float.self))
        }
        XCTAssertEqual(copies[3][0, 0, 0].item(Float.self), Float(37 * width + 3))
    }

    /// SPEC-048 target-sample exact match: seeded sampled native rows (and a
    /// greedy native row beside them) emit exactly the tokens the same seeded
    /// rows emit on the ordinary path, because each verify position samples
    /// with the row's own sampler at the step ordinary decode would use.
    func testSeededSampledNativeRowsMatchSeededOrdinaryRows() async throws {
        try requireMetal()
        let rows: [(id: String, temperature: Double, topP: Double)] = [
            ("cool", 0.3, 1.0),
            ("warm", 0.7, 0.9),
            ("hot", 1.0, 1.0),
            ("greedy", 0, 1.0),
        ]
        func run(_ path: DecodePath) async throws -> (
            results: [String: ContinuousBatchSchedulerResult],
            finalized: [ContinuousBatchNativeMTPFinalizeInput]
        ) {
            let tiny = try Self.tinyQwen35Native()
            let scheduler = try Self.makeScheduler(maxActiveRows: 5, backend: tiny.backend, maxPhysicalBlocks: 64)
            var tasks: [String: Task<ContinuousBatchSchedulerResult, any Error>] = [:]
            for (index, row) in rows.enumerated() {
                let prompt = Self.tinyPrompt(length: 6 + index, salt: 30 + index)
                tasks[row.id] = Task {
                    try await scheduler.submit(Self.tinyNativeRequest(
                        row.id, prompt, 24,
                        decodePath: path,
                        temperature: row.temperature,
                        topP: row.topP
                    ))
                }
            }
            // A sampled ordinary row shares the batch in both runs.
            tasks["ordinary-sampled"] = Task {
                try await scheduler.submit(Self.tinyNativeRequest(
                    "ordinary-sampled", Self.tinyPrompt(length: 5, salt: 99), 24,
                    decodePath: .ordinary,
                    temperature: 0.8
                ))
            }
            var results: [String: ContinuousBatchSchedulerResult] = [:]
            for (id, task) in tasks {
                results[id] = try await task.value
            }
            return (results, tiny.backend.finalizedRounds().flatMap { $0 })
        }

        let ordinary = try await run(.ordinary)
        let native = try await run(.nativeMTP)
        for id in rows.map(\.id) + ["ordinary-sampled"] {
            let expected = try XCTUnwrap(ordinary.results[id])
            let actual = try XCTUnwrap(native.results[id])
            XCTAssertEqual(actual.terminalStatus, .length, id)
            XCTAssertEqual(actual.generatedTokens, expected.generatedTokens, "\(id) native diverged from seeded ordinary")
        }
        XCTAssertTrue(ordinary.finalized.isEmpty)
        let sampledCommits = native.finalized.filter {
            $0.shouldCommit && ["cool", "warm", "hot"].contains($0.requestID) && $0.proposalTokenCount == 1
        }
        XCTAssertTrue(sampledCommits.contains { $0.committedProposalTokenCount == 1 }, "no sampled acceptance exercised")
        XCTAssertTrue(sampledCommits.contains { $0.committedProposalTokenCount == 0 }, "no sampled rejection exercised")
        // Sampling differs from greedy on these rows, so the test is not
        // vacuously comparing argmax streams.
        let sampledHot = try XCTUnwrap(native.results["hot"]).generatedTokens
        let greedyHot = try await {
            let tiny = try Self.tinyQwen35Native()
            let scheduler = try Self.makeScheduler(maxActiveRows: 1, backend: tiny.backend, maxPhysicalBlocks: 64)
            return try await scheduler.submit(Self.tinyNativeRequest(
                "hot", Self.tinyPrompt(length: 8, salt: 32), 24, decodePath: .ordinary
            )).generatedTokens
        }()
        XCTAssertNotEqual(sampledHot, greedyHot)
    }

    func testNativeMTPIntegrityProbeBlocksBuyerAdmissionAndReleasesAfterCompletion() async throws {
        let prefillGate = RuntimeBridgeTestGate()
        let backend = RuntimeBridgeScriptedBackend(
            scripts: ["probe": [11], "buyer": [21, 22], "buyer-after": [31, 32]],
            nativeProposalScripts: ["probe": [[12]]],
            prefillGate: prefillGate
        )
        let scheduler = try Self.makeScheduler(maxActiveRows: 1, backend: backend)
        let fence = Self.nativeMTPFence()

        let probeTask = Task {
            try await scheduler.submitNativeMTPIntegrityProbe(Self.schedulerRequest(
                id: "probe",
                promptTokens: [10],
                maxOutputTokens: 3,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: fence,
                nativeMTPIntegrityProbe: true
            ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        do {
            _ = try await scheduler.submit(Self.schedulerRequest(
                id: "buyer",
                promptTokens: [20],
                maxOutputTokens: 2
            ))
            XCTFail("buyer admission should be rejected while integrity probe is actor-held")
        } catch {
            XCTAssertEqual(error as? ContinuousBatchSchedulerError, .backpressure)
        }

        await prefillGate.open()
        let probe = try await probeTask.value
        XCTAssertEqual(probe.terminalStatus, .length)
        XCTAssertEqual(probe.nativeMTPCounters?.acceptedTokens, 1)

        let buyerAfter = try await scheduler.submit(Self.schedulerRequest(
            id: "buyer-after",
            promptTokens: [30],
            maxOutputTokens: 2
        ))
        XCTAssertEqual(buyerAfter.terminalStatus, .length)
        XCTAssertEqual(buyerAfter.generatedTokens, [31, 32])
    }

    /// The self-test probe ID is deterministic (`native-mtp-selftest-<challenge>`)
    /// and the replay authority is durable across restarts. A probe that
    /// claimed it would find its own earlier claim after the next restart,
    /// fail as a replay, and leave the tuple unadmitted for good.
    func testNativeMTPIntegrityProbeDoesNotClaimTheDurableReplayWindow() async throws {
        let durable = RuntimeBridgeReplayAuthority()
        for restart in 0..<2 {
            let backend = RuntimeBridgeScriptedBackend(
                scripts: ["native-mtp-selftest-probe": [11]],
                nativeProposalScripts: ["native-mtp-selftest-probe": [[12]]]
            )
            let scheduler = try Self.makeScheduler(maxActiveRows: 1, backend: backend, replayAuthority: durable)
            let probe = try await scheduler.submitNativeMTPIntegrityProbe(Self.schedulerRequest(
                id: "native-mtp-selftest-probe",
                promptTokens: [10],
                maxOutputTokens: 3,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: Self.nativeMTPFence(),
                nativeMTPIntegrityProbe: true
            ))
            XCTAssertEqual(probe.terminalStatus, .length, "start \(restart)")
        }
    }

    func testNativeMTPCountersAggregateAcrossRounds() async throws {
        let backend = RuntimeBridgeScriptedBackend(
            scripts: ["multi": [11]],
            nativeProposalScripts: ["multi": [[12], [14]]]
        )
        let scheduler = try Self.makeScheduler(maxActiveRows: 1, backend: backend)
        let result = try await scheduler.submitNativeMTPIntegrityProbe(Self.schedulerRequest(
            id: "multi",
            promptTokens: [10],
            maxOutputTokens: 5,
            decodePath: .nativeMTP,
            nativeMTPMaximumProposalDepth: 1,
            nativeMTPTupleFence: Self.nativeMTPFence(),
            nativeMTPIntegrityProbe: true
        ))

        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.nativeMTPCounters?.acceptedTokens, 2)
        XCTAssertEqual(result.nativeMTPCounters?.rejectedTokens, 0)
        XCTAssertEqual(result.nativeMTPCounters?.bonusTokens, 2)
        XCTAssertEqual(result.nativeMTPCounters?.committedTokens, 4)
        let finalized = await backend.nativeFinalizeInputs()
        XCTAssertEqual(finalized.filter(\.shouldCommit).count, 2)
    }

    func testNativeMTPTupleDisableRejectsNewAndQueuedRowsAndContinuesPreoutputOrdinary() async throws {
        let prefillGate = RuntimeBridgeTestGate()
        let backend = RuntimeBridgeScriptedBackend(
            scripts: [
                "holder": [41, 42],
                "queued-native": [51],
                "preoutput": [61, 62, 63],
            ],
            nativeProposalScripts: [
                "queued-native": [[52]],
                "preoutput": [[64]],
            ],
            prefillGate: prefillGate
        )
        let scheduler = try Self.makeScheduler(maxActiveRows: 1, backend: backend)
        let fence = Self.nativeMTPFence()

        await scheduler.disableNativeMTPTuple(fence)
        do {
            _ = try await scheduler.submit(Self.schedulerRequest(
                id: "new-disabled",
                promptTokens: [50],
                maxOutputTokens: 2,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: fence
            ))
            XCTFail("new disabled tuple row should fail before admission")
        } catch {
            XCTAssertEqual(
                error as? ContinuousBatchSchedulerError,
                .requestFailed("continuous_batching_native_mtp_tuple_disabled")
            )
        }

        let activeFence = Self.nativeMTPFence(admission: String(repeating: "b", count: 64))
        let holder = Task {
            try await scheduler.submit(Self.schedulerRequest(
                id: "holder",
                promptTokens: [40],
                maxOutputTokens: 2
            ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let queued = Task {
            try await scheduler.submit(Self.schedulerRequest(
                id: "queued-native",
                promptTokens: [50],
                maxOutputTokens: 2,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: activeFence
            ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await scheduler.disableNativeMTPTuple(activeFence)
        await prefillGate.open()
        _ = try await holder.value
        let queuedResult = try await queued.value
        XCTAssertEqual(queuedResult.terminalStatus, .requestFailed)
        XCTAssertEqual(queuedResult.errorCode, "continuous_batching_native_mtp_tuple_disabled")

        let preoutputFence = Self.nativeMTPFence(admission: String(repeating: "c", count: 64))
        let preoutputGate = RuntimeBridgeTestGate()
        let preoutputBackend = RuntimeBridgeScriptedBackend(
            scripts: ["preoutput": [61, 62, 63]],
            nativeProposalScripts: ["preoutput": [[64]]],
            prefillGate: preoutputGate
        )
        let preoutputScheduler = try Self.makeScheduler(maxActiveRows: 1, backend: preoutputBackend)
        let preoutput = Task {
            try await preoutputScheduler.submit(Self.schedulerRequest(
                id: "preoutput",
                promptTokens: [60],
                maxOutputTokens: 3,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: preoutputFence
            ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await preoutputScheduler.disableNativeMTPTuple(preoutputFence)
        await preoutputGate.open()
        let preoutputResult = try await preoutput.value
        XCTAssertEqual(preoutputResult.terminalStatus, .length)
        XCTAssertNil(preoutputResult.nativeMTPCounters)
        XCTAssertEqual(preoutputResult.generatedTokens, [61, 62, 63])

        let postoutputFence = Self.nativeMTPFence(admission: String(repeating: "d", count: 64))
        let postoutputGate = RuntimeBridgeTestGate()
        let postoutputBackend = RuntimeBridgeScriptedBackend(
            scripts: ["postoutput": [71]],
            nativeProposalScripts: ["postoutput": [[72], [74]]],
            nativeVerifyGate: postoutputGate,
            nativeVerifyGateCall: 2
        )
        let postoutputScheduler = try Self.makeScheduler(maxActiveRows: 1, backend: postoutputBackend)
        let postoutput = Task {
            try await postoutputScheduler.submit(Self.schedulerRequest(
                id: "postoutput",
                promptTokens: [70],
                maxOutputTokens: 5,
                decodePath: .nativeMTP,
                nativeMTPMaximumProposalDepth: 1,
                nativeMTPTupleFence: postoutputFence
            ))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await postoutputScheduler.disableNativeMTPTuple(postoutputFence)
        await postoutputGate.open()
        let postoutputResult = try await postoutput.value
        XCTAssertEqual(postoutputResult.terminalStatus, .requestFailed)
        XCTAssertEqual(
            postoutputResult.errorCode,
            "continuous_batching_native_mtp_tuple_disabled_postoutput"
        )
        XCTAssertEqual(postoutputResult.generatedTokens, [])
    }

    func testMTPPackedCacheStagesProposalColumnsPrivatelyAndIgnoresPadding() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["mtp-a", "ordinary-b"],
            initialOffsets: [0, 0]
        )
        let result = try PagedKVSharedForwardBackend.exerciseMTPPackedCacheForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 11, queryOffset: 0, inputCount: 3, proposalCount: 2),
                MTPPackedVerificationRowMap(rowIndex: 22, queryOffset: 0, inputCount: 1, proposalCount: 0),
            ],
            width: 3
        )

        XCTAssertEqual(result.batchOffsetsBeforeUpdate, [0, 0])
        XCTAssertEqual(result.returnedKeyShape, [2, 1, 3, 1])
        XCTAssertEqual(result.rowOffsetsAfterUpdate, [0, 0])
        XCTAssertEqual(result.rowStoredTokensAfterUpdate, [0, 0])
        XCTAssertEqual(result.rowStateTokenCountsAfterUpdate, [0, 0])
        XCTAssertEqual(result.batchTokenCountBeforeFinalize, 3)
        XCTAssertEqual(result.batchTokenCountAfterFinalize, 0)
        XCTAssertEqual(result.rowStateTokenCountsAfterFinalize, [0, 0])
        XCTAssertEqual(result.maskShape, [2, 1, 3, 3])
        XCTAssertEqual(result.maskValues, [
            true, false, false,
            true, true, false,
            true, true, true,
            true, false, false,
            false, false, false,
            false, false, false,
        ])
    }

    func testMTPPackedCacheKeepsUnequalOffsetsAndReorderedRowsIndependent() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["late-row", "early-row"],
            initialOffsets: [2, 0]
        )
        let result = try PagedKVSharedForwardBackend.exerciseMTPPackedCacheForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 100, queryOffset: 2, inputCount: 2, proposalCount: 1),
                MTPPackedVerificationRowMap(rowIndex: 7, queryOffset: 0, inputCount: 1, proposalCount: 0),
            ],
            width: 2
        )

        XCTAssertEqual(result.batchOffsetsBeforeUpdate, [2, 0])
        // The host mirror the packed-verify facade validates against must
        // equal the device offsets before and after the packed write.
        XCTAssertEqual(result.hostBatchOffsetsBeforeUpdate, [2, 0])
        XCTAssertEqual(result.batchOffsetsAfterUpdate, [4, 1])
        XCTAssertEqual(result.hostBatchOffsetsAfterUpdate, [4, 1])
        XCTAssertEqual(result.rowOffsetsAfterUpdate, [2, 0])
        XCTAssertEqual(result.rowStoredTokensAfterUpdate, [0, 0])
        XCTAssertEqual(result.rowStateTokenCountsAfterFinalize, [0, 0])
        XCTAssertEqual(result.maskShape, [2, 1, 2, 4])
        XCTAssertEqual(result.maskValues, [
            true, true, true, false,
            true, true, true, true,
            true, false, false, false,
            false, false, false, false,
        ])
    }

    func testPackedTopTokenIDsMatchPerRowArgmaxInPackedOrder() throws {
        try requireMetal()

        // Row 0 has one proposal, row 1 none, row 2 one: the packed argmax must
        // return each row's proposal IDs then its bonus ID, row by row.
        let rows: [(proposalLogits: MLXArray, bonusLogits: MLXArray)] = [
            (MLXArray([Float(0), 5, 1, 0], [1, 4]), MLXArray([Float(9), 0, 0, 0], [1, 4])),
            (MLXArray.zeros([0, 4]), MLXArray([Float(0), 0, 0, 7], [1, 4])),
            (MLXArray([Float(0), 0, 3, 0], [1, 4]), MLXArray([Float(0), 2, 0, 0], [1, 4])),
        ]
        let packed = PagedKVSharedForwardBackend.packedTopTokenIDs(rows: rows)
        let perRow = rows.map { row -> [Int] in
            var ids: [Int] = []
            if row.proposalLogits.dim(0) > 0 {
                ids += argMax(row.proposalLogits, axis: -1).asArray(Int.self)
            }
            return ids + argMax(row.bonusLogits, axis: -1).asArray(Int.self)
        }
        XCTAssertEqual(packed, [[1, 0], [3], [2, 1]])
        XCTAssertEqual(packed, perRow)
        XCTAssertEqual(PagedKVSharedForwardBackend.packedTopTokenIDs(rows: []), [])
    }

    func testMTPPackedCacheResolutionCommitsBaseColumnAndAcceptedPrefixOnly() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["accept-one", "accept-zero"],
            initialOffsets: [0, 0]
        )

        let result = try PagedKVSharedForwardBackend.exerciseMTPPackedCacheResolutionForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 0, inputCount: 3, proposalCount: 2),
                MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 0, inputCount: 2, proposalCount: 1),
            ],
            width: 3,
            committedInputCounts: [2, 1]
        )

        XCTAssertEqual(result.rowOffsetsAfterStaging, [0, 0])
        XCTAssertEqual(result.rowStoredTokensAfterStaging, [0, 0])
        XCTAssertEqual(result.rowStateTokenCountsAfterStaging, [0, 0])
        XCTAssertEqual(result.pendingInputCountsBeforeFinalize, [3, 2])
        XCTAssertEqual(result.pendingProposalCountsBeforeFinalize, [2, 1])
        XCTAssertEqual(result.pendingInputCountsAfterFacadeFinalize, [3, 2])
        XCTAssertEqual(result.pendingProposalCountsAfterFacadeFinalize, [2, 1])
        XCTAssertEqual(result.rowOffsetsAfterResolution, [2, 1])
        XCTAssertEqual(result.rowStoredTokensAfterResolution, [2, 1])
        XCTAssertEqual(result.rowStateTokenCountsAfterResolution, [2, 1])
    }

    /// Finalize stages every row/layer commit and evaluates once. The staged
    /// path must leave each row byte-identical to the old per-row
    /// commit-and-eval path, including uncommitted (aborted) rows.
    func testMTPPackedCacheStagedCommitMatchesPerRowCommitByteForByte() async throws {
        try requireMetal()

        let rowMaps = [
            MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 2, inputCount: 2, proposalCount: 1),
            MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 0, inputCount: 1, proposalCount: 0),
            MTPPackedVerificationRowMap(rowIndex: 2, queryOffset: 1, inputCount: 2, proposalCount: 1),
            MTPPackedVerificationRowMap(rowIndex: 3, queryOffset: 3, inputCount: 2, proposalCount: 1),
        ]
        // Accept one proposal, depth-zero commit, reject the proposal, abort.
        let commits: [Int?] = [2, 1, 1, nil]
        func run(staged: Bool) async throws -> PagedKVMTPPackedCacheResolutionResult {
            let descriptor = Self.bridgeDescriptor()
            let allocator = try PagedKVBlockAllocator(
                blockSizeTokens: descriptor.blockSizeTokens,
                maxPhysicalBlocks: descriptor.maxPhysicalBlocks
            )
            let rows = try await Self.pagedRows(
                descriptor: descriptor,
                allocator: allocator,
                ids: ["accept", "depth-zero", "reject", "abort"],
                initialOffsets: [2, 0, 1, 3]
            )
            return try PagedKVSharedForwardBackend.exerciseMTPPackedCacheResolutionForTest(
                rowCaches: rows,
                rowMaps: rowMaps,
                width: 2,
                committedInputCounts: commits,
                stagedCommit: staged
            )
        }

        let perRow = try await run(staged: false)
        let staged = try await run(staged: true)

        XCTAssertEqual(staged, perRow)
        XCTAssertEqual(staged.rowOffsetsAfterResolution, [4, 1, 2, 3])
        XCTAssertEqual(staged.rowStoredTokensAfterResolution, [2, 1, 1, 0])
        // Row-local values: each committed row holds only its own packed
        // columns (row r's columns are 2r+1, 2r+2; values add 1000).
        XCTAssertEqual(staged.rowStateValuesAfterResolution[0].filter { $0 != 0 }, [1, 2, 1_001, 1_002])
        XCTAssertEqual(staged.rowStateValuesAfterResolution[1].filter { $0 != 0 }, [3, 1_003])
        XCTAssertEqual(staged.rowStateValuesAfterResolution[2].filter { $0 != 0 }, [5, 1_005])
    }

    func testMTPPackedCacheAbortRestoresExactRowsAfterFacadeFinalize() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["abort-a", "abort-b"],
            initialOffsets: [1, 3]
        )
        let beforeOffsets = rows.map(\.offset)
        let beforeStoredTokens = rows.map(\.storedTokens)
        let beforeStateCounts = rows.map { row -> Int in
            let state = row.state
            return state.count == 2 ? state[0].dim(2) : 0
        }

        let result = try PagedKVSharedForwardBackend.exerciseMTPPackedCacheResolutionForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 1, inputCount: 2, proposalCount: 1),
                MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 3, inputCount: 3, proposalCount: 2),
            ],
            width: 3,
            committedInputCounts: [nil, nil]
        )

        XCTAssertEqual(result.rowOffsetsAfterStaging, beforeOffsets)
        XCTAssertEqual(result.rowStoredTokensAfterStaging, beforeStoredTokens)
        XCTAssertEqual(result.rowStateTokenCountsAfterStaging, beforeStateCounts)
        XCTAssertEqual(result.pendingInputCountsAfterFacadeFinalize, [2, 3])
        XCTAssertEqual(result.pendingProposalCountsAfterFacadeFinalize, [1, 2])
        XCTAssertEqual(result.rowOffsetsAfterResolution, beforeOffsets)
        XCTAssertEqual(result.rowStoredTokensAfterResolution, beforeStoredTokens)
        XCTAssertEqual(result.rowStateTokenCountsAfterResolution, beforeStateCounts)
    }

    func testMTPPackedCacheRejectsOutOfRangeResolutionWithoutRowMutation() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["bad-resolution"],
            initialOffsets: [0]
        )

        XCTAssertThrowsError(try PagedKVSharedForwardBackend.exerciseMTPPackedCacheResolutionForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 0, queryOffset: 0, inputCount: 2, proposalCount: 1),
            ],
            width: 2,
            committedInputCounts: [3]
        ))
        XCTAssertEqual(rows.map(\.offset), [0])
        XCTAssertEqual(rows.map(\.storedTokens), [0])
    }

    func testMTPPackedCacheRejectsMalformedMapsBeforeMutation() async throws {
        try requireMetal()

        let descriptor = Self.bridgeDescriptor()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let rows = try await Self.pagedRows(
            descriptor: descriptor,
            allocator: allocator,
            ids: ["bad-a", "bad-b"],
            initialOffsets: [1, 0]
        )

        XCTAssertThrowsError(try PagedKVSharedForwardBackend.validateMTPPackedCacheForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 0, inputCount: 1, proposalCount: 0),
                MTPPackedVerificationRowMap(rowIndex: 2, queryOffset: 0, inputCount: 1, proposalCount: 0),
            ]
        ))
        XCTAssertEqual(rows.map(\.offset), [1, 0])
        XCTAssertEqual(rows.map(\.storedTokens), [0, 0])

        XCTAssertThrowsError(try PagedKVSharedForwardBackend.validateMTPPackedCacheForTest(
            rowCaches: rows,
            rowMaps: [
                MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 1, inputCount: 2, proposalCount: 0),
                MTPPackedVerificationRowMap(rowIndex: 1, queryOffset: 0, inputCount: 1, proposalCount: 0),
            ]
        ))
        XCTAssertEqual(rows.map(\.offset), [1, 0])
        XCTAssertEqual(rows.map(\.storedTokens), [0, 0])
    }

    func testLockstepSharedForwardDecodePopulatesBatchInnerState() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: descriptor.modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [
                1: 4,
                4: 5,
                5: 6,
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
        _ = try await allocator.extend(aHandle, by: 1)
        _ = try await allocator.extend(bHandle, by: 1)
        let aPrefill = try await allocator.binding(for: aHandle)
        let bPrefill = try await allocator.binding(for: bHandle)
        _ = try await backend.prefill(rows: [
            ContinuousBatchPrefillInput(
                requestID: "row-a",
                promptTokens: [10],
                binding: aPrefill,
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 1,
                isFinalChunk: true
            ),
            ContinuousBatchPrefillInput(
                requestID: "row-b",
                promptTokens: [11],
                binding: bPrefill,
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 1,
                isFinalChunk: true
            ),
        ])

        let first = try await backend.decode(rows: [
            try await Self.decodeInput(
                requestID: "row-a",
                currentToken: 1,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 1
            ),
            try await Self.decodeInput(
                requestID: "row-b",
                currentToken: 12,
                handle: bHandle,
                allocator: allocator,
                committedKVTokenCount: 1
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)
        XCTAssertEqual(Self.tokens(from: first), ["row-a": 4, "row-b": 7])
        XCTAssertTrue(backend.lockstepInnerStateNonEmptyForTest())

        let second = try await backend.decode(rows: [
            try await Self.decodeInput(
                requestID: "row-a",
                currentToken: 4,
                handle: aHandle,
                allocator: allocator,
                committedKVTokenCount: 2
            ),
            try await Self.decodeInput(
                requestID: "row-b",
                currentToken: 7,
                handle: bHandle,
                allocator: allocator,
                committedKVTokenCount: 2
            ),
        ])
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)
        XCTAssertEqual(Self.tokens(from: second), ["row-a": 5, "row-b": 8])
        XCTAssertTrue(backend.lockstepInnerStateNonEmptyForTest())
        backend.finish(requestID: "row-a")
        backend.finish(requestID: "row-b")
        XCTAssertEqual(backend.retainedRowCountForTest(), 0)
        XCTAssertFalse(backend.lockstepInnerStateNonEmptyForTest())
    }

    func testLockstepWindowReturnsEverySampledTokenInOrder() async throws {
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
        _ = try await allocator.extend(aHandle, by: 2)
        _ = try await allocator.extend(bHandle, by: 2)
        try await allocator.beginDecodeStep(aHandle)
        try await allocator.beginDecodeStep(bHandle)
        let window = try await backend.decodeLockstepWindow(
            rows: [
                try await Self.decodeInput(
                    requestID: "row-a",
                    currentToken: 1,
                    handle: aHandle,
                    allocator: allocator,
                    committedKVTokenCount: 0,
                    extendBy: 0,
                    beginDecode: false,
                    targetOffset: 2
                ),
                try await Self.decodeInput(
                    requestID: "row-b",
                    currentToken: 12,
                    handle: bHandle,
                    allocator: allocator,
                    committedKVTokenCount: 0,
                    extendBy: 0,
                    beginDecode: false,
                    targetOffset: 2
                ),
            ],
            steps: 2
        )
        try await allocator.endDecodeStep(aHandle)
        try await allocator.endDecodeStep(bHandle)

        var tokensByID: [String: [Int]] = [:]
        for outcome in window {
            guard case .output(let output) = outcome else {
                XCTFail("expected window outputs, got \(outcome)")
                return
            }
            tokensByID[output.requestID] = output.tokens
        }
        XCTAssertEqual(tokensByID["row-a"], [4, 5])
        XCTAssertEqual(tokensByID["row-b"], [7, 8])
        backend.finish(requestID: "row-a")
        backend.finish(requestID: "row-b")
    }

    /// The window reports each step's tokens as sampled (equal to the returned
    /// prefix) and ends after a step when the observer asks it to.
    func testLockstepWindowStreamsStepsAndEndsWhenObserverStops() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        for stopAfterFirstStep in [false, true] {
            let descriptor = Self.bridgeDescriptor()
            let container = ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: RuntimeBridgeFakeModel(nextTokenByInput: [1: 4, 4: 5, 12: 7, 7: 8]),
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            ))
            let backend = PagedKVSharedForwardBackend(container: container, descriptor: descriptor, layerCount: 1)
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: descriptor.blockSizeTokens, maxPhysicalBlocks: 16)
            let aHandle = try await allocator.allocate(conversationKey: "row-a", maxTokens: 8)
            let bHandle = try await allocator.allocate(conversationKey: "row-b", maxTokens: 8)
            _ = try await allocator.extend(aHandle, by: 2)
            _ = try await allocator.extend(bHandle, by: 2)
            try await allocator.beginDecodeStep(aHandle)
            try await allocator.beginDecodeStep(bHandle)
            let steps = StepRecorder()
            let window = try await backend.decodeLockstepWindow(
                rows: [
                    try await Self.decodeInput(
                        requestID: "row-a", currentToken: 1, handle: aHandle, allocator: allocator,
                        committedKVTokenCount: 0, extendBy: 0, beginDecode: false, targetOffset: 2
                    ),
                    try await Self.decodeInput(
                        requestID: "row-b", currentToken: 12, handle: bHandle, allocator: allocator,
                        committedKVTokenCount: 0, extendBy: 0, beginDecode: false, targetOffset: 2
                    ),
                ],
                steps: 2,
                onStep: { step in
                    steps.append(step)
                    return !stopAfterFirstStep
                }
            )
            try await allocator.endDecodeStep(aHandle)
            try await allocator.endDecodeStep(bHandle)

            var tokensByID: [String: [Int]] = [:]
            for outcome in window {
                guard case .output(let output) = outcome else {
                    XCTFail("expected window outputs, got \(outcome)")
                    return
                }
                tokensByID[output.requestID] = output.tokens
            }
            let recorded = steps.steps()
            if stopAfterFirstStep {
                XCTAssertEqual(tokensByID["row-a"], [4])
                XCTAssertEqual(tokensByID["row-b"], [7])
                XCTAssertEqual(recorded.map(\.tokens), [[4, 7]])
                // An early-ended (all-cancelled) window records no row state.
                XCTAssertEqual(backend.retainedRowCountForTest(), 0)
            } else {
                XCTAssertEqual(tokensByID["row-a"], [4, 5])
                XCTAssertEqual(tokensByID["row-b"], [7, 8])
                XCTAssertEqual(recorded.map(\.tokens), [[4, 7], [5, 8]])
            }
            XCTAssertEqual(recorded.map(\.stepIndex), Array(0 ..< recorded.count))
            backend.finish(requestID: "row-a")
            backend.finish(requestID: "row-b")
        }
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
        let contiguousCacheBridge = PagedKVRuntimeContiguousCacheBridge()
        let backend = PagedKVSharedForwardBackend(
            container: container,
            descriptor: descriptor,
            layerCount: 1,
            contiguousCacheBridge: contiguousCacheBridge
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: 16,
            contiguousCacheBridge: contiguousCacheBridge
        )
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
        await XCTAssertThrowsErrorAsync(try await allocator.materializeContiguousByteCache(handle))
    }

    func testSharedForwardBackendFinishPreservesRetainedPagedHandoffRecord() async throws {
        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let bridge = RuntimeBridgeRecordingCacheBridge()
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            contiguousCacheBridge: bridge
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 8, initialTokens: 4)
        let binding = try await allocator.binding(for: handle)
        let paged = PagedKVCache(descriptor: descriptor, binding: binding, initialOffset: 4)
        try backend.installRowStateForTest(caches: [paged], requestID: "retained-row", binding: binding)
        XCTAssertEqual(backend.retainedRowCountForTest(), 1)
        XCTAssertTrue(bridge.hasRecord(for: handle))

        let retained = try await allocator.retain(handle)
        backend.finish(requestID: "retained-row")
        XCTAssertEqual(backend.retainedRowCountForTest(), 0)
        XCTAssertTrue(bridge.hasRecord(for: handle))
        XCTAssertEqual(bridge.discardedHandles(), [])
        _ = try await allocator.reattach(retained, conversationKey: "conv:a")
    }

    func testLabStateDigestObserverRecordsPagedKVCacheLogicalPrefix() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            contiguousCacheBridge: RuntimeBridgeRecordingCacheBridge()
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let handle = try await allocator.allocate(conversationKey: "conv:digest", maxTokens: 8, initialTokens: 3)
        let binding = try await allocator.binding(for: handle)
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)
        paged.state = [
            MLXArray([Float](repeating: 1, count: 6), [1, 2, 3, 1]),
            MLXArray([Float](repeating: 2, count: 6), [1, 2, 3, 1]),
        ]
        XCTAssertEqual(paged.offset, 3)
        XCTAssertEqual(paged.storedTokens, 3)
        try backend.installRowStateForTest(caches: [paged], requestID: "digest-row", binding: binding)

        let observer = NativeMTPStateDigestObserver()
        backend.installLabNativeMTPStateDigestObserver(observer)
        try await backend.recordLabNativeMTPStateDigest(phase: .ordinaryAfterDecode, requestIDs: ["digest-row"])

        let records = observer.snapshot()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.requestID, "digest-row")
        XCTAssertEqual(record.phase, .ordinaryAfterDecode)
        XCTAssertEqual(record.committedKVTokenCount, 3)
        XCTAssertEqual(record.cacheDigestSHA256.count, 64)
        XCTAssertEqual(record.digestSHA256.count, 64)
    }

    func testLabDrafterStateDigestIgnoresPhysicalPaddingBeyondCommittedPrefix() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let paddedKey = MLXArray([Float](arrayLiteral: 1, 2, 99, 100), [1, 1, 4, 1])
        let paddedValue = MLXArray([Float](arrayLiteral: 3, 4, 101, 102), [1, 1, 4, 1])
        let compactKey = MLXArray([Float](arrayLiteral: 1, 2), [1, 1, 2, 1])
        let compactValue = MLXArray([Float](arrayLiteral: 3, 4), [1, 1, 2, 1])
        let changedKey = MLXArray([Float](arrayLiteral: 1, 42), [1, 1, 2, 1])
        let changedValue = MLXArray([Float](arrayLiteral: 3, 4), [1, 1, 2, 1])
        let paddedCache = KVCacheSimple()
        paddedCache.state = [paddedKey, paddedValue]
        let compactCache = KVCacheSimple()
        compactCache.state = [compactKey, compactValue]
        let changedCache = KVCacheSimple()
        changedCache.state = [changedKey, changedValue]
        let padded = MTPDrafterState(cache: [paddedCache], nextPosition: 2, seedToken: nil, seedHidden: nil)
        let compact = MTPDrafterState(cache: [compactCache], nextPosition: 2, seedToken: nil, seedHidden: nil)
        let changed = MTPDrafterState(cache: [changedCache], nextPosition: 2, seedToken: nil, seedHidden: nil)

        let paddedDigest = try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: padded, seed: 7)
        let compactDigest = try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: compact, seed: 7)
        let changedDigest = try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: changed, seed: 7)

        XCTAssertEqual(paddedDigest, compactDigest)
        XCTAssertNotEqual(paddedDigest, changedDigest)
    }

    func testLabStateDigestObserverFailsClosedForPagedSlidingWindowCache() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            contiguousCacheBridge: RuntimeBridgeRecordingCacheBridge()
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let handle = try await allocator.allocate(conversationKey: "conv:window", maxTokens: 8, initialTokens: 3)
        let binding = try await allocator.binding(for: handle)
        let paged = PagedKVCache(
            descriptor: descriptor,
            binding: binding,
            attentionWindowTokens: 2
        )
        paged.state = [
            MLXArray([Float](repeating: 1, count: 6), [1, 2, 3, 1]),
            MLXArray([Float](repeating: 2, count: 6), [1, 2, 3, 1]),
        ]
        try backend.installRowStateForTest(caches: [paged], requestID: "window-row", binding: binding)

        let observer = NativeMTPStateDigestObserver()
        backend.installLabNativeMTPStateDigestObserver(observer)
        do {
            try await backend.recordLabNativeMTPStateDigest(phase: .ordinaryAfterDecode, requestIDs: ["window-row"])
            XCTFail("sliding-window paged cache must stay fail-closed for state digesting")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "native_mtp_observer_unsupported_sliding_window_state")
        }
        XCTAssertEqual(observer.snapshot(), [])
    }

    func testLabStateDigestObserverFailsClosedForUnknownCacheKind() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 4)
        let backend = PagedKVSharedForwardBackend(
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: descriptor.modelID),
                model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
                processor: StandInUserInputProcessor(),
                tokenizer: RuntimeBridgeFakeTokenizer()
            )),
            descriptor: descriptor,
            layerCount: 1,
            contiguousCacheBridge: RuntimeBridgeRecordingCacheBridge()
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks
        )
        let handle = try await allocator.allocate(conversationKey: "conv:unknown", maxTokens: 8, initialTokens: 3)
        let binding = try await allocator.binding(for: handle)
        let cache = RuntimeBridgeUnknownKVCache(offset: 3, state: [
            MLXArray([Float](repeating: 1, count: 6), [1, 2, 3, 1]),
            MLXArray([Float](repeating: 2, count: 6), [1, 2, 3, 1]),
        ])
        try backend.installRowStateForTest(caches: [cache], requestID: "unknown-row", binding: binding)

        let observer = NativeMTPStateDigestObserver()
        backend.installLabNativeMTPStateDigestObserver(observer)
        do {
            try await backend.recordLabNativeMTPStateDigest(phase: .ordinaryAfterDecode, requestIDs: ["unknown-row"])
            XCTFail("unknown cache kind must stay fail-closed for state digesting")
        } catch ContinuousBatchSchedulerError.unsupported(let reason) {
            XCTAssertEqual(reason, "native_mtp_observer_unsupported_cache_kind")
        }
        XCTAssertEqual(observer.snapshot(), [])
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
            continuousBatchingDurableReplayAuthorityAvailable: true,
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
            .withRequestID("relay-request-1500")

        let completion = try await runtime.complete(request)
        XCTAssertEqual(completion.content, "3 3")
        XCTAssertEqual(completion.finishReason, "length")
        XCTAssertEqual(completion.promptTokens, 1)
        XCTAssertEqual(completion.completionTokens, 2)
        let completionDecodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(completionDecodeCalls, 1)
        let completionDecodeBatches = await backend.decodeBatches()
        XCTAssertEqual(completionDecodeBatches, [["relay-request-1500"]])

        let chunkRecorder = RuntimeBridgeChunkRecorder()
        let streamingRequest = try Self.chatRequest(modelID: modelID, maxTokens: 2)
            .withRequestID("relay-request-1501")
        let handle = try await runtime.acquireRequestHandle(streamingRequest)
        let streamed = try await runtime.stream(
            streamingRequest,
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
        XCTAssertEqual(streamedDecodeCalls, 2)
        let allDecodeBatches = await backend.decodeBatches()
        XCTAssertEqual(Array(allDecodeBatches.suffix(1)), [["relay-request-1501"]])
    }

    // A batched row's budget is the served context: an explicit max_tokens
    // past it is clamped and reports `length`, and a prompt that fills the
    // context is the serial 413 before any backend work.
    func testAttachedServePathBoundsRowsByServedContext() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let modelID = "mlx-community/Qwen-Test"
        func runtime(promptTokens: [Int32], backend: RuntimeBridgeScriptedBackend) -> ModelRuntime {
            let modelSHA = String(repeating: "a", count: 64)
            let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
            return ModelRuntime(
                modelID: modelID,
                modelHash: modelSHA,
                maxContextTokensOverride: 4,
                pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
                maxBatch: 2,
                continuousBatchingMode: .on,
                continuousBatchingDurableReplayAuthorityAvailable: true,
                warmSwapEnabled: false,
                pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
                pagedKVHardwareSizingProof: proof,
                pagedKVRuntimeCacheClass: "KVCacheSimple",
                pagedKVSchedulerBackendInstalled: true,
                container: ModelContainer(context: ModelContext(
                    configuration: ModelConfiguration(id: modelID),
                    model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
                    processor: RuntimeBridgePromptProcessor(tokens: promptTokens),
                    tokenizer: RuntimeBridgeFakeTokenizer()
                )),
                continuousBatchingBackend: backend,
                loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }
            )
        }

        let clampBackend = RuntimeBridgeScriptedBackend(scripts: [:])
        let clamped = try await runtime(promptTokens: [3], backend: clampBackend).complete(
            try Self.chatRequest(modelID: modelID, maxTokens: 100).withRequestID("context-cap-clamp")
        )
        XCTAssertEqual(clamped.completionTokens, 3)
        XCTAssertEqual(clamped.finishReason, "length")

        let fullBackend = RuntimeBridgeScriptedBackend(scripts: [:])
        do {
            _ = try await runtime(promptTokens: [3, 3, 3, 3], backend: fullBackend).complete(
                try Self.chatRequest(modelID: modelID, maxTokens: 1).withRequestID("context-cap-full")
            )
            XCTFail("expected a context rejection")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 413)
            XCTAssertEqual(error.code, "context_length_exceeded")
        }
        let prefillCalls = await fullBackend.prefillCallCount()
        XCTAssertEqual(prefillCalls, 0)
    }

    func testAttachedServePathPrefillsChatPreparedMultiTokenPrompt() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let modelID = "mlx-community/Qwen-Test"
        let backend = RuntimeBridgeScriptedBackend(scripts: [:])
        let promptTokens = Array(repeating: Int32(3), count: 16)
        let runtime = Self.attachedRuntime(
            modelID: modelID,
            backend: backend,
            promptTokens: promptTokens
        )
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)
            .withRequestID("serve-path-prefill-16")

        let completion = try await runtime.complete(request)
        XCTAssertEqual(completion.promptTokens, 16)
        XCTAssertEqual(completion.finishReason, "length")
        let prefillCalls = await backend.prefillCallCount()
        let prefillLengths = await backend.prefillPromptLengths()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(prefillCalls, 1)
        XCTAssertEqual(prefillLengths, [16])
        XCTAssertEqual(decodeCalls, 1)
    }

    func testAttachedServePathPrefillFailureReturnsReasonCoded503() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let modelID = "mlx-community/Qwen-Test"
        let backend = RuntimeBridgeScriptedBackend(
            scripts: [:],
            prefillError: ContinuousBatchSchedulerError.unsupported("continuous_batching_invalid_cache_layout")
        )
        let runtime = Self.attachedRuntime(
            modelID: modelID,
            backend: backend,
            promptTokens: Array(repeating: Int32(3), count: 16)
        )
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)
            .withRequestID("serve-path-prefill-fail")

        do {
            _ = try await runtime.complete(request)
            XCTFail("expected serve-path prefill to fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.code, "continuous_batching_prefill_failed")
            XCTAssertFalse(error.inferenceRan)
            XCTAssertFalse(error.settlementRan)
        }
        let prefillCalls = await backend.prefillCallCount()
        let decodeCalls = await backend.decodeCallCount()
        XCTAssertEqual(prefillCalls, 1)
        XCTAssertEqual(decodeCalls, 0)
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
            .withRequestID("cancel-row")
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
            .withRequestID("cancel-stream-row")
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
        let emittedContent = chunks.chunks().compactMap { chunk -> String? in
            if case .content(let text) = chunk { return text }
            return nil
        }
        XCTAssertEqual(emittedContent, ["3"])
    }

    func testContiguousCacheBridgeRestoresLiveKVCacheByteExactAndRoundTrips() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 2, maxPhysicalBlocks: 6)
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            physicalBlockOrder: [4, 1, 3, 0, 2, 5],
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 6, initialTokens: 5)
        let binding = try await allocator.binding(for: handle)
        XCTAssertEqual(binding.currentTable.physicalBlocks, [4, 1, 3])

        let keyBytes = Self.fp16Bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let valueBytes = Self.fp16Bytes([101, 102, 103, 104, 105, 106, 107, 108, 109, 110])
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)
        paged.state = [
            MLXArray(keyBytes, [1, 2, 5, 1], dtype: .float16),
            MLXArray(valueBytes, [1, 2, 5, 1], dtype: .float16),
        ]
        try bridge.record(caches: [paged], binding: binding)

        let permutedTable = PagedKVBlockTable(
            handleID: binding.currentTable.handleID,
            blockSizeTokens: binding.currentTable.blockSizeTokens,
            logicalTokenCount: binding.currentTable.logicalTokenCount,
            physicalBlocks: Array(binding.currentTable.physicalBlocks.reversed()),
            tailValidTokenCount: binding.currentTable.tailValidTokenCount,
            poolEpoch: binding.currentTable.poolEpoch
        )
        XCTAssertThrowsError(try bridge.materializeContiguousByteCache(handle: handle, table: permutedTable))

        let replacementKeyBytes = Self.fp16Bytes([201, 202, 203, 204, 205, 206, 207, 208, 209, 210])
        let replacementValueBytes = Self.fp16Bytes([301, 302, 303, 304, 305, 306, 307, 308, 309, 310])
        paged.state = [
            MLXArray(replacementKeyBytes, [1, 2, 5, 1], dtype: .float16),
            MLXArray(replacementValueBytes, [1, 2, 5, 1], dtype: .float16),
        ]
        XCTAssertNotEqual(paged.state[0].asData(access: .copy).data, keyBytes)

        let materialized = try await allocator.materializeContiguousByteCache(handle)
        XCTAssertEqual(materialized.layers[0].keyBytes, replacementKeyBytes)
        XCTAssertEqual(materialized.layers[0].valueBytes, replacementValueBytes)

        let handoff = try bridge.materializeContiguousKVCache(handle: handle, table: binding.currentTable)
        XCTAssertEqual(handoff.caches.count, 1)
        XCTAssertEqual(handoff.caches[0].offset, 5)
        XCTAssertEqual(handoff.caches[0].state[0].asData(access: .copy).data, replacementKeyBytes)
        XCTAssertEqual(handoff.caches[0].state[1].asData(access: .copy).data, replacementValueBytes)

        let nextKeyBytes = Self.fp16Bytes([11, 12])
        let nextValueBytes = Self.fp16Bytes([111, 112])
        let updated = handoff.caches[0].update(
            keys: MLXArray(nextKeyBytes, [1, 2, 1, 1], dtype: .float16),
            values: MLXArray(nextValueBytes, [1, 2, 1, 1], dtype: .float16)
        )
        eval(updated.0, updated.1)
        XCTAssertEqual(handoff.caches[0].offset, 6)
        XCTAssertEqual(
            handoff.caches[0].state[0].asData(access: .copy).data,
            Self.fp16Bytes([201, 202, 203, 204, 205, 11, 206, 207, 208, 209, 210, 12])
        )
        XCTAssertEqual(
            handoff.caches[0].state[1].asData(access: .copy).data,
            Self.fp16Bytes([301, 302, 303, 304, 305, 111, 306, 307, 308, 309, 310, 112])
        )
    }

    func testContiguousCacheBridgeRecordsBFloat16KV() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 2, maxPhysicalBlocks: 6)
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            physicalBlockOrder: [4, 1, 3, 0, 2, 5],
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(conversationKey: "conv:bf16", maxTokens: 6, initialTokens: 5)
        let binding = try await allocator.binding(for: handle)
        let keyBytes = Self.fp16Bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let valueBytes = Self.fp16Bytes([101, 102, 103, 104, 105, 106, 107, 108, 109, 110])
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)
        paged.state = [
            MLXArray(keyBytes, [1, 2, 5, 1], dtype: .bfloat16),
            MLXArray(valueBytes, [1, 2, 5, 1], dtype: .bfloat16),
        ]
        try bridge.record(caches: [paged], binding: binding)
        let materialized = try await allocator.materializeContiguousByteCache(handle)
        XCTAssertEqual(materialized.layers[0].dtype, .bf16)
        XCTAssertEqual(materialized.layers[0].keyBytes, keyBytes)
        XCTAssertEqual(materialized.layers[0].valueBytes, valueBytes)
        let handoff = try bridge.materializeContiguousKVCache(handle: handle, table: binding.currentTable)
        XCTAssertEqual(handoff.caches[0].state[0].dtype, .bfloat16)
        XCTAssertEqual(handoff.caches[0].state[0].asData(access: .copy).data, keyBytes)
    }

    func testCompiledWritebackKeepsEachRowsOwnTargetLength() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let row0 = MLXArray((1...8).map(Float.init), [1, 1, 8, 1])
        let row1 = MLXArray((11...18).map(Float.init), [1, 1, 8, 1])
        let keys = concatenated([row0, row1], axis: 0)
        let values = concatenated(
            [
                MLXArray((101...108).map(Float.init), [1, 1, 8, 1]),
                MLXArray((111...118).map(Float.init), [1, 1, 8, 1]),
            ],
            axis: 0
        )
        eval(keys, values)
        let slices = try PagedKVCompiledWriteback.rowSlices(
            keysValues: [keys, values],
            targets: [3, 6]
        )
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].0.dim(0), 1)
        XCTAssertEqual(slices[0].0.dim(2), 3)
        XCTAssertEqual(slices[1].0.dim(2), 6)
        eval(slices[0].0, slices[1].0)
        XCTAssertEqual(slices[0].0.asArray(Float.self), [1, 2, 3])
        XCTAssertEqual(slices[1].0.asArray(Float.self), [11, 12, 13, 14, 15, 16])
    }

    func testCompiledWritebackThrowsWhenCompiledShorterThanARowTarget() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let keys = MLXArray((1...4).map(Float.init), [1, 1, 4, 1])
        let values = MLXArray((101...104).map(Float.init), [1, 1, 4, 1])
        eval(keys, values)
        XCTAssertThrowsError(
            try PagedKVCompiledWriteback.rowSlices(keysValues: [keys, values], targets: [5])
        ) { error in
            XCTAssertEqual(
                error as? ContinuousBatchSchedulerError,
                .unsupported("continuous_batching_invalid_cache_layout")
            )
        }
    }

    func testCompiledWritebackThrowsOnMalformedCompiledState() {
        XCTAssertThrowsError(
            try PagedKVCompiledWriteback.rowSlices(keysValues: [], targets: [2])
        ) { error in
            XCTAssertEqual(
                error as? ContinuousBatchSchedulerError,
                .unsupported("continuous_batching_invalid_cache_layout")
            )
        }
    }

    func testContiguousCacheBridgePreservesMidBlockTrimAcrossExtractAndRetainReattach() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 6)
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            physicalBlockOrder: [2, 5, 1, 0, 4, 3],
            contiguousCacheBridge: bridge
        )
        let handle = try await allocator.allocate(
            conversationKey: "conv:a",
            initialCapacityTokens: 8,
            maxLogicalTokens: 8,
            initialTokens: 7
        )
        let binding = try await allocator.binding(for: handle)
        XCTAssertEqual(binding.currentTable.tailValidTokenCount, 3)

        let keyBytes = Self.fp16Bytes([1, 2, 3, 4, 5, 6, 7])
        let valueBytes = Self.fp16Bytes([101, 102, 103, 104, 105, 106, 107])
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)
        paged.state = [
            MLXArray(keyBytes, [1, 1, 7, 1], dtype: .float16),
            MLXArray(valueBytes, [1, 1, 7, 1], dtype: .float16),
        ]
        try bridge.record(caches: [paged], binding: binding)

        var extracted = try bridge.materializeContiguousKVCache(handle: handle, table: binding.currentTable)
        try extracted.trim(toLogicalTokens: 5)
        XCTAssertEqual(extracted.caches[0].offset, 5)
        XCTAssertEqual(extracted.logicalTokenCount, 5)
        XCTAssertEqual(extracted.tailValidTokenCount, 1)
        XCTAssertEqual(extracted.caches[0].state[0].asData(access: .copy).data, Self.fp16Bytes([1, 2, 3, 4, 5]))

        let retained = try await allocator.retain(handle)
        await XCTAssertThrowsErrorAsync(
            try await allocator.reattach(retained, conversationKey: "conv:b", trimToLogicalTokens: 5)
        )
        let reattached = try await allocator.reattach(
            retained,
            conversationKey: "conv:a",
            trimToLogicalTokens: 5
        )
        let reattachedTable = try await allocator.table(for: reattached)
        XCTAssertEqual(reattachedTable.logicalTokenCount, 5)
        XCTAssertEqual(reattachedTable.tailValidTokenCount, 1)
        XCTAssertThrowsError(try bridge.materializeContiguousKVCache(handle: handle, table: binding.currentTable))

        let pagedHandoff = try bridge.reattachPagedKVCache(handle: reattached, table: reattachedTable)
        XCTAssertEqual(pagedHandoff.logicalTokenCount, 5)
        XCTAssertEqual(pagedHandoff.tailValidTokenCount, 1)
        XCTAssertEqual(pagedHandoff.caches.count, 1)
        XCTAssertTrue(pagedHandoff.caches[0] === paged)
        XCTAssertEqual(pagedHandoff.caches[0].offset, 5)
        XCTAssertEqual(pagedHandoff.caches[0].state[0].asData(access: .copy).data, Self.fp16Bytes([1, 2, 3, 4, 5]))

        let materializedAfterReattach = try await allocator.materializeContiguousByteCache(reattached)
        XCTAssertEqual(materializedAfterReattach.layers[0].keyShape, [1, 1, 5, 1])
        XCTAssertEqual(materializedAfterReattach.layers[0].keyBytes, Self.fp16Bytes([1, 2, 3, 4, 5]))
        XCTAssertEqual(materializedAfterReattach.layers[0].valueBytes, Self.fp16Bytes([101, 102, 103, 104, 105]))

        _ = try await allocator.extend(reattached, by: 1)
        let continued = pagedHandoff.caches[0].update(
            keys: MLXArray(Self.fp16Bytes([6]), [1, 1, 1, 1], dtype: .float16),
            values: MLXArray(Self.fp16Bytes([106]), [1, 1, 1, 1], dtype: .float16)
        )
        eval(continued.0, continued.1)
        try bridge.record(caches: pagedHandoff.caches, binding: try await allocator.binding(for: reattached))
        XCTAssertEqual(paged.offset, 6)
        XCTAssertEqual(pagedHandoff.caches[0].state[0].asData(access: .copy).data, Self.fp16Bytes([1, 2, 3, 4, 5, 6]))
        let materializedAfterContinuation = try await allocator.materializeContiguousByteCache(reattached)
        XCTAssertEqual(materializedAfterContinuation.layers[0].keyBytes, Self.fp16Bytes([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(materializedAfterContinuation.layers[0].valueBytes, Self.fp16Bytes([101, 102, 103, 104, 105, 106]))

        let zeroRetained = try await allocator.retain(reattached)
        let zeroReattached = try await allocator.reattach(
            zeroRetained,
            conversationKey: "conv:a",
            trimToLogicalTokens: 0
        )
        let zeroTable = try await allocator.table(for: zeroReattached)
        XCTAssertEqual(zeroTable.logicalTokenCount, 0)
        XCTAssertEqual(zeroTable.tailValidTokenCount, 0)
        await XCTAssertThrowsErrorAsync(try await allocator.materializeContiguousByteCache(zeroReattached))
    }

    func testContiguousCacheBridgeRejectsCrossHandleCacheRecord() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        let descriptor = Self.bridgeDescriptor(blockSizeTokens: 2, maxPhysicalBlocks: 6)
        let bridge = PagedKVRuntimeContiguousCacheBridge()
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: descriptor.blockSizeTokens,
            maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
            contiguousCacheBridge: bridge
        )
        let first = try await allocator.allocate(conversationKey: "conv:a", maxTokens: 4, initialTokens: 2)
        let second = try await allocator.allocate(conversationKey: "conv:b", maxTokens: 4, initialTokens: 2)
        let firstBinding = try await allocator.binding(for: first)
        let secondBinding = try await allocator.binding(for: second)
        let paged = PagedKVCache(descriptor: descriptor, binding: firstBinding)
        paged.state = [
            MLXArray(Self.fp16Bytes([1, 2]), [1, 1, 2, 1], dtype: .float16),
            MLXArray(Self.fp16Bytes([101, 102]), [1, 1, 2, 1], dtype: .float16),
        ]

        XCTAssertThrowsError(try bridge.record(caches: [paged], binding: secondBinding))
        await XCTAssertThrowsErrorAsync(try await allocator.materializeContiguousByteCache(second))
    }

    func testConversationKeyWithoutRetainedHandoffRunsAsFreshSchedulerRow() async throws {
        let backend = RuntimeBridgeScriptedBackend(scripts: ["keyed": [7]])
        let scheduler = try Self.makeScheduler(maxActiveRows: 2, backend: backend)

        let result = try await scheduler.submit(.init(
            id: "keyed",
            conversationKey: "conversation-1",
            promptTokens: [1],
            maxOutputTokens: 1,
            temperature: 0.0,
            topP: 1.0
        ))
        let decodeCallCount = await backend.decodeCallCount()
        XCTAssertEqual(result.terminalStatus, .length)
        XCTAssertEqual(result.conversationKey, "conversation-1")
        XCTAssertEqual(result.cachedPromptTokens, 0)
        XCTAssertEqual(result.outputTokens, [7])
        XCTAssertEqual(decodeCallCount, 0)
    }

    private static func makeScheduler(
        maxActiveRows: Int,
        backend: any ContinuousBatchSchedulerBackend,
        maxPhysicalBlocks: Int = 16,
        maxPromptChunkTokens: Int = 256,
        replayAuthority: any ContinuousBatchSchedulerReplayAuthority = RuntimeBridgeReplayAuthority()
    ) throws -> ContinuousBatchScheduler {
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: 4,
            maxPhysicalBlocks: maxPhysicalBlocks,
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
                maxPromptChunkTokens: maxPromptChunkTokens,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: descriptor.modelID,
                    modelSHA256: descriptor.modelSHA256,
                    weightsGeneration: 1
                )
            ),
            allocator: try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: maxPhysicalBlocks),
            backend: backend,
            replayAuthority: replayAuthority
        )
    }

    private static func schedulerRequest(
        id: String,
        promptTokens: [Int],
        maxOutputTokens: Int,
        decodePath: DecodePath = .ordinary,
        nativeMTPMaximumProposalDepth: Int = 0,
        nativeMTPTupleFence: NativeMTPTupleFence? = nil,
        nativeMTPIntegrityProbe: Bool = false
    ) -> ContinuousBatchSchedulerRequest {
        ContinuousBatchSchedulerRequest(
            id: id,
            conversationKey: "",
            promptTokens: promptTokens,
            maxOutputTokens: maxOutputTokens,
            samplerSeed: ContinuousBatchRowSampler.requestSeed(requestID: id),
            temperature: 0,
            topP: 1,
            decodePath: decodePath,
            nativeMTPMaximumProposalDepth: nativeMTPMaximumProposalDepth,
            nativeMTPCompleteWindowBytesByDepth: decodePath == .nativeMTP
                ? Array(repeating: 16, count: max(1, nativeMTPMaximumProposalDepth + 1))
                : [],
            nativeMTPTupleFence: nativeMTPTupleFence,
            nativeMTPIntegrityProbe: nativeMTPIntegrityProbe
        )
    }

    private static func nativeMTPFence(
        admission: String = String(repeating: "a", count: 64),
        snapshot: String = "snapshot",
        generation: UInt64 = 1
    ) -> NativeMTPTupleFence {
        NativeMTPTupleFence(
            admissionTupleSHA256: admission,
            servedSnapshotID: snapshot,
            targetGeneration: generation
        )
    }

    private static func qwen35HybridConfig(
        layerTypes: [String]? = nil,
        includeMTPMetadata: Bool = true
    ) -> Data {
        let defaultLayers = (0..<32).map { index in
            (index + 1).isMultiple(of: 4) ? "full_attention" : "linear_attention"
        }
        var textConfig: [String: Any] = [
            "model_type": "qwen3_5_text",
            "num_hidden_layers": 32,
            "full_attention_interval": 4,
            "layer_types": layerTypes ?? defaultLayers,
        ]
        if includeMTPMetadata {
            textConfig["mtp_num_hidden_layers"] = 1
            textConfig["mtp_use_dedicated_embeddings"] = false
        }
        let object: [String: Any] = [
            "model_type": "qwen3_5",
            "architectures": ["Qwen3_5ForConditionalGeneration"],
            "text_config": textConfig,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Two-layer hybrid (one gated-delta recurrent layer, one full-attention
    /// layer) with a one-layer MTP head, small enough for unit tests. The
    /// gated-delta Metal kernel needs key heads of a multiple of 32.
    private static let tinyQwen35HybridConfiguration = """
        {
          "model_type": "qwen3_5_text",
          "hidden_size": 16,
          "num_hidden_layers": 2,
          "intermediate_size": 32,
          "num_attention_heads": 2,
          "num_key_value_heads": 1,
          "head_dim": 8,
          "linear_num_value_heads": 2,
          "linear_num_key_heads": 1,
          "linear_key_head_dim": 32,
          "linear_value_head_dim": 32,
          "linear_conv_kernel_dim": 2,
          "rms_norm_eps": 1e-6,
          "vocab_size": 8,
          "rope_theta": 100000.0,
          "partial_rotary_factor": 0.25,
          "max_position_embeddings": 128,
          "tie_word_embeddings": true,
          "attention_bias": false,
          "full_attention_interval": 2,
          "mtp_num_hidden_layers": 1,
          "mtp_use_dedicated_embeddings": false,
          "rope_parameters": {
            "type": "default",
            "rope_theta": 100000.0,
            "partial_rotary_factor": 0.25
          }
        }
        """

    private static func bridgeDescriptor(blockSizeTokens: Int = 4, maxPhysicalBlocks: Int = 16) -> PagedKVDescriptor {
        PagedKVDescriptor(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
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

    private static func fp16Bytes(_ values: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 2)
        for value in values {
            var littleEndian = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static func decodeInput(
        requestID: String,
        currentToken: Int,
        handle: PagedKVBlockTableHandle,
        allocator: PagedKVBlockAllocator,
        committedKVTokenCount: Int,
        extendBy: Int = 1,
        beginDecode: Bool = true,
        targetOffset: Int = 1
    ) async throws -> ContinuousBatchDecodeInput {
        let targetKVTokenCount = committedKVTokenCount + targetOffset
        if extendBy > 0 {
            _ = try await allocator.extend(handle, by: extendBy)
        }
        if beginDecode {
            try await allocator.beginDecodeStep(handle)
        }
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

    private static func pagedRows(
        descriptor: PagedKVDescriptor,
        allocator: PagedKVBlockAllocator,
        ids: [String],
        initialOffsets: [Int]
    ) async throws -> [PagedKVCache] {
        precondition(ids.count == initialOffsets.count)
        var rows: [PagedKVCache] = []
        rows.reserveCapacity(ids.count)
        for (id, offset) in zip(ids, initialOffsets) {
            let handle = try await allocator.allocate(conversationKey: id, maxTokens: 8)
            let binding = try await allocator.binding(for: handle)
            rows.append(PagedKVCache(
                blockSizeTokens: descriptor.blockSizeTokens,
                maxPhysicalBlocks: descriptor.maxPhysicalBlocks,
                poolEpoch: descriptor.poolEpoch,
                binding: binding,
                initialOffset: offset,
                reconstructViaGather: false
            ))
        }
        return rows
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
        backend: RuntimeBridgeScriptedBackend,
        promptTokens: [Int32] = [3]
    ) -> ModelRuntime {
        let modelSHA = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: RuntimeBridgePromptProcessor(tokens: promptTokens),
            tokenizer: RuntimeBridgeFakeTokenizer()
        ))
        return ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2,
            continuousBatchingMode: .on,
            continuousBatchingDurableReplayAuthorityAvailable: true,
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

    /// A parity probe result that satisfies every gate in `measurePagedKVRuntime`
    /// (`established`, `gatherKernelCalls == nLayers * nNew * 2`, `maxLogicalBlocks >= 3`,
    /// `nonIdentityPermutation`). Used wherever a test needs the parity leg of the
    /// pipeline to be genuinely satisfied so it can isolate a DIFFERENT gate (kernel
    /// identifier, hardware fingerprint, MoE proof, tuple binding) as the thing under test.
    private static func establishedParityProbe(nLayers: Int = 2, nNew: Int = 4) -> PagedKVRuntimeParityProbeResult {
        PagedKVRuntimeParityProbeResult(
            established: true,
            nLayers: nLayers,
            nNew: nNew,
            gatherKernelCalls: nLayers * nNew * 2,
            maxLogicalBlocks: 3,
            nonIdentityPermutation: true
        )
    }

    /// A fully-proven batched shared-forward isolation probe. `measurePagedKVRuntime` now
    /// requires this for EVERY paging-eligible model (dense and MoE alike), since the
    /// serve-time batched decode path's cross-row mask is family-independent, so dense
    /// tests must supply it too. `moeDispatchProven` stays MoE-specific and is derived
    /// from `requiresMoEDispatch`, not from this probe.
    private static func provenBatchedProbe() -> PagedKVRuntimeMoEProbeResult {
        PagedKVRuntimeMoEProbeResult(
            proven: true,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: 0,
            sharedForwardParityProven: true,
            parityTokensCompared: PagedKVRuntimeParityProbe.sharedForwardParityTokens,
            challengeDistinguishing: true
        )
    }

    /// A `PagedKVRuntimeMeasurementEnvironment` with a present, readable metallib and a
    /// valid hardware fingerprint — the "everything the environment itself needs to say
    /// yes" fixture, reused by tests that vary the parity/MoE probe instead.
    private static func liveMeasurementEnvironment(
        metallibBytes: Data = Data("packaged metallib bytes".utf8)
    ) -> PagedKVRuntimeMeasurementEnvironment {
        PagedKVRuntimeMeasurementEnvironment(
            metallibCandidatePaths: { ["/tmp/present/default.metallib"] },
            fileExists: { $0 == "/tmp/present/default.metallib" },
            readFileData: { _ in metallibBytes },
            hardwareFingerprint: {
                MachineFingerprint(
                    ramGB: 64,
                    chip: "Apple M-test",
                    osVersion: "macOS test",
                    binaryVersion: "test"
                )
            },
            registeredKernelIdentifier: { PagedKVGatherKernel.registeredKernelName }
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

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
}

private final class RuntimeBridgeFakeModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1]
    private let vocabularySize: Int
    private let nextTokenByInput: [Int: Int]
    private let emitsMTPState: Bool
    private let lock = NSLock()
    private var forwardCalls = 0

    init(vocabularySize: Int = 32, nextTokenByInput: [Int: Int], emitsMTPState: Bool = false) {
        self.vocabularySize = vocabularySize
        self.nextTokenByInput = nextTokenByInput
        self.emitsMTPState = emitsMTPState
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        lock.lock()
        forwardCalls += 1
        lock.unlock()
        let batch = input.tokens.dim(0)
        let sequenceLength = input.tokens.dim(1)
        let flatTokens = input.tokens.asArray(Int32.self).map(Int.init)
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
        var outputState: LMOutput.State?
        if emitsMTPState, state?[mtpEmitFlagKey] != nil {
            var state = LMOutput.State()
            state[mtpLastHiddenStatesKey] = MLXArray.zeros([batch, sequenceLength, 2])
            outputState = state
        }
        return LMOutput(
            logits: MLXArray(logits, [batch, sequenceLength, vocabularySize]),
            state: outputState
        )
    }

    func forwardCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return forwardCalls
    }
}

/// Forwards to the real backend and records each native finalize batch.
private final class RuntimeBridgeRecordingNativeMTPBackend: ContinuousBatchSchedulerBackend, @unchecked Sendable {
    let base: PagedKVSharedForwardBackend
    private let lock = NSLock()
    private var finalized: [[ContinuousBatchNativeMTPFinalizeInput]] = []
    private var proposals: [String: [Int: [Int]]] = [:]
    private var capturedDecodeSteps: [String: [Int]] = [:]
    private var verifyHook: (@Sendable ([String]) async -> Void)?

    /// Runs before each packed verify with the round's request IDs.
    var onVerify: (@Sendable ([String]) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return verifyHook
        }
        set {
            lock.lock()
            verifyHook = newValue
            lock.unlock()
        }
    }

    init(_ base: PagedKVSharedForwardBackend) {
        self.base = base
    }

    func finalizedRounds() -> [[ContinuousBatchNativeMTPFinalizeInput]] {
        lock.lock()
        defer { lock.unlock() }
        return finalized
    }

    /// Backend proposals by request ID and sampler step (committed tokens).
    func proposalsByStep() -> [String: [Int: [Int]]] {
        lock.lock()
        defer { lock.unlock() }
        return proposals
    }

    /// Sampler steps at which a native row rode the ordinary forward.
    func capturedDecodeStepsByRow() -> [String: [Int]] {
        lock.lock()
        defer { lock.unlock() }
        return capturedDecodeSteps
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        try await base.prefill(rows: rows)
    }

    func decode(rows: [ContinuousBatchDecodeInput]) async throws -> [ContinuousBatchDecodeOutcome] {
        try await base.decode(rows: rows)
    }

    func decodeLockstepWindow(
        rows: [ContinuousBatchDecodeInput],
        steps: Int,
        onStep: ContinuousBatchDecodeWindowStepObserver?
    ) async throws -> [ContinuousBatchDecodeOutcome] {
        lock.lock()
        for row in rows where row.captureNativeMTPDrafterColumns {
            capturedDecodeSteps[row.requestID, default: []].append(row.samplerStep)
        }
        lock.unlock()
        return try await base.decodeLockstepWindow(rows: rows, steps: steps, onStep: onStep)
    }

    func proposeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]? {
        let result = try await base.proposeNativeMTPPackedRound(rows: rows)
        lock.lock()
        for row in rows {
            if let proposal = result?[row.requestID], !proposal.isEmpty {
                proposals[row.requestID, default: [:]][row.samplerStep] = proposal
            }
        }
        lock.unlock()
        return result
    }

    func verifyNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
        await onVerify?(rows.map(\.requestID))
        return try await base.verifyNativeMTPPackedRound(rows: rows)
    }

    func finalizeNativeMTPPackedRound(rows: [ContinuousBatchNativeMTPFinalizeInput]) async throws {
        lock.lock()
        finalized.append(rows)
        lock.unlock()
        try await base.finalizeNativeMTPPackedRound(rows: rows)
    }

    func installRetainedPagedKVCache(
        requestID: String,
        handoff: PagedKVPagedCacheHandoff,
        binding: PagedKVStorageBinding,
        recurrentCheckpoint: RecurrentStateCheckpoint?
    ) async throws {
        try await base.installRetainedPagedKVCache(
            requestID: requestID,
            handoff: handoff,
            binding: binding,
            recurrentCheckpoint: recurrentCheckpoint
        )
    }

    func commitTerminalKV(_ input: ContinuousBatchTerminalKVCommitInput) async throws {
        try await base.commitTerminalKV(input)
    }

    func snapshotRecurrentState(requestID: String, tokenCount: Int) async -> RecurrentStateCheckpoint? {
        await base.snapshotRecurrentState(requestID: requestID, tokenCount: tokenCount)
    }

    func materializeSerialConversationCache(
        requestID: String,
        binding: PagedKVStorageBinding,
        tokenCount: Int,
        recurrentCheckpoints: [RecurrentStateCheckpoint]
    ) async throws -> ContinuousBatchSerialConversationCache? {
        try await base.materializeSerialConversationCache(
            requestID: requestID,
            binding: binding,
            tokenCount: tokenCount,
            recurrentCheckpoints: recurrentCheckpoints
        )
    }

    func finish(requestID: String) {
        base.finish(requestID: requestID)
    }

    func cancelInFlight() async {
        await base.cancelInFlight()
    }
}

private final class RuntimeBridgeUnknownKVCache: KVCache {
    var offset: Int
    var maxSize: Int? { nil }
    var state: [MLXArray]
    var metaState: [String] = ["runtime_bridge_unknown_kv_cache"]
    var isTrimmable: Bool { false }

    init(offset: Int, state: [MLXArray]) {
        self.offset = offset
        self.state = state
    }

    func innerState() -> [MLXArray] { state }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        offset += keys.ndim >= 3 ? keys.dim(keys.ndim - 2) : 0
        state = [keys, values]
        return (keys, values)
    }

    @discardableResult
    func trim(_ n: Int) -> Int { 0 }

    func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        .none
    }

    func copy() -> any KVCache {
        RuntimeBridgeUnknownKVCache(offset: offset, state: state)
    }
}

private final class RuntimeBridgeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Sets the flag; returns true only for the call that set it.
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}

/// Holds a task started from inside a token sink so the test can await it.
private final class RuntimeBridgeTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ContinuousBatchSchedulerResult, any Error>?

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    func start(_ body: @escaping @Sendable () async throws -> ContinuousBatchSchedulerResult) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { try await body() }
    }

    func value() async throws -> ContinuousBatchSchedulerResult {
        while true {
            lock.lock()
            let current = task
            lock.unlock()
            if let current { return try await current.value }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class RuntimeBridgePendingColumnsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Int?

    func record(_ count: Int) {
        lock.lock()
        recorded = count
        lock.unlock()
    }

    func value() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class RuntimeBridgeRecordingMTPDrafter: Module, StatefulMTPDrafterModel {
    let maximumBlockSize: Int? = 2
    let requiresSharedTargetKV = false
    let requiresPromptPrefill = true
    let requiresGreedySampling = true
    private let lock = NSLock()
    private var promptWidths: [Int] = []
    private var hiddenWidths: [Int] = []

    func makeState(parameters: GenerateParameters?) -> MTPDrafterState {
        MTPDrafterState(cache: [])
    }

    func prepareDrafterState(
        target: any LanguageModel,
        promptTokens: MLXArray,
        targetHidden: MLXArray,
        firstBonus: MLXArray,
        positionDeltas: MLXArray?,
        state: inout MTPDrafterState,
        sampler: any LogitSampler
    ) {
        lock.lock()
        promptWidths.append(promptTokens.dim(1))
        hiddenWidths.append(targetHidden.dim(1))
        lock.unlock()
    }

    func draftBlock(
        target: any LanguageModel,
        lastToken: MLXArray,
        lastHidden: MLXArray,
        sharedKV: [String: (MLXArray, MLXArray)],
        positionDeltas: MLXArray?,
        queryOffset: Int,
        blockSize: Int,
        state: inout MTPDrafterState,
        sampler: any LogitSampler
    ) -> MLXArray {
        MLXArray.zeros([1, max(0, blockSize - 1)], dtype: .int32)
    }

    func draftBlock(
        target: any LanguageModel,
        lastToken: MLXArray,
        lastHidden: MLXArray,
        sharedKV: [String: (MLXArray, MLXArray)],
        queryOffset: Int,
        blockSize: Int,
        sampler: any LogitSampler
    ) -> MLXArray {
        draftBlock(
            target: target,
            lastToken: lastToken,
            lastHidden: lastHidden,
            sharedKV: sharedKV,
            positionDeltas: nil,
            queryOffset: queryOffset,
            blockSize: blockSize,
            sampler: sampler)
    }

    func draftBlock(
        target: any LanguageModel,
        lastToken: MLXArray,
        lastHidden: MLXArray,
        sharedKV: [String: (MLXArray, MLXArray)],
        positionDeltas: MLXArray?,
        queryOffset: Int,
        blockSize: Int,
        sampler: any LogitSampler
    ) -> MLXArray {
        MLXArray.zeros([1, max(0, blockSize - 1)], dtype: .int32)
    }

    func preparedPromptWidths() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return promptWidths
    }

    func preparedHiddenWidths() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return hiddenWidths
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
            let flatTokens = input.tokens.asArray(Int32.self).map(Int.init)
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
    private let nativeProposalScripts: [String: [[Int]]]
    private let prefillGate: RuntimeBridgeTestGate?
    private let decodeGate: RuntimeBridgeTestGate?
    private let nativeVerifyGate: RuntimeBridgeTestGate?
    private let nativeVerifyGateCall: Int
    private let prefillError: (any Error)?
    private var decodeCalls = 0
    private var prefillCalls = 0
    private var nativeProposalCallsByID: [String: Int] = [:]
    private var nativeVerifyCalls = 0
    private var nativeFinalizeRows: [ContinuousBatchNativeMTPFinalizeInput] = []
    private var prefillLengths: [Int] = []
    private var batches: [[String]] = []

    init(
        scripts: [String: [Int]],
        nativeProposalScripts: [String: [[Int]]] = [:],
        prefillGate: RuntimeBridgeTestGate? = nil,
        decodeGate: RuntimeBridgeTestGate? = nil,
        nativeVerifyGate: RuntimeBridgeTestGate? = nil,
        nativeVerifyGateCall: Int = 1,
        prefillError: (any Error)? = nil
    ) {
        self.scripts = scripts
        self.nativeProposalScripts = nativeProposalScripts
        self.prefillGate = prefillGate
        self.decodeGate = decodeGate
        self.nativeVerifyGate = nativeVerifyGate
        self.nativeVerifyGateCall = nativeVerifyGateCall
        self.prefillError = prefillError
    }

    func prefill(rows: [ContinuousBatchPrefillInput]) async throws -> [ContinuousBatchPrefillOutput] {
        prefillCalls += 1
        prefillLengths.append(contentsOf: rows.map(\.promptTokens.count))
        if prefillCalls == 1, let prefillGate {
            await prefillGate.wait()
        }
        if let prefillError {
            throw prefillError
        }
        return rows.map { row in
            let script = scripts[row.requestID] ?? []
            return ContinuousBatchPrefillOutput(
                requestID: row.requestID,
                sampledToken: row.sampleFirstToken ? (script.first ?? row.promptTokens.last) : nil
            )
        }
    }

    func proposeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPProposalInput]
    ) async throws -> [String: [Int]]? {
        var proposals: [String: [Int]] = [:]
        for row in rows {
            let call = nativeProposalCallsByID[row.requestID] ?? 0
            nativeProposalCallsByID[row.requestID] = call + 1
            let scripts = nativeProposalScripts[row.requestID] ?? []
            proposals[row.requestID] = call < scripts.count ? scripts[call] : []
        }
        return proposals
    }

    func verifyNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPVerifyInput]
    ) async throws -> [NativeMTPVerifiedRow] {
        nativeVerifyCalls += 1
        if nativeVerifyCalls == nativeVerifyGateCall, let nativeVerifyGate {
            await nativeVerifyGate.wait()
        }
        return rows.map { row in
            NativeMTPVerifiedRow(
                schedulerRowID: row.requestID,
                packedRowIndex: row.packedRowIndex,
                proposedTokenIDs: row.proposalTokens,
                targetTopTokenIDs: row.proposalTokens + [10_000 + nativeVerifyCalls]
            )
        }
    }

    func finalizeNativeMTPPackedRound(
        rows: [ContinuousBatchNativeMTPFinalizeInput]
    ) async throws {
        nativeFinalizeRows.append(contentsOf: rows)
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

    func prefillCallCount() -> Int {
        prefillCalls
    }

    func prefillPromptLengths() -> [Int] {
        prefillLengths
    }

    func decodeBatches() -> [[String]] {
        batches
    }

    func nativeFinalizeInputs() -> [ContinuousBatchNativeMTPFinalizeInput] {
        nativeFinalizeRows
    }
}

private final class RuntimeBridgeRecordingCacheBridge: PagedKVRuntimeCacheBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Set<UUID> = []
    private var discarded: [UUID] = []

    func record(caches: [PagedKVCache], binding: PagedKVStorageBinding) throws {
        lock.lock()
        recorded.insert(binding.handle.handleID)
        lock.unlock()
    }

    func discard(handle: PagedKVBlockTableHandle) {
        discardContiguousCache(handle: handle)
    }

    func discardContiguousCache(handle: PagedKVBlockTableHandle) {
        lock.lock()
        recorded.remove(handle.handleID)
        discarded.append(handle.handleID)
        lock.unlock()
    }

    func hasRecord(for handle: PagedKVBlockTableHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recorded.contains(handle.handleID)
    }

    func discardedHandles() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return discarded
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

    func release(_ key: ContinuousBatchSchedulerReplayKey) {
        lock.lock()
        defer { lock.unlock() }
        keys.remove("\(key.requestID):\(key.fingerprintSHA256.base64EncodedString())")
    }
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ContinuousBatchDecodeWindowStep] = []

    func append(_ step: ContinuousBatchDecodeWindowStep) {
        lock.lock()
        stored.append(step)
        lock.unlock()
    }

    func steps() -> [ContinuousBatchDecodeWindowStep] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
