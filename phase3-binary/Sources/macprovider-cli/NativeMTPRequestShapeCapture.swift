import Darwin
import Foundation

struct NativeMTPRequestShapeCaptureConfig: Sendable, Equatable {
    static let directoryEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR"
    static let maxRecordsEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_RECORDS"
    static let maxBytesEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_BYTES"

    let directory: URL
    let maxRecords: Int
    let maxBytes: Int

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeMTPRequestShapeCaptureConfig? {
        guard let rawDirectory = environment[directoryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDirectory.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: ConfigLoader.expandTilde(rawDirectory), isDirectory: true)
        return NativeMTPRequestShapeCaptureConfig(
            directory: directory,
            maxRecords: positiveInt(environment[maxRecordsEnvironmentKey]) ?? 1_000,
            maxBytes: positiveInt(environment[maxBytesEnvironmentKey]) ?? 10 * 1024 * 1024
        )
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw,
              let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else {
            return nil
        }
        return parsed
    }
}

final class NativeMTPRequestShapeCapture: @unchecked Sendable {
    static let schema = "macprovider.native-mtp-request-shape-capture.v1"

    private let lock = NSLock()
    private let fileURL: URL
    private let fileHandle: FileHandle
    private let maxRecords: Int
    private let maxBytes: Int
    private var recordsWritten = 0
    private var bytesWritten = 0
    private var droppedAfterLimit = 0
    private var writeErrors = 0

    init(
        config: NativeMTPRequestShapeCaptureConfig,
        nativeMTPMode: NativeMTPMode,
        runningBuildIdentity: ModelRuntime.NativeMTPRunningBuildIdentity?,
        now: Date = Date()
    ) throws {
        guard nativeMTPMode == .off else {
            throw NativeMTPRequestShapeCaptureError.requiresNativeMTPOff
        }
        let directory = config.directory.standardizedFileURL
        try Self.prepareDirectory(directory)
        self.fileURL = directory.appendingPathComponent(Self.fileName(now: now), isDirectory: false)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NativeMTPRequestShapeCaptureError.outputFileExists
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ])
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        self.maxRecords = max(1, config.maxRecords)
        self.maxBytes = max(1024, config.maxBytes)

        let header: [String: Any] = [
            "schema": Self.schema,
            "record_type": "header",
            "captured_at": Self.iso8601(now),
            "native_mtp_mode": nativeMTPMode.rawValue,
            "capture_requires_native_mtp_off": true,
            "served_identity": "per_record_sha256",
            "build_source_commit": runningBuildIdentity?.sourceCommit ?? "unavailable",
            "build_cdhash": runningBuildIdentity?.liveExecutableCDHash ?? "unavailable",
            "cli_version": CoordinatorClient.binaryVersion,
            "max_records": self.maxRecords,
            "max_bytes": self.maxBytes,
        ]
        try writeLocked(header)
    }

    deinit {
        try? fileHandle.close()
    }

    func record(
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        admission: NativeMTPRuntimeAdmission,
        lease: ConversationCacheLease?,
        leaseAllowed: Bool,
        completion: CompletionResult,
        stream: Bool,
        now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard recordsWritten < maxRecords, bytesWritten < maxBytes else {
            droppedAfterLimit += 1
            return
        }
        let sequence = recordsWritten + 1
        let payload = Self.payload(
            sequence: sequence,
            request: request,
            snapshot: snapshot,
            admission: admission,
            lease: lease,
            leaseAllowed: leaseAllowed,
            completion: completion,
            stream: stream,
            now: now
        )
        do {
            try writeLocked(payload)
            recordsWritten = sequence
        } catch {
            writeErrors += 1
        }
    }

    private static func payload(
        sequence: Int,
        request: ChatCompletionRequest,
        snapshot: RuntimeSnapshot,
        admission: NativeMTPRuntimeAdmission,
        lease: ConversationCacheLease?,
        leaseAllowed: Bool,
        completion: CompletionResult,
        stream: Bool,
        now: Date
    ) -> [String: Any] {
        let keyPresent = request.conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let leaseState: String
        let cachedPromptTokens: Int
        let retainedHandoff: Bool
        if keyPresent {
            if let lease {
                cachedPromptTokens = lease.cachedPromptTokens
                retainedHandoff = lease.reusableCache?.retainedPagedKVSequence != nil || lease.recurrentCheckpoint != nil
                leaseState = cachedPromptTokens > 0 || retainedHandoff ? "hit" : "miss"
            } else {
                cachedPromptTokens = 0
                retainedHandoff = false
                leaseState = leaseAllowed ? "missing" : "not_applicable"
            }
        } else {
            cachedPromptTokens = 0
            retainedHandoff = false
            leaseState = "not_applicable"
        }

        let reason = admission.selection.nativeMTPReason?.rawValue ?? "eligible"
        let preCapacityEligible = admission.selection.nativeMTPReason?.isEligible ?? true
        return [
            "schema": Self.schema,
            "record_type": "request_shape",
            "sequence": sequence,
            "shape_id": String(format: "shape-%06d", sequence),
            "captured_at": Self.iso8601(now),
            "served_model_hash_sha256": snapshot.modelHash ?? "unavailable",
            "served_weights_manifest_sha256": snapshot.weightsManifestSHA256 ?? "unavailable",
            "native_mtp_tuple_sha256": admission.tupleFence?.admissionTupleSHA256 ?? "none",
            "native_mtp_served_snapshot_id_sha256": admission.tupleFence?.servedSnapshotID ?? "none",
            "native_mtp_target_generation": admission.tupleFence.map { Int($0.targetGeneration) } ?? 0,
            "stream": stream,
            "stop_sequences": request.stop.count,
            "sampling_requested": request.temperature != 0.0 || request.topP != 1.0,
            "multiple_completions_requested": NativeMTPRequestShapeCapture.jsonInt(request.promptSource.n) ?? 1 != 1,
            "tools_present": !NativeMTPRequestShapeCapture.hasNoTools(request.promptSource.tools)
                || !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.toolChoice)
                || request.messages.contains { $0.role == .tool || !($0.toolCalls?.isEmpty ?? true) },
            "structured_output_requested": request.responseFormat != .text,
            "logprobs_requested": !NativeMTPRequestShapeCapture.isAbsentNullOrFalse(request.promptSource.logprobs)
                || !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.topLogprobs),
            "logit_controls_requested": request.presencePenalty != 0.0
                || request.frequencyPenalty != 0.0
                || !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.logitBias)
                || !NativeMTPRequestShapeCapture.absentOrZero(request.promptSource.minP)
                || !NativeMTPRequestShapeCapture.absentOrOne(request.promptSource.repetitionPenalty),
            "reasoning_or_template_model": HarmonyResponseParser.isHarmonyModelID(request.model),
            "multimodal_requested": request.containsNonTextMessageContentPart,
            "unknown_request_fields_present": !request.topLevelKeys.isSubset(of: NativeMTPSelector.admittedTopLevelKeys)
                || !request.streamOptionKeys.isSubset(of: NativeMTPSelector.admittedStreamOptionKeys),
            "conversation_key_present": keyPresent,
            "conversation_key_cache_only": keyPresent ? request.conversationCacheOnly : false,
            "conversation_cache_lease": leaseState,
            "conversation_cache_cached_prompt_tokens": cachedPromptTokens,
            "conversation_cache_retained_handoff": retainedHandoff,
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "generated_completion_tokens": completion.generatedCompletionTokens,
            "max_completion_tokens_requested": request.maxTokens ?? 0,
            "pre_capacity_selector_reason": reason,
            "pre_capacity_eligible": preCapacityEligible,
            "effective_path": admission.effectivePath.rawValue,
        ]
    }

    private func writeLocked(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        guard bytesWritten + data.count <= maxBytes else {
            droppedAfterLimit += 1
            return
        }
        try fileHandle.write(contentsOf: data)
        bytesWritten += data.count
    }

    private static func prepareDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NativeMTPRequestShapeCaptureError.directoryNotDirectory
            }
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
                throw NativeMTPRequestShapeCaptureError.unsafeDirectory
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.int32Value
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard owner == getuid(), mode & 0o077 == 0 else {
                throw NativeMTPRequestShapeCaptureError.unsafeDirectory
            }
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    private static func fileName(now: Date) -> String {
        "native-mtp-request-shapes-\(Self.fileTimestamp(now)).jsonl"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter.autotuneInternet.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func hasNoTools(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .array(let entries):
            return entries.isEmpty
        default:
            return false
        }
    }

    private static func isAbsentOrNull(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        default:
            return false
        }
    }

    private static func isAbsentNullOrFalse(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .bool(let bool):
            return bool == false
        default:
            return false
        }
    }

    private static func jsonInt(_ value: JSONValue?) -> Int? {
        guard case .int(let int)? = value else { return nil }
        return int
    }

    private static func absentOrZero(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .int(let int):
            return int == 0
        case .double(let double):
            return double == 0
        default:
            return false
        }
    }

    private static func absentOrOne(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .int(let int):
            return int == 1
        case .double(let double):
            return double == 1
        default:
            return false
        }
    }
}

enum NativeMTPRequestShapeCaptureError: Error, Equatable {
    case requiresNativeMTPOff
    case directoryNotDirectory
    case unsafeDirectory
    case outputFileExists
}
