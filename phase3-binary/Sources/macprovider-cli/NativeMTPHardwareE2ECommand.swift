import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers

/// Hidden Mac Studio lab harness for the real Qwen3.5 native-MTP path.
///
/// This intentionally mirrors `NativeMTPHardwareE2ETests` without XCTest so
/// the designated lab box can run the hardware acceptance even when the host
/// only has CommandLineTools installed. The runtime admission/drafter injection
/// it depends on is compiled out of release builds by `ModelRuntime`; use the
/// debug product for this command and keep release builds for production
/// compile proof. With `MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1`, the workload
/// runs on the target and drafter containers returned by the real serve loader.
struct NativeMTPHardwareE2ECommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-hardware-e2e",
        abstract: "Run the hidden real-model native MTP hardware e2e harness.",
        shouldDisplay: false
    )

    @Option(
        name: .customLong("root"),
        help: "Fixture root containing plain target/ and mtp/ snapshot directories."
    )
    var root: String?

    @Flag(
        name: .customLong("allow-non-studio"),
        help: "Debug escape hatch for development only; lab acceptance must not set this."
    )
    var allowNonStudio: Bool = false

    func run() async throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8
            ))
            throw ExitCode(2)
        }
        if !allowNonStudio {
            try NativeMTPHardwareE2ERunner.requireStudioHost()
        }
        let rootPath = root ?? environment["MACPROVIDER_NATIVE_MTP_E2E_ROOT"]
        guard let rootPath, !rootPath.isEmpty else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: --root or MACPROVIDER_NATIVE_MTP_E2E_ROOT is required\n".utf8
            ))
            throw ExitCode(2)
        }
        let report = try await NativeMTPHardwareE2ERunner(
            rootPath: rootPath,
            verifyServePath: environment["MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH"] == "1"
        ).run()
        FileHandle.standardOutput.write(Data(report.jsonLine.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        #else
        FileHandle.standardError.write(Data(
            "native-mtp-hardware-e2e: unavailable in release builds; build debug product for the lab harness\n".utf8
        ))
        throw ExitCode(2)
        #endif
    }
}

#if DEBUG
private struct NativeMTPHardwareE2EReport: Sendable {
    let targetSHA256: String
    let mtpSHA256: String
    let admissions: Int
    let maxObservedBatchDepth: Int
    let servePathVerified: Bool
    let jsonLine: String
}

private struct NativeMTPHardwareAdmissionFixture {
    let capability: NativeMTPAdmissionCapability
    let sidecarURL: URL
    let signatureURL: URL
    let trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
    let runningBuildIdentity: ModelRuntime.NativeMTPRunningBuildIdentity
    let resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority
}

private final class NativeMTPHardwareE2ERunner {
    private static let modelID = "mlx-community/Qwen3.5-9B-4bit"
    private static let upstreamRevision = "e874140ecb5b04aeb445eb3837d48f7b187b867e"
    private static let providerRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let liveExecutableCDHash = "456789abcdef0123456789abcdef0123456789ab"
    private static let releaseID = "native-mtp-hardware-e2e"

    private let root: URL
    private let verifyServePath: Bool

    init(rootPath: String, verifyServePath: Bool) {
        root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        self.verifyServePath = verifyServePath
    }

    static func requireStudioHost() throws {
        let model = shellOutput("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = shellOutput("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard arch == "arm64", model.hasPrefix("Mac15,") || model.hasPrefix("Mac14,") else {
            throw NativeMTPHardwareE2EError.hostRejected("expected Mac Studio-class arm64 host, got model=\(model) arch=\(arch)")
        }
    }

    func run() async throws -> NativeMTPHardwareE2EReport {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)

        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let machine = MachineFingerprinter().sample()
        let admissionFixture = try makeAndValidateAdmission(
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            machine: machine
        )
        let admission = admissionFixture.capability
        try require(admission.targetArtifactSHA256 == targetIdentity.digest, "target digest admission mismatch")
        try require(admission.mtpArtifactSHA256 == mtpIdentity.digest, "MTP digest admission mismatch")
        try require(admission.maxProposalDepth == 1, "unexpected proposal depth")
        try require(admission.selfTestChallengeBank.challengeBankPath == "native-mtp-selftest-bank.json", "bad self-test bank")

        let servePathLoad: ModelRuntime.NativeMTPHardwareE2ELoad?
        if verifyServePath {
            servePathLoad = await ModelRuntime.nativeMTPServePathLoadForHardwareE2E(
                targetModelID: Self.modelID,
                targetModelRevision: targetIdentity.digest,
                targetDirectory: targetDirectory,
                slotCount: 2,
                sidecarURL: admissionFixture.sidecarURL,
                signatureURL: admissionFixture.signatureURL,
                trustedKeyring: admissionFixture.trustedKeyring,
                runningBuildIdentity: admissionFixture.runningBuildIdentity,
                resolvedArtifactAuthority: admissionFixture.resolvedArtifactAuthority
            )
            try require(servePathLoad != nil, "serve-path native-MTP admission rejected")
        } else {
            servePathLoad = nil
        }

        let configData = try Data(contentsOf: targetDirectory.appendingPathComponent("config.json"))
        let modelCapabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: Self.modelID,
            configJSONData: configData
        )
        try require(modelCapabilities.modelFamily == "qwen", "expected qwen model family")
        try require(modelCapabilities.hybridDecoderArchitectureVerified, "hybrid decoder not verified")
        try require(
            ModelRuntime.nativeMTPAdmissionCacheClass(
                runtimeCacheClass: "mixed",
                modelCapabilities: modelCapabilities
            ) == "paged_kv",
            "admission cache class mismatch"
        )

        let targetContainer: ModelContainer
        let drafterContainer: MTPDrafterContainer
        if let servePathLoad {
            targetContainer = servePathLoad.targetContainer
            drafterContainer = servePathLoad.drafterContainer
        } else {
            await Qwen35TextMTPRegistration.register()
            targetContainer = try await LLMModelFactory.shared.loadContainer(
                from: targetDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            drafterContainer = try await MTPDrafterModelFactory.shared.loadContainer(
                from: mtpDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        }
        let maximumBlockSize = await drafterContainer.perform { context in
            context.model.maximumBlockSize
        }
        try require(maximumBlockSize == 2, "unexpected MTP maximum block size \(String(describing: maximumBlockSize))")

        let cacheKinds = try await targetContainer.perform { context in
            try context.model.newCache(parameters: nil as GenerateParameters?).map { cache in
                if cache is KVCacheSimple { return PagedKVSharedForwardBackend.CacheKind.pagedAttention }
                if cache is MambaCache { return PagedKVSharedForwardBackend.CacheKind.recurrentMamba }
                throw NativeMTPHardwareE2EError.unsupportedCache(String(describing: type(of: cache)))
            }
        }
        try require(cacheKinds.contains(.pagedAttention), "paged-attention cache not observed")
        try require(cacheKinds.contains(.recurrentMamba), "recurrent Mamba cache not observed")

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
        try require(native.keys.sorted() == ordinary.keys.sorted(), "ordinary/native key mismatch")
        for id in ordinary.keys.sorted() {
            guard let expected = ordinary[id], let actual = native[id] else {
                throw NativeMTPHardwareE2EError.assertionFailed("missing result for \(id)")
            }
            try require(actual.content == expected.content, "content mismatch for \(id)")
            try require(actual.finishReason == expected.finishReason, "finish reason mismatch for \(id)")
            try require(actual.promptTokens == expected.promptTokens, "prompt token mismatch for \(id)")
            try require(actual.completionTokens == expected.completionTokens, "completion token mismatch for \(id)")
            try require(
                actual.generatedCompletionTokens == expected.generatedCompletionTokens,
                "generated token mismatch for \(id)"
            )
        }
        let recordedAdmissions = admissionRecorder.snapshot()
        try require(recordedAdmissions.count == requests.count, "unexpected admission count \(recordedAdmissions.count)")
        try require(recordedAdmissions.allSatisfy { $0.effectivePath == .nativeMTP }, "non-native admission observed")

        let streamingStopRequest = try makeRequest(
            id: "native-mtp-real-stream-stop",
            prompt: "Answer with a terse sentence ending in STOP.",
            stream: true,
            stop: ["STOP"]
        )
        let handle = try await nativeRuntime.acquireRequestHandle(streamingStopRequest)
        defer { Task { await nativeRuntime.unregisterInFlight(handle.registrationID) } }
        let streamRecorder = NativeMTPHardwareStreamRecorder()
        let admissionsBeforeStreaming = admissionRecorder.snapshot().count
        _ = try await nativeRuntime.stream(streamingStopRequest, with: handle) { chunk in
            streamRecorder.append(chunk)
        }
        try require(!streamRecorder.snapshot().isEmpty, "stream produced no chunks")
        let admissionsAfterStreaming = admissionRecorder.snapshot()
        try require(
            admissionsAfterStreaming.count == admissionsBeforeStreaming + 1,
            "stream admission was not recorded"
        )
        try require(admissionsAfterStreaming.last?.effectivePath == .nativeMTP, "stream did not use native MTP")

        let snapshot = await nativeRuntime.currentSnapshot()
        try require(snapshot.continuousBatching?.pagedKVDecision == "attached", "paged KV not attached")
        let maxDepth = snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth ?? 0
        try require(maxDepth >= 2, "batch depth below 2: \(maxDepth)")
        let totalAdmissions = admissionRecorder.snapshot().count
        let json = """
        {"schema":"macprovider.native-mtp-hardware-e2e-result.v1","status":"pass","model_id":"\(Self.modelID)","target_sha256":"\(targetIdentity.digest)","mtp_sha256":"\(mtpIdentity.digest)","admissions":\(totalAdmissions),"max_observed_batch_depth":\(maxDepth),"serve_path_verified":\(verifyServePath)}
        """
        return NativeMTPHardwareE2EReport(
            targetSHA256: targetIdentity.digest,
            mtpSHA256: mtpIdentity.digest,
            admissions: totalAdmissions,
            maxObservedBatchDepth: maxDepth,
            servePathVerified: verifyServePath,
            jsonLine: json
        )
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
                guard let requestID = request.requestID else {
                    throw NativeMTPHardwareE2EError.assertionFailed("missing request id")
                }
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
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        machine: MachineFingerprint
    ) throws -> NativeMTPHardwareAdmissionFixture {
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: root.appendingPathComponent("mtp/config.json"))
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-hardware-e2e"
        let selfTestBankData = try jsonData([
            "schema_version": NativeMTPSelfTestChallenge.bankSchemaVersion,
            "release_id": Self.releaseID,
            "issued_at": iso8601Seconds(Date().addingTimeInterval(-3600)),
            "expires_at": iso8601Seconds(Date().addingTimeInterval(3600)),
            "signer_key_id": keyID,
            "entries": [[
                "challenge_id": "native-mtp-hardware-e2e-serve-path",
                "model_id": Self.modelID,
                "model_hash": targetIdentity.digest,
                "tokenizer_sha256": tokenizerSHA,
                "artifact_sha256": mtpIdentity.digest,
                "mtp_manifest_sha256": manifestSHA,
                "prompt_token_ids": [1],
                "max_completion_tokens": 1,
                "fixed_proposal_depth": 1,
                "expected_token_ids": [],
                "expected_token_id_sha256": sha256Hex(Data("[]".utf8)),
                "expected_terminal_reason": "completed",
                "expected_counters": [
                    "accepted": 0,
                    "rejected": 0,
                    "bonus": 0,
                    "committed": 0,
                ],
                "expected_committed_state_sha256": String(repeating: "0", count: 64),
            ]],
        ])
        try selfTestBankData.write(to: root.appendingPathComponent("native-mtp-selftest-bank.json"), options: [.atomic])
        let selfTestSignature = try signer.signature(for: selfTestBankData).base64EncodedString()
        let selfTestSignatureData = Data("""
        {"alg":"ed25519","key_id":"\(keyID)","signature":"\(selfTestSignature)"}

        """.utf8)
        try selfTestSignatureData.write(
            to: root.appendingPathComponent("native-mtp-selftest-bank.json.sig"),
            options: [.atomic]
        )

        let projectionData = try artifactProjectionData(
            targetSHA: targetIdentity.digest,
            mtpSHA: mtpIdentity.digest,
            tokenizerSHA: tokenizerSHA,
            manifestSHA: manifestSHA
        )
        try projectionData.write(
            to: root.appendingPathComponent("native-mtp-artifact-manifest.json"),
            options: [.atomic]
        )
        let sidecarData = try legacyAdmissionSidecarData(
            machine: machine,
            targetSHA: targetIdentity.digest,
            mtpSHA: mtpIdentity.digest,
            tokenizerSHA: tokenizerSHA,
            manifestSHA: manifestSHA,
            challengeBankSHA: sha256Hex(selfTestBankData),
            challengeBankSignatureSHA: sha256Hex(selfTestSignatureData),
            signerKeyID: keyID
        )
        let signature = try signer.signature(for: sidecarData).base64EncodedString()
        let signatureData = Data("""
        {"alg":"ed25519","key_id":"\(keyID)","signature":"\(signature)"}

        """.utf8)
        let sidecarURL = root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = root.appendingPathComponent("native-mtp-admission.json.sig")
        try sidecarData.write(to: sidecarURL, options: [.atomic])
        try signatureData.write(to: signatureURL, options: [.atomic])
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
        let trustedKeyring = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: [keyID: signer.publicKey.rawRepresentation.base64EncodedString()],
            requiredKeyID: keyID
        )
        let capability = try NativeMTPAdmissionSidecar.loadLegacyObjectForTesting(
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
            trustedKeyring: trustedKeyring,
            captureArtifacts: false
        )
        return NativeMTPHardwareAdmissionFixture(
            capability: capability,
            sidecarURL: sidecarURL,
            signatureURL: signatureURL,
            trustedKeyring: trustedKeyring,
            runningBuildIdentity: ModelRuntime.NativeMTPRunningBuildIdentity(
                sourceCommit: Self.providerRevision,
                reproducibleBuildSHA256: String(repeating: "1", count: 64),
                liveExecutableCDHash: Self.liveExecutableCDHash,
                upstreamMLXSwiftLMRevision: Self.upstreamRevision
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

    private func legacyAdmissionSidecarData(
        machine: MachineFingerprint,
        targetSHA: String,
        mtpSHA: String,
        tokenizerSHA: String,
        manifestSHA: String,
        challengeBankSHA: String,
        challengeBankSignatureSHA: String,
        signerKeyID: String
    ) throws -> Data {
        func object(tupleSHA: String) -> [String: Any] {
            [
                "schema_version": NativeMTPAdmissionSidecar.schemaVersion,
                "tuple_sha256": tupleSHA,
                "decode_path": "native_mtp",
                "admission_enabled": true,
                "model": [
                    "id": Self.modelID,
                    "revision": targetSHA,
                    "family_adapter": "qwen3_5_mtp_v1",
                ],
                "artifacts": [
                    "target": ["path": "target", "sha256": targetSHA],
                    "mtp": ["path": "mtp", "sha256": mtpSHA],
                    "tokenizer": ["path": "target/tokenizer.json", "sha256": tokenizerSHA],
                    "manifest": ["path": "mtp/config.json", "sha256": manifestSHA],
                ],
                "mtp": [
                    "manifest_sha256": manifestSHA,
                    "source_layout": "separate_artifact",
                    "prediction_layer_count": 1,
                    "max_proposal_depth": 1,
                    "complete_window_bytes_by_depth": [1_048_576, 2_097_152],
                    "throughput_delta_ppm": 0,
                    "adaptation_enabled": true,
                    "adaptation_max_depth": 1,
                ],
                "quantization": [
                    "target": "mlx_affine_4bit",
                    "mtp": "mlx_affine_4bit",
                ],
                "cache_state": [
                    "cache_class": "paged_kv",
                    "state_class": "hybrid_stageable_rewindable",
                ],
                "revisions": [
                    "provider": Self.providerRevision,
                    "upstream_mlx_swift_lm": Self.upstreamRevision,
                ],
                "hardware": [
                    "chip": NativeMTPAdmissionSidecar.canonicalHardwareClass(machine.chip),
                    "ram_gb": machine.ramGB,
                    "qualified_slots": 2,
                    "max_slots": 2,
                    "os_version": machine.osVersion,
                ],
                "request_profile": [
                    "text_only": true,
                    "streaming": true,
                    "tools": false,
                    "structured_outputs": false,
                    "logprobs": false,
                    "penalties": false,
                    "conversation_cache": false,
                    "disk_cache": false,
                    "max_prompt_tokens": 4096,
                    "max_completion_tokens": 8,
                ],
                "spec023": [
                    "release_id": Self.releaseID,
                    "source_commit": Self.providerRevision,
                    "reproducible_build_sha256": String(repeating: "1", count: 64),
                    "live_executable_cdhash": Self.liveExecutableCDHash,
                    "benchmark_policy_sha256": String(repeating: "2", count: 64),
                    "native_mtp_admission_tuple_sha256": tupleSHA,
                    "evidence_artifact_sha256": Array(repeating: String(repeating: "3", count: 64), count: 7),
                ],
                "selftest": [
                    "release_id": Self.releaseID,
                    "challenge_bank_path": "native-mtp-selftest-bank.json",
                    "challenge_bank_sha256": challengeBankSHA,
                    "signature_path": "native-mtp-selftest-bank.json.sig",
                    "signer_key_id": signerKeyID,
                    "signature_sha256": challengeBankSignatureSHA,
                ],
                "flags": [
                    "admission_allowed": true,
                ],
            ]
        }
        let placeholder = object(tupleSHA: String(repeating: "1", count: 64))
        let tupleSHA = try NativeMTPAdmissionSidecar.admissionTupleSHA256ForTesting(placeholder)
        return try jsonData(object(tupleSHA: tupleSHA))
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

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NativeMTPHardwareE2EError.assertionFailed(message)
        }
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

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func shellOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

private enum NativeMTPHardwareE2EError: Error, CustomStringConvertible {
    case missingDirectory(String)
    case unsupportedCache(String)
    case unexpectedLoader
    case assertionFailed(String)
    case hostRejected(String)

    var description: String {
        switch self {
        case .missingDirectory(let path):
            return "missing directory: \(path)"
        case .unsupportedCache(let cache):
            return "unsupported cache: \(cache)"
        case .unexpectedLoader:
            return "unexpected model loader call"
        case .assertionFailed(let message):
            return "assertion failed: \(message)"
        case .hostRejected(let message):
            return "host rejected: \(message)"
        }
    }
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
#endif
