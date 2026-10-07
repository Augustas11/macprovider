import CryptoKit
import Darwin
import Foundation
import MacProviderCore

struct NativeMTPRequestShapeCaptureConfig: Sendable, Equatable {
    static let directoryEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR"
    static let maxRecordsEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_RECORDS"
    static let maxBytesEnvironmentKey = "MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_MAX_BYTES"
    static let hardMaxRecords = 1_000
    static let hardMaxBytes = 10 * 1024 * 1024

    let directory: URL
    let maxRecords: Int
    let maxBytes: Int

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> NativeMTPRequestShapeCaptureConfig? {
        guard let rawDirectory = environment[directoryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDirectory.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: ConfigLoader.expandTilde(rawDirectory), isDirectory: true)
        return NativeMTPRequestShapeCaptureConfig(
            directory: directory,
            maxRecords: try boundedInt(environment[maxRecordsEnvironmentKey], defaultValue: hardMaxRecords, upperBound: hardMaxRecords),
            maxBytes: try boundedInt(environment[maxBytesEnvironmentKey], defaultValue: hardMaxBytes, upperBound: hardMaxBytes)
        )
    }

    private static func boundedInt(_ raw: String?, defaultValue: Int, upperBound: Int) throws -> Int {
        guard let raw else { return defaultValue }
        guard let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0,
              parsed <= upperBound else {
            throw NativeMTPRequestShapeCaptureError.invalidLimit
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
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw NativeMTPRequestShapeCaptureError.outputFileExists }
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        if fchmod(fd, S_IRUSR | S_IWUSR) != 0 {
            close(fd)
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        self.fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.maxRecords = min(max(1, config.maxRecords), NativeMTPRequestShapeCaptureConfig.hardMaxRecords)
        self.maxBytes = min(max(1024, config.maxBytes), NativeMTPRequestShapeCaptureConfig.hardMaxBytes)

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
        _ = try writeLocked(header)
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
        resolvedMaxCompletionTokens: Int? = nil,
        now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard admission.effectivePath == .ordinary, admission.selection.nativeMTPReason == .modeOff else { return }
        guard completion.promptTokens > 0, completion.completionTokens > 0 else { return }
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
            resolvedMaxCompletionTokens: resolvedMaxCompletionTokens,
            now: now
        )
        do {
            if try writeLocked(payload) {
                recordsWritten = sequence
            }
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
        resolvedMaxCompletionTokens: Int?,
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
        let requestedN = NativeMTPRequestShapeCapture.jsonInt(request.promptSource.n) ?? 1
        let topKPresent = !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.topK)
        let minPNonzero = !NativeMTPRequestShapeCapture.absentOrZero(request.promptSource.minP)
        let repetitionPenaltyNondefault = !NativeMTPRequestShapeCapture.absentOrOne(request.promptSource.repetitionPenalty)
        let logitBiasPresent = !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.logitBias)
        let topLogprobsPresent = !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.topLogprobs)
        let toolsPresent = !NativeMTPRequestShapeCapture.hasNoTools(request.promptSource.tools)
        let toolChoicePresent = !NativeMTPRequestShapeCapture.isAbsentOrNull(request.promptSource.toolChoice)
        let toolTurnStatePresent = request.messages.contains { $0.role == .tool || !($0.toolCalls?.isEmpty ?? true) }
        let unknownTopLevelKeysPresent = !request.topLevelKeys.isSubset(of: NativeMTPSelector.admittedTopLevelKeys)
        let unknownStreamOptionKeysPresent = !request.streamOptionKeys.isSubset(of: NativeMTPSelector.admittedStreamOptionKeys)
        let resolvedMaxCompletionTokens = resolvedMaxCompletionTokens ?? request.maxTokens ?? completion.generatedCompletionTokens
        let structuredOutputRequested: Bool
        if case .text = request.responseFormat {
            structuredOutputRequested = false
        } else {
            structuredOutputRequested = true
        }
        return [
            "schema": Self.schema,
            "record_type": "request_shape",
            "sequence": sequence,
            "shape_id": String(format: "shape-%06d", sequence),
            "captured_at": Self.iso8601(now),
            "served_model_hash_sha256": snapshot.modelHash ?? "unavailable",
            "served_weights_manifest_sha256": snapshot.weightsManifestSHA256 ?? "unavailable",
            "native_mtp_tuple_sha256": admission.tupleFence?.admissionTupleSHA256 ?? "none",
            "native_mtp_served_snapshot_id_sha256": admission.tupleFence.map { NativeMTPRequestShapeCapture.sha256Hex($0.servedSnapshotID) } ?? "none",
            "native_mtp_target_generation": admission.tupleFence.map { Int($0.targetGeneration) } ?? 0,
            "stream": stream,
            "stop_sequences": request.stop.count,
            "requested_temperature": request.temperature,
            "requested_top_p": request.topP,
            "requested_n": requestedN,
            "requested_max_completion_tokens": request.maxTokens ?? 0,
            "resolved_max_completion_tokens": resolvedMaxCompletionTokens,
            "sampling_requested": request.temperature != 0.0 || request.topP != 1.0,
            "multiple_completions_requested": requestedN != 1,
            "top_k_present": topKPresent,
            "min_p_nonzero": minPNonzero,
            "frequency_penalty_nonzero": request.frequencyPenalty != 0.0,
            "presence_penalty_nonzero": request.presencePenalty != 0.0,
            "repetition_penalty_nondefault": repetitionPenaltyNondefault,
            "logit_bias_present": logitBiasPresent,
            "tools_present": toolsPresent || toolChoicePresent || toolTurnStatePresent,
            "tool_choice_present": toolChoicePresent,
            "tool_turn_state_present": toolTurnStatePresent,
            "structured_output_requested": structuredOutputRequested,
            "response_format_kind": NativeMTPRequestShapeCapture.responseFormatKind(request.responseFormat),
            "logprobs_requested": !NativeMTPRequestShapeCapture.isAbsentNullOrFalse(request.promptSource.logprobs)
                || topLogprobsPresent,
            "top_logprobs_requested": topLogprobsPresent,
            "logit_controls_requested": request.presencePenalty != 0.0
                || request.frequencyPenalty != 0.0
                || logitBiasPresent
                || minPNonzero
                || repetitionPenaltyNondefault,
            "reasoning_or_template_model": HarmonyResponseParser.isHarmonyModelID(request.model),
            "multimodal_requested": request.containsNonTextMessageContentPart,
            "unknown_request_fields_present": unknownTopLevelKeysPresent || unknownStreamOptionKeysPresent,
            "unknown_top_level_keys_present": unknownTopLevelKeysPresent,
            "unknown_stream_option_keys_present": unknownStreamOptionKeysPresent,
            "conversation_key_present": keyPresent,
            "conversation_key_cache_only": keyPresent ? request.conversationCacheOnly : false,
            "conversation_cache_lease": leaseState,
            "conversation_cache_cached_prompt_tokens": cachedPromptTokens,
            "conversation_cache_retained_handoff": retainedHandoff,
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "generated_completion_tokens": completion.generatedCompletionTokens,
            "max_completion_tokens_requested": request.maxTokens ?? 0,
            "resolved_max_completion_tokens": resolvedMaxCompletionTokens,
            "pre_capacity_selector_reason": reason,
            "pre_capacity_eligible": preCapacityEligible,
            "effective_path": admission.effectivePath.rawValue,
        ]
    }

    private func writeLocked(_ payload: [String: Any]) throws -> Bool {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        guard bytesWritten + data.count <= maxBytes else {
            droppedAfterLimit += 1
            return false
        }
        try fileHandle.write(contentsOf: data)
        bytesWritten += data.count
        return true
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
            let currentUID = Int32(getuid())
            guard let owner, owner == currentUID, mode & 0o077 == 0 else {
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

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    private static func responseFormatKind(_ responseFormat: ResponseFormat) -> String {
        switch responseFormat {
        case .text:
            return "text"
        case .jsonObject:
            return "json_object"
        case .jsonSchema(_):
            return "json_schema"
        }
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
    case invalidLimit
}
