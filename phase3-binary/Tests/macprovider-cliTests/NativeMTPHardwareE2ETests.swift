import CryptoKit
import Foundation
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

/// Opt-in real-model coverage for the native Qwen3.5 MTP serving path.
///
/// The fixture root must contain two plain, symlink-free snapshot directories:
/// `target/` and `mtp/`. Preparing that immutable test bundle is intentionally an
/// operator/lab action; ordinary CI never downloads model weights.
final class NativeMTPHardwareE2ETests: XCTestCase {
    private static let enabledVariable = "MACPROVIDER_NATIVE_MTP_E2E"
    private static let rootVariable = "MACPROVIDER_NATIVE_MTP_E2E_ROOT"
    private static let modelID = "mlx-community/Qwen3.5-9B-4bit"
    private static let upstreamRevision = "ca8c384c4fb6bc7d2fbb7c70a18c34b935701805"
    private static let providerRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let liveExecutableCDHash = "456789abcdef0123456789abcdef0123456789ab"
    private static let releaseID = "native-mtp-hardware-e2e"

    func testRealQwen35NativeMTPMatchesOrdinaryGreedyBatch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.enabledVariable] == "1" else {
            throw XCTSkip("set \(Self.enabledVariable)=1 on the Mac Studio")
        }
        guard let rootPath = environment[Self.rootVariable], !rootPath.isEmpty else {
            XCTFail("\(Self.rootVariable) must name the prepared target+MTP fixture root")
            return
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)

        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let machine = MachineFingerprinter().sample()
        let admission = try makeAndValidateAdmission(
            root: root,
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            machine: machine
        )
        XCTAssertEqual(admission.targetArtifactSHA256, targetIdentity.digest)
        XCTAssertEqual(admission.mtpArtifactSHA256, mtpIdentity.digest)
        XCTAssertEqual(admission.maxProposalDepth, 1)
        XCTAssertEqual(admission.spec023ReleaseID, Self.releaseID)
        XCTAssertEqual(admission.sidecarSHA256.count, 64)
        XCTAssertEqual(admission.selfTestChallengeBank.challengeBankPath, "native-mtp-selftest-bank.json")

        let configData = try Data(contentsOf: targetDirectory.appendingPathComponent("config.json"))
        let modelCapabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: Self.modelID,
            configJSONData: configData
        )
        XCTAssertEqual(modelCapabilities.modelFamily, "qwen")
        XCTAssertTrue(modelCapabilities.hybridDecoderArchitectureVerified)
        XCTAssertEqual(
            ModelRuntime.nativeMTPAdmissionCacheClass(
                runtimeCacheClass: "mixed",
                modelCapabilities: modelCapabilities
            ),
            "paged_kv"
        )

        await Qwen35TextMTPRegistration.register()
        let targetContainer = try await LLMModelFactory.shared.loadContainer(
            from: targetDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        let drafterContainer = try await MTPDrafterModelFactory.shared.loadContainer(
            from: mtpDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        let maximumBlockSize = await drafterContainer.perform { context in
            context.model.maximumBlockSize
        }
        XCTAssertEqual(maximumBlockSize, 2)

        let cacheKinds = try await targetContainer.perform { context in
            try context.model.newCache(parameters: nil as GenerateParameters?).map { cache in
                guard let kind = PagedKVSharedForwardBackend.CacheKind.recognized(from: cache) else {
                    throw NativeMTPHardwareE2EError.unsupportedCache(String(describing: type(of: cache)))
                }
                return kind
            }
        }
        XCTAssertTrue(cacheKinds.contains(.pagedAttention))
        XCTAssertTrue(cacheKinds.contains(.recurrentMamba))

        let proof = sizingProof(modelSHA: targetIdentity.digest)
        let observed = observedIdentity(from: proof)
        let pagedConfig = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 512)
        let capability = NativeMTPCapability(
            admitted: true,
            revoked: false,
            revocationStateAvailable: true,
            supportsCurrentProcessor: true,
            supportsCurrentStateCache: true,
            supportsStreaming: true,
            supportsNonStreaming: true,
            supportsStopSequences: true,
            hasQualifiedRowMappedTransactions: true,
            maximumProposalDepth: admission.maxProposalDepth,
            maximumPromptTokens: admission.maxPromptTokens,
            maximumCompletionTokens: admission.maxCompletionTokens,
            completeWindowBytesByDepth: admission.completeWindowBytesByDepth,
            family: admission.familyAdapter,
            throughputDeltaPPM: admission.throughputDeltaPPM
        )
        let ordinaryBackend = PagedKVSharedForwardBackend(
            container: targetContainer,
            blockSizeTokens: 32,
            maxPhysicalBlocks: 512,
            poolEpoch: 1,
            layerCount: cacheKinds.count,
            cacheKinds: cacheKinds
        )
        let nativeBackend = PagedKVSharedForwardBackend(
            container: targetContainer,
            blockSizeTokens: 32,
            maxPhysicalBlocks: 512,
            poolEpoch: 1,
            layerCount: cacheKinds.count,
            cacheKinds: cacheKinds,
            drafterContainer: drafterContainer
        )
        let ordinaryRuntime = makeRuntime(
            modelSHA: targetIdentity.digest,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            targetContainer: targetContainer,
            backend: ordinaryBackend,
            nativeCapability: nil,
            drafterContainer: nil,
            admissionRecorder: nil
        )
        let admissionRecorder = NativeMTPHardwareAdmissionRecorder()
        let nativeRuntime = makeRuntime(
            modelSHA: targetIdentity.digest,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            targetContainer: targetContainer,
            backend: nativeBackend,
            nativeCapability: capability,
            drafterContainer: drafterContainer,
            admissionRecorder: admissionRecorder
        )

        let requests = try [
            makeRequest(
                id: "native-mtp-real-a",
                prompt: "Continue this sequence with a short answer: one, two, three, four,"
            ),
            makeRequest(
                id: "native-mtp-real-b",
                prompt: "Continue this sequence with a short answer: red, orange, yellow, green,"
            ),
        ]
        let ordinary = try await completeConcurrently(requests, with: ordinaryRuntime)
        let native = try await completeConcurrently(requests, with: nativeRuntime)

        XCTAssertEqual(native.keys.sorted(), ordinary.keys.sorted())
        for id in ordinary.keys.sorted() {
            let expected = try XCTUnwrap(ordinary[id])
            let actual = try XCTUnwrap(native[id])
            XCTAssertEqual(actual.content, expected.content, "content mismatch for \(id)")
            XCTAssertEqual(actual.finishReason, expected.finishReason, "finish reason mismatch for \(id)")
            XCTAssertEqual(actual.promptTokens, expected.promptTokens, "prompt token mismatch for \(id)")
            XCTAssertEqual(actual.completionTokens, expected.completionTokens, "completion token mismatch for \(id)")
            XCTAssertEqual(
                actual.generatedCompletionTokens,
                expected.generatedCompletionTokens,
                "generated token mismatch for \(id)"
            )
        }
        XCTAssertEqual(admissionRecorder.snapshot().count, requests.count)
        XCTAssertTrue(admissionRecorder.snapshot().allSatisfy { $0.effectivePath == .nativeMTP })

        let streamingStopRequest = try makeRequest(
            id: "native-mtp-real-stream-stop",
            prompt: "Answer with a terse sentence ending in STOP.",
            stream: true,
            stop: ["STOP"]
        )
        let admissionCountBeforeStream = admissionRecorder.snapshot().count
        let handle = try await nativeRuntime.acquireRequestHandle(streamingStopRequest)
        defer { Task { await nativeRuntime.unregisterInFlight(handle.registrationID) } }
        let streamRecorder = NativeMTPHardwareStreamRecorder()
        _ = try await nativeRuntime.stream(streamingStopRequest, with: handle) { chunk in
            streamRecorder.append(chunk)
        }
        XCTAssertFalse(streamRecorder.snapshot().isEmpty)
        let streamingAdmissions = admissionRecorder.snapshot().dropFirst(admissionCountBeforeStream)
        XCTAssertEqual(streamingAdmissions.last?.effectivePath, .nativeMTP)

        let snapshot = await nativeRuntime.currentSnapshot()
        XCTAssertEqual(snapshot.continuousBatching?.pagedKVDecision, "attached")
        XCTAssertGreaterThanOrEqual(snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth ?? 0, 2)
    }

    private func makeRuntime(
        modelSHA: String,
        pagedConfig: PagedKVConfig,
        proof: PagedKVHardwareSizingProof,
        observed: PagedKVObservedRuntimeIdentity,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        targetContainer: ModelContainer,
        backend: PagedKVSharedForwardBackend,
        nativeCapability: NativeMTPCapability?,
        drafterContainer: MTPDrafterContainer?,
        admissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: Self.modelID,
            modelHash: modelSHA,
            maxContextTokensOverride: 4096,
            pagedKVConfig: pagedConfig,
            prefillStepSize: 512,
            maxBatch: 2,
            continuousBatchingMode: .on,
            continuousBatchingDurableReplayAuthorityAvailable: true,
            nativeMTPMode: nativeCapability == nil ? .off : .auto,
            nativeMTPCapability: nativeCapability,
            nativeMTPSchedulerSupported: drafterContainer != nil,
            nativeMTPDrafterContainer: drafterContainer,
            testNativeMTPAdmissionObserver: { admission in
                admissionRecorder?.append(admission)
            },
            warmSwapEnabled: false,
            pagedKVObservedRuntimeIdentity: observed,
            pagedKVHardwareSizingProof: proof,
            pagedKVRuntimeCacheClass: "mixed",
            pagedKVSchedulerBackendInstalled: true,
            pagedKVModelCapabilities: modelCapabilities,
            container: targetContainer,
            continuousBatchingBackend: backend,
            loader: { _ in throw NativeMTPHardwareE2EError.unexpectedLoader }
        )
    }

    private func completeConcurrently(
        _ requests: [ChatCompletionRequest],
        with runtime: ModelRuntime
    ) async throws -> [String: CompletionResult] {
        try await withThrowingTaskGroup(of: (String, CompletionResult).self) { group in
            for request in requests {
                let requestID = try XCTUnwrap(request.requestID)
                group.addTask {
                    (requestID, try await runtime.complete(request))
                }
            }
            var results: [String: CompletionResult] = [:]
            for try await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }

    private func makeRequest(
        id: String,
        prompt: String,
        stream: Bool = false,
        stop: [String]? = nil
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": Self.modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 8,
            "temperature": 0,
            "top_p": 1.0,
            "stream": stream,
        ]
        if let stop {
            object["stop"] = stop
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(id)
    }

    private func makeAndValidateAdmission(
        root: URL,
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        machine: MachineFingerprint
    ) throws -> NativeMTPAdmissionCapability {
        let artifactObservation = try NativeMTPArtifactObserver.observePair(
            targetDirectory: root.appendingPathComponent("target", isDirectory: true),
            mtpDirectory: root.appendingPathComponent("mtp", isDirectory: true)
        )
        let affineRepresentation = try NativeMTPArtifactObserver.affineRepresentation(for: artifactObservation)
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: root.appendingPathComponent("mtp/config.json"))
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-hardware-e2e"
        let selfTestBankData = Data(#"{"schema":"native_mtp_selftest_bank.v1","release_id":"native-mtp-hardware-e2e-selftest","prompts":[[1,2,3]]}"#.utf8)
        try selfTestBankData.write(to: root.appendingPathComponent("native-mtp-selftest-bank.json"))
        let selfTestSignature = try signer.signature(for: selfTestBankData).base64EncodedString()
        let selfTestSignatureData = Data("""
        {"alg":"ed25519","key_id":"\(keyID)","signature":"\(selfTestSignature)"}

        """.utf8)
        try selfTestSignatureData.write(to: root.appendingPathComponent("native-mtp-selftest-bank.json.sig"))

        let projectionData = try artifactProjectionData(
            targetSHA: targetIdentity.digest,
            mtpSHA: mtpIdentity.digest,
            tokenizerSHA: tokenizerSHA,
            manifestSHA: manifestSHA
        )
        try projectionData.write(to: root.appendingPathComponent("native-mtp-artifact-manifest.json"))
        let sidecarData = try releaseEnvelopeData(
            machine: machine,
            targetSHA: targetIdentity.digest,
            tokenizerSHA: tokenizerSHA,
            manifestSHA: manifestSHA,
            artifactManifestSHA: sha256Hex(projectionData),
            challengeBankSHA: sha256Hex(selfTestBankData),
            signerKeyID: keyID,
            affineRepresentation: affineRepresentation
        )
        let signature = try signer.signature(for: sidecarData).base64EncodedString()
        let signatureData = Data("""
        {"alg":"ed25519","key_id":"\(keyID)","signature":"\(signature)"}

        """.utf8)
        let authority = NativeMTPResolvedArtifactAuthority.uncheckedForTesting(
            releaseID: Self.releaseID,
            signerKeyID: keyID,
            feedSHA256: String(repeating: "5", count: 64),
            modelKey: Self.modelID,
            artifactID: "primary",
            hashAlgorithm: NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            hash: targetIdentity.digest,
            verificationStatus: "verified",
            targetURLPath: root.appendingPathComponent("target", isDirectory: true).standardizedFileURL.path,
            targetSHA256: targetIdentity.digest
        )
        return try NativeMTPAdmissionSidecar.load(
            sidecarData: sidecarData,
            signatureData: signatureData,
            snapshotRoot: root,
            context: NativeMTPAdmissionSidecar.RuntimeContext(
                modelID: Self.modelID,
                modelRevision: targetIdentity.digest,
                providerRevision: Self.providerRevision,
                upstreamMLXSwiftLMRevision: Self.upstreamRevision,
                hardwareChip: machine.chip,
                ramGB: machine.ramGB,
                osVersion: machine.osVersion,
                slotCount: 2,
                revokedTupleSHA256: []
            ),
            trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring(
                publicKeysByKeyID: [keyID: signer.publicKey.rawRepresentation.base64EncodedString()],
                requiredKeyID: keyID
            ),
            resolvedArtifactAuthority: authority
        )
    }

    private func artifactProjectionData(
        targetSHA: String,
        mtpSHA: String,
        tokenizerSHA: String,
        manifestSHA: String
    ) throws -> Data {
        try jsonData([
            "schema_version": "macprovider.native-mtp-artifact-projection.v1",
            "artifacts": [
                "target": ["path": "target", "sha256": targetSHA],
                "mtp": ["path": "mtp", "sha256": mtpSHA],
                "tokenizer": ["path": "target/tokenizer.json", "sha256": tokenizerSHA],
                "manifest": ["path": "mtp/config.json", "sha256": manifestSHA],
            ],
        ])
    }

    private func releaseEnvelopeData(
        machine: MachineFingerprint,
        targetSHA: String,
        tokenizerSHA: String,
        manifestSHA: String,
        artifactManifestSHA: String,
        challengeBankSHA: String,
        signerKeyID: String,
        affineRepresentation: NativeMTPAffineRepresentation
    ) throws -> Data {
        let entry: [String: Any] = [
            "model_key": Self.modelID,
            "artifact_id": "primary",
            "hash_algorithm": NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm,
            "artifact_hash": targetSHA,
            "artifact_manifest_sha256": artifactManifestSHA,
            "tokenizer_sha256": tokenizerSHA,
            "decode_path": "native_mtp",
            "mtp_manifest_sha256": manifestSHA,
            "mtp_family_adapter": "qwen3_5_mtp_v1",
            "mtp_state_class": "hybrid_stageable_rewindable",
            "mtp_head_count": 1,
            "proposal_depth": 1,
            "complete_window_bytes_by_depth": [1_048_576, 2_097_152],
            "runtime_revision": Self.upstreamRevision,
            "provider_revision": Self.providerRevision,
            "source_commit": Self.providerRevision,
            "reproducible_build_sha256": String(repeating: "1", count: 64),
            "live_executable_cdhash": Self.liveExecutableCDHash,
            "cache_state_classes": ["hybrid_stageable_rewindable"],
            "hardware_class": NativeMTPAdmissionSidecar.canonicalHardwareClass(machine.chip),
            "ram_bytes": machine.ramGB * 1_073_741_824,
            "qualified_slots": 2,
            "max_native_active_rows": 2,
            "request_feature_profile": "native_mtp_greedy_text_v1",
            "max_prompt_tokens": 32768,
            "decrease_threshold_ppm": 1,
            "increase_threshold_ppm": 2,
            "max_verification_positions_per_committed_milli": 1000,
            "throughput_delta_ppm": 0,
            "benchmark_policy_sha256": String(repeating: "2", count: 64),
            "challenge_bank_sha256": challengeBankSHA,
            "fit_evidence_sha256": String(repeating: "3", count: 64),
            "quality_evidence_sha256": String(repeating: "3", count: 64),
            "correctness_evidence_sha256": String(repeating: "3", count: 64),
            "state_rollback_evidence_sha256": String(repeating: "3", count: 64),
            "batch_evidence_sha256": String(repeating: "3", count: 64),
            "performance_evidence_sha256": String(repeating: "3", count: 64),
            "security_negative_evidence_sha256": String(repeating: "3", count: 64),
            "quantization": [
                "kind": "mlx_affine",
                "packed_data_dtype": "uint32",
                "packed_layout": "mlx_array_native_v1",
                "scale_dtype": "bfloat16",
                "scale_layout": "per_block",
                "block_size_elements": affineRepresentation.groupSize,
                "alignment_bytes": NSNull(),
                "padding_rule": "none",
                "unquantized_exceptions": affineRepresentation.unquantizedExceptions,
                "per_layer_exceptions": affineRepresentation.perLayerExceptions,
                "representation_manifest_sha256": affineRepresentation.manifestSHA256,
            ],
            "ordinary_baseline": [
                "decode_path": "ordinary",
                "runtime_revision": Self.upstreamRevision,
                "provider_revision": Self.providerRevision,
                "artifact_hash": targetSHA,
                "qualified_slots": 2,
                "measurement_sha256": String(repeating: "8", count: 64),
                "aggregate_tps_milli": 1,
            ],
        ]
        return try jsonData([
            "schema_version": NativeMTPAdmissionSidecar.schemaVersion,
            "release_id": Self.releaseID,
            "issued_at": iso8601Seconds(Date().addingTimeInterval(-3600)),
            "expires_at": iso8601Seconds(Date().addingTimeInterval(3600)),
            "signer_key_id": signerKeyID,
            "challenge_bank_signer_key_id": signerKeyID,
            "revocation_signer_key_id": signerKeyID,
            "entries": [entry],
        ])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    private func iso8601Seconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func sizingProof(modelSHA: String) -> PagedKVHardwareSizingProof {
        PagedKVHardwareSizingProof(
            modelID: Self.modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-native-mtp-e2e",
            metallibSHA256: String(repeating: "a", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: 512,
            maxResidentTokens: 16_384,
            poolEpoch: 1,
            parityLabel: "native-mtp-hardware-e2e-v1"
        )
    }

    private func observedIdentity(from proof: PagedKVHardwareSizingProof) -> PagedKVObservedRuntimeIdentity {
        PagedKVObservedRuntimeIdentity(
            hardwareClass: proof.hardwareClass,
            metallibSHA256: proof.metallibSHA256,
            kernelIdentifier: proof.kernelIdentifier,
            parityLabel: proof.parityLabel,
            moeDispatchProven: false,
            poolEpoch: proof.poolEpoch,
            source: .runtimeMeasurement
        )
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeMTPHardwareE2EError.missingDirectory(url.path)
        }
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum NativeMTPHardwareE2EError: Error {
    case missingDirectory(String)
    case unsupportedCache(String)
    case unexpectedLoader
}

private final class NativeMTPHardwareAdmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var admissions: [NativeMTPRuntimeAdmission] = []

    func append(_ admission: NativeMTPRuntimeAdmission) {
        lock.lock()
        admissions.append(admission)
        lock.unlock()
    }

    func snapshot() -> [NativeMTPRuntimeAdmission] {
        lock.lock()
        defer { lock.unlock() }
        return admissions
    }
}

private final class NativeMTPHardwareStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [StreamChunk] = []

    func append(_ chunk: StreamChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    func snapshot() -> [StreamChunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}
