import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers

// Lab-only: compiled out of plain release builds, command type and
// registration included, so a production binary carries no lab surface.
#if DEBUG || MACPROVIDER_LAB_HARNESS
let nativeMTPHardwareDefaultModelID = "mlx-community/Qwen3.5-9B-4bit"

/// Hidden Mac Studio lab harness for the real Qwen3.5 native-MTP path.
///
/// This intentionally mirrors `NativeMTPHardwareE2ETests` without XCTest so
/// the designated lab box can run the hardware acceptance even when the host
/// only has CommandLineTools installed. The command and the runtime
/// admission/drafter injection it depends on are compiled out of plain release
/// builds; use a debug build or the explicit lab-harness compile condition.
/// With `MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1`, the target and drafter
/// containers come from the production serve-path admission loader (signed
/// sidecar, captured artifacts, observer, drafter admission) instead of a
/// direct factory load, so a serve-path rejection fails the run.
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

    @Option(name: .customLong("model-id"), help: "Model identifier bound into the lab runtime.")
    var modelID: String = nativeMTPHardwareDefaultModelID

    @Option(name: .customLong("max-batch"), help: "Maximum concurrent scheduler rows. Default 2.")
    var maxBatch: Int = 2

    @Option(name: .customLong("sizing-prompt-tokens"), help: "Prompt-token budget used to size paged-KV blocks. Default 512.")
    var sizingPromptTokens: Int = 512

    @Option(name: .customLong("sizing-output-tokens"), help: "Output-token budget used to size paged-KV blocks. Default 8.")
    var sizingOutputTokens: Int = 8

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8
            ))
            throw ExitCode(2)
        }
        // Unconditional: a pass line from any other host is not lab evidence.
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        let rootPath = root ?? environment["MACPROVIDER_NATIVE_MTP_E2E_ROOT"]
        guard let rootPath, !rootPath.isEmpty else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: --root or MACPROVIDER_NATIVE_MTP_E2E_ROOT is required\n".utf8
            ))
            throw ExitCode(2)
        }
        guard maxBatch >= 1, sizingPromptTokens >= 1, sizingOutputTokens >= 1 else {
            throw ValidationError("--max-batch, --sizing-prompt-tokens, and --sizing-output-tokens must be >=1")
        }
        let maxPhysicalBlocks = NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
            slots: maxBatch,
            promptTokens: sizingPromptTokens,
            outputTokens: sizingOutputTokens
        )
        let report = try await NativeMTPHardwareE2ERunner(
            rootPath: rootPath,
            modelID: modelID,
            maxBatch: maxBatch,
            maxPhysicalBlocks: maxPhysicalBlocks,
            verifyServePath: environment["MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH"] == "1"
        ).run()
        FileHandle.standardOutput.write(Data(report.jsonLine.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct NativeMTPHardwareE2EReport: Sendable {
    let targetSHA256: String
    let mtpSHA256: String
    let admissions: Int
    let maxObservedBatchDepth: Int
    let servePathVerified: Bool
    let jsonLine: String
}

struct NativeMTPHardwareSignedAdmission {
    let capability: NativeMTPAdmissionCapability
    let sidecarData: Data
    let signatureData: Data
    let trustedKeyring: NativeMTPAdmissionSidecar.TrustedKeyring
    let resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority
}

struct NativeMTPHardwareRuntimePair: @unchecked Sendable {
    let ordinary: ModelRuntime
    let native: ModelRuntime
    let targetContainer: ModelContainer
}

struct NativeMTPHardwareRuntimeFixture: @unchecked Sendable {
    let targetIdentity: MLXSnapshotIdentity
    let mtpIdentity: MLXSnapshotIdentity
    let tokenizerSHA256: String
    let manifestSHA256: String
    let machine: MachineFingerprint
    let admission: NativeMTPAdmissionCapability
    let runtimes: NativeMTPHardwareRuntimePair
    let ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?
    let nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?
}

final class NativeMTPHardwareE2ERunner {
    static let defaultModelID = nativeMTPHardwareDefaultModelID
    static let upstreamRevision = "9c1cd900287de58ec6577ec0da7aa3ee61781200"
    private static let providerRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let liveExecutableCDHash = "456789abcdef0123456789abcdef0123456789ab"
    private static let reproducibleBuildSHA256 = String(repeating: "1", count: 64)
    private static let releaseID = "native-mtp-hardware-e2e"

    private let root: URL
    private let modelID: String
    private let maxBatch: Int
    private let maxNativeActiveRows: Int
    private let maxPromptTokens: Int
    private let maxPhysicalBlocks: Int
    private let verifyServePath: Bool

    static func sizedMaxPhysicalBlocks(slots: Int, promptTokens: Int, outputTokens: Int) -> Int {
        let boundedSlots = max(1, slots)
        let boundedPrompt = max(1, promptTokens)
        let boundedOutput = max(1, outputTokens)
        let tokens = boundedSlots * (boundedPrompt + boundedOutput + 64)
        let blocks = (tokens + 31) / 32
        return max(512, Int(ceil(Double(blocks) * 1.25)))
    }

    init(
        rootPath: String,
        modelID: String = NativeMTPHardwareE2ERunner.defaultModelID,
        maxBatch: Int = 2,
        maxNativeActiveRows: Int? = nil,
        maxPromptTokens: Int = 1_048_576,
        maxPhysicalBlocks: Int = 512,
        verifyServePath: Bool = false
    ) {
        root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        self.modelID = modelID
        self.maxBatch = maxBatch
        self.maxNativeActiveRows = maxNativeActiveRows ?? maxBatch
        self.maxPromptTokens = maxPromptTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.verifyServePath = verifyServePath
    }

    static func requireStudioHost() throws {
        let model = shellOutput("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = shellOutput("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = MachineFingerprinter().sample()
        guard arch == "arm64",
              model.hasPrefix("Mac15,"),
              machine.chip.caseInsensitiveCompare("Apple M3 Ultra") == .orderedSame else {
            throw NativeMTPHardwareE2EError.hostRejected(
                "expected Mac Studio M3 Ultra host, got model=\(model) arch=\(arch) chip=\(machine.chip)"
            )
        }
    }

    func run() async throws -> NativeMTPHardwareE2EReport {
        let admissionRecorder = NativeMTPHardwareAdmissionRecorder()
        let fixture = try await loadRuntimeFixture(
            maxContextTokens: 4096,
            ordinaryAdmissionRecorder: nil,
            nativeAdmissionRecorder: admissionRecorder
        )
        let targetIdentity = fixture.targetIdentity
        let mtpIdentity = fixture.mtpIdentity
        let runtimes = fixture.runtimes
        let ordinaryRuntime = runtimes.ordinary
        let nativeRuntime = runtimes.native

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
        // Parity only means something if ordinary batched decode reproduces itself.
        let ordinaryRepeat = try await completeConcurrently(requests, with: ordinaryRuntime)
        for id in ordinary.keys.sorted() {
            try require(
                ordinaryRepeat[id]?.content == ordinary[id]?.content,
                "ordinary decode not reproducible for \(id): first=\(String(reflecting: ordinary[id]?.content)) repeat=\(String(reflecting: ordinaryRepeat[id]?.content))"
            )
        }
        let native = try await completeConcurrently(requests, with: nativeRuntime)
        try require(native.keys.sorted() == ordinary.keys.sorted(), "ordinary/native key mismatch")
        for id in ordinary.keys.sorted() {
            guard let expected = ordinary[id], let actual = native[id] else {
                throw NativeMTPHardwareE2EError.assertionFailed("missing result for \(id)")
            }
            try require(
                actual.content == expected.content,
                "content mismatch for \(id): ordinary=\(String(reflecting: expected.content)) native=\(String(reflecting: actual.content))"
            )
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
        {"schema":"macprovider.native-mtp-hardware-e2e-result.v1","status":"pass","evidence_class":"correctness_only","model_id":"\(modelID)","target_sha256":"\(targetIdentity.digest)","mtp_sha256":"\(mtpIdentity.digest)","admissions":\(totalAdmissions),"max_observed_batch_depth":\(maxDepth),"serve_path_verified":\(verifyServePath)}
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

    func loadRuntimeFixture(
        maxContextTokens: Int,
        ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?,
        nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) async throws -> NativeMTPHardwareRuntimeFixture {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)

        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: root.appendingPathComponent("mtp/config.json"))
        let machine = MachineFingerprinter().sample()
        let signedAdmission = try makeAndValidateAdmission(
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            machine: machine
        )
        let admission = signedAdmission.capability
        try require(admission.targetArtifactSHA256 == targetIdentity.digest, "target digest admission mismatch")
        try require(admission.mtpArtifactSHA256 == mtpIdentity.digest, "MTP digest admission mismatch")
        try require(admission.maxProposalDepth == 1, "unexpected proposal depth")
        try require(admission.selfTestChallengeBank.challengeBankPath == "native-mtp-selftest-bank.json", "bad self-test bank")
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
            throughputDeltaPPM: admission.throughputDeltaPPM,
            maximumNativeActiveRows: admission.maxNativeActiveRows,
            supportsSampling: admission.supportsSampling
        )
        let servePathLoad: ModelRuntime.NativeMTPHardwareE2EServePathLoad?
        if verifyServePath {
            servePathLoad = try await loadServePath(
                signedAdmission: signedAdmission,
                targetIdentity: targetIdentity,
                maxContextTokens: maxContextTokens
            )
        } else {
            servePathLoad = nil
        }
        let runtimes = try await loadRuntimePair(
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            nativeCapability: capability,
            nativeAdmissionCapability: admission,
            servePathLoad: servePathLoad,
            maxContextTokens: maxContextTokens,
            ordinaryAdmissionRecorder: ordinaryAdmissionRecorder,
            nativeAdmissionRecorder: nativeAdmissionRecorder
        )
        return NativeMTPHardwareRuntimeFixture(
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            tokenizerSHA256: tokenizerSHA,
            manifestSHA256: manifestSHA,
            machine: machine,
            admission: admission,
            runtimes: runtimes,
            ordinaryAdmissionRecorder: ordinaryAdmissionRecorder,
            nativeAdmissionRecorder: nativeAdmissionRecorder
        )
    }

    /// Runs the production serve-path admission loader over the same signed
    /// sidecar the lab admission validated. Any rejection is logged by the
    /// loader as one structured reason-coded line and fails the run here.
    private func loadServePath(
        signedAdmission: NativeMTPHardwareSignedAdmission,
        targetIdentity: MLXSnapshotIdentity,
        maxContextTokens: Int
    ) async throws -> ModelRuntime.NativeMTPHardwareE2EServePathLoad {
        let sidecarURL = root.appendingPathComponent("native-mtp-admission.json")
        let signatureURL = root.appendingPathComponent("native-mtp-admission.json.sig")
        try signedAdmission.sidecarData.write(to: sidecarURL, options: [.atomic])
        try signedAdmission.signatureData.write(to: signatureURL, options: [.atomic])
        let load = await ModelRuntime.nativeMTPServePathLoadForHardwareE2E(
            targetModelID: modelID,
            targetModelRevision: targetIdentity.digest,
            targetDirectory: root.appendingPathComponent("target", isDirectory: true),
            maxContextTokens: maxContextTokens,
            slotCount: maxBatch,
            sidecarURL: sidecarURL,
            signatureURL: signatureURL,
            trustedKeyring: signedAdmission.trustedKeyring,
            runningBuildIdentity: ModelRuntime.NativeMTPRunningBuildIdentity(
                sourceCommit: Self.providerRevision,
                reproducibleBuildSHA256: Self.reproducibleBuildSHA256,
                liveExecutableCDHash: Self.liveExecutableCDHash,
                upstreamMLXSwiftLMRevision: Self.upstreamRevision
            ),
            resolvedArtifactAuthority: signedAdmission.resolvedArtifactAuthority
        )
        guard let load else {
            throw NativeMTPHardwareE2EError.assertionFailed("serve-path native-MTP admission rejected")
        }
        return load
    }

    func loadRuntimePair(
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        nativeCapability: NativeMTPCapability,
        nativeAdmissionCapability: NativeMTPAdmissionCapability,
        servePathLoad: ModelRuntime.NativeMTPHardwareE2EServePathLoad? = nil,
        maxContextTokens: Int,
        ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?,
        nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) async throws -> NativeMTPHardwareRuntimePair {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)
        let observedTargetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let observedMTPIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        try require(observedTargetIdentity == targetIdentity, "target identity changed during load")
        try require(observedMTPIdentity == mtpIdentity, "MTP identity changed during load")
        // Run the same artifact observer the production enable path runs
        // (ModelRuntime native-MTP load) so lab evidence cannot pass on artifacts
        // that production would reject.
        let artifactObservation = try NativeMTPArtifactObserver.observePair(
            targetDirectory: targetDirectory,
            mtpDirectory: mtpDirectory
        )
        try require(
            ModelRuntime.nativeMTPArtifactObservationMatchesAdmissionForTest(
                artifactObservation,
                admissionCapability: nativeAdmissionCapability
            ),
            "artifact observation does not match admission"
        )

        let configData = try Data(contentsOf: targetDirectory.appendingPathComponent("config.json"))
        let modelCapabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: modelID,
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
                guard let kind = PagedKVSharedForwardBackend.CacheKind.recognized(from: cache) else {
                    throw NativeMTPHardwareE2EError.unsupportedCache(String(describing: type(of: cache)))
                }
                return kind
            }
        }
        try require(cacheKinds.contains(.pagedAttention), "paged-attention cache not observed")
        try require(cacheKinds.contains(.recurrentMamba), "recurrent Mamba cache not observed")

        let pagedConfig = PagedKVConfig(
            enabled: true,
            blockSizeTokens: 32,
            maxPhysicalBlocks: maxPhysicalBlocks
        )
        // Attach from the same live parity + batched-isolation (MoE dispatch)
        // probes production runs at load; a synthesized identity cannot prove
        // MoE dispatch and would hide real attach failures.
        let placeholderProof = sizingProof(modelSHA: targetIdentity.digest, maxContextTokens: maxContextTokens)
        let probeRuntime = makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: placeholderProof,
            observed: observedIdentity(from: placeholderProof),
            modelCapabilities: modelCapabilities,
            targetContainer: targetContainer,
            backend: PagedKVSharedForwardBackend(
                container: targetContainer,
                blockSizeTokens: 32,
                maxPhysicalBlocks: maxPhysicalBlocks,
                poolEpoch: 1,
                layerCount: cacheKinds.count,
                cacheKinds: cacheKinds
            ),
            nativeCapability: nil,
            nativeAdmissionCapability: nil,
            drafterContainer: nil,
            admissionRecorder: nil
        )
        guard let measurement = await probeRuntime.labMeasurePagedKVRuntime(
            container: targetContainer,
            modelID: modelID,
            modelCapabilities: modelCapabilities,
            runtimeCacheClass: "mixed"
        ) else {
            throw NativeMTPHardwareE2EError.assertionFailed("live paged-KV parity/isolation probes did not establish attach evidence")
        }
        let proof = measurement.hardwareSizingProof
        let observed = measurement.observedRuntimeIdentity
        let ordinaryBackend = PagedKVSharedForwardBackend(
            container: targetContainer,
            blockSizeTokens: 32,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: cacheKinds.count,
            cacheKinds: cacheKinds
        )
        let nativeBackend = PagedKVSharedForwardBackend(
            container: targetContainer,
            blockSizeTokens: 32,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: cacheKinds.count,
            cacheKinds: cacheKinds,
            drafterContainer: drafterContainer
        )
        let ordinary = makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            targetContainer: targetContainer,
            backend: ordinaryBackend,
            nativeCapability: nil,
            nativeAdmissionCapability: nil,
            drafterContainer: nil,
            admissionRecorder: ordinaryAdmissionRecorder
        )
        let native = makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            targetContainer: targetContainer,
            backend: nativeBackend,
            nativeCapability: nativeCapability,
            nativeAdmissionCapability: nativeAdmissionCapability,
            drafterContainer: drafterContainer,
            admissionRecorder: nativeAdmissionRecorder
        )
        return NativeMTPHardwareRuntimePair(
            ordinary: ordinary,
            native: native,
            targetContainer: targetContainer
        )
    }

    private func makeRuntime(
        modelSHA: String,
        maxContextTokens: Int,
        pagedConfig: PagedKVConfig,
        proof: PagedKVHardwareSizingProof,
        observed: PagedKVObservedRuntimeIdentity,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        targetContainer: ModelContainer,
        backend: PagedKVSharedForwardBackend,
        nativeCapability: NativeMTPCapability?,
        nativeAdmissionCapability: NativeMTPAdmissionCapability?,
        drafterContainer: MTPDrafterContainer?,
        admissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            maxContextTokensOverride: maxContextTokens,
            pagedKVConfig: pagedConfig,
            prefillStepSize: 512,
            maxBatch: maxBatch,
            continuousBatchingMode: .on,
            continuousBatchingDurableReplayAuthorityAvailable: true,
            nativeMTPMode: nativeCapability == nil ? .off : .auto,
            nativeMTPCapability: nativeCapability,
            nativeMTPSchedulerSupported: drafterContainer != nil,
            nativeMTPDrafterContainer: drafterContainer,
            labNativeMTPAdmissionCapability: nativeAdmissionCapability,
            testNativeMTPAdmissionObserver: { admission in
                admissionRecorder?.append(admission)
            },
            testNativeMTPAdmissionRequestObserver: { requestID, admission, otherActiveRows in
                admissionRecorder?.append(requestID: requestID, admission: admission, otherActiveRows: otherActiveRows)
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
            "model": modelID,
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
    ) throws -> NativeMTPHardwareSignedAdmission {
        let artifactObservation = try NativeMTPArtifactObserver.observePair(
            targetDirectory: root.appendingPathComponent("target", isDirectory: true),
            mtpDirectory: root.appendingPathComponent("mtp", isDirectory: true)
        )
        let affineRepresentation = try NativeMTPArtifactObserver.affineRepresentation(for: artifactObservation)
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: root.appendingPathComponent("mtp/config.json"))
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-hardware-e2e"
        let selfTestBankData = try selfTestChallengeBankData(
            targetSHA: targetIdentity.digest,
            mtpSHA: mtpIdentity.digest,
            tokenizerSHA: tokenizerSHA,
            manifestSHA: manifestSHA,
            signerKeyID: keyID
        )
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
            modelKey: modelID,
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
        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: sidecarData,
            signatureData: signatureData,
            snapshotRoot: root,
            context: NativeMTPAdmissionSidecar.RuntimeContext(
                modelID: modelID,
                modelRevision: targetIdentity.digest,
                providerRevision: Self.providerRevision,
                upstreamMLXSwiftLMRevision: Self.upstreamRevision,
                hardwareChip: machine.chip,
                ramGB: machine.ramGB,
                osVersion: machine.osVersion,
                slotCount: maxBatch,
                revokedTupleSHA256: []
            ),
            trustedKeyring: trustedKeyring,
            resolvedArtifactAuthority: authority
        )
        return NativeMTPHardwareSignedAdmission(
            capability: capability,
            sidecarData: sidecarData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring,
            resolvedArtifactAuthority: authority
        )
    }

    /// A schema-valid, release-bound challenge bank with exactly one entry for
    /// this fixture's tuple, as the production serve-path loader requires
    /// (SPEC-048 §4 `native_mtp_selftest_v1`). This e2e does not execute the
    /// self-test, so the expected-output fields are declared placeholders; the
    /// identity fields are the real fixture digests the loader matches on.
    func selfTestChallengeBankData(
        targetSHA: String,
        mtpSHA: String,
        tokenizerSHA: String,
        manifestSHA: String,
        signerKeyID: String
    ) throws -> Data {
        let expectedTokenIDs: [Int] = []
        return try jsonData([
            "schema_version": NativeMTPSelfTestChallenge.bankSchemaVersion,
            "release_id": Self.releaseID,
            "issued_at": iso8601Seconds(Date().addingTimeInterval(-3600)),
            "expires_at": iso8601Seconds(Date().addingTimeInterval(3600)),
            "signer_key_id": signerKeyID,
            "entries": [[
                "challenge_id": "native-mtp-hardware-e2e-0001",
                "model_id": modelID,
                "model_hash": targetSHA,
                "tokenizer_sha256": tokenizerSHA,
                "artifact_sha256": mtpSHA,
                "mtp_manifest_sha256": manifestSHA,
                "prompt_token_ids": [1, 2, 3],
                "max_completion_tokens": 8,
                "fixed_proposal_depth": 1,
                "expected_token_ids": expectedTokenIDs,
                "expected_token_id_sha256": NativeMTPSelfTest.tokenDigest(expectedTokenIDs),
                "expected_terminal_reason": "length",
                "expected_counters": ["accepted": 0, "rejected": 0, "bonus": 0, "committed": 0],
                "expected_committed_state_sha256": String(repeating: "4", count: 64),
            ]],
        ])
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
            "model_key": modelID,
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
            "reproducible_build_sha256": Self.reproducibleBuildSHA256,
            "live_executable_cdhash": Self.liveExecutableCDHash,
            "cache_state_classes": ["hybrid_stageable_rewindable"],
            "hardware_class": NativeMTPAdmissionSidecar.canonicalHardwareClass(machine.chip),
            "ram_bytes": machine.ramGB * 1_073_741_824,
            "qualified_slots": maxBatch,
            "max_native_active_rows": maxNativeActiveRows,
            // The lab tuple qualifies sampled rows too (target-sample exact
            // match), so temperature cells measure the native path.
            "request_feature_profile": NativeMTPAdmissionSidecar.sampledRequestFeatureProfile,
            "max_prompt_tokens": maxPromptTokens,
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
                "qualified_slots": maxBatch,
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

    private func sizingProof(modelSHA: String, maxContextTokens: Int) -> PagedKVHardwareSizingProof {
        PagedKVHardwareSizingProof(
            modelID: modelID,
            modelSHA256: modelSHA,
            tokenizerSHA256: nil,
            chatTemplateSHA256: nil,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-native-mtp-e2e",
            metallibSHA256: String(repeating: "a", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: 32,
            maxPhysicalBlocks: maxPhysicalBlocks,
            maxResidentTokens: max(maxPhysicalBlocks * 32, maxContextTokens * maxBatch),
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

enum NativeMTPHardwareE2EError: Error, CustomStringConvertible {
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

final class NativeMTPHardwareAdmissionRecorder: @unchecked Sendable {
    struct RequestAdmission: Sendable {
        let requestID: String?
        let admission: NativeMTPRuntimeAdmission
        /// Other in-flight requests the runtime counted against the R007
        /// bound when it admitted this one.
        let otherActiveRows: Int
    }

    private let lock = NSLock()
    private var admissions: [NativeMTPRuntimeAdmission] = []
    private var requestAdmissions: [RequestAdmission] = []

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

    func append(requestID: String?, admission: NativeMTPRuntimeAdmission, otherActiveRows: Int) {
        lock.lock()
        requestAdmissions.append(RequestAdmission(
            requestID: requestID,
            admission: admission,
            otherActiveRows: otherActiveRows
        ))
        lock.unlock()
    }

    func requestSnapshot() -> [RequestAdmission] {
        lock.lock()
        defer { lock.unlock() }
        return requestAdmissions
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
