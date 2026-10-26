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
    // CPU-only scheduler fixtures change the process-wide default device. Pin
    // this Metal-backed class for each invocation so test order cannot route
    // GPU-only model kernels to the CPU. Explicit CPU scopes below still win.
    override func invokeTest() {
        guard Self.metallibAvailable else { return super.invokeTest() }
        Device.withDefaultDevice(Device(.gpu)) {
            super.invokeTest()
        }
    }

    private static var metallibAvailable: Bool {
        let bundle = Bundle(for: PagedKVRuntimeBridgeTests.self)
        return PagedKVMetallibGate.defaultMetallibExists(
            bundleURL: bundle.resourceURL, executableURL: bundle.executableURL
        ) || PagedKVMetallibGate.defaultMetallibExists()
    }

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

    // SPEC-049-R010: the live relay-to-row mapping carries the ingest
    // provenance, so the replay authority can keep privacy claims in memory.
    func testProductionSchedulerSubmissionCarriesIngestProvenance() throws {
        let base = try Self.chatRequest(modelID: "mlx-community/Qwen-Test", maxTokens: 1)
            .withRequestID("relay-request-2015")
        for provenance in KVIngestProvenance.allCases {
            let submission = try ModelRuntime.continuousBatchSubmission(
                for: base.withIngestProvenance(provenance),
                promptTokens: [1, 2],
                maxOutputTokens: 1
            )
            XCTAssertEqual(submission.schedulerRequest.ingestProvenance, provenance)
        }
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
        try requireMetal()

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

    /// A real tiny Qwen native row at offset four shares the ordinary row's
    /// offset-zero target forward. Its target caches, sampled output and
    /// continued greedy decode match the same ragged group with MTP disabled,
    /// while its drafter seed matches a definitional whole-prompt seed.
    func testRealQwen35NativeRowInRaggedSharedPrefillMatchesMTPDisabledGroup() async throws {
        try requireMetal()
        let nativePrompt = Self.tinyPrompt(length: 8, salt: 11)
        let ordinaryPrompt = Self.tinyPrompt(length: 4, salt: 12)
        let ids = ["native", "ordinary"]
        let steps = 4

        func run(nativeRow: Bool) async throws -> (
            tokens: [String: [Int]],
            targetCacheDigests: [String: String],
            seedToken: Int?,
            definitionalSeedToken: Int?
        ) {
            let tiny = try Self.tinyQwen35Native()
            let backend = tiny.backend.base
            XCTAssertTrue(backend.nativeMTPPromptRowsJoinRaggedPrefill)
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
            let nativeHandle = try await allocator.allocate(conversationKey: ids[0], maxTokens: 16)
            let ordinaryHandle = try await allocator.allocate(conversationKey: ids[1], maxTokens: 16)
            let handles = [nativeHandle, ordinaryHandle]

            _ = try await allocator.extend(nativeHandle, by: 4)
            let firstChunk = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: ids[0],
                promptTokens: Array(nativePrompt[0 ..< 4]),
                binding: try await allocator.binding(for: nativeHandle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: 4,
                isFinalChunk: false,
                nativeMTPPromptPrefill: nativeRow,
                nativeMTPNextPromptToken: nativeRow ? nativePrompt[4] : nil
            )])
            XCTAssertEqual(firstChunk, [ContinuousBatchPrefillOutput(requestID: ids[0])])

            _ = try await allocator.extend(nativeHandle, by: 4)
            _ = try await allocator.extend(ordinaryHandle, by: 4)
            let inputs = [
                ContinuousBatchPrefillInput(
                    requestID: ids[0],
                    promptTokens: Array(nativePrompt[4 ..< 8]),
                    binding: try await allocator.binding(for: nativeHandle),
                    promptTokenOffset: 4,
                    committedKVTokenCount: 4,
                    targetKVTokenCount: 8,
                    isFinalChunk: true,
                    nativeMTPPromptPrefill: nativeRow
                ),
                ContinuousBatchPrefillInput(
                    requestID: ids[1],
                    promptTokens: ordinaryPrompt,
                    binding: try await allocator.binding(for: ordinaryHandle),
                    promptTokenOffset: 0,
                    committedKVTokenCount: 0,
                    targetKVTokenCount: 4,
                    isFinalChunk: true
                ),
            ]
            XCTAssertTrue(PagedKVSharedForwardBackend.hasRaggedPromptOffsets(inputs))
            XCTAssertEqual(PagedKVSharedForwardBackend.canSharePrefillForward(inputs), !nativeRow)
            XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward(
                inputs,
                nativeMTPPromptRowsJoinRaggedPrefill: backend.nativeMTPPromptRowsJoinRaggedPrefill
            ))
            let prefill = try await backend.prefill(rows: inputs)
            var tokens: [String: [Int]] = [:]
            for output in prefill {
                tokens[output.requestID] = [try XCTUnwrap(output.sampledToken, output.failureCode ?? "")]
            }
            var targetCacheDigests: [String: String] = [:]
            for id in ids {
                targetCacheDigests[id] = try backend.rowTargetCacheDigestForTest(requestID: id)
            }
            let snapshot = backend.nativeMTPDrafterSnapshotForTest(requestID: ids[0])
            let definitionalSeed = nativeRow ? try Self.definitionalDrafterSeed(
                target: tiny.target,
                drafter: tiny.drafter,
                prompt: nativePrompt,
                generated: [try XCTUnwrap(tokens[ids[0]]?.first)]
            ) : nil
            for step in 0 ..< steps {
                var decodeInputs: [ContinuousBatchDecodeInput] = []
                for (index, id) in ids.enumerated() {
                    decodeInputs.append(try await Self.decodeInput(
                        requestID: id,
                        currentToken: try XCTUnwrap(tokens[id]?.last),
                        handle: handles[index],
                        allocator: allocator,
                        committedKVTokenCount: (index == 0 ? nativePrompt.count : ordinaryPrompt.count) + step
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
            return (tokens, targetCacheDigests, snapshot.seedToken, definitionalSeed)
        }

        let ordinary = try await run(nativeRow: false)
        let mixed = try await run(nativeRow: true)
        for id in ids {
            XCTAssertEqual(ordinary.tokens[id]?.count, steps + 1, id)
            XCTAssertEqual(mixed.tokens[id], ordinary.tokens[id], "\(id) diverged from the MTP-disabled group")
            XCTAssertEqual(
                mixed.targetCacheDigests[id],
                ordinary.targetCacheDigests[id],
                "\(id) target cache diverged during ragged native prefill"
            )
        }
        XCTAssertNotNil(mixed.seedToken)
        XCTAssertEqual(mixed.seedToken, mixed.definitionalSeedToken)
        XCTAssertNil(ordinary.seedToken)
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
        XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward(
            [atZero, nativeAtFour],
            nativeMTPPromptRowsJoinRaggedPrefill: true
        ))
        XCTAssertTrue(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, nativeAtZero]))
        XCTAssertFalse(PagedKVSharedForwardBackend.canSharePrefillForward([atZero, lagging]))
    }

    func testNativeRaggedPrefillCapabilityIsBoundOnlyToQwenAdapter() {
        XCTAssertTrue(PagedKVSharedForwardBackend.supportsNativeMTPPromptRowsInRaggedPrefill(
            familyAdapter: "qwen3_5_mtp_v1"
        ))
        XCTAssertFalse(PagedKVSharedForwardBackend.supportsNativeMTPPromptRowsInRaggedPrefill(
            familyAdapter: "glm5_next_mtp_v1"
        ))
        XCTAssertFalse(PagedKVSharedForwardBackend.supportsNativeMTPPromptRowsInRaggedPrefill(
            familyAdapter: nil
        ))
    }

    func testGroupedPrefillRowsRunAloneOnlyUnderAFlattenedTokenCapBelowTwoGroupedChunks() {
        typealias Backend = PagedKVSharedForwardBackend
        let mla: [Backend.CacheKind] = [.recurrentMamba, .pagedMLA(kpool: 4)]
        let glmRule = ContinuousBatchPrefillGroupingRule.sortedGatherMoE(numExperts: 288, topK: 8)
        XCTAssertEqual(glmRule.minimumGroupedChunkTokens, 144)
        XCTAssertTrue(Backend.prefillsGroupedRowsAlone(cacheKinds: mla, minimumGroupedChunkTokens: glmRule.minimumGroupedChunkTokens))
        XCTAssertTrue(Backend.prefillsGroupedRowsAlone(cacheKinds: mla, minimumGroupedChunkTokens: Int.max))
        // Two 4-token rows fit the 8-token cap: they share a forward.
        XCTAssertFalse(Backend.prefillsGroupedRowsAlone(cacheKinds: mla, minimumGroupedChunkTokens: 4))
        XCTAssertTrue(Backend.prefillsGroupedRowsAlone(cacheKinds: mla, minimumGroupedChunkTokens: 5))
        // Without a flattened-token cap grouped rows may share a forward.
        XCTAssertFalse(Backend.prefillsGroupedRowsAlone(cacheKinds: [.pagedAttention], minimumGroupedChunkTokens: 144))
        XCTAssertFalse(Backend.prefillsGroupedRowsAlone(cacheKinds: [.slidingWindow(windowTokens: 128)], minimumGroupedChunkTokens: 33))
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

    /// Grouped CB prefill must not change a row's kernel route. A tiny real
    /// Qwen3.5 MoE (4 experts, top-2), every projection 4-bit, has a grouping
    /// bound of 33 tokens per chunk: below it a chunk alone takes `qmv`
    /// (`qmv_quad` at K 64) for its dense projections and an unsorted
    /// `gather_qmv` for its experts (48 selections), while two grouped chunks
    /// take `qmm` and the sorted gather. Two short prompts arriving together
    /// must therefore prefill alone and generate exactly what each generates
    /// by itself; two prompts at the bound share one forward and still match.
    func testRealQwen35MoEPrefillGroupingFollowsTheKernelRouteBound() async throws {
        try requireMetal()
        try await assertPrefillGroupingFollowsTheKernelRouteBound(
            configuration: Self.tinyQwen35MoEConfiguration,
            expectedBound: 33,
            requiresQuantizedExperts: true
        )
    }

    /// The same for a dense model (Qwen3.6-27B shape class): a shared prefill
    /// flattens rows x chunk into each quantized projection's M, so a
    /// 24-token chunk takes `qmv` alone and `qmm` beside a second row. Below
    /// the 33-token bound the rows prefill alone; at the bound they group,
    /// and both match their lone serial greedy tokens.
    func testRealQwen35DensePrefillGroupingFollowsTheKernelRouteBound() async throws {
        try requireMetal()
        try await assertPrefillGroupingFollowsTheKernelRouteBound(
            configuration: Self.tinyQwen35DenseConfiguration,
            expectedBound: 33,
            requiresQuantizedExperts: false
        )
    }

    private func assertPrefillGroupingFollowsTheKernelRouteBound(
        configuration json: String,
        expectedBound: Int,
        requiresQuantizedExperts: Bool
    ) async throws {
        let configData = Data(json.utf8)
        // The served artifacts declare 4-bit affine quantization at the top
        // level of `config.json`; the rule reads it from there.
        var served = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        served["quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let rule = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(
            try JSONSerialization.data(withJSONObject: served),
            modelID: nil
        )
        XCTAssertEqual(rule.minimumGroupedChunkTokens, expectedBound)

        let configuration = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: configData)
        MLXRandom.seed(1906)
        let target = Qwen35TextModel(configuration)
        quantize(model: target, groupSize: 64, bits: 4, mode: .affine)
        eval(target)
        let leaves = target.leafModules().flattened().map(\.1)
        XCTAssertFalse(
            leaves.contains { type(of: $0) == Linear.self },
            "every projection must run the quantized matmul kernels"
        )
        if requiresQuantizedExperts {
            XCTAssertTrue(
                leaves.contains { $0 is QuantizedSwitchLinear },
                "the expert projections must run the quantized gather kernels"
            )
        }

        func serialGreedy(_ prompt: [Int], count: Int) throws -> [Int] {
            let cache = try target.newCache(parameters: nil)
            var logits = target(MLXArray(prompt.map(Int32.init)).reshaped(1, prompt.count), cache: cache)
            var tokens: [Int] = []
            for _ in 0 ..< count {
                let next = argMax(logits[0, -1], axis: -1).item(Int.self)
                tokens.append(next)
                logits = target(MLXArray([Int32(next)]).reshaped(1, 1), cache: cache)
            }
            return tokens
        }

        let steps = 6
        let descriptor = Self.bridgeDescriptor(maxPhysicalBlocks: 128)
        for (length, expectedGroups) in [
            (24, [["hold"], ["row-a"], ["row-b"]]),
            (expectedBound, [["hold"], ["row-a", "row-b"]]),
        ] {
            let prompts = [
                "row-a": Self.tinyPrompt(length: length, salt: 31, vocabulary: 64),
                "row-b": Self.tinyPrompt(length: length, salt: 32, vocabulary: 64),
            ]
            let backend = RuntimeBridgeRecordingNativeMTPBackend(PagedKVSharedForwardBackend(
                container: ModelContainer(context: ModelContext(
                    configuration: ModelConfiguration(id: descriptor.modelID),
                    model: target,
                    processor: StandInUserInputProcessor(),
                    tokenizer: RuntimeBridgeFakeTokenizer()
                )),
                descriptor: descriptor,
                layerCount: 2,
                cacheKinds: [.recurrentMamba, .pagedAttention]
            ))
            let holdGate = RuntimeBridgeTestGate()
            backend.onPrefill = { ids in
                if ids.contains("hold") { await holdGate.wait() }
            }
            let scheduler = try Self.makeScheduler(
                maxActiveRows: 4,
                backend: backend,
                maxPhysicalBlocks: 128,
                maxPromptChunkTokens: 64,
                maxPrefillRowsPerIteration: 4,
                maxPrefillTokensPerIteration: 128,
                prefillGrouping: rule
            )
            // `hold` parks the pump inside its prefill so both rows queue and
            // are admitted in one pass with one cursor and chunk length.
            let hold = Task {
                try await scheduler.submit(Self.schedulerRequest(id: "hold", promptTokens: [1, 2], maxOutputTokens: 1))
            }
            try await Self.eventually { backend.prefillRequestGroups().count == 1 }
            var rows: [Task<ContinuousBatchSchedulerResult, Error>] = []
            for (index, id) in ["row-a", "row-b"].enumerated() {
                rows.append(Task {
                    try await scheduler.submit(Self.schedulerRequest(
                        id: id,
                        promptTokens: prompts[id]!,
                        maxOutputTokens: steps
                    ))
                })
                try await Self.eventually { await scheduler.metrics().waitingCount == index + 1 }
            }
            await holdGate.open()
            _ = try await hold.value
            var generated: [String: [Int]] = [:]
            for (id, task) in zip(["row-a", "row-b"], rows) {
                generated[id] = try await task.value.outputTokens
            }

            XCTAssertEqual(backend.prefillRequestGroups(), expectedGroups, "length \(length)")
            for id in ["row-a", "row-b"] {
                XCTAssertEqual(
                    generated[id],
                    try serialGreedy(prompts[id]!, count: steps),
                    "\(id) at length \(length) diverged from its lone serial run"
                )
            }
        }
    }

    /// The grouping bound also holds for ragged shared prefill (SPEC-038
    /// FR-CB2): a row mid-prompt and a row at offset 0 whose chunks share one
    /// length share a forward only at or above the bound. Below it (20-token
    /// chunks, bound 33) every chunk prefills alone; at 40-token chunks the
    /// second chunk of `row-a` and the first of `row-b` share one ragged
    /// forward. Either way each row generates exactly what it generates when
    /// it is the only row in the scheduler (same chunk partition).
    func testRealQwen35RaggedPrefillGroupingFollowsTheKernelRouteBound() async throws {
        try requireMetal()
        let configData = Data(Self.tinyQwen35DenseConfiguration.utf8)
        var served = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        served["quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let rule = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(
            try JSONSerialization.data(withJSONObject: served),
            modelID: nil
        )
        XCTAssertEqual(rule.minimumGroupedChunkTokens, 33)
        let configuration = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: configData)
        MLXRandom.seed(1906)
        let target = Qwen35TextModel(configuration)
        quantize(model: target, groupSize: 64, bits: 4, mode: .affine)
        eval(target)

        let steps = 6
        let descriptor = Self.bridgeDescriptor(maxPhysicalBlocks: 128)
        for (chunk, expectedGroups) in [
            (20, [["row-a"], ["row-a"], ["row-b"]]),
            (40, [["row-a"], ["row-a", "row-b"]]),
        ] {
            let prompts = [
                "row-a": Self.tinyPrompt(length: 2 * chunk, salt: 41, vocabulary: 64),
                "row-b": Self.tinyPrompt(length: chunk, salt: 42, vocabulary: 64),
            ]
            /// Runs `ids` through one scheduler; `row-b` is submitted while
            /// `row-a`'s first chunk is parked in the backend.
            func run(_ ids: [String]) async throws -> (groups: [[String]], tokens: [String: [Int]]) {
                let sharedBackend = PagedKVSharedForwardBackend(
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
                XCTAssertTrue(sharedBackend.supportsRaggedPrefillOffsets)
                let backend = RuntimeBridgeRecordingNativeMTPBackend(sharedBackend)
                let firstChunkGate = RuntimeBridgeTestGate()
                let parksFirstChunk = ids.count > 1
                backend.onPrefill = { prefillIDs in
                    if parksFirstChunk, prefillIDs == ["row-a"], backend.prefillRequestGroups().count == 1 {
                        await firstChunkGate.wait()
                    }
                }
                let scheduler = try Self.makeScheduler(
                    maxActiveRows: 4,
                    backend: backend,
                    maxPhysicalBlocks: 128,
                    maxPromptChunkTokens: chunk,
                    maxPrefillRowsPerIteration: 4,
                    maxPrefillTokensPerIteration: 4 * chunk,
                    prefillGrouping: rule,
                    allowsRaggedPrefillOffsets: true
                )
                var tasks: [Task<ContinuousBatchSchedulerResult, Error>] = []
                for (index, id) in ids.enumerated() {
                    tasks.append(Task {
                        try await scheduler.submit(Self.schedulerRequest(
                            id: id,
                            promptTokens: prompts[id]!,
                            maxOutputTokens: steps
                        ))
                    })
                    if parksFirstChunk, index == 0 {
                        try await Self.eventually { backend.prefillRequestGroups().count == 1 }
                    }
                }
                if parksFirstChunk {
                    try await Self.eventually { await scheduler.metrics().waitingCount == 1 }
                    await firstChunkGate.open()
                }
                var tokens: [String: [Int]] = [:]
                for (id, task) in zip(ids, tasks) {
                    tokens[id] = try await task.value.outputTokens
                }
                return (backend.prefillRequestGroups(), tokens)
            }

            let grouped = try await run(["row-a", "row-b"])
            XCTAssertEqual(grouped.groups, expectedGroups, "chunk \(chunk)")
            for id in ["row-a", "row-b"] {
                let alone = try await run([id])
                XCTAssertEqual(grouped.tokens[id]?.count, steps, "\(id) chunk \(chunk)")
                XCTAssertEqual(grouped.tokens[id], alone.tokens[id], "\(id) at chunk \(chunk) diverged from its lone run")
            }
        }
    }

    /// SPEC-038 FR-CB2 ragged shared prefill, driven through the ragged batch
    /// cache the backend builds and `attentionWithCacheUpdate`, at the served
    /// attention shapes (Qwen3.6-35B-A3B 16 query / 2 KV heads and 27B 24 / 4
    /// at head dim 256; head dim 128): every row's output is bit-identical to
    /// the same row attended alone, and each row cache holds exactly its
    /// history plus its own chunk. Key lengths straddle the 4096-key softmax
    /// switch of the unfused path, which a single padded call chooses from
    /// the longest row.
    func testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise() throws {
        try requireMetal()
        MLXRandom.seed(1906)
        try assertBatchCacheAttentionMatchesLoneBits([
            BatchAttentionCase(label: "prefill", queryTokens: 33, histories: [0, 7, 30], ragged: true),
            BatchAttentionCase(label: "prefill", queryTokens: 128, histories: [3000, 3968, 2100], ragged: true),
            BatchAttentionCase(label: "prefill", queryTokens: 128, histories: [3900, 4100], ragged: true),
            BatchAttentionCase(label: "prefill", queryTokens: 128, histories: [7000, 8100], ragged: true),
        ])
    }

    /// SPEC-038 FR-CB2 decode and packed MTP verification isolation, through
    /// the shared decode batch cache, at the served attention shapes. Decode
    /// histories straddle the one-pass / two-pass switch (1024 keys) and the
    /// two-pass partition-count switch (16384 keys) of the vector kernels,
    /// which a single padded call chooses from the longest row; verification
    /// rows differ in offset and in real columns.
    func testSharedDecodeAndVerifyAttentionMatchLoneBitsAtServedHeadDims() throws {
        try requireMetal()
        MLXRandom.seed(1906)
        try assertBatchCacheAttentionMatchesLoneBits([
            BatchAttentionCase(label: "decode", queryTokens: 1, histories: [600, 901, 1501, 3000, 9000]),
            BatchAttentionCase(label: "decode", queryTokens: 1, histories: [1022, 1023, 4095, 16383, 16400]),
            BatchAttentionCase(label: "decode equal", queryTokens: 1, histories: [1501, 1501]),
            BatchAttentionCase(label: "verify", queryTokens: 3, histories: [600, 901, 1501, 3000], inputCounts: [3, 1, 2, 3]),
            BatchAttentionCase(label: "verify equal", queryTokens: 2, histories: [901, 901], inputCounts: [2, 2]),
        ])
    }

    /// The same isolation across a lockstep decode window: unequal rows take
    /// several steps through one batch cache (the serve window reuses it),
    /// crossing the 1024-key one-pass / two-pass switch mid-window, and every
    /// step of every row matches that row decoded alone step by step.
    func testSharedDecodeWindowAttentionMatchesLoneBitsEveryStep() throws {
        try requireMetal()
        MLXRandom.seed(1953)
        let (queryHeads, kvHeads, headDim) = (16, 2, 256)
        let scale = 1 / Float(headDim).squareRoot()
        let histories = [1019, 1500, 600, 9000]
        let steps = 8
        let historyKeys = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let historyValues = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let inputs = (0 ..< steps).map { _ in (
            queries: MLXRandom.normal([histories.count, queryHeads, 1, headDim]).asType(.bfloat16),
            keys: MLXRandom.normal([histories.count, kvHeads, 1, headDim]).asType(.bfloat16),
            values: MLXRandom.normal([histories.count, kvHeads, 1, headDim]).asType(.bfloat16)
        ) }
        eval(historyKeys + historyValues + inputs.flatMap { [$0.queries, $0.keys, $0.values] })
        let rowCaches = histories.indices.map { Self.attentionRowCache(history: historyKeys[$0], historyValues[$0]) }
        let windowed = PagedKVSharedForwardBackend.batchAttentionWindowForTest(
            rowCaches: rowCaches,
            steps: inputs,
            scale: scale
        )
        for row in histories.indices {
            let serial = Self.attentionRowCache(history: historyKeys[row], historyValues[row])
            for step in 0 ..< steps {
                let slice = { (array: MLXArray) in array[row ..< row + 1, 0..., 0..., 0...] }
                let lone = attentionWithCacheUpdate(
                    queries: slice(inputs[step].queries),
                    keys: slice(inputs[step].keys),
                    values: slice(inputs[step].values),
                    cache: serial,
                    scale: scale,
                    mask: serial.makeMask(n: 1, windowSize: nil, returnArray: false)
                )
                XCTAssertTrue(
                    arrayEqual(windowed[step][row ..< row + 1], lone).item(Bool.self),
                    "row \(row) (\(histories[row]) keys) step \(step)"
                )
            }
            XCTAssertEqual(rowCaches[row].offset, histories[row] + steps)
            XCTAssertTrue(arrayEqual(rowCaches[row].state[0], serial.state[0]).item(Bool.self), "row \(row) keys")
        }
    }

    private struct BatchAttentionCase {
        let label: String
        let queryTokens: Int
        let histories: [Int]
        var ragged = false
        /// Packed MTP verification: each row's `1 + proposals` columns.
        var inputCounts: [Int]?
    }

    /// Rows with their own histories share one call through the batch cache;
    /// each row's output must equal the same row attended alone (the serial
    /// cache path, and a one-row batch cache) bit for bit, and each row cache
    /// must hold exactly its history plus its own new tokens (verification
    /// stages and commits nothing). Prints, without asserting, the rows that
    /// a single padded call would have given other bits (device dependent).
    private func assertBatchCacheAttentionMatchesLoneBits(_ cases: [BatchAttentionCase]) throws {
        var paddedRouteDifferences: [String] = []
        for (queryHeads, kvHeads, headDim) in [(16, 2, 256), (24, 4, 256), (16, 2, 128)] {
            let scale = 1 / Float(headDim).squareRoot()
            for testCase in cases {
                let rows = testCase.histories.count
                let width = testCase.queryTokens
                let label = "\(testCase.label) \(queryHeads)/\(kvHeads)x\(headDim) histories \(testCase.histories)"
                let historyKeys = testCase.histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
                let historyValues = testCase.histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
                let queries = MLXRandom.normal([rows, queryHeads, width, headDim]).asType(.bfloat16)
                let keys = MLXRandom.normal([rows, kvHeads, width, headDim]).asType(.bfloat16)
                let values = MLXRandom.normal([rows, kvHeads, width, headDim]).asType(.bfloat16)
                eval(historyKeys + historyValues + [queries, keys, values])
                func caches(_ indices: [Int]) -> [PagedKVCache] {
                    indices.map { Self.attentionRowCache(history: historyKeys[$0], historyValues[$0]) }
                }
                func rowMaps(_ indices: [Int]) -> [MTPPackedVerificationRowMap]? {
                    testCase.inputCounts.map { counts in
                        indices.enumerated().map { position, row in
                            MTPPackedVerificationRowMap(
                                rowIndex: position,
                                queryOffset: testCase.histories[row],
                                inputCount: counts[row],
                                proposalCount: counts[row] - 1
                            )
                        }
                    }
                }

                let rowCaches = caches(Array(0 ..< rows))
                let batched = try PagedKVSharedForwardBackend.batchAttentionForTest(
                    rowCaches: rowCaches,
                    queries: queries,
                    keys: keys,
                    values: values,
                    scale: scale,
                    raggedPrefill: testCase.ragged,
                    mtpPackedRowMaps: rowMaps(Array(0 ..< rows))
                )
                XCTAssertEqual(batched.shape, queries.shape, label)

                for row in 0 ..< rows {
                    let columns = testCase.inputCounts?[row] ?? width
                    let rowQueries = queries[row ..< row + 1, 0..., ..<columns, 0...]
                    let rowKeys = keys[row ..< row + 1, 0..., ..<columns, 0...]
                    let rowValues = values[row ..< row + 1, 0..., ..<columns, 0...]
                    let ownOutput = batched[row ..< row + 1, 0..., ..<columns, 0...]
                    let oneRowBatch = try PagedKVSharedForwardBackend.batchAttentionForTest(
                        rowCaches: caches([row]),
                        queries: rowQueries,
                        keys: rowKeys,
                        values: rowValues,
                        scale: scale,
                        raggedPrefill: testCase.ragged,
                        mtpPackedRowMaps: rowMaps([row])
                    )
                    XCTAssertTrue(arrayEqual(ownOutput, oneRowBatch).item(Bool.self), "\(label) row \(row) vs one-row batch")
                    if testCase.inputCounts == nil {
                        let serial = caches([row])[0]
                        let lone = attentionWithCacheUpdate(
                            queries: rowQueries,
                            keys: rowKeys,
                            values: rowValues,
                            cache: serial,
                            scale: scale,
                            mask: serial.makeMask(n: columns, windowSize: nil, returnArray: false)
                        )
                        XCTAssertTrue(arrayEqual(ownOutput, lone).item(Bool.self), "\(label) row \(row) vs serial")
                        let state = rowCaches[row].state
                        XCTAssertEqual(rowCaches[row].offset, testCase.histories[row] + width, label)
                        XCTAssertTrue(arrayEqual(
                            state[0],
                            concatenated([historyKeys[row], rowKeys], axis: 2)
                        ).item(Bool.self), "\(label) row \(row) keys")
                        XCTAssertTrue(arrayEqual(
                            state[1],
                            concatenated([historyValues[row], rowValues], axis: 2)
                        ).item(Bool.self), "\(label) row \(row) values")
                    } else {
                        // Verification stages; nothing reaches the row cache.
                        XCTAssertEqual(rowCaches[row].offset, testCase.histories[row], label)
                        XCTAssertTrue(arrayEqual(rowCaches[row].state[0], historyKeys[row]).item(Bool.self), label)
                        if columns < width {
                            XCTAssertTrue(
                                all(batched[row ..< row + 1, 0..., columns..., 0...] .== 0).item(Bool.self),
                                "\(label) row \(row) padded columns"
                            )
                        }
                    }
                }

                // Evidence only: the single padded call the batch cache used
                // to make for unequal rows. Not asserted (its route depends
                // on the device).
                if testCase.inputCounts == nil, Set(testCase.histories).count > 1 {
                    let longest = testCase.histories.max()! + width
                    func padded(_ history: [MLXArray], _ incoming: MLXArray) -> MLXArray {
                        concatenated((0 ..< rows).map { row in
                            let own = concatenated([history[row], incoming[row ..< row + 1, 0..., 0..., 0...]], axis: 2)
                            let pad = longest - own.dim(2)
                            return pad == 0 ? own : concatenated(
                                [own, MLXArray.zeros([1, kvHeads, pad, headDim], dtype: own.dtype)],
                                axis: 2
                            )
                        }, axis: 0)
                    }
                    let mask = PagedKVSharedForwardBackend.batchLayerMaskForTest(
                        rowCaches: caches(Array(0 ..< rows)),
                        n: width,
                        windowSize: nil
                    )
                    let single = MLXFast.scaledDotProductAttention(
                        queries: queries,
                        keys: padded(historyKeys, keys),
                        values: padded(historyValues, values),
                        scale: scale,
                        mask: mask
                    )
                    for row in 0 ..< rows where !arrayEqual(single[row ..< row + 1], batched[row ..< row + 1]).item(Bool.self) {
                        let gap = abs(single[row ..< row + 1].asType(.float32) - batched[row ..< row + 1].asType(.float32))
                            .max().item(Float.self)
                        paddedRouteDifferences.append("\(label) row \(row) (\(testCase.histories[row]) keys) max |diff| \(gap)")
                    }
                }
            }
        }
        print("decode-isolation padded single call differs from lone (\(paddedRouteDifferences.count)):")
        paddedRouteDifferences.forEach { print("  \($0)") }
    }

    /// The vector-attention route port pins core `v0.32.4-macprovider.4`
    /// (`scaled_dot_product_attention.cpp` lines 754-763, 772-812, 1577): every
    /// pass-count and partition-count boundary on both sides. A rebase that
    /// moves one must update the port and this table.
    func testVectorAttentionRouteMatchesTheCoreDispatchBoundaries() {
        typealias R = PagedKVVectorAttentionRoute
        func route(_ n: Int, q: Int = 16, kv: Int = 2, d: Int = 256, l: Int = 1, mask: Bool = true, arch: String = "applegpu_g15d") -> R.Route? {
            R.route(keyTokens: n, queryTokens: l, queryHeads: q, kvHeads: kv, headDim: d, valueDim: d,
                    hasArrayMask: mask, architecture: arch, partitionOverride: nil)
        }
        let one = R.Route(twoPass: false, partitions: 32, gqaKernel: false)
        func two(_ p: Int, gqa: Bool = false) -> R.Route { R.Route(twoPass: true, partitions: p, gqaKernel: gqa) }
        // Ultra ('d'), A3B decode shape (8 query heads per KV head).
        XCTAssertEqual(route(1023), one)
        XCTAssertEqual(route(1024), two(128))
        XCTAssertEqual(route(16383), two(128))
        XCTAssertEqual(route(16384), two(512))
        XCTAssertEqual(route(65535), two(512))
        XCTAssertEqual(route(65536), two(1024))
        // 27B decode shape (6 per KV head) and a 2-simdgroup shape.
        XCTAssertEqual(route(16384, q: 24, kv: 4), two(512))
        XCTAssertEqual(route(8192, q: 4, kv: 2), two(128))
        XCTAssertEqual(route(8193, q: 4, kv: 2), two(256))
        // Verify widths multiply the simdgroups.
        XCTAssertEqual(route(16384, q: 4, kv: 2, l: 3), two(512))
        // The `_gqa` first pass: no array mask, one query, 8x GQA, head dim 64/128, 8192+ keys.
        XCTAssertEqual(route(8191, d: 128, mask: false), two(128))
        XCTAssertEqual(route(8192, d: 128, mask: false), two(128, gqa: true))
        XCTAssertEqual(route(8192, d: 128, mask: true), two(128))
        XCTAssertEqual(route(8192, d: 256, mask: false), two(128))
        // v0.32.4 adds `_gqa_12` and `_gqa_16` at head dim 128 only.
        XCTAssertEqual(route(8192, q: 24, kv: 2, d: 128, mask: false), two(128, gqa: true))
        XCTAssertEqual(route(8192, q: 32, kv: 2, d: 128, mask: false), two(128, gqa: true))
        XCTAssertEqual(route(8192, q: 32, kv: 2, d: 64, mask: false), two(128))
        XCTAssertEqual(route(8192, q: 8, kv: 2, d: 128, mask: false), two(128))
        // Max ('s').
        XCTAssertEqual(route(1023, arch: "applegpu_g15s"), one)
        XCTAssertEqual(route(1024, arch: "applegpu_g15s"), two(64))
        XCTAssertEqual(route(1025, arch: "applegpu_g15s"), two(128))
        XCTAssertEqual(route(8193, arch: "applegpu_g15s"), two(256))
        XCTAssertEqual(route(32769, arch: "applegpu_g15s"), two(512))
        XCTAssertEqual(route(65537, arch: "applegpu_g15s"), two(1024))
        // Other devices: two passes only with GQA from 4096 keys.
        XCTAssertEqual(route(4095, arch: "applegpu_g13g"), one)
        XCTAssertEqual(route(4096, arch: "applegpu_g13g"), two(64))
        XCTAssertEqual(route(4096, q: 2, kv: 2, arch: "applegpu_g13g"), one)
        XCTAssertEqual(route(4096, q: 4, kv: 2, arch: "applegpu_g13g"), two(32))
        // Prompt chunks and unknown shapes have no vector route.
        XCTAssertNil(route(4096, l: 9))
        XCTAssertNil(route(4096, arch: ""))
        // The override applies to every two-pass call.
        XCTAssertEqual(
            R.route(keyTokens: 2048, queryTokens: 1, queryHeads: 16, kvHeads: 2, headDim: 256, valueDim: 256,
                    hasArrayMask: true, architecture: "applegpu_g15d", partitionOverride: 96),
            two(96)
        )
    }

    /// Per-row attention synthesizes lone masks only under plain masks the
    /// batch cache builds; a model-supplied array mask is sliced per row, so
    /// its semantics are kept. A row whose stored keys do not match its
    /// logical offset (no stored history) cannot be isolated: the padded
    /// call is flagged as outside the cache path (the backend fails it).
    func testPerRowAttentionKeepsTheSingleCallForForeignMasksAndMissingHistory() throws {
        try requireMetal()
        MLXRandom.seed(1958)
        let (queryHeads, kvHeads, headDim) = (16, 2, 256)
        let scale = 1 / Float(headDim).squareRoot()
        let histories = [600, 1500]
        let historyKeys = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let historyValues = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let queries = MLXRandom.normal([2, queryHeads, 1, headDim]).asType(.bfloat16)
        let keys = MLXRandom.normal([2, kvHeads, 1, headDim]).asType(.bfloat16)
        let values = MLXRandom.normal([2, kvHeads, 1, headDim]).asType(.bfloat16)
        eval(historyKeys + historyValues + [queries, keys, values])
        func caches() -> [PagedKVCache] {
            histories.indices.map { Self.attentionRowCache(history: historyKeys[$0], historyValues[$0]) }
        }
        func padded(_ history: [MLXArray], _ incoming: MLXArray) -> MLXArray {
            concatenated(histories.indices.map { row in
                let own = concatenated([history[row], incoming[row ..< row + 1, 0..., 0..., 0...]], axis: 2)
                let pad = 1501 - own.dim(2)
                return pad == 0 ? own : concatenated([own, MLXArray.zeros([1, kvHeads, pad, headDim], dtype: own.dtype)], axis: 2)
            }, axis: 0)
        }
        // Row 0 may not attend its first key; its padding stays masked.
        let positions = MLXArray(Int32(0) ..< Int32(1501)).reshaped([1, 1, 1, 1501])
        let lengths = MLXArray([Int32(601), Int32(1501)]).reshaped([2, 1, 1, 1])
        let foreign = (positions .< lengths) .&& (positions .> MLXArray(Int32(0)))
        let withForeignMask = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: caches(), queries: queries, keys: keys, values: values, scale: scale,
            maskOverride: .array(foreign)
        )
        let single = MLXFast.scaledDotProductAttention(
            queries: queries, keys: padded(historyKeys, keys), values: padded(historyValues, values),
            scale: scale, mask: .array(foreign)
        )
        // Under a foreign mask every padded row splits: the 601-key row keeps
        // its own slice of the mask, and the 1501-key row (no padding) gets
        // the bits of the padded call.
        let splitRow = MLXFast.scaledDotProductAttention(
            queries: queries[0 ..< 1],
            keys: concatenated([historyKeys[0], keys[0 ..< 1]], axis: 2),
            values: concatenated([historyValues[0], values[0 ..< 1]], axis: 2),
            scale: scale,
            mask: .array(foreign[0 ..< 1, 0..., 0..., ..<601])
        )
        XCTAssertTrue(arrayEqual(withForeignMask[0 ..< 1], splitRow).item(Bool.self), "a foreign mask's semantics are kept for a split row")
        XCTAssertTrue(arrayEqual(withForeignMask[1 ..< 2], single[1 ..< 2]).item(Bool.self))
        XCTAssertFalse(
            arrayEqual(withForeignMask[0 ..< 1], MLXFast.scaledDotProductAttention(
                queries: queries[0 ..< 1],
                keys: concatenated([historyKeys[0], keys[0 ..< 1]], axis: 2),
                values: concatenated([historyValues[0], values[0 ..< 1]], axis: 2),
                scale: scale,
                mask: .none
            )).item(Bool.self),
            "the excluded first key stays excluded"
        )

        // A row at logical offset 600 with no stored keys beside a full row.
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "offset-only", poolEpoch: 1)
        let offsetOnly = PagedKVCache(
            blockSizeTokens: 256,
            maxPhysicalBlocks: 128,
            poolEpoch: 1,
            binding: PagedKVStorageBinding(
                handle: handle,
                blockSizeTokens: 256,
                maxLogicalTokens: 256 * 128,
                currentTable: PagedKVBlockTable(
                    handleID: handle.handleID, blockSizeTokens: 256, logicalTokenCount: 0,
                    physicalBlocks: [], tailValidTokenCount: 0, poolEpoch: 1
                ),
                poolEpoch: 1
            ),
            initialOffset: 600,
            reconstructViaGather: false
        )
        let full = Self.attentionRowCache(history: historyKeys[1], historyValues[1])
        let rows = [offsetOnly, full]
        let mask = PagedKVSharedForwardBackend.batchLayerMaskForTest(rowCaches: rows, n: 1, windowSize: nil)
        let mixed = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: [offsetOnly, full], queries: queries, keys: keys, values: values, scale: scale,
            maskOverride: mask
        )
        XCTAssertEqual(mixed.shape, queries.shape)
        XCTAssertEqual(offsetOnly.storedTokens, 1)
        XCTAssertEqual(offsetOnly.offset, 601)
        XCTAssertTrue(PagedKVSharedForwardBackend.lastBatchAttentionLeftCachePathForTest)

        // An all-true foreign mask over rows on one route (600 and 901 keys,
        // both one-pass): the short row must still attend only its own keys.
        let sameRoute = [599, 900]
        let sameKeys = sameRoute.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let sameValues = sameRoute.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        eval(sameKeys + sameValues)
        let allTrue = MLXArray.ones([2, 1, 1, 901], dtype: .bool)
        let permissive = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: sameRoute.indices.map { Self.attentionRowCache(history: sameKeys[$0], sameValues[$0]) },
            queries: queries, keys: keys, values: values, scale: scale,
            maskOverride: .array(allTrue)
        )
        let shortLone = MLXFast.scaledDotProductAttention(
            queries: queries[0 ..< 1],
            keys: concatenated([sameKeys[0], keys[0 ..< 1]], axis: 2),
            values: concatenated([sameValues[0], values[0 ..< 1]], axis: 2),
            scale: scale,
            mask: .array(allTrue[0 ..< 1, 0..., 0..., ..<600])
        )
        XCTAssertTrue(arrayEqual(permissive[0 ..< 1], shortLone).item(Bool.self), "a foreign mask never admits padding")

        // The same for packed verification: two width-2 rows on one route
        // under an all-true foreign mask.
        let verifyQueries = MLXRandom.normal([2, queryHeads, 2, headDim]).asType(.bfloat16)
        let verifyKeys = MLXRandom.normal([2, kvHeads, 2, headDim]).asType(.bfloat16)
        let verifyValues = MLXRandom.normal([2, kvHeads, 2, headDim]).asType(.bfloat16)
        eval(verifyQueries, verifyKeys, verifyValues)
        let packedAllTrue = MLXArray.ones([2, 1, 2, 902], dtype: .bool)
        let packedPermissive = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: sameRoute.indices.map { Self.attentionRowCache(history: sameKeys[$0], sameValues[$0]) },
            queries: verifyQueries, keys: verifyKeys, values: verifyValues, scale: scale,
            mtpPackedRowMaps: sameRoute.enumerated().map {
                MTPPackedVerificationRowMap(rowIndex: $0.offset, queryOffset: $0.element, inputCount: 2, proposalCount: 1)
            },
            maskOverride: .array(packedAllTrue)
        )
        let packedShortLone = MLXFast.scaledDotProductAttention(
            queries: verifyQueries[0 ..< 1],
            keys: concatenated([sameKeys[0], verifyKeys[0 ..< 1]], axis: 2),
            values: concatenated([sameValues[0], verifyValues[0 ..< 1]], axis: 2),
            scale: scale,
            mask: .array(packedAllTrue[0 ..< 1, 0..., 0..., ..<601])
        )
        XCTAssertTrue(
            arrayEqual(packedPermissive[0 ..< 1], packedShortLone).item(Bool.self),
            "a foreign mask never admits padding in packed verification"
        )
    }

    /// Sliding-window decode rows of different lengths attend over their own
    /// presented suffix, bit-identical to the row decoded alone.
    func testSlidingWindowDecodeRowsMatchTheirLoneBits() throws {
        try requireMetal()
        MLXRandom.seed(1960)
        let (queryHeads, kvHeads, headDim, window) = (16, 2, 128, 1100)
        let scale = 1 / Float(headDim).squareRoot()
        let histories = [300, 900, 5000]
        let historyKeys = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let historyValues = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let queries = MLXRandom.normal([3, queryHeads, 1, headDim]).asType(.bfloat16)
        let keys = MLXRandom.normal([3, kvHeads, 1, headDim]).asType(.bfloat16)
        let values = MLXRandom.normal([3, kvHeads, 1, headDim]).asType(.bfloat16)
        eval(historyKeys + historyValues + [queries, keys, values])
        let rows = histories.indices.map { Self.attentionRowCache(history: historyKeys[$0], historyValues[$0], window: window) }
        let batched = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: rows, queries: queries, keys: keys, values: values, scale: scale
        )
        XCTAssertFalse(PagedKVSharedForwardBackend.lastBatchAttentionLeftCachePathForTest)
        for row in histories.indices {
            let serial = Self.attentionRowCache(history: historyKeys[row], historyValues[row], window: window)
            let slice = { (array: MLXArray) in array[row ..< row + 1, 0..., 0..., 0...] }
            let lone = attentionWithCacheUpdate(
                queries: slice(queries), keys: slice(keys), values: slice(values),
                cache: serial, scale: scale,
                mask: serial.makeMask(n: 1, windowSize: nil, returnArray: false)
            )
            XCTAssertTrue(arrayEqual(batched[row ..< row + 1], lone).item(Bool.self), "row \(row) (\(histories[row]) keys)")
        }
    }

    /// A ragged prompt whose mask carries a sliding window (full-history row
    /// caches, `makeMask(windowSize:)`) keeps that window for split rows.
    func testRaggedPromptKeepsAWindowedMaskForSplitRows() throws {
        try requireMetal()
        MLXRandom.seed(1959)
        let (queryHeads, kvHeads, headDim, chunk, window) = (16, 2, 256, 9, 4)
        let scale = 1 / Float(headDim).squareRoot()
        let histories = [3, 11]
        let historyKeys = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let historyValues = histories.map { MLXRandom.normal([1, kvHeads, $0, headDim]).asType(.bfloat16) }
        let queries = MLXRandom.normal([2, queryHeads, chunk, headDim]).asType(.bfloat16)
        let keys = MLXRandom.normal([2, kvHeads, chunk, headDim]).asType(.bfloat16)
        let values = MLXRandom.normal([2, kvHeads, chunk, headDim]).asType(.bfloat16)
        eval(historyKeys + historyValues + [queries, keys, values])
        let rows = histories.indices.map { Self.attentionRowCache(history: historyKeys[$0], historyValues[$0]) }
        let attended = try PagedKVSharedForwardBackend.batchAttentionForTest(
            rowCaches: rows, queries: queries, keys: keys, values: values, scale: scale,
            raggedPrefill: true, maskWindowSize: window
        )
        let windowed = PagedKVRaggedPrefillMask.make(queryTokens: chunk, rowOffsets: histories, windowSize: window)
        for row in histories.indices {
            let own = histories[row] + chunk
            let expected = MLXFast.scaledDotProductAttention(
                queries: queries[row ..< row + 1],
                keys: concatenated([historyKeys[row], keys[row ..< row + 1]], axis: 2),
                values: concatenated([historyValues[row], values[row ..< row + 1]], axis: 2),
                scale: scale,
                mask: .array(windowed[row ..< row + 1, 0..., 0..., ..<own])
            )
            XCTAssertTrue(arrayEqual(attended[row ..< row + 1], expected).item(Bool.self), "row \(row) keeps its window")
        }
        XCTAssertFalse(PagedKVSharedForwardBackend.lastBatchAttentionLeftCachePathForTest)
    }

    /// The Swift ports of core routing (`PagedKVVectorAttentionRoute`,
    /// `ContinuousBatchDecodeRouteBound`) and the padding invariance they rely
    /// on are pinned to the resolved core sources. A core rebase that changes
    /// any of these regions fails here until the ports and their tables are
    /// re-derived and these digests updated (runbook per-rebase gate).
    func testCoreRoutingSourcesMatchThePortedDispatch() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal")
        func read(_ path: String) throws -> [String] {
            let url = core.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("resolved MLX core source missing: \(url.path)")
                throw XCTSkip("no core checkout")
            }
            return text.components(separatedBy: "\n")
        }
        func region(_ lines: [String], from start: (String) -> Bool, through end: (String) -> Bool) -> String {
            guard let first = lines.firstIndex(where: start),
                  let last = lines[first...].firstIndex(where: end)
            else { return "" }
            return lines[first ... last].joined(separator: "\n") + "\n"
        }
        func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let quantized = try read("quantized.cpp")
        XCTAssertEqual(
            digest(region(quantized, from: { $0.hasPrefix("inline int get_qmv_batch_limit") }, through: { $0 == "}" })),
            "0e3012862456a0b8a6ab5231f4e1f75fcfcabb0b80f5510baba88b45aae272ab",
            "get_qmv_batch_limit changed: re-derive ContinuousBatchDecodeRouteBound and ContinuousBatchPrefillGroupingRule"
        )
        let sdpa = try read("scaled_dot_product_attention.cpp")
        XCTAssertEqual(
            digest(region(sdpa, from: { $0.hasPrefix("void sdpa_vector_2pass(") }, through: { $0.contains("size_t k_head_stride") })),
            "b703ced4cc336d8fea7934631dbf6d040688f95511a7e7012fce3256647d335f",
            "sdpa_vector_2pass partition/variant choice changed: re-derive PagedKVVectorAttentionRoute"
        )
        XCTAssertEqual(
            digest(region(sdpa, from: { $0.contains("// We route to the 2 pass fused attention if") }, through: { $0 == "    }" })),
            "6b79dadefe71a2f86ac2df014f4d0ddc198826caa0d303c301e540c187da148b",
            "one-pass/two-pass choice changed: re-derive PagedKVVectorAttentionRoute"
        )
        XCTAssertTrue(sdpa.contains("  if (q_pre.shape(2) <= 8) {"), "vector-mode query bound changed")
        XCTAssertEqual(
            digest(try read("kernels/sdpa_vector.h").joined(separator: "\n")),
            "32146cdd4b9982723ee696da1ad8d146682d84d2ee40098a4063a25b8a1ec322",
            "vector attention kernels changed: re-check that masked keys are skipped and keys are dealt to partitions by index"
        )
    }

    /// Rows that share the padded call: exactly those whose lone route equals
    /// it; an unknown route shares nothing.
    func testOnlyRowsInThePaddedCallsRouteShareIt() {
        typealias E = PagedKVRowAttentionExtent
        func shared(_ extents: [E], width: Int = 1, padded: Int, mask: Bool = true, lone: Bool = false, arch: String = "applegpu_g15d") -> Set<Int> {
            PagedKVVectorAttentionRoute.rowsMatchingPaddedCall(
                extents: extents, queryTokens: width, paddedKeyTokens: padded, queryHeads: 16, kvHeads: 2,
                headDim: 256, valueDim: 256, paddedCallHasArrayMask: mask, loneCallHasArrayMask: lone,
                architecture: arch, partitionOverride: nil
            )
        }
        let decode = [601, 902, 1502, 3001, 9001].map { E(queryTokens: 1, keyTokens: $0) }
        XCTAssertEqual(shared(decode, padded: 9001), [2, 3, 4])
        XCTAssertEqual(shared(decode + [E(queryTokens: 1, keyTokens: 16400)], padded: 16400), [5])
        XCTAssertEqual(shared(decode, padded: 9001, mask: false), [], "without an array mask the padded call attends padding")
        XCTAssertEqual(shared(decode, padded: 9001, arch: ""), [], "unknown route: every row splits")
        let verify = [E(queryTokens: 3, keyTokens: 1503), E(queryTokens: 2, keyTokens: 3002), E(queryTokens: 3, keyTokens: 9003)]
        XCTAssertEqual(shared(verify, width: 3, padded: 9003, lone: true), [0, 2])
        XCTAssertEqual(shared(verify.map { E(queryTokens: 12, keyTokens: $0.keyTokens) }, width: 12, padded: 9012), [], "prompt chunks never share")
    }

    /// Packed verification splits into consecutive groups of at most the
    /// token bound (rows x the group's widest row), never below one row.
    func testPackedVerifyGroupsStayWithinTheTokenBound() {
        typealias B = PagedKVSharedForwardBackend
        XCTAssertEqual(B.verifyGroups(widths: [2, 2, 2, 2, 2], maxTokens: 11), [0 ..< 5])
        XCTAssertEqual(B.verifyGroups(widths: Array(repeating: 2, count: 8), maxTokens: 11), [0 ..< 5, 5 ..< 8])
        XCTAssertEqual(B.verifyGroups(widths: [1, 1, 2, 1, 2, 2, 1], maxTokens: 5), [0 ..< 2, 2 ..< 4, 4 ..< 6, 6 ..< 7])
        XCTAssertEqual(B.verifyGroups(widths: [8, 1], maxTokens: 5), [0 ..< 1, 1 ..< 2], "a row wider than the bound verifies alone")
        XCTAssertEqual(B.verifyGroups(widths: [], maxTokens: 5), [])
        XCTAssertEqual(B.verifyGroups(widths: Array(repeating: 2, count: 16), maxTokens: .max), [0 ..< 16])
    }

    /// Which batched attention calls split per row: only padded ones.
    func testRowAttentionExtentsSplitOnlyPaddedRows() {
        typealias Extent = PagedKVRowAttentionExtent
        XCTAssertNil(PagedKVRowAttention.extents(queryTokens: 1, offsetsBefore: [900], packedRows: nil))
        XCTAssertNil(PagedKVRowAttention.extents(queryTokens: 1, offsetsBefore: [900, 900], packedRows: nil))
        XCTAssertEqual(
            PagedKVRowAttention.extents(queryTokens: 1, offsetsBefore: [900, 1500], packedRows: nil),
            [Extent(queryTokens: 1, keyTokens: 901), Extent(queryTokens: 1, keyTokens: 1501)]
        )
        XCTAssertEqual(
            PagedKVRowAttention.extents(queryTokens: 33, offsetsBefore: [0, 7], packedRows: nil),
            [Extent(queryTokens: 33, keyTokens: 33), Extent(queryTokens: 33, keyTokens: 40)]
        )
        // Packed verification: equal offsets and full widths share one call;
        // a narrower row or a different offset splits.
        XCTAssertNil(PagedKVRowAttention.extents(
            queryTokens: 3,
            offsetsBefore: [900, 900],
            packedRows: [(900, 3), (900, 3)]
        ))
        XCTAssertEqual(
            PagedKVRowAttention.extents(queryTokens: 3, offsetsBefore: [900, 900], packedRows: [(900, 3), (900, 2)]),
            [Extent(queryTokens: 3, keyTokens: 903), Extent(queryTokens: 2, keyTokens: 902)]
        )
        XCTAssertNil(PagedKVRowAttention.extents(
            queryTokens: 3,
            offsetsBefore: [900, 900],
            packedRows: [(900, 4), (900, 2)]
        ), "an input wider than the call is malformed: one call")
    }

    private static func attentionRowCache(history keys: MLXArray, _ values: MLXArray, window: Int? = nil) -> PagedKVCache {
        let blockSize = 256
        let blocks = 128
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "attention-row", poolEpoch: 1)
        let cache = PagedKVCache(
            blockSizeTokens: blockSize,
            maxPhysicalBlocks: blocks,
            poolEpoch: 1,
            binding: PagedKVStorageBinding(
                handle: handle,
                blockSizeTokens: blockSize,
                maxLogicalTokens: blockSize * blocks,
                currentTable: PagedKVBlockTable(
                    handleID: handle.handleID,
                    blockSizeTokens: blockSize,
                    logicalTokenCount: 0,
                    physicalBlocks: [],
                    tailValidTokenCount: 0,
                    poolEpoch: 1
                ),
                poolEpoch: 1
            ),
            initialOffset: 0,
            reconstructViaGather: false,
            attentionWindowTokens: window
        )
        if keys.dim(2) > 0 {
            let stored = cache.update(keys: keys, values: values)
            eval(stored.0, stored.1)
        }
        return cache
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
        try await runPackedNativeMTPRowsMatchSerialOrdinaryGreedy(maxVerifyTokensPerForward: nil)
    }

    /// The same scenario with packed verification bounded to 2 target tokens
    /// per forward, so every round of several native rows verifies in
    /// consecutive groups (SPEC-038 FR-CB2 verify token bound). Row identity,
    /// acceptance, the cancelled row's abort inside a committing round and
    /// the serial greedy tokens must be unchanged.
    func testRealQwen35PackedNativeMTPRowsVerifiedInBoundedGroupsMatchSerialOrdinaryGreedy() async throws {
        try await runPackedNativeMTPRowsMatchSerialOrdinaryGreedy(maxVerifyTokensPerForward: 2)
    }

    private func runPackedNativeMTPRowsMatchSerialOrdinaryGreedy(maxVerifyTokensPerForward: Int?) async throws {
        try requireMetal()

        let configuration = try JSONDecoder().decode(
            Qwen35TextConfiguration.self,
            from: Data(Self.tinyQwen35HybridConfiguration.utf8)
        )
        MLXRandom.seed(1770)
        let target = Qwen35TextModel(configuration)
        let drafter = Qwen35MTPDraftModel(configuration)
        eval(target, drafter)

        func serialGreedy(_ prompt: [Int], count: Int) throws -> [Int] {
            let cache = try target.newCache(parameters: nil)
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
            )),
            maxVerifyTokensPerForward: maxVerifyTokensPerForward
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
                try serialGreedy(prompts[id]!, count: budgets[id]!),
                "\(id) diverged from serial ordinary greedy"
            )
        }
        XCTAssertTrue(joinedMidFlight, "joiner must be admitted while the first cohort is decoding")
        let cancelled = try XCTUnwrap(results["cancelled"])
        XCTAssertEqual(cancelled.terminalStatus, .cancelled)
        XCTAssertLessThan(cancelled.generatedTokens.count, budgets["cancelled"]!)
        XCTAssertEqual(
            cancelled.generatedTokens,
            Array(try serialGreedy(prompts["cancelled"]!, count: budgets["cancelled"]!)
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
            nativeMTPFamilyAdapter: "qwen3_5_mtp_v1",
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
    private static func tinyPrompt(length: Int, salt: Int, vocabulary: UInt64 = 8) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % vocabulary)
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
            cache: try target.newCache(parameters: nil),
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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()
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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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

    /// Window A2 journey steps 05 and 09: with the lab state-digest observer
    /// installed, every glm5_next native prefill failed because the drafter
    /// digest cut each state array as a [.., T, D] KV slab at the drafter
    /// position; a GLM5NextAttentionCache state is already logical (empty
    /// slots are [0]). It now hashes those arrays whole, and the digest still
    /// tells different states apart.
    func testDrafterDigestHashesAGLMLatentCacheStateWhole() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            func cache(_ latent: [Float]) -> GLM5NextAttentionCache {
                let cache = GLM5NextAttentionCache(kpool: 4)
                _ = cache.appendLatent(MLXArray(latent, [1, 1, latent.count, 1]))
                return cache
            }
            let state = MTPDrafterState(cache: [cache([1, 2, 3])], nextPosition: 5, seedToken: nil, seedHidden: nil)
            let same = MTPDrafterState(cache: [cache([1, 2, 3])], nextPosition: 5, seedToken: nil, seedHidden: nil)
            let changed = MTPDrafterState(cache: [cache([1, 2, 4])], nextPosition: 5, seedToken: nil, seedHidden: nil)
            let digest = try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: state, seed: 7)
            XCTAssertEqual(digest, try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: same, seed: 7))
            XCTAssertNotEqual(digest, try PagedKVSharedForwardBackend.nativeMTPDrafterDigestForTest(state: changed, seed: 7))
        }
    }

    /// Window J: the lab digests hash each state array as concurrently
    /// computed 1 MiB chunk digests. Every chunk is the plain SHA-256 of its
    /// bytes, in order, and a change in any chunk changes the result.
    func testConcurrentChunkDigestsAreOrderedPerChunkSHA256() {
        let a = Data((0 ..< 10_000).map { UInt8($0 % 251) })
        let b = Data((0 ..< 300).map { UInt8($0 % 7) })
        let digests = PagedKVSharedForwardBackend.concurrentChunkDigests([a, Data(), b], chunkBytes: 4096)
        func expected(_ data: Data) -> Data {
            stride(from: 0, to: data.count, by: 4096).reduce(into: Data()) { result, start in
                result.append(contentsOf: SHA256.hash(data: data[start ..< min(start + 4096, data.count)]))
            }
        }
        XCTAssertEqual(digests.count, 3)
        XCTAssertEqual(digests[0], expected(a))
        XCTAssertEqual(digests[0].count, 3 * SHA256.byteCount)
        XCTAssertEqual(digests[1], Data())
        XCTAssertEqual(digests[2], expected(b))
        var changed = a
        changed[9_999] ^= 1
        let changedDigests = PagedKVSharedForwardBackend.concurrentChunkDigests([changed], chunkBytes: 4096)
        XCTAssertEqual(changedDigests[0].prefix(2 * SHA256.byteCount), digests[0].prefix(2 * SHA256.byteCount))
        XCTAssertNotEqual(changedDigests[0], digests[0])
    }

    /// The row digest's array records see only the logical bytes: a strided
    /// logical slice and the same values stored contiguously agree, and one
    /// changed value in a later chunk does not.
    func testArrayDigestRecordsHashLogicalBytesAcrossChunks() throws {
        try requireMetal()
        try Device.withDefaultDevice(.cpu) {
            let values = (0 ..< 2 * 6 * 4).map { Float($0) }
            let stored = MLXArray(values, [1, 2, 6, 4])
            let logical = stored[0 ..< 4, axis: 2]
            let compact = MLXArray((0 ..< 2).flatMap { head in
                (0 ..< 4 * 4).map { Float(head * 24 + $0) }
            }, [1, 2, 4, 4])
            var changedValues = values
            changedValues[24 + 15] += 1
            let changed = MLXArray(changedValues, [1, 2, 6, 4])
            let records = try PagedKVSharedForwardBackend.arrayDigestRecords([
                (array: stored, logicalTokens: 4),
                (array: compact, logicalTokens: nil),
                (array: logical, logicalTokens: nil),
                (array: changed, logicalTokens: 4),
            ], chunkBytes: 16)
            XCTAssertEqual(records[0], records[1])
            XCTAssertEqual(records[0], records[2])
            XCTAssertEqual(records[0].shape, [1, 2, 4, 4])
            XCTAssertEqual(records[0].byteCount, 2 * 4 * 4 * 4)
            XCTAssertEqual(records[0].chunkDigests.count, 8 * SHA256.byteCount)
            XCTAssertNotEqual(records[0], records[3])
            XCTAssertEqual(records[0].chunkDigests.prefix(7 * SHA256.byteCount), records[3].chunkDigests.prefix(7 * SHA256.byteCount))
        }
    }

    /// The finalize-site drafter recompute runs on a row's first committed
    /// round and once per crossed 256-token interval after it.
    func testLabDrafterRecomputeIsDueOnFirstRoundAndEachCrossedInterval() {
        typealias Backend = PagedKVSharedForwardBackend
        XCTAssertEqual(Backend.labDrafterRecomputeIntervalTokens, 256)
        XCTAssertTrue(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: nil, prefixTokens: 31))
        XCTAssertFalse(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 31, prefixTokens: 33))
        XCTAssertFalse(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 31, prefixTokens: 255))
        XCTAssertTrue(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 255, prefixTokens: 256))
        XCTAssertTrue(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 254, prefixTokens: 257))
        XCTAssertFalse(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 257, prefixTokens: 511))
        XCTAssertTrue(Backend.labDrafterRecomputeDue(lastRecomputedPrefixTokens: 511, prefixTokens: 513))
    }

    func testJourneyDrafterRecomputeCoverageMatchesTheFinalizeSampling() {
        let finalize = Array(stride(from: 31, through: 1_053, by: 2))
        var last: Int?
        var recomputed: [Int] = []
        for tokens in finalize where PagedKVSharedForwardBackend.labDrafterRecomputeDue(
            lastRecomputedPrefixTokens: last, prefixTokens: tokens
        ) {
            recomputed.append(tokens)
            last = tokens
        }
        XCTAssertEqual(recomputed, [31, 257, 513, 769, 1_025])
        XCTAssertTrue(NativeMTPJourneyRunner.drafterRecomputeCoverageHolds(
            finalizeTokenCounts: finalize, recomputedTokenCounts: recomputed))
        XCTAssertFalse(NativeMTPJourneyRunner.drafterRecomputeCoverageHolds(
            finalizeTokenCounts: finalize, recomputedTokenCounts: Array(recomputed.dropFirst())))
        XCTAssertFalse(NativeMTPJourneyRunner.drafterRecomputeCoverageHolds(
            finalizeTokenCounts: finalize, recomputedTokenCounts: [31, 257, 769, 1_025]))
        XCTAssertFalse(NativeMTPJourneyRunner.drafterRecomputeCoverageHolds(
            finalizeTokenCounts: [], recomputedTokenCounts: []))
    }

    private typealias JourneyRound = NativeMTPJourneyRunner.NativeRoundRecord

    private static func journeyRound(_ round: Int?, _ tokens: Int, _ digest: String, rejected: Bool) -> JourneyRound {
        JourneyRound(round: round, tokens: tokens, digest: digest, proposedTokens: 1, committedProposals: rejected ? 0 : 1)
    }

    /// Window 13:22Z step 05: ordinary decode records one state per 16-token
    /// window, so the old "every native round has an ordinary record" rule
    /// could never hold. The comparison is over the window-end counts the
    /// native row lands on, all of which must match, and a compared record
    /// follows a rejection only when the round numbered one less rejected.
    func testJourneyAlignedCacheComparisonUsesWindowEndCounts() {
        typealias Runner = NativeMTPJourneyRunner
        let ordinary = stride(from: 45, through: 125, by: 16).map { (tokens: $0, digest: "o\($0)") }
        func rounds(_ accepted: [Bool], from start: Int = 30) -> [JourneyRound] {
            var tokens = start
            return accepted.enumerated().map { round, accepted in
                tokens += accepted ? 2 : 1
                return Self.journeyRound(round, tokens, "o\(tokens)", rejected: !accepted)
            }
        }
        // Every third round rejected, from 30 tokens to past 125.
        let native = rounds((0 ..< 60).map { $0 % 3 != 0 })
        let matched = Runner.alignedCacheComparison(native: native, ordinary: ordinary)
        XCTAssertTrue(matched.roundsOrdered)
        XCTAssertEqual(matched.comparableOrdinaryCounts, 6)
        XCTAssertGreaterThanOrEqual(matched.pairs, 2)
        XCTAssertEqual(matched.equalPairs, matched.pairs)
        let expectedFollowing = native.indices.filter { index in
            index > 0 && native[index - 1].rejectedAProposal && ordinary.contains { $0.tokens == native[index].tokens }
        }.count
        XCTAssertGreaterThanOrEqual(expectedFollowing, 1)
        XCTAssertEqual(matched.pairsFollowingRejection, expectedFollowing)
        XCTAssertTrue(matched.holds)

        let pairedIndex = native.indices.first { index in ordinary.contains { $0.tokens == native[index].tokens } }!
        var mismatched = native
        mismatched[pairedIndex].digest = "different"
        let failed = Runner.alignedCacheComparison(native: mismatched, ordinary: ordinary)
        XCTAssertFalse(failed.holds)
        XCTAssertEqual(failed.mismatchTokenCounts, [native[pairedIndex].tokens])

        XCTAssertFalse(Runner.alignedCacheComparison(native: [], ordinary: ordinary).holds)
        XCTAssertFalse(Runner.alignedCacheComparison(
            native: rounds(Array(repeating: true, count: 60)), ordinary: ordinary
        ).holds, "no rejection at all")
    }

    /// Audit round 2: a rejected round whose own record lands on a window end
    /// is not a comparison after a rejection; the next round's is. Round 3:
    /// the predecessor is the bridge's round number minus one, so a missing,
    /// duplicated, renumbered or unnumbered record fails closed.
    func testJourneyAlignedComparisonCountsOnlyTheRoundAfterARejection() {
        typealias Runner = NativeMTPJourneyRunner
        let ordinary = [(tokens: 45, digest: "o45"), (tokens: 61, digest: "o61")]
        var native: [JourneyRound] = []
        var tokens = 30
        for round in 0 ..< 16 {
            let rejected = tokens + 1 == 45 || tokens + 1 == 61
            tokens += rejected ? 1 : 2
            native.append(Self.journeyRound(round, tokens, "o\(tokens)", rejected: rejected))
        }
        let selfOnly = Runner.alignedCacheComparison(native: native, ordinary: ordinary)
        XCTAssertGreaterThanOrEqual(selfOnly.pairs, 1)
        XCTAssertTrue(native.contains { $0.rejectedAProposal && ordinary.map(\.tokens).contains($0.tokens) })
        XCTAssertEqual(selfOnly.pairsFollowingRejection, 0)
        XCTAssertFalse(selfOnly.holds)

        let following = [
            Self.journeyRound(0, 42, "x", rejected: false),
            Self.journeyRound(1, 43, "x", rejected: true),
            Self.journeyRound(2, 45, "o45", rejected: false),
            Self.journeyRound(3, 47, "x", rejected: false),
        ]
        XCTAssertEqual(Runner.alignedCacheComparison(native: following, ordinary: ordinary).pairsFollowingRejection, 1)
        XCTAssertTrue(Runner.alignedCacheComparison(native: following, ordinary: ordinary).holds)
        // An earlier but not immediately preceding rejection does not count.
        var earlier = following
        earlier[1].committedProposals = 1
        earlier[0].committedProposals = 0
        XCTAssertEqual(Runner.alignedCacheComparison(native: earlier, ordinary: ordinary).pairsFollowingRejection, 0)
        // A round that proposed nothing rejected nothing.
        var proposalFree = following
        proposalFree[1].proposedTokens = 0
        XCTAssertEqual(Runner.alignedCacheComparison(native: proposalFree, ordinary: ordinary).pairsFollowingRejection, 0)
        // Missing round 1: the rejection's successor must not inherit it.
        let missing = [following[0], following[2], following[3]]
        let missingResult = Runner.alignedCacheComparison(native: missing, ordinary: ordinary)
        XCTAssertFalse(missingResult.roundsOrdered)
        XCTAssertEqual(missingResult.pairsFollowingRejection, 0)
        XCTAssertFalse(missingResult.holds)
        // Duplicate, reordered, renumbered from 1, unnumbered.
        XCTAssertFalse(Runner.alignedCacheComparison(native: [following[0], following[1], following[1], following[2]], ordinary: ordinary).holds)
        XCTAssertFalse(Runner.alignedCacheComparison(native: [following[0], following[2], following[1], following[3]], ordinary: ordinary).holds)
        XCTAssertFalse(Runner.alignedCacheComparison(native: following.map { var r = $0; r.round = $0.round.map { $0 + 1 }; return r }, ordinary: ordinary).holds)
        var unnumbered = following
        unnumbered[2].round = nil
        XCTAssertFalse(Runner.alignedCacheComparison(native: unnumbered, ordinary: ordinary).holds)
    }

    /// Round 3: through the production record path. Two bridges hold the
    /// same token stream in a KVCacheSimple row (CPU): the ordinary one
    /// records at every fourth token, the native one advances 2 or 1 tokens a
    /// round and records through the bridge's finalize bookkeeping, which
    /// numbers the rounds. The journey's extraction plus comparison holds; a
    /// dropped after-finalize record fails closed.
    func testJourneyComparisonOverBridgeNumberedObserverRecords() async throws {
        try requireMetal()
        try await Device.withDefaultDevice(.cpu) {
            func backend() -> PagedKVSharedForwardBackend {
                let descriptor = Self.bridgeDescriptor(blockSizeTokens: 4, maxPhysicalBlocks: 64)
                return PagedKVSharedForwardBackend(
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
            }
            func column(_ start: Int, _ count: Int) -> (MLXArray, MLXArray) {
                let values = (start ..< start + count).flatMap { t in (0 ..< 4).map { Float(t * 4 + $0) } }
                return (MLXArray(values, [1, 1, count, 4]), MLXArray(values.map { -$0 }, [1, 1, count, 4]))
            }
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
            let ordinary = backend()
            let native = backend()
            let ordinaryCache = KVCacheSimple()
            let nativeCache = KVCacheSimple()
            for (bridge, cache, key) in [(ordinary, ordinaryCache, "conv:o"), (native, nativeCache, "conv:n")] {
                let handle = try await allocator.allocate(conversationKey: key, maxTokens: 128, initialTokens: 8)
                let prompt = column(0, 8)
                _ = cache.update(keys: prompt.0, values: prompt.1)
                try bridge.installRowStateForTest(caches: [cache], requestID: "row", binding: try await allocator.binding(for: handle))
            }
            let ordinaryObserver = NativeMTPStateDigestObserver()
            let nativeObserver = NativeMTPStateDigestObserver()
            ordinary.installLabNativeMTPStateDigestObserver(ordinaryObserver)
            native.installLabNativeMTPStateDigestObserver(nativeObserver)
            for t in 8 ..< 60 {
                let next = column(t, 1)
                _ = ordinaryCache.update(keys: next.0, values: next.1)
                if (t + 1) % 4 == 0 {
                    try await ordinary.recordLabNativeMTPStateDigest(phase: .ordinaryAfterDecode, requestIDs: ["row"])
                }
            }
            var round = 0
            while nativeCache.offset < 58 {
                let rejected = round % 3 == 1
                let advance = rejected ? 1 : 2
                let next = column(nativeCache.offset, advance)
                _ = nativeCache.update(keys: next.0, values: next.1)
                try native.labRecordCommittedFinalizeForTest(inputs: [ContinuousBatchNativeMTPFinalizeInput(
                    requestID: "row", proposalTokenCount: 1, committedProposalTokenCount: rejected ? 0 : 1,
                    acceptedTokenIDs: Array(repeating: 0, count: advance), committedInputTokenCount: advance,
                    shouldCommit: true
                )])
                round += 1
            }
            let ordinaryRecords = ordinaryObserver.snapshot().map { (tokens: $0.committedKVTokenCount, digest: $0.cacheDigestSHA256) }
            let records = nativeObserver.snapshot()
            XCTAssertEqual(records.filter { $0.phase == .beforeFinalize }.map(\.nativeRound), Array(0 ..< round).map { Optional($0) })
            let rounds = NativeMTPJourneyRunner.nativeRoundRecords(records, requestID: "row")
            XCTAssertEqual(rounds.map(\.round), Array(0 ..< round).map { Optional($0) })
            let intact = NativeMTPJourneyRunner.alignedCacheComparison(native: rounds, ordinary: ordinaryRecords)
            XCTAssertTrue(intact.roundsOrdered)
            XCTAssertGreaterThanOrEqual(intact.pairs, 3)
            XCTAssertEqual(intact.equalPairs, intact.pairs)
            XCTAssertGreaterThanOrEqual(intact.pairsFollowingRejection, 1)
            XCTAssertTrue(intact.holds)

            // Drop the after-finalize record of a rejected round whose successor is compared.
            let rejectedRound = try XCTUnwrap(rounds.indices.first { index in
                index + 1 < rounds.count && rounds[index].rejectedAProposal
                    && ordinaryRecords.contains { $0.tokens == rounds[index + 1].tokens }
            })
            let dropped = records.filter { !($0.phase == .afterFinalize && $0.nativeRound == rejectedRound) }
            let gapped = NativeMTPJourneyRunner.alignedCacheComparison(
                native: NativeMTPJourneyRunner.nativeRoundRecords(dropped, requestID: "row"),
                ordinary: ordinaryRecords
            )
            XCTAssertFalse(gapped.roundsOrdered)
            XCTAssertFalse(gapped.holds)
        }
    }

    func testLabStateDigestObserverFailsClosedForPagedSlidingWindowCache() async throws {
        try requireMetal()

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
        try requireMetal()

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

    func testQwenPreparationLaneEligibilityIsClosedToExactAdapterAndTextTarget() {
        XCTAssertTrue(ModelRuntime.continuousBatchTextPreparationEligible(
            familyAdapter: "qwen3_5_mtp_v1",
            nativeVisionProfile: nil
        ))
        XCTAssertFalse(ModelRuntime.continuousBatchTextPreparationEligible(
            familyAdapter: "glm5_next_mtp_v1",
            nativeVisionProfile: nil
        ))
        XCTAssertFalse(ModelRuntime.continuousBatchTextPreparationEligible(
            familyAdapter: nil,
            nativeVisionProfile: nil
        ))
        XCTAssertFalse(ModelRuntime.continuousBatchTextPreparationEligible(
            familyAdapter: "qwen3_5_mtp_v1",
            nativeVisionProfile: NativeVisionProfile(
                artifactSHA256: "vision",
                processorConfigSHA256: "processor",
                tokenizerConfigSHA256: "tokenizer",
                chatTemplateSHA256: "template"
            )
        ))
    }

    func testQwenPreparationLanePreservesRequiredToolGrammarPromptStopsAndCheckpoints() async throws {
        try requireMetal()

        let tokenizer = RuntimeBridgePreparationTokenizer()
        let generationPrompt = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let baseTokens = [tokenizer.imStartTokenID]
            + tokenizer.encode(text: "system\n" + String(repeating: "s", count: 40), addSpecialTokens: false)
            + [tokenizer.imStartTokenID]
            + tokenizer.encode(text: "user\nweather", addSpecialTokens: false)
            + tokenizer.encode(text: generationPrompt, addSpecialTokens: false)
        let laneProcessor = RuntimeBridgeCapturingPromptProcessor(tokens: baseTokens.map(Int32.init))
        let legacyProcessor = RuntimeBridgeCapturingPromptProcessor(tokens: baseTokens.map(Int32.init))
        // Required tool calls compile a token grammar from resolved tokenizer
        // metadata. Keep this character tokenizer fixture consistent with its
        // on-disk byte vocabulary rather than bypassing grammar admission.
        let tokenizerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-tool-tokenizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tokenizerDirectory) }
        var vocabulary = Dictionary(uniqueKeysWithValues: (33...126).map {
            (String(UnicodeScalar($0)!), $0)
        })
        vocabulary.merge(["Ġ": 32, "Ċ": 10, "ĉ": 9, "č": 13]) { _, new in new }
        let tokenizerMetadata: [String: Any] = [
            "model": ["type": "BPE", "vocab": vocabulary, "merges": []],
            "decoder": ["type": "ByteLevel"],
            "added_tokens": [
                ["id": tokenizer.eosTokenID, "content": tokenizer.eosToken!, "special": true],
                ["id": tokenizer.extraEOSTokenID, "content": tokenizer.extraEOSToken, "special": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: tokenizerMetadata)
            .write(to: tokenizerDirectory.appendingPathComponent("tokenizer.json"))
        let configuration = ModelConfiguration(
            id: ToolSelectionPolicy.supportedNativeModel,
            tokenizerSource: .directory(tokenizerDirectory),
            extraEOSTokens: [tokenizer.extraEOSToken],
            eosTokenIds: [901]
        )
        let lane = ContinuousBatchTextPreparationLane(
            processor: laneProcessor,
            tokenizer: tokenizer,
            configuration: configuration,
            hasRecurrentLayers: true
        )
        let request = try Self.toolChatRequest(modelID: ToolSelectionPolicy.supportedNativeModel)
            .withConversationKey("conv:lane-parity")
        let (prepared, _) = try await lane.prepare(
            request: request,
            maxContextTokens: 4096,
            templateSupportsThinkingToggle: true,
            templateSupportsPreserveThinking: true,
            toolSelectionModelID: ToolSelectionPolicy.supportedNativeModel,
            drainCancelled: DrainCancelToken()
        )
        let context = ModelContext(
            configuration: configuration,
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: legacyProcessor,
            tokenizer: tokenizer
        )
        let (legacyInput, legacyToolCallPrefill) = try await ModelRuntime.preparedRequestInput(
            for: request,
            context: context,
            templateSupportsThinkingToggle: true,
            templateSupportsPreserveThinking: true,
            toolSelectionModelID: ToolSelectionPolicy.supportedNativeModel
        )
        let plan = try XCTUnwrap(ModelRuntime.toolCallPrefill(
            for: request,
            toolSelectionModelID: ToolSelectionPolicy.supportedNativeModel
        ))
        XCTAssertEqual(
            Array(baseTokens.suffix(tokenizer.encode(text: plan.generationPromptSuffix, addSpecialTokens: false).count)),
            tokenizer.encode(text: plan.generationPromptSuffix, addSpecialTokens: false)
        )
        // Required-tool grammar owns the generated tool delimiters. Both
        // preparation paths must avoid appending an extra textual prefill.
        let expectedPrompt = baseTokens
        let expectedStops: Set<Int> = [901, tokenizer.eosTokenID, tokenizer.extraEOSTokenID]
        XCTAssertNotNil(prepared.grammarConstraint, "Required tool calls must retain grammar admission")
        XCTAssertEqual(prepared.promptTokens, expectedPrompt)
        XCTAssertEqual(prepared.promptTokens, legacyInput.text.tokens.asArray(Int.self))
        XCTAssertNil(prepared.toolCallPrefill)
        XCTAssertEqual(prepared.toolCallPrefill, legacyToolCallPrefill)
        XCTAssertEqual(prepared.modelStopTokenIDs, expectedStops)
        XCTAssertEqual(
            prepared.stopTokenSequences,
            expectedStops.sorted().map { [$0] } + [tokenizer.encode(text: "BUYER", addSpecialTokens: false)]
        )
        let legacyCheckpointPositions = ModelRuntime.continuousBatchRecurrentCheckpointPositions(
            promptTokens: legacyInput.text.tokens.asArray(Int.self),
            conversationKey: request.conversationKey,
            hybrid: true,
            context: context
        )
        XCTAssertEqual(prepared.recurrentCheckpointPositions, legacyCheckpointPositions)
        XCTAssertEqual(prepared.recurrentCheckpointPositions, [61])
        XCTAssertTrue(prepared.modelHasRecurrentLayers)
        let laneInput = try XCTUnwrap(laneProcessor.lastInput())
        let legacyCapturedInput = try XCTUnwrap(legacyProcessor.lastInput())
        XCTAssertEqual(laneInput, legacyCapturedInput)
        XCTAssertEqual(laneInput.roles, ["system", "user"])
        XCTAssertTrue(laneInput.contents[0].contains("Return only tool calls"))
        XCTAssertEqual(laneInput.toolNames, ["get_weather"])
        XCTAssertEqual(laneInput.enableThinking, false)
        XCTAssertEqual(laneInput.preserveThinking, true)
    }

    func testQwenPreparationLaneRejectsQueuedDrainBeforeProcessorRuns() async throws {
        try requireMetal()

        let preparationGate = RuntimeBridgeTestGate()
        let processor = RuntimeBridgeBlockingPromptProcessor(
            tokens: [3],
            firstPreparationGate: preparationGate
        )
        let lane = ContinuousBatchTextPreparationLane(
            processor: processor,
            tokenizer: RuntimeBridgePreparationTokenizer(),
            configuration: ModelConfiguration(id: "mlx-community/Qwen3.6-Test"),
            hasRecurrentLayers: true
        )
        let firstDrain = DrainCancelToken()
        let secondDrain = DrainCancelToken()
        let firstRequest = try Self.chatRequest(modelID: "mlx-community/Qwen3.6-Test", maxTokens: 1)
            .withRequestID("lane-drain-first")
        let secondRequest = try Self.chatRequest(modelID: "mlx-community/Qwen3.6-Test", maxTokens: 1)
            .withRequestID("lane-drain-second")
        let first = Task<Void, Error> {
            _ = try await lane.prepare(
                request: firstRequest,
                maxContextTokens: 4096,
                templateSupportsThinkingToggle: false,
                templateSupportsPreserveThinking: false,
                toolSelectionModelID: nil,
                drainCancelled: firstDrain
            )
        }
        defer {
            first.cancel()
            Task { await preparationGate.open() }
        }
        try await Self.eventually {
            let waitingCount = await preparationGate.waitingCount()
            let processorCallCount = processor.callCount()
            return waitingCount == 1 && processorCallCount == 1
        }

        let second = Task<Void, Error> {
            _ = try await lane.prepare(
                request: secondRequest,
                maxContextTokens: 4096,
                templateSupportsThinkingToggle: false,
                templateSupportsPreserveThinking: false,
                toolSelectionModelID: nil,
                drainCancelled: secondDrain
            )
        }
        defer { second.cancel() }
        try await Self.eventually {
            await lane.preparationEntryCountForTest() == 2
        }
        let callsWhileSecondQueued = processor.callCount()
        XCTAssertEqual(callsWhileSecondQueued, 1)

        secondDrain.fire()
        await preparationGate.open()
        try await first.value
        do {
            try await second.value
            XCTFail("queued drained preparation must fail before invoking the processor")
        } catch is DrainCancelledError {
            // Expected: the drain fired while this preparation awaited the lane permit.
        }
        let finalCallCount = processor.callCount()
        XCTAssertEqual(finalCallCount, 1)
    }

    func testQwenPreparationLaneSnapshotStaysPinnedAcrossWarmSwap() async throws {
        let tokenizer = RuntimeBridgePreparationTokenizer()
        let processor = RuntimeBridgePromptProcessor(tokens: [3])
        let configuration = ModelConfiguration(id: "mlx-community/Qwen3.6-Test")
        let oldLane = ContinuousBatchTextPreparationLane(
            processor: processor,
            tokenizer: tokenizer,
            configuration: configuration,
            hasRecurrentLayers: true
        )
        let loaderGate = RuntimeBridgeTestGate()
        let runtime = Self.attachedRuntime(
            modelID: "mlx-community/Qwen3.6-Test",
            backend: RuntimeBridgeScriptedBackend(scripts: [:]),
            preparationLane: oldLane,
            warmSwapEnabled: true,
            testLoader: { target in
                await loaderGate.wait()
                return (target, "new-hash")
            }
        )
        let oldRequest = try Self.chatRequest(modelID: "mlx-community/Qwen3.6-Test", maxTokens: 1)
            .withRequestID("old-lane")
        let oldHandle = try await runtime.acquireRequestHandle(oldRequest)
        let swap = try await runtime.beginSwap(targetModelID: "mlx-community/Qwen3.6-New")
        defer { Task { await loaderGate.open() } }
        try await Self.eventually { await loaderGate.waitingCount() == 1 }
        let loadingSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(loadingSnapshot.state, .loading)
        XCTAssertTrue(oldHandle.snapshot.continuousBatchTextPreparationLane === oldLane)
        await runtime.unregisterInFlight(oldHandle.registrationID)
        await loaderGate.open()
        try await swap.value
        let swappedSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(swappedSnapshot.modelID, "mlx-community/Qwen3.6-New")
        XCTAssertNil(swappedSnapshot.continuousBatchTextPreparationLane)
        XCTAssertTrue(oldHandle.snapshot.continuousBatchTextPreparationLane === oldLane)
    }

    func testQwenPreparationLaneAdmitsNonStreamingRowWhileTargetLockIsHeld() async throws {
        try requireMetal()

        try await assertQwenPreparationLaneAdmitsWhileTargetLockIsHeld(streaming: false)
    }

    func testQwenPreparationLaneAdmitsStreamingRowWhileTargetLockIsHeld() async throws {
        try requireMetal()

        try await assertQwenPreparationLaneAdmitsWhileTargetLockIsHeld(streaming: true)
    }

    func testAttachedModelRuntimeServesFreshGreedyRequestsThroughScheduler() async throws {
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()

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
        try requireMetal()
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
        try requireMetal()
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
        try requireMetal()

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
        try requireMetal()

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
        maxPrefillRowsPerIteration: Int = 1,
        maxPrefillTokensPerIteration: Int? = nil,
        prefillGrouping: ContinuousBatchPrefillGroupingRule = .unconstrained,
        allowsRaggedPrefillOffsets: Bool = false,
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
                maxPrefillRowsPerIteration: maxPrefillRowsPerIteration,
                prefillGrouping: prefillGrouping,
                maxPrefillTokensPerIteration: maxPrefillTokensPerIteration,
                maxPromptChunkTokens: maxPromptChunkTokens,
                allowsRaggedPrefillOffsets: allowsRaggedPrefillOffsets,
                snapshot: ContinuousBatchSchedulerSnapshot(
                    modelID: descriptor.modelID,
                    modelSHA256: descriptor.modelSHA256,
                    weightsGeneration: 1
                ),
                // Scripted rounds must not depend on unrelated Studio memory use.
                nativeMTPRoundSystemMemoryProbe: .init(identity: "runtime-bridge-test") {
                    NativeMTPRoundSystemMemorySample(
                        availableBytes: 1_000_000_000,
                        physicalBytes: 1_000_000_000
                    )
                }
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

    /// Tiny dense Qwen3.5 (hybrid linear/full attention). Linear inputs are
    /// 64 wide so every projection quantizes at group size 64.
    private static let tinyQwen35DenseConfiguration = """
        {
          "model_type": "qwen3_5_text",
          "hidden_size": 64,
          "num_hidden_layers": 2,
          "intermediate_size": 64,
          "num_attention_heads": 2,
          "num_key_value_heads": 1,
          "head_dim": 32,
          "linear_num_value_heads": 2,
          "linear_num_key_heads": 1,
          "linear_key_head_dim": 32,
          "linear_value_head_dim": 32,
          "linear_conv_kernel_dim": 2,
          "rms_norm_eps": 1e-6,
          "vocab_size": 64,
          "rope_theta": 100000.0,
          "partial_rotary_factor": 0.25,
          "max_position_embeddings": 256,
          "tie_word_embeddings": true,
          "attention_bias": false,
          "full_attention_interval": 2,
          "rope_parameters": {
            "type": "default",
            "rope_theta": 100000.0,
            "partial_rotary_factor": 0.25
          }
        }
        """

    /// Tiny Qwen3.5 MoE: 4 experts, top-2. Linear inputs are 64 wide so the
    /// expert projections quantize at group size 64.
    private static let tinyQwen35MoEConfiguration = """
        {
          "model_type": "qwen3_5_moe_text",
          "hidden_size": 64,
          "num_hidden_layers": 2,
          "intermediate_size": 64,
          "num_attention_heads": 2,
          "num_key_value_heads": 1,
          "head_dim": 32,
          "linear_num_value_heads": 2,
          "linear_num_key_heads": 1,
          "linear_key_head_dim": 32,
          "linear_value_head_dim": 32,
          "linear_conv_kernel_dim": 2,
          "rms_norm_eps": 1e-6,
          "vocab_size": 64,
          "rope_theta": 100000.0,
          "partial_rotary_factor": 0.25,
          "max_position_embeddings": 256,
          "tie_word_embeddings": true,
          "attention_bias": false,
          "full_attention_interval": 2,
          "num_experts": 4,
          "num_experts_per_tok": 2,
          "moe_intermediate_size": 64,
          "shared_expert_intermediate_size": 64,
          "norm_topk_prob": true,
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

    private static func toolChatRequest(modelID: String) throws -> ChatCompletionRequest {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "What's the weather in Paris?"]],
            "max_tokens": 2,
            "stop": ["BUYER"],
            "tool_choice": "required",
            "tools": [[
                "type": "function",
                "function": ["name": "get_weather", "parameters": schema],
            ]],
        ]
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func assertQwenPreparationLaneAdmitsWhileTargetLockIsHeld(streaming: Bool) async throws {
        let modelID = "mlx-community/Qwen3.6-Test"
        let tokenizer = RuntimeBridgePreparationTokenizer()
        let processor = RuntimeBridgePromptProcessor(tokens: [3])
        let configuration = ModelConfiguration(id: modelID)
        let container = ModelContainer(context: ModelContext(
            configuration: configuration,
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: processor,
            tokenizer: tokenizer
        ))
        let lane = ContinuousBatchTextPreparationLane(
            processor: processor,
            tokenizer: tokenizer,
            configuration: configuration,
            hasRecurrentLayers: true
        )
        let backend = RuntimeBridgeScriptedBackend(scripts: [:])
        let runtime = Self.attachedRuntime(
            modelID: modelID,
            backend: backend,
            container: container,
            preparationLane: lane
        )
        let request = try Self.chatRequest(modelID: modelID, maxTokens: 2)
            .withRequestID(streaming ? "lane-lock-stream" : "lane-lock-complete")
        let handle = streaming ? try await runtime.acquireRequestHandle(request) : nil
        let targetLock = RuntimeBridgeTestGate()
        let lockTask = Task {
            try await container.perform { _ in
                await targetLock.wait()
            }
        }
        defer {
            Task { await targetLock.open() }
        }
        try await Self.eventually { await targetLock.waitingCount() == 1 }

        let operation = Task<CompletionResult, Error> {
            if let handle {
                try await runtime.preflight(request, with: handle)
                return try await runtime.stream(request, with: handle) { _ in }
            }
            return try await runtime.complete(request)
        }
        defer {
            operation.cancel()
            if let handle {
                Task { await runtime.unregisterInFlight(handle.registrationID) }
            }
        }
        try await Self.eventually { await backend.prefillCallCount() == 1 }
        let prefillCallsWhileLocked = await backend.prefillCallCount()
        let lockWaitersBeforeRelease = await targetLock.waitingCount()
        XCTAssertEqual(prefillCallsWhileLocked, 1)
        XCTAssertEqual(lockWaitersBeforeRelease, 1)

        await targetLock.open()
        try await lockTask.value
        let completion = try await operation.value
        XCTAssertEqual(completion.promptTokens, 1)
        XCTAssertEqual(completion.completionTokens, 2)
        if let handle {
            await runtime.unregisterInFlight(handle.registrationID)
        }
    }

    func testCreativeHoldPreservesActiveContinuousBatchingAndNativeMTP() async throws {
        try requireMetal()
        let modelID = "model-a"
        let hash = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: hash)
        let admission = Self.creativeAdmission(modelID: modelID, hash: hash)
        let capability = NativeMTPCapability(
            admitted: true, revoked: false, revocationStateAvailable: true,
            supportsCurrentProcessor: true, supportsCurrentStateCache: true,
            supportsStreaming: true, supportsNonStreaming: true, supportsStopSequences: true,
            hasQualifiedRowMappedTransactions: true, maximumProposalDepth: 1,
            maximumPromptTokens: 4096, maximumCompletionTokens: 256,
            completeWindowBytesByDepth: [8, 32], family: admission.familyAdapter)
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: RuntimeBridgeFakeModel(nextTokenByInput: [:]),
            processor: RuntimeBridgePromptProcessor(tokens: [3]), tokenizer: RuntimeBridgeFakeTokenizer()))
        let drafter = MTPDrafterContainer(context: MTPDrafterContext(
            configuration: ModelConfiguration(id: "same-drafter"), model: RuntimeBridgeRecordingMTPDrafter()))
        let runtime = ModelRuntime(
            modelID: modelID, modelHash: hash,
            pagedKVConfig: PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64),
            maxBatch: 2, continuousBatchingMode: .on, continuousBatchingDurableReplayAuthorityAvailable: true,
            nativeMTPMode: .auto, nativeMTPCapability: capability, nativeMTPSchedulerSupported: true,
            nativeMTPDrafterContainer: drafter, labNativeMTPAdmissionCapability: admission,
            warmSwapEnabled: false, pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
            pagedKVHardwareSizingProof: proof, pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            pagedKVModelCapabilities: ModelRuntime.pagedKVModelCapabilities(modelID: "mlx-community/Qwen-Test", configJSONData: nil),
            container: container,
            continuousBatchingBackend: RuntimeBridgeScriptedBackend(scripts: [:]),
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected }, testLoader: { ($0, hash) })
        let offer = NativeMTPTupleReofferTests.offer()
        await runtime.installNativeMTPTupleOfferForTest(offer)
        let before = await runtime.currentSnapshot()
        let beforeDrafter = await runtime.creativeNativeDrafterArtifactForTest()
        XCTAssertTrue(before.continuousBatching?.active == true)
        XCTAssertTrue(before.nativeMTPStatus.enabled)
        XCTAssertTrue(before.schedulerSupportsNativeMTP)
        try await runtime.unloadForLocalCreativeHold()
        let unloaded = await runtime.currentSnapshot()
        XCTAssertNil(unloaded.modelID)
        XCTAssertNil(unloaded.nativeMTPTupleOffer)
        let tuple = NativeMTPSelfTestRuntimeTuple(
            modelID: modelID, modelHash: hash, modelHashAlgorithm: "sha256",
            tokenizerDigest: offer.runtimeTuple.tokenizerDigest, artifactDigest: offer.runtimeTuple.artifactDigest,
            manifestDigest: offer.runtimeTuple.manifestDigest, sidecarDigest: offer.runtimeTuple.sidecarDigest,
            providerBinarySHA256: offer.runtimeTuple.providerBinarySHA256, runtimeCDHash: offer.runtimeTuple.runtimeCDHash,
            cacheNamespace: offer.runtimeTuple.cacheNamespace, stateDigest: offer.runtimeTuple.stateDigest, proposalDepth: 1)
        let input = NativeMTPSelfTestInput(
            tupleSHA256: admission.tupleSHA256, modelID: modelID, modelRevision: hash,
            familyAdapter: admission.familyAdapter, proposalDepth: 1, challengeBank: admission.selfTestChallengeBank,
            servedSnapshot: NativeMTPSelfTestServedSnapshot(tupleSHA256: admission.tupleSHA256,
                runtimeTuple: tuple, generation: UInt64(before.specDecodeGeneration + 1), proposalDepth: 1))
        let receipt = NativeMTPSelfTestReceipt(
            version: NativeMTPSelfTestRunner.capability, tupleSHA256: admission.tupleSHA256,
            challengeBankSHA256: admission.selfTestChallengeBank.challengeBankSHA256,
            promptTokenIDs: [3], generatedTokenIDs: [4], terminalReason: .length,
            acceptedTokens: 1, rejectedTokens: 0, bonusTokens: 0, committedTokens: 1,
            committedStateDigestSHA256: String(repeating: "8", count: 64), actualDecodePath: .nativeMTP, fallbackUsed: false)
        // Replace only external loading/self-check execution with a deterministic
        // admitted fixture. The production install, scheduler, tuple publication,
        // revocation watcher and failure/ownership transitions all run below.
        let load = ModelRuntime.NativeMTPRuntimeLoadResult(
            targetContainer: container, targetDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            drafterContainer: drafter, capability: capability, admissionCapability: admission,
            selfTestInput: input, selfTestRuntimeTuple: tuple, runtimeTuple: offer.runtimeTuple,
            servedSnapshotID: "restored-snapshot", runtimeCacheClass: "KVCacheSimple",
            modelCapabilities: ModelRuntime.pagedKVModelCapabilities(modelID: "mlx-community/Qwen-Test", configJSONData: nil),
            revocationSignerKeyID: "test-signer", revocationTrustedKeyring:
                NativeMTPAdmissionSidecar.TrustedKeyring(publicKeysByKeyID: [:], requiredKeyID: "test-signer"),
            revocationExpiresAt: nil)
        await runtime.setNativeMTPRevocationPollerForTest { _, _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {}
        }
        await runtime.setCreativeNativeReloadForTest({ load }, receipt: receipt)
        try await runtime.restoreAfterLocalCreativeHold()
        let after = await runtime.currentSnapshot()
        XCTAssertEqual(after.modelID, before.modelID)
        XCTAssertEqual(after.modelHash, before.modelHash)
        XCTAssertEqual(after.continuousBatching?.active, before.continuousBatching?.active)
        XCTAssertEqual(after.continuousBatching?.mode, before.continuousBatching?.mode)
        XCTAssertEqual(after.continuousBatching?.scheduler?.slotsTotal, before.continuousBatching?.scheduler?.slotsTotal)
        XCTAssertEqual(after.nativeMTPStatus.enabled, before.nativeMTPStatus.enabled)
        XCTAssertEqual(after.nativeMTPCapability, before.nativeMTPCapability)
        XCTAssertEqual(after.schedulerSupportsNativeMTP, before.schedulerSupportsNativeMTP)
        XCTAssertEqual(after.nativeMTPTupleOffer?.nativeMTPAdmissionTupleSHA256, before.nativeMTPTupleOffer?.nativeMTPAdmissionTupleSHA256)
        XCTAssertEqual(after.nativeMTPTupleOffer?.runtimeTuple, before.nativeMTPTupleOffer?.runtimeTuple)
        let afterDrafter = await runtime.creativeNativeDrafterArtifactForTest()
        XCTAssertEqual(afterDrafter, beforeDrafter)
        XCTAssertNotNil(afterDrafter)
        let cache = await runtime.creativeConversationCacheForTest()
        for _ in 0..<2 {
            let lease = await cache.begin(conversationKey: "after-hold", incomingTokens: [3], modelID: modelID, kvBits: nil)
            XCTAssertNotNil(lease, "Restoration must leave conversation-cache leases usable")
            if let lease { await cache.abort(lease) }
        }
        let watcher = await runtime.nativeMTPRevocationWatcherActiveForTest()
        XCTAssertTrue(watcher)
        // Coordinator bank mismatch must survive the hold without publishing
        // an offer until the ordinary re-offer/revocation gates permit it.
        let parkedOffer = try XCTUnwrap(after.nativeMTPTupleOffer)
        let didPark = await runtime.parkNativeMTPTupleForReoffer(
            admissionTupleSHA256: parkedOffer.nativeMTPAdmissionTupleSHA256,
            servedSnapshotID: parkedOffer.servedSnapshotID,
            targetGeneration: parkedOffer.targetGeneration)
        XCTAssertTrue(didPark)
        let parkedBefore = await runtime.currentSnapshot()
        try await runtime.unloadForLocalCreativeHold()
        try await runtime.restoreAfterLocalCreativeHold()
        let parkedAfter = await runtime.currentSnapshot()
        let remainsParked = await runtime.nativeMTPTupleIsParkedForTest()
        XCTAssertTrue(remainsParked)
        XCTAssertNil(parkedAfter.nativeMTPTupleOffer)
        XCTAssertEqual(parkedAfter.nativeMTPStatus, parkedBefore.nativeMTPStatus)
        XCTAssertEqual(parkedAfter.continuousBatching?.active, parkedBefore.continuousBatching?.active)
        XCTAssertEqual(parkedAfter.continuousBatching?.mode, parkedBefore.continuousBatching?.mode)
        await runtime.setNativeMTPRevokedSetReaderForTest { _, _ in [] }
        let reoffered = await runtime.restoreParkedNativeMTPTuple(parkedOffer)
        XCTAssertEqual(reoffered, .restored)
        let publishedAfterHold = await runtime.currentSnapshot()
        XCTAssertEqual(publishedAfterHold.nativeMTPTupleOffer, parkedOffer)
        XCTAssertTrue(publishedAfterHold.nativeMTPStatus.enabled)

        // A fresh hold can drain the rebuilt scheduler; the old scheduler's
        // permanently drained state is not reused.
        try await runtime.unloadForLocalCreativeHold()
        let failedReceipt = NativeMTPSelfTestReceipt(
            version: NativeMTPSelfTestRunner.capability, tupleSHA256: admission.tupleSHA256,
            challengeBankSHA256: admission.selfTestChallengeBank.challengeBankSHA256,
            promptTokenIDs: [3], generatedTokenIDs: [4], terminalReason: .length,
            acceptedTokens: 0, rejectedTokens: 1, bonusTokens: 0, committedTokens: 1,
            committedStateDigestSHA256: String(repeating: "8", count: 64), actualDecodePath: .ordinary, fallbackUsed: true)
        await runtime.setCreativeNativeReloadForTest({ load }, receipt: failedReceipt)
        try await runtime.restoreAfterLocalCreativeHold()
        let failedQualification = await runtime.currentSnapshot()
        XCTAssertEqual(failedQualification.modelID, modelID)
        XCTAssertTrue(failedQualification.continuousBatching?.active == true)
        XCTAssertNil(failedQualification.nativeMTPTupleOffer)
        XCTAssertFalse(failedQualification.nativeMTPStatus.enabled)
        XCTAssertEqual(failedQualification.continuousBatching?.mode, before.continuousBatching?.mode)

        // A revoked/unavailable admission uses ordinary loading too, without
        // requiring the operator's warm-swap feature to be enabled.
        await runtime.installNativeMTPTupleOfferForTest(offer)
        try await runtime.unloadForLocalCreativeHold()
        await runtime.setCreativeNativeReloadForTest({
            throw ModelRuntimeLoadError(target: modelID, reason: "tuple revoked")
        }, receipt: receipt)
        try await runtime.restoreAfterLocalCreativeHold()
        let revoked = await runtime.currentSnapshot()
        XCTAssertEqual(revoked.modelID, modelID)
        XCTAssertTrue(revoked.continuousBatching?.active == true)
        XCTAssertNil(revoked.nativeMTPTupleOffer)
        XCTAssertFalse(revoked.nativeMTPStatus.enabled)
        XCTAssertEqual(revoked.continuousBatching?.mode, before.continuousBatching?.mode)

    }

    func testCreativeHoldPreservesOrdinaryActiveBatching() async throws {
        try requireMetal()
        let hash = String(repeating: "a", count: 64)
        let runtime = Self.attachedRuntime(modelID: "mlx-community/Qwen-Test",
            backend: RuntimeBridgeScriptedBackend(scripts: [:]), warmSwapEnabled: true,
            testLoader: { ($0, hash) },
            testCompletion: { _, _ in throw PagedKVRuntimeBridgeTestError.notExpected })
        let before = await runtime.currentSnapshot()
        XCTAssertTrue(before.continuousBatching?.active == true)
        try await runtime.unloadForLocalCreativeHold()
        try await runtime.restoreAfterLocalCreativeHold()
        let after = await runtime.currentSnapshot()
        XCTAssertEqual(after.continuousBatching?.active, before.continuousBatching?.active)
        XCTAssertEqual(after.nativeMTPStatus.enabled, before.nativeMTPStatus.enabled)
        XCTAssertEqual(after.continuousBatching?.mode, before.continuousBatching?.mode)
        XCTAssertEqual(after.continuousBatching?.scheduler?.slotsTotal, before.continuousBatching?.scheduler?.slotsTotal)
    }

    func testCreativeHoldPreservesNativeMTPPausedAfterFallback() async throws {
        try requireMetal()
        let hash = String(repeating: "a", count: 64)
        let runtime = Self.attachedRuntime(modelID: "mlx-community/Qwen-Test",
            backend: RuntimeBridgeScriptedBackend(scripts: [:]), warmSwapEnabled: false,
            testLoader: { ($0, hash) },
            testCompletion: { _, _ in throw PagedKVRuntimeBridgeTestError.notExpected })
        // This is the state after native runtime fallback has fenced its tuple:
        // base batching remains healthy, while native remains disabled.
        await runtime.setNativeMTPDisabledStatusReasonForTest(.runtimeFailure)
        let before = await runtime.currentSnapshot()
        try await runtime.unloadForLocalCreativeHold()
        try await runtime.restoreAfterLocalCreativeHold()
        let after = await runtime.currentSnapshot()
        XCTAssertEqual(after.modelID, before.modelID)
        XCTAssertEqual(after.nativeMTPStatus, before.nativeMTPStatus)
        XCTAssertNil(after.nativeMTPTupleOffer)
        XCTAssertFalse(after.nativeMTPStatus.enabled)
        XCTAssertEqual(after.continuousBatching?.active, before.continuousBatching?.active)
        XCTAssertEqual(after.continuousBatching?.mode, before.continuousBatching?.mode)
    }

    private static func creativeAdmission(modelID: String, hash: String) -> NativeMTPAdmissionCapability {
        NativeMTPAdmissionCapability(
            tupleSHA256: String(repeating: "7", count: 64),
            sidecarSHA256: String(repeating: "0", count: 64),
            modelID: modelID,
            modelRevision: hash,
            targetArtifactSHA256: hash,
            mtpArtifactSHA256: String(repeating: "2", count: 64),
            tokenizerSHA256: String(repeating: "3", count: 64),
            mtpManifestSHA256: String(repeating: "4", count: 64),
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact",
            predictionLayerCount: 1,
            maxProposalDepth: 1,
            completeWindowBytesByDepth: [8, 32],
            throughputDeltaPPM: 0,
            maxPromptTokens: 4096,
            maxCompletionTokens: 256,
            cacheClass: "paged_kv",
            stateClass: "hybrid_stageable_rewindable",
            quantization: NativeMTPAdmissionSidecar.Quantization(target: "mlx_affine_4bit", mtp: "mlx_affine_4bit"),
            providerRevision: String(repeating: "a", count: 40),
            upstreamMLXSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            qualifiedSlots: 2,
            maxNativeActiveRows: 2,
            spec023ReleaseID: "native-mtp-test",
            spec023SourceCommit: String(repeating: "a", count: 40),
            spec023BuildDigestSHA256: String(repeating: "b", count: 64),
            spec023LiveExecutableCDHash: String(repeating: "1", count: 40),
            evidenceArtifactSHA256: [String(repeating: "5", count: 64)],
            challengeBankSignerKeyID: "native-mtp-selftest-test",
            revocationSignerKeyID: "native-mtp-revocation-test",
            selfTestChallengeBank: NativeMTPSelfTestChallengeBank(
                releaseID: "native-mtp-test",
                challengeBankPath: "native-mtp-selftest-bank.json",
                challengeBankSHA256: String(repeating: "6", count: 64),
                signaturePath: "native-mtp-selftest-bank.json.sig",
                signerKeyID: "native-mtp-selftest-test",
                signatureSHA256: String(repeating: "7", count: 64)
            ),
            capturedArtifacts: nil
        )
    }

    private static func attachedRuntime(
        modelID: String,
        backend: RuntimeBridgeScriptedBackend,
        promptTokens: [Int32] = [3],
        container suppliedContainer: ModelContainer? = nil,
        preparationLane: ContinuousBatchTextPreparationLane? = nil,
        warmSwapEnabled: Bool = false,
        testLoader: (@Sendable (String) async throws -> (String, String?))? = nil,
        testCompletion: (@Sendable (RuntimeSnapshot, ChatCompletionRequest) async throws -> CompletionResult)? = nil
    ) -> ModelRuntime {
        let modelSHA = String(repeating: "a", count: 64)
        let proof = Self.sizingProof(modelID: modelID, modelSHA: modelSHA)
        let container = suppliedContainer ?? ModelContainer(context: ModelContext(
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
            warmSwapEnabled: warmSwapEnabled,
            pagedKVObservedRuntimeIdentity: Self.observedIdentity(from: proof),
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "KVCacheSimple",
            pagedKVSchedulerBackendInstalled: true,
            container: container,
            continuousBatchingBackend: backend,
            testContinuousBatchTextPreparationLane: preparationLane,
            loader: { _ in throw PagedKVRuntimeBridgeTestError.notExpected },
            testLoader: testLoader,
            testCompletion: testCompletion
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
        // SwiftPM may launch XCTest through swiftpm-testing-helper, whose main
        // bundle is not the test bundle containing the packaged MLX resources.
        let testBundle = Bundle(for: PagedKVRuntimeBridgeTests.self)
        guard Self.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable; test bundle=\(testBundle.bundleURL.path), test resources=\(testBundle.resourceURL?.path ?? "nil"), test executable=\(testBundle.executableURL?.path ?? "nil"), main bundle=\(Bundle.main.bundleURL.path), main executable=\(Bundle.main.executableURL?.path ?? "nil")")
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

    func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
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
                // Attend through the cache like the served models.
                let attended = attentionWithCacheUpdate(
                    queries: keys,
                    keys: keys,
                    values: values,
                    cache: layer,
                    scale: 1,
                    mask: sequenceLength > 1 ? .causal : .none
                )
                eval(attended)
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
    private var prefillHook: (@Sendable ([String]) async -> Void)?
    private var prefillGroups: [[String]] = []

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

    /// Runs before each prefill call with the call's request IDs.
    var onPrefill: (@Sendable ([String]) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return prefillHook
        }
        set {
            lock.lock()
            prefillHook = newValue
            lock.unlock()
        }
    }

    init(_ base: PagedKVSharedForwardBackend) {
        self.base = base
    }

    /// Request IDs of every prefill call, in call order.
    func prefillRequestGroups() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return prefillGroups
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
        let ids = rows.map(\.requestID)
        lock.lock()
        prefillGroups.append(ids)
        let hook = prefillHook
        lock.unlock()
        await hook?(ids)
        return try await base.prefill(rows: rows)
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

    func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
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
                // Attend through the cache like the served models.
                let attended = attentionWithCacheUpdate(
                    queries: keys,
                    keys: keys,
                    values: values,
                    cache: layer,
                    scale: 1,
                    mask: sequenceLength > 1 ? .causal : .none
                )
                eval(attended)
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

private struct RuntimeBridgePreparationTokenizer: Tokenizer {
    let imStartTokenID = 151_644
    let eosTokenID = 151_645
    let extraEOSTokenID = 151_646
    let extraEOSToken = "<|extra_eos|>"
    let bosToken: String? = nil
    let eosToken: String? = "<|eos|>"
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        let specialTokens = [
            ("<|im_start|>", imStartTokenID),
            ("<|eos|>", eosTokenID),
            (extraEOSToken, extraEOSTokenID),
        ]
        var tokens: [Int] = []
        var index = text.startIndex
        while index < text.endIndex {
            if let special = specialTokens.first(where: { text[index...].hasPrefix($0.0) }) {
                tokens.append(special.1)
                index = text.index(index, offsetBy: special.0.count)
            } else {
                tokens.append(Int(text[index].unicodeScalars.first!.value))
                index = text.index(after: index)
            }
        }
        return tokens
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { tokenID in
            switch tokenID {
            case imStartTokenID: return "<|im_start|>"
            case eosTokenID: return skipSpecialTokens ? "" : "<|eos|>"
            case extraEOSTokenID: return skipSpecialTokens ? "" : extraEOSToken
            default: return UnicodeScalar(tokenID).map(String.init) ?? ""
            }
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? {
        switch token {
        case "<|im_start|>": return imStartTokenID
        case "<|eos|>": return eosTokenID
        case extraEOSToken: return extraEOSTokenID
        default: return Int(token)
        }
    }

    func convertIdToToken(_ id: Int) -> String? {
        switch id {
        case imStartTokenID: return "<|im_start|>"
        case eosTokenID: return "<|eos|>"
        case extraEOSTokenID: return extraEOSToken
        default: return UnicodeScalar(id).map(String.init)
        }
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}

private struct RuntimeBridgeCapturedUserInput: Equatable {
    let roles: [String]
    let contents: [String]
    let toolNames: [String]
    let enableThinking: Bool?
    let preserveThinking: Bool?
}

private final class RuntimeBridgeCapturingPromptProcessor: UserInputProcessor, @unchecked Sendable {
    private let tokens: [Int32]
    private let lock = NSLock()
    private var captured: RuntimeBridgeCapturedUserInput?

    init(tokens: [Int32]) {
        self.tokens = tokens
    }

    func prepare(input: UserInput) throws -> LMInput {
        let messages: [Chat.Message]
        if case .chat(let chat) = input.prompt {
            messages = chat
        } else {
            messages = []
        }
        let toolNames = input.tools?.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        } ?? []
        let fingerprint = RuntimeBridgeCapturedUserInput(
            roles: messages.map(\.role.rawValue),
            contents: messages.map(\.content),
            toolNames: toolNames,
            enableThinking: input.additionalContext?["enable_thinking"] as? Bool,
            preserveThinking: input.additionalContext?["preserve_thinking"] as? Bool
        )
        lock.lock()
        captured = fingerprint
        lock.unlock()
        return LMInput(tokens: MLXArray(tokens).reshaped(1, tokens.count))
    }

    func lastInput() -> RuntimeBridgeCapturedUserInput? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private struct RuntimeBridgePromptProcessor: UserInputProcessor {
    let tokens: [Int32]

    func prepare(input: UserInput) throws -> LMInput {
        LMInput(tokens: MLXArray(tokens).reshaped(1, tokens.count))
    }
}

private final class RuntimeBridgeBlockingPromptProcessor: UserInputProcessor, @unchecked Sendable {
    private let tokens: [Int32]
    private let firstPreparationGate: RuntimeBridgeTestGate
    private let lock = NSLock()
    private var calls = 0

    init(tokens: [Int32], firstPreparationGate: RuntimeBridgeTestGate) {
        self.tokens = tokens
        self.firstPreparationGate = firstPreparationGate
    }

    func prepare(input: UserInput) async throws -> LMInput {
        let isFirstCall = lock.withLock {
            calls += 1
            return calls == 1
        }
        if isFirstCall {
            await firstPreparationGate.wait()
        }
        return LMInput(tokens: MLXArray(tokens).reshaped(1, tokens.count))
    }

    func callCount() -> Int {
        lock.withLock { calls }
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

    func waitingCount() -> Int {
        continuations.count
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
