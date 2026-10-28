import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers

// Measurement helpers are shared with isolated signed qualification.
// Legacy top-level command registration remains LAB-only.
let nativeMTPHardwareDefaultModelID = "mlx-community/Qwen3.5-9B-4bit"

/// The native-MTP family a hardware fixture exercises, chosen from the
/// fixture target's own `config.json`.
struct NativeMTPHardwareE2EFamily: Equatable, Sendable {
    /// `PagedKVRuntimeModelCapabilities.modelFamily` of the target.
    let modelFamily: String
    let familyAdapter: String
    /// The next-N layer ships inside the target (`checkpoint_mtp`), so the
    /// fixture has no `mtp/` directory and the drafter is built from the
    /// target (SPEC-048 MTP-2).
    let embeddedMTP: Bool
    let blockSizeTokens: Int
    /// The paged kind the target's attention layers must use.
    let pagedKind: PagedKVSharedForwardBackend.CacheKind

    /// The Qwen3.5 fixture's paged block (unchanged from the Qwen-only harness).
    static let qwenBlockSizeTokens = 32

    static let qwen35 = NativeMTPHardwareE2EFamily(
        modelFamily: "qwen",
        familyAdapter: "qwen3_5_mtp_v1",
        embeddedMTP: false,
        blockSizeTokens: qwenBlockSizeTokens,
        pagedKind: .pagedAttention
    )

    /// GLM-5.3-Flash: KDA on `MambaCache`, DSA on `pagedMLA` at the family
    /// block size (SPEC-039 v0.1.19).
    static let glm5Next = NativeMTPHardwareE2EFamily(
        modelFamily: "glm5_next",
        familyAdapter: "glm5_next_mtp_v1",
        embeddedMTP: true,
        blockSizeTokens: PagedKVConfig.familyDefaultBlockSizeTokens["glm5_next"] ?? 256,
        pagedKind: .pagedMLA(kpool: 4)
    )

    static let deepseekV4 = NativeMTPHardwareE2EFamily(
        modelFamily: "deepseek_v4",
        familyAdapter: "deepseek_v4_dspark_v1",
        embeddedMTP: true,
        blockSizeTokens: 32,
        pagedKind: .deepseekV4Pool(ratio: 4, windowTokens: 128)
    )

    var maximumProposalDepth: Int { self == .deepseekV4 ? 5 : (self == .glm5Next ? 2 : 1) }
    var predictionLayerCount: Int { self == .deepseekV4 ? 3 : 1 }
    var stateClass: String { self == .deepseekV4 ? "stageable_rewindable" : "hybrid_stageable_rewindable" }
    var quantizationLabel: String { self == .deepseekV4 ? "mlx_mxfp4_mxfp8" : "4bit" }

    /// The lab tuple's `request_feature_profile`: sampled where the family
    /// may sign it (Qwen3.5 and GLM-5-Next, SPEC-048 MTP-2).
    var requestFeatureProfile: String {
        NativeMTPAdmissionSidecar.allowedRequestFeatureProfiles(familyAdapter: familyAdapter)
            .contains(NativeMTPAdmissionSidecar.sampledRequestFeatureProfile)
            ? NativeMTPAdmissionSidecar.sampledRequestFeatureProfile
            : NativeMTPAdmissionSidecar.greedyRequestFeatureProfile
    }

    /// The lab tuple's `complete_window_bytes_by_depth` (SPEC-048 R012): the
    /// bytes one row's native round stages, so the scheduler's round
    /// reservation and its 10% free-memory floor check run on honest
    /// numbers. glm5_next, as the provider stages it: a copy of every sparse
    /// layer's latent and pooled keys (11 target layers plus the next-N
    /// layer, 1,088 bytes per context token each, SPEC-048 MTP-12 sizing)
    /// and one KDA recurrent plus convolution state set (34 layers x
    /// 4,341,760 bytes) per kept prefix of a depth-d verify (d + 1 sets).
    /// Qwen3.5 keeps the placeholder its harness always signed.
    func completeWindowBytesByDepth(maxContextTokens: Int, maxDepth: Int = 1) -> [Int] {
        if self == .deepseekV4 {
            let context = max(1, maxContextTokens)
            // Snapshot/replay retains target windows, both compressed pools,
            // float32 remainder/overlap buffers, and every verified hidden column.
            let windows = 43 * 128 * 512 * 2
            let pools = 21 * ((context + 3) / 4) * (512 + 128) * 2
                + 20 * ((context + 127) / 128) * 512 * 2
            let pending = 21 * 4 * 4 * (1024 + 256) * 4 + 20 * 128 * 512 * 4 * 2
            return (0 ... max(0, maxDepth)).map { depth in
                (depth + 1) * (windows + pools + pending + 43 * 4096 * 4 * 2)
                    + 3 * 128 * 512 * 2
            }
        }
        guard self == .glm5Next else { return [1_048_576, 2_097_152] }
        let context = max(1, maxContextTokens)
        let latent = Self.glm5NextStagedLatentLayers * Self.glm5NextLatentBytesPerToken * context
        return (0 ... max(0, maxDepth)).map { depth in
            latent + (depth + 1) * Self.glm5NextKDALayers * Self.glm5NextKDAStateBytes
        }
    }

    static let glm5NextStagedLatentLayers = 12
    static let glm5NextLatentBytesPerToken = 1_088
    static let glm5NextKDALayers = 34
    static let glm5NextKDAStateBytes = 64 * 128 * 128 * 4 + 3 * 24_576 * 2

    /// The native active-row bound the family's tuple signs (SPEC-048 R007),
    /// nil when the harness's slot count is used. glm5_next signs 1: at four
    /// rows native MTP decoded at 0.79x ordinary in window A2 (1.27x at one).
    var signedMaxNativeActiveRows: Int? { self == .glm5Next ? 1 : nil }
    var implementationMaxNativeActiveRows: Int? {
        NativeMTPAdmissionSidecar.maxNativeActiveRowsBound(familyAdapter: familyAdapter)
    }

    /// Whether the tuple admits sampled rows to native MTP.
    var admitsSampledRows: Bool { requestFeatureProfile == NativeMTPAdmissionSidecar.sampledRequestFeatureProfile }

    /// The serve path's process setup for this family, which the harness
    /// must match or it measures another runtime: the MLX per-command-buffer
    /// budget (`ModelRuntime.commandBufferBudgetMBByFamily`, set before any
    /// MLX device use) and the model-lifetime resident-weights ticket
    /// (`ModelRuntime.residentWeightsFamilies`). Without the ticket a
    /// GLM-5.3-Flash target pays a residency cost on every forward (about
    /// 2.2 s per decode step in window A2).
    var commandBufferBudgetMB: Int? { ModelRuntime.commandBufferBudgetMBByFamily[modelFamily] }
    var holdsResidentWeights: Bool { ModelRuntime.residentWeightsFamilies.contains(modelFamily) }

    /// The fixture directory the drafter artifact lives in.
    var mtpDirectoryName: String { embeddedMTP ? "target" : "mtp" }

    func matchesPagedKind(_ kind: PagedKVSharedForwardBackend.CacheKind) -> Bool {
        switch (pagedKind, kind) {
        case (.pagedAttention, .pagedAttention), (.pagedMLA, .pagedMLA), (.deepseekV4Pool, .deepseekV4Pool): true
        default: false
        }
    }

    static func detect(configJSONData: Data?) -> NativeMTPHardwareE2EFamily? {
        switch ModelRuntime.pagedKVModelCapabilities(modelID: nil, configJSONData: configJSONData).modelFamily {
        case "qwen": .qwen35
        case "glm5_next": .glm5Next
        case "deepseek_v4": .deepseekV4
        default: nil
        }
    }
}

/// Hidden Mac Studio lab harness for the real native-MTP path (Qwen3.5 with a
/// separate drafter artifact, or GLM-5.3-Flash with its embedded next-N layer;
/// the family comes from `target/config.json`).
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
        help: "Fixture root containing a plain target/ snapshot directory, plus mtp/ for a separate drafter artifact."
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

    @Option(
        name: .customLong("throughput-tokens"),
        help: "Greedy completion tokens per row for the lab throughput phase (rows 1 and --max-batch, ordinary vs native, parity required). 0 skips it. Default 0."
    )
    var throughputTokens: Int = 0

    @Option(name: .customLong("proposal-depth"), help: "Frozen proposal depth; DSpark permits 1...5. Default 1.")
    var proposalDepth: Int = 1

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8
            ))
            throw ExitCode(2)
        }
        let rootPath = root ?? environment["MACPROVIDER_NATIVE_MTP_E2E_ROOT"]
        guard let rootPath, !rootPath.isEmpty else {
            FileHandle.standardError.write(Data(
                "native-mtp-hardware-e2e: --root or MACPROVIDER_NATIVE_MTP_E2E_ROOT is required\n".utf8
            ))
            throw ExitCode(2)
        }
        // Before any MLX device use (the host check samples the GPU).
        NativeMTPHardwareE2ERunner.applyServeProcessSetup(rootPath: rootPath)
        // Unconditional: a pass line from any other host is not lab evidence.
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        guard maxBatch >= 1, sizingPromptTokens >= 1, sizingOutputTokens >= 1, (1...5).contains(proposalDepth) else {
            throw ValidationError("--max-batch, --sizing-prompt-tokens, and --sizing-output-tokens must be >=1")
        }
        guard (0...4096).contains(throughputTokens) else {
            throw ValidationError("--throughput-tokens must be 0...4096")
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
            proposalDepth: proposalDepth,
            maxPhysicalBlocks: maxPhysicalBlocks,
            verifyServePath: environment["MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH"] == "1",
            throughputTokens: throughputTokens
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
    /// The serve path's resident-weights ticket for the one loaded target,
    /// held for the run (nil for families served without one).
    var residentWeights: WiredMemoryTicket? = nil
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
    var dsparkRoundRecorder: NativeMTPDSparkRoundRecorder? = nil
}

final class NativeMTPDSparkRoundRecorder: @unchecked Sendable {
    struct Round: Sendable {
        let requestID: String
        let proposed: Int
        let accepted: Int
    }
    private let lock = NSLock()
    private var rounds: [Round] = []

    func record(requestID: String, proposed: Int, accepted: Int) {
        lock.lock()
        rounds.append(.init(requestID: requestID, proposed: proposed, accepted: accepted))
        lock.unlock()
    }

    func metrics(requestIDs: Set<String>, maximumDepth: Int) -> [String: Any] {
        lock.lock()
        let selected = rounds.filter { requestIDs.contains($0.requestID) }
        lock.unlock()
        var drafted = Array(repeating: 0, count: maximumDepth)
        var accepted = Array(repeating: 0, count: maximumDepth)
        var proposedHistogram = Array(repeating: 0, count: maximumDepth + 1)
        var acceptedHistogram = Array(repeating: 0, count: maximumDepth + 1)
        for round in selected {
            proposedHistogram[min(maximumDepth, max(0, round.proposed))] += 1
            acceptedHistogram[min(maximumDepth, max(0, round.accepted))] += 1
            for position in 0..<maximumDepth {
                if round.proposed > position { drafted[position] += 1 }
                if round.accepted > position { accepted[position] += 1 }
            }
        }
        return ["mtp_drafted_by_position": drafted, "mtp_accepted_by_position": accepted,
            "mtp_proposal_depth_histogram": proposedHistogram,
            "mtp_accepted_prefix_histogram": acceptedHistogram,
            "mtp_resolved_rounds": selected.count]
    }
}

final class NativeMTPHardwareE2ERunner {
    static let defaultModelID = nativeMTPHardwareDefaultModelID
    /// The pinned mlx-swift-lm revision; single source is `KVBuildIdentity`, whose
    /// drift test fails CI when it disagrees with Package.resolved.
    static let upstreamRevision = KVBuildIdentity.mlxSwiftLMRevision
    private static let providerRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let liveExecutableCDHash = "456789abcdef0123456789abcdef0123456789ab"
    private static let reproducibleBuildSHA256 = String(repeating: "1", count: 64)
    private static let releaseID = "native-mtp-hardware-e2e"

    private let root: URL
    private let modelID: String
    private let maxBatch: Int
    private let maxNativeActiveRows: Int
    let proposalDepth: Int
    private let maxPromptTokens: Int
    private let maxPhysicalBlocks: Int
    private let signedJourneyInputs: String?
    private let verifyServePath: Bool
    /// Lab throughput phase completion tokens per row; 0 skips it.
    private let throughputTokens: Int
    private let dsparkRoundRecorder = NativeMTPDSparkRoundRecorder()
    private let diagnosticEligibilityBypass: Bool
    /// Detected from `target/config.json`; Qwen3.5 when unreadable, so an
    /// unrecognized target fails the family check in the fixture load.
    let family: NativeMTPHardwareE2EFamily
    /// SPEC-024-R005 lab leg: both runtimes admit positive-cached turns to
    /// their CB rows (the test runtimes cover every tuple).
    var continuousBatchingCachedTurns = false

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
        proposalDepth: Int = 1,
        maxPromptTokens: Int = 1_048_576,
        maxPhysicalBlocks: Int = 512,
        verifyServePath: Bool = false,
        throughputTokens: Int = 0,
        diagnosticEligibilityBypass: Bool = false,
        signedJourneyInputs: String? = nil
    ) {
        root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        self.modelID = modelID
        self.maxBatch = maxBatch
        self.proposalDepth = proposalDepth
        self.maxPromptTokens = maxPromptTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.signedJourneyInputs = signedJourneyInputs
        self.verifyServePath = verifyServePath
        self.throughputTokens = throughputTokens
        self.diagnosticEligibilityBypass = diagnosticEligibilityBypass
        let family = NativeMTPHardwareE2EFamily.detect(configJSONData: try? Data(
            contentsOf: root.appendingPathComponent("target/config.json")
        )) ?? .qwen35
        self.family = family
        self.maxNativeActiveRows = maxNativeActiveRows ?? family.signedMaxNativeActiveRows ?? maxBatch
    }

    private var mtpDirectory: URL {
        root.appendingPathComponent(family.mtpDirectoryName, isDirectory: true)
    }

    private func observeArtifacts(targetDirectory: URL) throws -> NativeMTPArtifactPairObservation {
        family.embeddedMTP
            ? try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: targetDirectory)
            : try NativeMTPArtifactObserver.observePair(targetDirectory: targetDirectory, mtpDirectory: mtpDirectory)
    }

    /// `min(rows, bound)` rows admitted native and every other row sent to
    /// ordinary decode by the active-row bound (SPEC-048 R007).
    static func admissionsRespectNativeBound(_ admissions: [NativeMTPRuntimeAdmission], rows: Int, bound: Int) -> Bool {
        let native = admissions.filter { $0.effectivePath == .nativeMTP }.count
        let boundRouted = admissions.filter {
            $0.effectivePath == .ordinary && $0.selection.nativeMTPReason == .capacityAboveNativeBound
        }.count
        return admissions.count == rows && native == min(rows, max(1, bound)) && native + boundRouted == rows
    }

    /// Applies the family's MLX command-buffer budget for this process, as
    /// `serve` does. Must run before any MLX device use; returns the MB set.
    @discardableResult
    static func applyServeProcessSetup(rootPath: String, mlxCacheLimitMB: Int? = 2048) -> Int? {
        let root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
        let family = NativeMTPHardwareE2EFamily.detect(configJSONData: try? Data(
            contentsOf: root.appendingPathComponent("target/config.json")
        ))
        // The budget first: MLX reads it when it creates its device.
        let mb = family.flatMap { ModelRuntime.applyMLXCommandBufferBudget(modelFamily: $0.modelFamily) }
        if let mb, let family {
            FileHandle.standardError.write(Data("native-mtp-e2e: mlx_max_mb_per_buffer=\(mb) family=\(family.modelFamily)\n".utf8))
        }
        // The lab and live serve configs bound MLX's buffer cache
        // (`mlx_cache_limit_mb: 2048`); unbounded, freed round buffers stay
        // cached and take the memory the native round's free-memory floor reads.
        if let applied = ModelRuntime.applyMLXCacheLimit(megabytes: mlxCacheLimitMB) {
            FileHandle.standardError.write(Data("native-mtp-e2e: mlx_cache_limit_bytes=\(applied)\n".utf8))
        }
        return mb
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
        let countersBefore = await nativeRuntime.currentSnapshot().nativeMTPStatus
        let native = try await completeConcurrently(requests, with: nativeRuntime)
        let parityCounters = NativeMTPStatusDelta(
            before: countersBefore, after: await nativeRuntime.currentSnapshot().nativeMTPStatus
        )
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
        // Rows above the tuple's native active-row bound take ordinary decode
        // (SPEC-048 R007); the rest must be native.
        try require(
            Self.admissionsRespectNativeBound(recordedAdmissions, rows: requests.count, bound: maxNativeActiveRows),
            "native admissions do not match the native active-row bound \(maxNativeActiveRows)"
        )

        let streamingStopRequest = try makeRequest(
            id: "native-mtp-real-stream-stop",
            prompt: "Answer with a terse sentence ending in STOP.",
            stream: true,
            stop: ["STOP"]
        )
        let handle = try await nativeRuntime.acquireRequestHandle(streamingStopRequest)
        let streamRecorder = NativeMTPHardwareStreamRecorder()
        let admissionsBeforeStreaming = admissionRecorder.snapshot().count
        // Unregistered as soon as the stream ends: a registration held to the
        // end of `run()` counts as an active row and pushed the throughput
        // phase's last row over the native active-row bound (window A2).
        do {
            _ = try await nativeRuntime.stream(streamingStopRequest, with: handle) { chunk in
                streamRecorder.append(chunk)
            }
        } catch {
            await nativeRuntime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await nativeRuntime.unregisterInFlight(handle.registrationID)
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
        let labThroughput = throughputTokens > 0
            ? try await measureLabThroughput(
                ordinary: ordinaryRuntime, native: nativeRuntime, recorder: admissionRecorder
            )
            : nil
        let labThroughputJSON = try labThroughput.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        } ?? "null"
        let json = """
        {"schema":"macprovider.native-mtp-hardware-e2e-result.v1","status":"pass","evidence_class":"correctness_only","model_id":"\(modelID)","model_family":"\(family.modelFamily)","family_adapter":"\(family.familyAdapter)","proposal_depth":\(proposalDepth),"target_sha256":"\(targetIdentity.digest)","mtp_sha256":"\(mtpIdentity.digest)","admissions":\(totalAdmissions),"max_observed_batch_depth":\(maxDepth),"serve_path_verified":\(verifyServePath),"parity_proposed":\(parityCounters.proposedTokens),"parity_accepted":\(parityCounters.acceptedTokens),"parity_rejected":\(parityCounters.rejectedTokens),"lab_throughput":\(labThroughputJSON)}
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

    /// `knownTargetIdentity`: the caller hashed the target in this process
    /// already; `loadRuntimePair` still re-hashes it right before loading.
    func loadRuntimeFixture(
        maxContextTokens: Int,
        knownTargetIdentity: MLXSnapshotIdentity? = nil,
        ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?,
        nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) async throws -> NativeMTPHardwareRuntimeFixture {
        guard NativeMTPQualificationScope.permitsFixtureHooks else { throw NativeMTPHardwareE2EError.assertionFailed("isolated qualification scope required") }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = self.mtpDirectory
        try require((1...family.maximumProposalDepth).contains(proposalDepth), "proposal depth exceeds family bound")
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)

        let targetIdentity = try knownTargetIdentity ?? MLXSnapshotIdentity.compute(directory: targetDirectory)
        // An embedded MTP layer is the target artifact: one identity, hashed once.
        let mtpIdentity = family.embeddedMTP
            ? targetIdentity
            : try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: mtpDirectory.appendingPathComponent("config.json"))
        let machine = MachineFingerprinter().sample()
        let signedAdmission: NativeMTPHardwareSignedAdmission
        if let signedJourneyInputs {
            try require(!diagnosticEligibilityBypass && !verifyServePath,
                        "signed-policy LAB execution forbids eligibility bypass and test build-identity injection")
            signedAdmission = try NativeMTPJourneySignedInputs.load(
                directory: URL(fileURLWithPath: ConfigLoader.expandTilde(signedJourneyInputs)),
                artifactRoot: root, modelID: modelID, target: targetIdentity,
                machine: machine, slots: maxBatch)
        } else {
            signedAdmission = try makeAndValidateAdmission(
                targetIdentity: targetIdentity, mtpIdentity: mtpIdentity,
                machine: machine, maxContextTokens: maxContextTokens)
        }
        let admission = signedAdmission.capability
        try require(admission.targetArtifactSHA256 == targetIdentity.digest, "target digest admission mismatch")
        try require(admission.mtpArtifactSHA256 == mtpIdentity.digest, "MTP digest admission mismatch")
        try require(admission.maxProposalDepth == proposalDepth, "unexpected proposal depth")
        if signedJourneyInputs != nil {
            try require(admission.maxPromptTokens == maxPromptTokens, "signed prompt cap mismatch")
            try require(admission.maxNativeActiveRows == maxNativeActiveRows, "signed native row bound mismatch")
        }
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
            maximumNativeActiveRows: diagnosticEligibilityBypass ? maxNativeActiveRows : admission.maxNativeActiveRows,
            supportsSampling: admission.supportsSampling || diagnosticEligibilityBypass,
            adaptationConfig: admission.adaptationConfig
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
            nativeAdmissionRecorder: nativeAdmissionRecorder,
            dsparkRoundRecorder: family == .deepseekV4 ? dsparkRoundRecorder : nil
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
        guard NativeMTPQualificationScope.permitsFixtureHooks else { throw NativeMTPHardwareE2EError.assertionFailed("isolated qualification scope required") }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = self.mtpDirectory
        try requireDirectory(targetDirectory)
        try requireDirectory(mtpDirectory)
        if diagnosticEligibilityBypass {
            try require(targetIdentity.directory == targetDirectory.standardizedFileURL.resolvingSymlinksInPath()
                && targetIdentity.isCurrent(), "target identity changed during diagnostic load")
            try require(mtpIdentity.directory == mtpDirectory.standardizedFileURL.resolvingSymlinksInPath()
                && mtpIdentity.isCurrent(), "MTP identity changed during diagnostic load")
        } else {
            let observedTargetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
            let observedMTPIdentity = family.embeddedMTP
                ? observedTargetIdentity
                : try MLXSnapshotIdentity.compute(directory: mtpDirectory)
            try require(observedTargetIdentity == targetIdentity, "target identity changed during load")
            try require(observedMTPIdentity == mtpIdentity, "MTP identity changed during load")
        }
        // Run the same artifact observer the production enable path runs
        // (ModelRuntime native-MTP load) so lab evidence cannot pass on artifacts
        // that production would reject.
        let artifactObservation = try observeArtifacts(targetDirectory: targetDirectory)
        try require(
            ModelRuntime.nativeMTPArtifactObservationMatchesAdmissionForTest(
                artifactObservation,
                admissionCapability: nativeAdmissionCapability
            ),
            "artifact observation does not match admission"
        )

        let configData = try Data(contentsOf: targetDirectory.appendingPathComponent("config.json"))
        let prefillGrouping = ContinuousBatchPrefillGroupingRule.fromModelConfiguration(configData, modelID: modelID)
        let modelCapabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: modelID,
            configJSONData: configData
        )
        try require(
            modelCapabilities.modelFamily == family.modelFamily,
            "expected \(family.modelFamily) model family, got \(modelCapabilities.modelFamily)"
        )
        if family != .deepseekV4 {
            try require(modelCapabilities.hybridDecoderArchitectureVerified, "hybrid decoder not verified")
        }
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
            targetContainer = try await LLMModelFactory.shared.loadContainer(
                from: targetDirectory,
                using: ChatTemplateCompatTokenizerLoader()
            )
            let drafterPresent = await ModelRuntime.nativeMTPDrafterPresent(
                familyAdapter: family.familyAdapter,
                targetContainer: targetContainer
            )
            try require(drafterPresent, "target loaded without its MTP drafter weights")
            drafterContainer = try await ModelRuntime.loadNativeMTPDrafterContainer(
                familyAdapter: family.familyAdapter,
                targetDirectory: targetDirectory,
                drafterDirectory: mtpDirectory,
                tokenizerLoader: ChatTemplateCompatTokenizerLoader(),
                maximumProposalDepth: proposalDepth
            )
        }
        // One target is loaded and shared by the ordinary and native
        // runtimes (the embedded drafter is parameterless); keep it resident
        // as serve does.
        let residentWeights = family.holdsResidentWeights
            ? await ModelRuntime.startResidentWeightsTicket(modelFamily: family.modelFamily)
            : nil
        if family.holdsResidentWeights {
            try require(residentWeights != nil, "\(family.modelFamily) target could not start its resident-weights ticket")
        }
        let maximumBlockSize = await drafterContainer.perform { context in
            context.model.maximumBlockSize
        }
        try require(
            NativeMTPProposalBounds.fits(
                maximumProposalDepth: proposalDepth,
                maximumBlockSize: maximumBlockSize
            ),
            "MTP proposal depth \(proposalDepth) exceeds drafter maximum block size \(String(describing: maximumBlockSize))"
        )

        let cacheKinds = try await targetContainer.perform { context in
            try context.model.newCache(parameters: nil as GenerateParameters?).map { cache in
                guard let kind = PagedKVSharedForwardBackend.CacheKind.recognized(from: cache) else {
                    throw NativeMTPHardwareE2EError.unsupportedCache(String(describing: type(of: cache)))
                }
                return kind
            }
        }
        try require(cacheKinds.contains(where: family.matchesPagedKind), "\(family.pagedKind) cache not observed")
        if family != .deepseekV4 {
            try require(cacheKinds.contains(.recurrentMamba), "recurrent Mamba cache not observed")
        }

        let pagedConfig = PagedKVConfig(
            enabled: true,
            blockSizeTokens: family.blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks
        )
        // Attach from the same live parity + batched-isolation (MoE dispatch)
        // probes production runs at load; a synthesized identity cannot prove
        // MoE dispatch and would hide real attach failures.
        let placeholderProof = sizingProof(modelSHA: targetIdentity.digest, maxContextTokens: maxContextTokens)
        let probeRuntime = await makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: placeholderProof,
            observed: observedIdentity(from: placeholderProof),
            modelCapabilities: modelCapabilities,
            prefillGrouping: prefillGrouping,
            targetContainer: targetContainer,
            backend: makeBackend(container: targetContainer, cacheKinds: cacheKinds),
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
        let ordinaryBackend = makeBackend(container: targetContainer, cacheKinds: cacheKinds)
        let nativeBackend = makeBackend(container: targetContainer, cacheKinds: cacheKinds,
            drafterContainer: drafterContainer, familyAdapter: nativeAdmissionCapability.familyAdapter)
        let ordinary = await makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            prefillGrouping: prefillGrouping,
            targetContainer: targetContainer,
            backend: ordinaryBackend,
            nativeCapability: nil,
            nativeAdmissionCapability: nil,
            drafterContainer: nil,
            admissionRecorder: ordinaryAdmissionRecorder
        )
        let native = await makeRuntime(
            modelSHA: targetIdentity.digest,
            maxContextTokens: maxContextTokens,
            pagedConfig: pagedConfig,
            proof: proof,
            observed: observed,
            modelCapabilities: modelCapabilities,
            prefillGrouping: prefillGrouping,
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
            targetContainer: targetContainer,
            residentWeights: residentWeights
        )
    }

    private func makeBackend(
        container: ModelContainer,
        cacheKinds: [PagedKVSharedForwardBackend.CacheKind],
        drafterContainer: MTPDrafterContainer? = nil,
        familyAdapter: String? = nil
    ) -> any ContinuousBatchSchedulerBackend {
        if family == .deepseekV4 {
            let backend = DeepseekV4ContinuousBatchBackend(container: container,
                nativeMTPDrafterContainer: drafterContainer)
            if drafterContainer != nil {
                let recorder = dsparkRoundRecorder
                backend.installLabRoundObserver { requestID, proposed, accepted in
                    recorder.record(requestID: requestID, proposed: proposed, accepted: accepted)
                }
            }
            return backend
        }
        return PagedKVSharedForwardBackend(container: container,
            blockSizeTokens: family.blockSizeTokens, maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1, layerCount: cacheKinds.count, cacheKinds: cacheKinds,
            drafterContainer: drafterContainer, nativeMTPFamilyAdapter: familyAdapter)
    }

    private func makeRuntime(
        modelSHA: String,
        maxContextTokens: Int,
        pagedConfig: PagedKVConfig,
        proof: PagedKVHardwareSizingProof,
        observed: PagedKVObservedRuntimeIdentity,
        modelCapabilities: PagedKVRuntimeModelCapabilities,
        prefillGrouping: ContinuousBatchPrefillGroupingRule,
        targetContainer: ModelContainer,
        backend: any ContinuousBatchSchedulerBackend,
        nativeCapability: NativeMTPCapability?,
        nativeAdmissionCapability: NativeMTPAdmissionCapability?,
        drafterContainer: MTPDrafterContainer?,
        admissionRecorder: NativeMTPHardwareAdmissionRecorder?
    ) async -> ModelRuntime {
        let preparationLane = await ModelRuntime.makeContinuousBatchTextPreparationLane(
            container: targetContainer,
            admissionCapability: nativeAdmissionCapability,
            nativeVisionProfile: nil,
            cacheKinds: await ModelRuntime.pagedKVCacheKinds(container: targetContainer)
        )
        return ModelRuntime(
            modelID: modelID,
            modelHash: modelSHA,
            maxContextTokensOverride: maxContextTokens,
            pagedKVConfig: pagedConfig,
            prefillStepSize: family == .deepseekV4 ? 2048 : 512,
            maxBatch: maxBatch,
            continuousBatchingMode: .on,
            continuousBatchingCachedTurns: continuousBatchingCachedTurns,
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
            continuousBatchPrefillGrouping: prefillGrouping,
            testContinuousBatchTextPreparationLane: preparationLane,
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

    /// Lab throughput phase (`--throughput-tokens`): greedy rows at 1 and
    /// `maxBatch` concurrent requests, ordinary then native on the same
    /// prompts, three passes each. Every native row must equal its ordinary
    /// row and be admitted native. Rates are end to end (all completion
    /// tokens over the batch wall time, prefill included); this is lab
    /// evidence, not the SPEC-048 R015 matrix (`native-mtp-bench`).
    private func measureLabThroughput(
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder
    ) async throws -> [String: Any] {
        let prompts = [
            "Explain in three sentences why the sky appears blue.",
            "Write a short Python function that reverses a linked list, then explain it.",
            "Describe a quiet harbor town at dawn in one paragraph.",
            "List five prime numbers greater than one hundred and say why each is prime.",
            "Summarize the rules of chess for a beginner.",
            "Give three tips for learning a new language, with an example for each.",
            "Write a haiku about winter rain, then explain its imagery.",
            "Compare TCP and UDP in a short table.",
        ]
        let passes = 3
        var cells: [[String: Any]] = []
        for rows in Array(Set([1, max(1, min(maxBatch, prompts.count))])).sorted() {
            var ratios: [Double] = []
            var ordinaryRates: [Double] = []
            var nativeRates: [Double] = []
            var proposed: UInt64 = 0
            var accepted: UInt64 = 0
            var rejected: UInt64 = 0
            for pass in 0..<passes {
                let requests = try (0..<rows).map {
                    try makeRequest(
                        id: "native-mtp-tput-r\(rows)-p\(pass)-\($0)", prompt: prompts[$0], maxTokens: throughputTokens
                    )
                }
                let ordinaryStart = Date()
                let expected = try await completeConcurrently(requests, with: ordinary)
                let ordinarySeconds = Date().timeIntervalSince(ordinaryStart)
                let admissionsBefore = recorder.snapshot().count
                let before = await native.currentSnapshot().nativeMTPStatus
                let nativeStart = Date()
                let actual = try await completeConcurrently(requests, with: native)
                let nativeSeconds = Date().timeIntervalSince(nativeStart)
                let delta = NativeMTPStatusDelta(before: before, after: await native.currentSnapshot().nativeMTPStatus)
                let admissions = recorder.snapshot().dropFirst(admissionsBefore)
                try require(
                    admissions.count == rows
                        && Self.admissionsRespectNativeBound(Array(admissions), rows: rows, bound: maxNativeActiveRows),
                    "throughput rows=\(rows) pass=\(pass): native admissions do not match the native bound \(maxNativeActiveRows)"
                )
                for id in expected.keys.sorted() {
                    try require(
                        actual[id]?.content == expected[id]?.content
                            && actual[id]?.completionTokens == expected[id]?.completionTokens,
                        "throughput greedy mismatch for \(id)"
                    )
                }
                let tokens = Double(expected.values.reduce(0) { $0 + $1.completionTokens })
                let ordinaryRate = ordinarySeconds > 0 ? tokens / ordinarySeconds : 0
                let nativeRate = nativeSeconds > 0 ? tokens / nativeSeconds : 0
                ordinaryRates.append(ordinaryRate)
                nativeRates.append(nativeRate)
                if ordinaryRate > 0 { ratios.append(nativeRate / ordinaryRate) }
                proposed += delta.proposedTokens
                accepted += delta.acceptedTokens
                rejected += delta.rejectedTokens
            }
            func median(_ values: [Double]) -> Double {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return 0 }
                return sorted.count % 2 == 1
                    ? sorted[sorted.count / 2]
                    : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            }
            cells.append([
                "rows": rows,
                "passes": passes,
                "completion_tokens_per_row": throughputTokens,
                "ordinary_e2e_tps_median": median(ordinaryRates),
                "native_e2e_tps_median": median(nativeRates),
                "native_over_ordinary_median": median(ratios),
                "proposed": proposed,
                "accepted": accepted,
                "rejected": rejected,
                "acceptance": proposed > 0 ? Double(accepted) / Double(proposed) : 0,
                "greedy_equal": true,
            ])
        }
        return ["r015_formal": false, "rate_basis": "end_to_end_batch_wall", "cells": cells]
    }

    private func makeRequest(
        id: String,
        prompt: String,
        stream: Bool = false,
        stop: [String]? = nil,
        maxTokens: Int = 8
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
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
        machine: MachineFingerprint,
        maxContextTokens: Int
    ) throws -> NativeMTPHardwareSignedAdmission {
        let artifactObservation = try observeArtifacts(
            targetDirectory: root.appendingPathComponent("target", isDirectory: true)
        )
        let affineRepresentation: NativeMTPAffineRepresentation
        if family == .deepseekV4 {
            affineRepresentation = try NativeMTPArtifactObserver.mixedMXRepresentation(for: artifactObservation)
        } else {
            affineRepresentation = try NativeMTPArtifactObserver.affineRepresentation(for: artifactObservation)
        }
        let tokenizerSHA = try sha256(of: root.appendingPathComponent("target/tokenizer.json"))
        let manifestSHA = try sha256(of: mtpDirectory.appendingPathComponent("config.json"))
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
            maxContextTokens: maxContextTokens,
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
                "fixed_proposal_depth": proposalDepth,
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
                "mtp": ["path": family.mtpDirectoryName, "sha256": mtpSHA],
                "tokenizer": ["path": "target/tokenizer.json", "sha256": tokenizerSHA],
                "manifest": ["path": "\(family.mtpDirectoryName)/config.json", "sha256": manifestSHA],
            ],
        ])
    }

    private func releaseEnvelopeData(
        maxContextTokens: Int,
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
            "mtp_family_adapter": family.familyAdapter,
            "mtp_state_class": family.stateClass,
            "mtp_head_count": family.predictionLayerCount,
            "proposal_depth": proposalDepth,
            "complete_window_bytes_by_depth": family.completeWindowBytesByDepth(maxContextTokens: maxContextTokens, maxDepth: proposalDepth),
            "runtime_revision": Self.upstreamRevision,
            "provider_revision": Self.providerRevision,
            "source_commit": Self.providerRevision,
            "reproducible_build_sha256": Self.reproducibleBuildSHA256,
            "live_executable_cdhash": Self.liveExecutableCDHash,
            "cache_state_classes": [family.stateClass],
            "hardware_class": NativeMTPAdmissionSidecar.canonicalHardwareClass(machine.chip),
            "ram_bytes": machine.ramGB * 1_073_741_824,
            "qualified_slots": maxBatch,
            "max_native_active_rows": diagnosticEligibilityBypass ? min(maxNativeActiveRows, family.signedMaxNativeActiveRows ?? maxNativeActiveRows) : maxNativeActiveRows,
            // A Qwen3.5 lab tuple qualifies sampled rows too (target-sample
            // exact match), so temperature cells measure the native path; a
            // glm5_next tuple is greedy only.
            "request_feature_profile": family.requestFeatureProfile,
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
                "kind": family == .deepseekV4 ? "mlx_mxfp4_mxfp8" : "mlx_affine",
                "packed_data_dtype": "uint32",
                "packed_layout": "mlx_array_native_v1",
                "scale_dtype": family == .deepseekV4 ? "uint8" : "bfloat16",
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
            modelFamily: family.modelFamily,
            hardwareClass: "apple-silicon-native-mtp-e2e",
            metallibSHA256: String(repeating: "a", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            blockSizeTokens: family.blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            maxResidentTokens: max(maxPhysicalBlocks * family.blockSizeTokens, maxContextTokens * maxBatch),
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
