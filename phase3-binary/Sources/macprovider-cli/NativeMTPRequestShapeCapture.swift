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
    private let statusURL: URL
    private let statusHandle: FileHandle
    private let sampleWindowStartedAt: Date
    private let sampleMethod = "opt_in_mtp_off_successful_ordinary_completions"
    private let buildIdentityComplete: Bool
    private let anonymousGroupSalt = SymmetricKey(size: .bits256)
    private let maxRecords: Int
    private let maxBytes: Int
    private var attempts = 0
    private var recordsWritten = 0
    private var bytesWritten = 0
    private var skippedIneligible = 0
    private var skippedEmptyCompletion = 0
    private var droppedMissingEffectiveBudget = 0
    private var droppedAfterRecordLimit = 0
    private var droppedAfterByteLimit = 0
    private var jsonlWriteErrors = 0
    private var statusWriteErrors = 0

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
        let captureFileName = Self.fileName(now: now)
        self.fileURL = directory.appendingPathComponent(captureFileName, isDirectory: false)
        self.statusURL = directory.appendingPathComponent("\(captureFileName).status.json", isDirectory: false)
        let directoryFD = try Self.openPrivateDirectory(directory)
        defer { close(directoryFD) }
        self.fileHandle = try Self.openPrivateNewFile(named: captureFileName, directoryFD: directoryFD)
        self.statusHandle = try Self.openPrivateNewFile(named: "\(captureFileName).status.json", directoryFD: directoryFD)
        self.sampleWindowStartedAt = now
        self.buildIdentityComplete = runningBuildIdentity?.sourceCommit != nil && runningBuildIdentity?.liveExecutableCDHash != nil
        self.maxRecords = min(max(1, config.maxRecords), NativeMTPRequestShapeCaptureConfig.hardMaxRecords)
        self.maxBytes = min(max(1024, config.maxBytes), NativeMTPRequestShapeCaptureConfig.hardMaxBytes)

        let header: [String: Any] = [
            "schema": Self.schema,
            "record_type": "header",
            "captured_at": Self.iso8601(now),
            "native_mtp_mode": nativeMTPMode.rawValue,
            "capture_requires_native_mtp_off": true,
            "sample_method": sampleMethod,
            "sample_window_started_at": Self.iso8601(sampleWindowStartedAt),
            "served_identity": "per_record_sha256",
            "build_source_commit": runningBuildIdentity?.sourceCommit ?? "unavailable",
            "build_cdhash": runningBuildIdentity?.liveExecutableCDHash ?? "unavailable",
            "build_identity_complete": buildIdentityComplete,
            "cli_version": CoordinatorClient.binaryVersion,
            "max_records": self.maxRecords,
            "max_bytes": self.maxBytes,
        ]
        _ = try writeLocked(header)
        writeStatusLocked(now: now)
    }

    deinit {
        lock.lock()
        writeStatusLocked(now: Date())
        lock.unlock()
        try? fileHandle.close()
        try? statusHandle.close()
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
        attempts += 1
        defer { writeStatusLocked(now: now) }
        guard admission.effectivePath == .ordinary, admission.selection.nativeMTPReason == .modeOff else {
            skippedIneligible += 1
            return
        }
        guard completion.promptTokens > 0, completion.completionTokens > 0 else {
            skippedEmptyCompletion += 1
            return
        }
        guard let effectiveMaxOutputTokens = resolvedMaxCompletionTokens ?? request.maxTokens, effectiveMaxOutputTokens > 0 else {
            droppedMissingEffectiveBudget += 1
            return
        }
        guard recordsWritten < maxRecords else {
            droppedAfterRecordLimit += 1
            return
        }
        guard bytesWritten < maxBytes else {
            droppedAfterByteLimit += 1
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
            effectiveMaxOutputTokens: effectiveMaxOutputTokens,
            anonymousCacheGroupSHA256: Self.anonymousCacheGroupSHA256(request.conversationKey, salt: anonymousGroupSalt),
            now: now
        )
        do {
            if try writeLocked(payload) {
                recordsWritten = sequence
            }
        } catch {
            jsonlWriteErrors += 1
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
        effectiveMaxOutputTokens: Int,
        anonymousCacheGroupSHA256: String?,
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
        let requestedMaxCompletionTokens: Any = request.maxTokens.map { $0 as Any } ?? NSNull()
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
            "stop_sequence_utf8_lengths": request.stop.map { $0.utf8.count },
            "stop_sequence_utf8_length_buckets": Self.stopLengthBuckets(request.stop),
            "requested_temperature": request.temperature,
            "requested_top_p": request.topP,
            "requested_top_k": Self.jsonNumberOrNull(request.promptSource.topK),
            "requested_min_p": Self.jsonNumberOrNull(request.promptSource.minP),
            "requested_presence_penalty": request.presencePenalty,
            "requested_frequency_penalty": request.frequencyPenalty,
            "requested_repetition_penalty": Self.jsonNumberOrNull(request.promptSource.repetitionPenalty),
            "requested_n": requestedN,
            "requested_max_completion_tokens": requestedMaxCompletionTokens,
            "effective_max_output_tokens": effectiveMaxOutputTokens,
            "sampling_requested": request.temperature != 0.0 || request.topP != 1.0,
            "multiple_completions_requested": requestedN != 1,
            "top_k_present": topKPresent,
            "min_p_nonzero": minPNonzero,
            "frequency_penalty_nonzero": request.frequencyPenalty != 0.0,
            "presence_penalty_nonzero": request.presencePenalty != 0.0,
            "repetition_penalty_nondefault": repetitionPenaltyNondefault,
            "logit_bias_present": logitBiasPresent,
            "logit_bias_geometry": Self.logitBiasGeometry(request.promptSource.logitBias),
            "tools_present": toolsPresent || toolChoicePresent || toolTurnStatePresent,
            "tool_count": Self.arrayCount(request.promptSource.tools),
            "tool_parameter_schema_geometries": Self.toolParameterSchemaGeometries(request.promptSource.tools),
            "tool_choice_present": toolChoicePresent,
            "tool_choice_kind": Self.toolChoiceKind(request.promptSource.toolChoice),
            "tool_turn_state_present": toolTurnStatePresent,
            "tool_message_count": request.messages.filter { $0.role == .tool }.count,
            "assistant_tool_call_count": request.messages.reduce(0) { $0 + ($1.toolCalls?.count ?? 0) },
            "structured_output_requested": structuredOutputRequested,
            "response_format_kind": NativeMTPRequestShapeCapture.responseFormatKind(request.responseFormat),
            "response_schema_geometry": Self.responseSchemaGeometry(request.responseFormat),
            "logprobs_requested": !NativeMTPRequestShapeCapture.isAbsentNullOrFalse(request.promptSource.logprobs)
                || topLogprobsPresent,
            "top_logprobs_requested": topLogprobsPresent,
            "requested_top_logprobs": Self.jsonNumberOrNull(request.promptSource.topLogprobs),
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
            "anonymous_cache_group_sha256": anonymousCacheGroupSHA256 ?? NSNull(),
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "generated_completion_tokens": completion.generatedCompletionTokens,
            "pre_capacity_selector_reason": reason,
            "pre_capacity_eligible": preCapacityEligible,
            "effective_path": admission.effectivePath.rawValue,
        ]
    }

    private func writeLocked(_ payload: [String: Any]) throws -> Bool {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        guard bytesWritten + data.count <= maxBytes else {
            droppedAfterByteLimit += 1
            return false
        }
        try fileHandle.write(contentsOf: data)
        bytesWritten += data.count
        return true
    }


    private func writeStatusLocked(now: Date) {
        let payload: [String: Any] = [
            "schema": Self.schema,
            "record_type": "status",
            "updated_at": Self.iso8601(now),
            "sample_method": sampleMethod,
            "sample_window_started_at": Self.iso8601(sampleWindowStartedAt),
            "capture_file_name": fileURL.lastPathComponent,
            "exports_raw_prompt_text": false,
            "exports_recoverable_cache_groups": false,
            "build_identity_complete": buildIdentityComplete,
            "attempts": attempts,
            "successful_records": recordsWritten,
            "skipped_ineligible": skippedIneligible,
            "skipped_empty_completion": skippedEmptyCompletion,
            "dropped_missing_effective_budget": droppedMissingEffectiveBudget,
            "dropped_after_record_limit": droppedAfterRecordLimit,
            "dropped_after_byte_limit": droppedAfterByteLimit,
            "jsonl_write_errors": jsonlWriteErrors,
            "status_write_errors": statusWriteErrors,
            "max_records": maxRecords,
            "max_bytes": maxBytes,
            "jsonl_bytes_written": bytesWritten,
            "jsonl_record_limit_reached": recordsWritten >= maxRecords,
            "jsonl_byte_limit_reached": bytesWritten >= maxBytes,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try statusHandle.seek(toOffset: 0)
            try statusHandle.truncate(atOffset: 0)
            try statusHandle.write(contentsOf: data)
            try statusHandle.write(contentsOf: Data([0x0a]))
            try statusHandle.synchronize()
        } catch {
            statusWriteErrors += 1
        }
    }

    private static func prepareDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        try validatePrivateDirectory(parent)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NativeMTPRequestShapeCaptureError.directoryNotDirectory
            }
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
                throw NativeMTPRequestShapeCaptureError.unsafeDirectory
            }
            try validatePrivateDirectory(directory)
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try validatePrivateDirectory(directory)
    }

    private static func anonymousCacheGroupSHA256(_ conversationKey: String?, salt: SymmetricKey) -> String? {
        guard let conversationKey = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !conversationKey.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(conversationKey.utf8), using: salt)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePrivateDirectory(_ directory: URL) throws {
        var statbuf = stat()
        guard lstat(directory.path, &statbuf) == 0 else {
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        guard (statbuf.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeMTPRequestShapeCaptureError.directoryNotDirectory
        }
        guard statbuf.st_uid == getuid(), statbuf.st_mode & 0o077 == 0 else {
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
    }

    private static func openPrivateDirectory(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        var statbuf = stat()
        guard fstat(fd, &statbuf) == 0,
              (statbuf.st_mode & S_IFMT) == S_IFDIR,
              statbuf.st_uid == getuid(),
              statbuf.st_mode & 0o077 == 0 else {
            close(fd)
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        return fd
    }

    private static func openPrivateNewFile(named name: String, directoryFD: Int32) throws -> FileHandle {
        guard !name.contains("/") else {
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw NativeMTPRequestShapeCaptureError.outputFileExists }
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        if fchmod(fd, S_IRUSR | S_IWUSR) != 0 {
            close(fd)
            throw NativeMTPRequestShapeCaptureError.unsafeDirectory
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
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

    private static func jsonNumberOrNull(_ value: JSONValue?) -> Any {
        switch value {
        case .int(let int): return int
        case .double(let double): return double
        default: return NSNull()
        }
    }

    private static func arrayCount(_ value: JSONValue?) -> Int {
        guard case .array(let entries)? = value else { return 0 }
        return entries.count
    }

    private static func toolParameterSchemaGeometries(_ value: JSONValue?) -> [[String: Any]] {
        guard case .array(let tools)? = value else { return [] }
        return tools.map { tool in
            guard case .object(let toolObject) = tool,
                  case .object(let functionObject)? = toolObject["function"],
                  let parameters = functionObject["parameters"] else {
                return jsonGeometry(.object([:]))
            }
            return jsonGeometry(parameters)
        }
    }

    private static func jsonGeometry(_ value: JSONValue) -> [String: Any] {
        [
            "byte_count": (try? value.deterministicJSONString().utf8.count) ?? 0,
            "max_depth": jsonContainerDepth(value),
            "object_count": jsonObjectCount(value),
            "array_count": jsonArrayCount(value),
            "property_count": jsonSchemaPropertyCount(value),
        ]
    }

    private static func toolChoiceKind(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null:
            return "absent"
        case .string(let string):
            switch string {
            case "none", "auto", "required": return string
            default: return "string_other"
            }
        case .object(let object):
            if case .string(let type)? = object["type"], type == "function" {
                return "function"
            }
            return "object_other"
        default:
            return "other"
        }
    }

    private static func stopLengthBuckets(_ stops: [String]) -> [String: Int] {
        stops.reduce(into: [:]) { result, stop in
            result[byteLengthBucket(stop.utf8.count), default: 0] += 1
        }
    }

    private static func byteLengthBucket(_ count: Int) -> String {
        switch count {
        case 0: return "0"
        case 1...4: return "1_4"
        case 5...16: return "5_16"
        case 17...64: return "17_64"
        default: return "65_plus"
        }
    }

    private static func logitBiasGeometry(_ value: JSONValue?) -> [String: Any] {
        guard case .object(let object)? = value else {
            return [
                "entry_count": 0,
                "positive_count": 0,
                "negative_count": 0,
                "zero_count": 0,
                "min_value": NSNull(),
                "max_value": NSNull(),
                "max_abs_bucket": "none",
            ]
        }
        var values: [Double] = []
        for item in object.values {
            switch item {
            case .int(let int): values.append(Double(int))
            case .double(let double): values.append(double)
            default: continue
            }
        }
        let maxAbs = values.map { abs($0) }.max()
        let minValue: Any = values.min().map { $0 as Any } ?? NSNull()
        let maxValue: Any = values.max().map { $0 as Any } ?? NSNull()
        return [
            "entry_count": object.count,
            "numeric_value_count": values.count,
            "positive_count": values.filter { $0 > 0 }.count,
            "negative_count": values.filter { $0 < 0 }.count,
            "zero_count": values.filter { $0 == 0 }.count,
            "min_value": minValue,
            "max_value": maxValue,
            "max_abs_bucket": maxAbs.map(logitBiasMagnitudeBucket) ?? "none",
        ]
    }

    private static func logitBiasMagnitudeBucket(_ value: Double) -> String {
        switch value {
        case 0: return "0"
        case 0..<1: return "lt_1"
        case 1..<5: return "1_5"
        case 5..<20: return "5_20"
        default: return "20_plus"
        }
    }

    private static func responseSchemaGeometry(_ responseFormat: ResponseFormat) -> [String: Any] {
        guard case .jsonSchema(let spec) = responseFormat else {
            return [
                "byte_count": 0,
                "max_depth": 0,
                "object_count": 0,
                "array_count": 0,
                "property_count": 0,
            ]
        }
        return jsonGeometry(spec.schema)
    }

    private static func jsonContainerDepth(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            return 1 + (object.values.map(jsonContainerDepth).max() ?? 0)
        case .array(let array):
            return 1 + (array.map(jsonContainerDepth).max() ?? 0)
        default:
            return 0
        }
    }

    private static func jsonObjectCount(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object): return 1 + object.values.reduce(0) { $0 + jsonObjectCount($1) }
        case .array(let array): return array.reduce(0) { $0 + jsonObjectCount($1) }
        default: return 0
        }
    }

    private static func jsonArrayCount(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object): return object.values.reduce(0) { $0 + jsonArrayCount($1) }
        case .array(let array): return 1 + array.reduce(0) { $0 + jsonArrayCount($1) }
        default: return 0
        }
    }

    private static func jsonSchemaPropertyCount(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            let here: Int
            if case .object(let properties)? = object["properties"] {
                here = properties.count
            } else {
                here = 0
            }
            return here + object.values.reduce(0) { $0 + jsonSchemaPropertyCount($1) }
        case .array(let array):
            return array.reduce(0) { $0 + jsonSchemaPropertyCount($1) }
        default:
            return 0
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
