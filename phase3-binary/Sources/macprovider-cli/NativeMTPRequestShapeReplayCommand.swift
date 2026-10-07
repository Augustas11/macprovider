import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import MLXLMCommon

#if DEBUG || MACPROVIDER_LAB_HARNESS
struct NativeMTPRequestShapeReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-request-shape-replay",
        abstract: "Run the hidden LAB-only native-MTP mixed request-shape replay.",
        shouldDisplay: false
    )

    @Option(name: .customLong("root"), help: "Fixture root containing target/ and mtp/ snapshot directories.")
    var root: String

    @Option(name: .customLong("capture"), help: "Privacy-reviewed request-shape capture JSONL.")
    var capturePath: String

    @Option(name: .customLong("policy"), help: "Frozen preregistration policy JSON.")
    var policyPath: String

    @Option(name: .customLong("out"), help: "Output JSONL path.")
    var outPath: String

    @Option(name: .customLong("provider-commit"), help: "Provider git commit for the header.")
    var providerCommit: String

    @Option(name: .customLong("blocks"), help: "Paired counterbalanced blocks to run.")
    var blocks: Int = 10

    @Option(name: .customLong("model-id"), help: "Model ID bound into requests/runtime.")
    var modelID: String = nativeMTPHardwareDefaultModelID

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data("native-mtp-request-shape-replay: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8))
            throw ExitCode(2)
        }
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        guard providerCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ValidationError("--provider-commit must be lowercase 40-hex")
        }
        guard blocks >= 10 else {
            throw ValidationError("--blocks must be >= 10 for R015 replay evidence")
        }

        let runner = try NativeMTPRequestShapeReplayRunner(
            rootPath: root,
            capturePath: capturePath,
            policyPath: policyPath,
            outPath: outPath,
            providerCommit: providerCommit,
            blocks: blocks,
            modelID: modelID
        )
        try await runner.run()
    }
}

final class NativeMTPRequestShapeReplayRunner {
    static let schema = "macprovider.native-mtp-request-shape-replay.v1"

    private let root: URL
    private let captureURL: URL
    private let policyURL: URL
    private let outURL: URL
    private let providerCommit: String
    private let blocks: Int
    private let modelID: String
    private let capture: NativeMTPRequestShapeReplayCapture
    private let policy: NativeMTPBenchPolicy
    private let captureSHA256: String
    private let policySHA256: String

    init(
        rootPath: String,
        capturePath: String,
        policyPath: String,
        outPath: String,
        providerCommit: String,
        blocks: Int,
        modelID: String
    ) throws {
        self.root = URL(fileURLWithPath: ConfigLoader.expandTilde(rootPath), isDirectory: true).standardizedFileURL
        self.captureURL = URL(fileURLWithPath: ConfigLoader.expandTilde(capturePath)).standardizedFileURL
        self.policyURL = URL(fileURLWithPath: ConfigLoader.expandTilde(policyPath)).standardizedFileURL
        self.outURL = URL(fileURLWithPath: ConfigLoader.expandTilde(outPath)).standardizedFileURL
        self.providerCommit = providerCommit
        self.blocks = blocks
        self.modelID = modelID
        self.captureSHA256 = try Self.sha256(of: self.captureURL)
        self.policySHA256 = try Self.sha256(of: self.policyURL)
        self.capture = try NativeMTPRequestShapeReplayCapture.load(from: self.captureURL)
        self.policy = try NativeMTPBenchPolicy.load(from: self.policyURL)
    }

    func run() async throws {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try Self.requireDirectory(targetDirectory)
        try Self.requireDirectory(mtpDirectory)
        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try Self.sha256(of: targetDirectory.appendingPathComponent("tokenizer.json"))
        try policy.validateObserved(
            modelID: modelID,
            targetSHA256: targetIdentity.digest,
            mtpSHA256: mtpIdentity.digest,
            tokenizerSHA256: tokenizerSHA
        )
        try policy.validateObserved(environment: NativeMTPBenchEnvironment.capture(providerCommit: providerCommit))

        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let writer = try NativeMTPRequestShapeReplayWriter(url: outURL)
        defer { try? writer.close() }
        try writer.write(header(targetIdentity: targetIdentity, mtpIdentity: mtpIdentity, tokenizerSHA256: tokenizerSHA))

        let plan = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture,
            blocks: blocks,
            seed: policy.seed
        )
        if let pending = plan.pendingReason {
            try writer.write(pendingRecord(reason: pending, plan: plan))
            return
        }

        let fixture = try await loadFixture(maxPromptTokens: plan.promptTokenTarget, maxCompletionTokens: plan.maxCompletionTokens)
        for block in plan.blocks {
            let ordinary = try await runPath(
                .ordinary,
                block: block,
                runtime: fixture.runtimes.ordinary,
                fixture: fixture
            )
            let native = try await runPath(
                .nativeMTP,
                block: block,
                runtime: fixture.runtimes.native,
                fixture: fixture
            )
            try writer.write(ordinary.record(policySHA256: policySHA256, captureSHA256: captureSHA256))
            try writer.write(native.record(policySHA256: policySHA256, captureSHA256: captureSHA256))
        }
    }

    private func loadFixture(maxPromptTokens: Int, maxCompletionTokens: Int) async throws -> NativeMTPHardwareRuntimeFixture {
        let maxBlocks = NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
            slots: NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            promptTokens: maxPromptTokens,
            outputTokens: maxCompletionTokens
        )
        let runner = NativeMTPHardwareE2ERunner(
            rootPath: root.path,
            modelID: modelID,
            maxBatch: NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            maxNativeActiveRows: NativeMTPRequestShapeReplayPlan.maxNativeActiveRows,
            maxPromptTokens: policy.maximumPromptTokens ?? 1_048_576,
            maxPhysicalBlocks: maxBlocks
        )
        return try await runner.loadRuntimeFixture(
            maxContextTokens: maxPromptTokens + maxCompletionTokens + 256,
            ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder(),
            nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder()
        )
    }

    private func runPath(
        _ path: NativeMTPRequestShapeReplayPath,
        block: NativeMTPRequestShapeReplayBlock,
        runtime: ModelRuntime,
        fixture: NativeMTPHardwareRuntimeFixture
    ) async throws -> NativeMTPRequestShapeReplayRunResult {
        let started = Date()
        let requests = try await makeRequests(block: block, runtime: runtime)
        let results = try await withThrowingTaskGroup(of: NativeMTPRequestShapeReplayRequestResult.self) { group in
            for request in requests {
                group.addTask {
                    try await Self.runStreamingRequest(request, runtime: runtime)
                }
            }
            var values: [NativeMTPRequestShapeReplayRequestResult] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted { $0.requestID < $1.requestID }
        }
        let ended = Date()
        let resultIDs = Set(results.map(\.requestID))
        let admissions: [NativeMTPHardwareAdmissionRecorder.RequestAdmission]
        switch path {
        case .ordinary:
            admissions = fixture.ordinaryAdmissionRecorder?.requestSnapshot().filter { admission in
                admission.requestID.map { resultIDs.contains($0) } ?? false
            } ?? []
        case .nativeMTP:
            admissions = fixture.nativeAdmissionRecorder?.requestSnapshot().filter { admission in
                admission.requestID.map { resultIDs.contains($0) } ?? false
            } ?? []
        }
        let observedRows = results.filter { result in
            block.rows.contains { $0.requestID == result.requestID && $0.metricsClass == .ordinaryBaseline }
        }
        let observedWall = max(observedRows.map { $0.endedAt }.max()?.timeIntervalSince(started) ?? ended.timeIntervalSince(started), 0.000_001)
        let observedCompletion = observedRows.reduce(0) { $0 + $1.completion.completionTokens }
        let allCompletion = results.reduce(0) { $0 + $1.completion.completionTokens }
        let allWall = max(ended.timeIntervalSince(started), 0.000_001)
        let admittedIDs = Set(admissions.compactMap(\.requestID))
        let missingAdmissionIDs = results.map(\.requestID).filter { !admittedIDs.contains($0) }
        return NativeMTPRequestShapeReplayRunResult(
            blockIndex: block.index,
            path: path,
            orderPosition: block.orderPosition(for: path),
            wallSeconds: allWall,
            requests: results,
            ordinaryObservedRequests: observedRows.count,
            ordinaryObservedCompletionTokens: observedCompletion,
            ordinaryObservedThroughputTPS: Double(observedCompletion) / observedWall,
            aggregateCompletionTokens: allCompletion,
            aggregateThroughputTPS: Double(allCompletion) / allWall,
            admissions: admissions,
            missingAdmissionRequestIDs: missingAdmissionIDs
        )
    }

    private func makeRequests(block: NativeMTPRequestShapeReplayBlock, runtime: ModelRuntime) async throws -> [ChatCompletionRequest] {
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            throw NativeMTPRequestShapeReplayError.assertionFailed("runtime has no loaded container")
        }
        let thinkingToggle = snapshot.templateSupportsThinkingToggle
        let preserveThinking = snapshot.templateSupportsPreserveThinking
        let modelID = self.modelID
        return try await container.perform { context in
            var requests: [ChatCompletionRequest] = []
            for row in block.rows {
                let prompt = try await Self.syntheticPrompt(
                    requestID: row.requestID,
                    targetTokens: row.promptTokens,
                    modelID: modelID,
                    maxTokens: row.maxCompletionTokens,
                    temperature: row.temperature,
                    topP: row.topP,
                    context: context,
                    thinkingToggle: thinkingToggle,
                    preserveThinking: preserveThinking
                )
                var request = try Self.makeRequest(
                    modelID: modelID,
                    requestID: row.requestID,
                    prompt: prompt,
                    maxTokens: row.maxCompletionTokens,
                    temperature: row.temperature,
                    topP: row.topP
                )
                if let anonymousGroup = row.anonymousCacheGroupSHA256 {
                    request = request.withConversationKey("lab-cache-\(anonymousGroup)", cacheOnly: row.conversationCacheOnly)
                }
                requests.append(request)
            }
            return requests
        }
    }

    private func header(
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        tokenizerSHA256: String
    ) -> [String: Any] {
        [
            "schema": Self.schema,
            "record_type": "header",
            "provider_commit": providerCommit,
            "model_id": modelID,
            "target_sha256": targetIdentity.digest,
            "mtp_sha256": mtpIdentity.digest,
            "tokenizer_sha256": tokenizerSHA256,
            "policy_sha256": policySHA256,
            "capture_sha256": captureSHA256,
            "capture_schema": capture.header.schema,
            "capture_requires_native_mtp_off": capture.header.captureRequiresNativeMTPOff,
            "run_order": "paired_random_counterbalanced",
            "mixed_rows": NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            "max_native_active_rows": NativeMTPRequestShapeReplayPlan.maxNativeActiveRows,
            "exports_raw_prompt_text": false,
            "exports_recoverable_cache_groups": false,
            "run_metrics_version": 1,
            "request_shapes": capture.shapes.map(\.sanitizedExport),
        ]
    }

    private func pendingRecord(reason: String, plan: NativeMTPRequestShapeReplayPlan) -> [String: Any] {
        [
            "schema": Self.schema,
            "record_type": "pending",
            "status": "pending",
            "pending_reason": reason,
            "policy_sha256": policySHA256,
            "capture_sha256": captureSHA256,
            "projected_request_count_per_block": plan.rowsPerBlock,
            "blocks": blocks,
            "qualified_slots": NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            "max_native_active_rows": NativeMTPRequestShapeReplayPlan.maxNativeActiveRows,
            "request_shapes": capture.shapes.map(\.sanitizedExport),
        ]
    }

    private static func syntheticPrompt(
        requestID: String,
        targetTokens: Int,
        modelID: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        context: ModelContext,
        thinkingToggle: Bool,
        preserveThinking: Bool
    ) async throws -> String {
        func servedCount(_ text: String) async throws -> Int {
            let request = try makeRequest(
                modelID: modelID,
                requestID: requestID,
                prompt: text,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP
            )
            let input = try ModelRuntime.userInput(
                for: request,
                templateSupportsThinkingToggle: thinkingToggle,
                templateSupportsPreserveThinking: preserveThinking
            )
            return try await context.processor.prepare(input: input).text.tokens.size
        }
        var text = "Native MTP R015 mixed replay synthetic prompt \(requestID)."
        var count = try await servedCount(text)
        var salt = 0
        while count < targetTokens {
            text += " replay-\(requestID)-\(salt) deterministic synthetic tokens"
            count = try await servedCount(text)
            salt += 1
        }
        guard count == targetTokens else {
            throw NativeMTPRequestShapeReplayError.pending(
                "synthetic_prompt_token_count_unavailable:\(requestID):wanted_\(targetTokens):got_\(count)"
            )
        }
        return text
    }

    private static func makeRequest(
        modelID: String,
        requestID: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double
    ) throws -> ChatCompletionRequest {
        let object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": topP,
            "stream": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(requestID)
    }

    private static func runStreamingRequest(
        _ request: ChatCompletionRequest,
        runtime: ModelRuntime
    ) async throws -> NativeMTPRequestShapeReplayRequestResult {
        guard let requestID = request.requestID else {
            throw NativeMTPRequestShapeReplayError.assertionFailed("request missing id")
        }
        let started = Date()
        let handle = try await runtime.acquireRequestHandle(request)
        let chunks = NativeMTPReplayChunkRecorder()
        let completion: CompletionResult
        do {
            completion = try await runtime.stream(request, with: handle) { chunk in
                if case .content(let text) = chunk, !text.isEmpty {
                    chunks.append(Date())
                }
            }
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await runtime.unregisterInFlight(handle.registrationID)
        return NativeMTPRequestShapeReplayRequestResult(
            requestID: requestID,
            startedAt: started,
            endedAt: Date(),
            completion: completion,
            chunkTimes: chunks.snapshot()
        )
    }

    private static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeMTPRequestShapeReplayError.missingDirectory(url.path)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeMTPRequestShapeReplayCapture {
    let header: NativeMTPRequestShapeReplayHeader
    let shapes: [NativeMTPRequestShapeReplayShape]

    static func load(from url: URL) throws -> NativeMTPRequestShapeReplayCapture {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("empty capture")
        }
        var header: NativeMTPRequestShapeReplayHeader?
        var shapes: [NativeMTPRequestShapeReplayShape] = []
        for (offset, line) in lines.enumerated() {
            let lineData = Data(line.utf8)
            try NativeMTPBenchJSON.rejectDuplicateKeys(lineData, label: "capture line \(offset + 1)")
            guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                throw NativeMTPRequestShapeReplayError.invalidCapture("line \(offset + 1) is not a JSON object")
            }
            try rejectRawMaterial(object, path: "line \(offset + 1)")
            switch object["record_type"] as? String {
            case "header":
                guard offset == 0, Data(first.utf8) == lineData else {
                    throw NativeMTPRequestShapeReplayError.invalidCapture("header must be first")
                }
                header = try NativeMTPRequestShapeReplayHeader(object)
            case "request_shape":
                shapes.append(try NativeMTPRequestShapeReplayShape(object))
            default:
                throw NativeMTPRequestShapeReplayError.invalidCapture("unknown record_type on line \(offset + 1)")
            }
        }
        guard let header else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing header")
        }
        guard header.nativeMTPMode == "off", header.captureRequiresNativeMTPOff else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("capture must be recorded with native_mtp_mode off")
        }
        guard !shapes.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("capture has no request_shape records")
        }
        return NativeMTPRequestShapeReplayCapture(header: header, shapes: shapes)
    }

    private static func rejectRawMaterial(_ value: Any, path: String) throws {
        let rawKeys: Set<String> = [
            "prompt", "messages", "input", "inputs", "conversation_key", "cache_group",
            "request_id", "id", "user", "authorization", "api_key",
        ]
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                if rawKeys.contains(key) {
                    throw NativeMTPRequestShapeReplayError.invalidCapture("raw_or_recoverable_field:\(path).\(key)")
                }
                try rejectRawMaterial(nested, path: "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try rejectRawMaterial(nested, path: "\(path)[\(index)]")
            }
        }
    }
}

struct NativeMTPRequestShapeReplayHeader {
    let schema: String
    let nativeMTPMode: String
    let captureRequiresNativeMTPOff: Bool

    init(_ object: [String: Any]) throws {
        self.schema = try Self.string(object, "schema")
        self.nativeMTPMode = try Self.string(object, "native_mtp_mode")
        self.captureRequiresNativeMTPOff = try Self.bool(object, "capture_requires_native_mtp_off")
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing string \(key)")
        }
        return value
    }

    private static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? Bool else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing bool \(key)")
        }
        return value
    }
}

struct NativeMTPRequestShapeReplayShape {
    let shapeID: String
    let stream: Bool
    let temperature: Double
    let topP: Double
    let requestedMaxCompletionTokens: Int
    let maxCompletionTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let generatedCompletionTokens: Int
    let preCapacitySelectorReason: String
    let preCapacityEligible: Bool
    let effectivePath: String
    let conversationKeyPresent: Bool
    let conversationCacheOnly: Bool
    let conversationCacheLease: String
    let conversationCacheCachedPromptTokens: Int
    let conversationCacheRetainedHandoff: Bool
    let anonymousCacheGroupSHA256: String?
    let features: [String: Any]

    init(_ object: [String: Any]) throws {
        guard object["schema"] as? String == NativeMTPRequestShapeCapture.schema else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("bad request_shape schema")
        }
        self.shapeID = try Self.string(object, "shape_id")
        self.stream = try Self.bool(object, "stream")
        self.temperature = try Self.double(object, "requested_temperature")
        self.topP = try Self.double(object, "requested_top_p")
        self.requestedMaxCompletionTokens = try Self.nonnegativeInt(object, "requested_max_completion_tokens")
        self.maxCompletionTokens = try Self.positiveInt(object, "resolved_max_completion_tokens")
        self.promptTokens = try Self.positiveInt(object, "prompt_tokens")
        self.completionTokens = try Self.nonnegativeInt(object, "completion_tokens")
        self.generatedCompletionTokens = try Self.nonnegativeInt(object, "generated_completion_tokens")
        self.preCapacitySelectorReason = try Self.string(object, "pre_capacity_selector_reason")
        self.preCapacityEligible = try Self.bool(object, "pre_capacity_eligible")
        self.effectivePath = try Self.string(object, "effective_path")
        self.conversationKeyPresent = try Self.bool(object, "conversation_key_present")
        self.conversationCacheOnly = try Self.bool(object, "conversation_key_cache_only")
        self.conversationCacheLease = try Self.string(object, "conversation_cache_lease")
        self.conversationCacheCachedPromptTokens = try Self.nonnegativeInt(object, "conversation_cache_cached_prompt_tokens")
        self.conversationCacheRetainedHandoff = try Self.bool(object, "conversation_cache_retained_handoff")
        self.anonymousCacheGroupSHA256 = try Self.optionalHex64(object, "anonymous_cache_group_sha256")
        self.features = Self.sanitizedFeatures(object)
    }

    var metricsClass: NativeMTPRequestShapeReplayMetricsClass {
        preCapacityEligible ? .ordinaryBaseline : .mixedIneligible
    }

    var sanitizedExport: [String: Any] {
        [
            "shape_id": shapeID,
            "stream": stream,
            "requested_temperature": temperature,
            "requested_top_p": topP,
            "requested_max_completion_tokens": requestedMaxCompletionTokens,
            "resolved_max_completion_tokens": maxCompletionTokens,
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "generated_completion_tokens": generatedCompletionTokens,
            "pre_capacity_selector_reason": preCapacitySelectorReason,
            "pre_capacity_eligible": preCapacityEligible,
            "effective_path": effectivePath,
            "conversation_key_present": conversationKeyPresent,
            "conversation_key_cache_only": conversationCacheOnly,
            "conversation_cache_lease": conversationCacheLease,
            "conversation_cache_cached_prompt_tokens": conversationCacheCachedPromptTokens,
            "conversation_cache_retained_handoff": conversationCacheRetainedHandoff,
            "anonymous_cache_group_sha256": anonymousCacheGroupSHA256 as Any,
        ]
    }

    private static func sanitizedFeatures(_ object: [String: Any]) -> [String: Any] {
        let keys = [
            "stop_sequences", "sampling_requested", "multiple_completions_requested",
            "top_k_present", "min_p_nonzero", "frequency_penalty_nonzero",
            "presence_penalty_nonzero", "repetition_penalty_nondefault",
            "logit_bias_present", "tools_present", "tool_choice_present",
            "tool_turn_state_present", "structured_output_requested", "response_format_kind",
            "logprobs_requested", "top_logprobs_requested", "logit_controls_requested",
            "reasoning_or_template_model", "multimodal_requested",
            "unknown_request_fields_present", "unknown_top_level_keys_present",
            "unknown_stream_option_keys_present",
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = object[key] { result[key] = value }
        }
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing string \(key)")
        }
        return value
    }

    private static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? Bool else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing bool \(key)")
        }
        return value
    }

    private static func double(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = object[key] as? NSNumber else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing number \(key)")
        }
        return value.doubleValue
    }

    private static func positiveInt(_ object: [String: Any], _ key: String) throws -> Int {
        let value = try nonnegativeInt(object, key)
        guard value > 0 else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be > 0")
        }
        return value
    }

    private static func nonnegativeInt(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing int \(key)")
        }
        let int = value.intValue
        guard int >= 0, Double(int) == value.doubleValue else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be a nonnegative integer")
        }
        return int
    }

    private static func optionalHex64(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value as? String,
              string.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be lowercase 64-hex")
        }
        return string
    }
}

struct NativeMTPRequestShapeReplayPlan {
    static let qualifiedSlots = 8
    static let maxNativeActiveRows = 1

    let blocks: [NativeMTPRequestShapeReplayBlock]
    let pendingReason: String?
    let promptTokenTarget: Int
    let requestedMaxCompletionTokens: Int
    let maxCompletionTokens: Int
    var rowsPerBlock: Int { blocks.first?.rows.count ?? 0 }

    static func make(
        capture: NativeMTPRequestShapeReplayCapture,
        blocks: Int,
        seed: Int
    ) throws -> NativeMTPRequestShapeReplayPlan {
        let rows = try projectedRows(capture.shapes)
        let promptTarget = rows.map(\.promptTokens).max() ?? NativeMTPBenchPolicy.gatedPromptTokens
        let maxCompletion = rows.map(\.maxCompletionTokens).max() ?? NativeMTPBenchPolicy.gatedMaxTokens
        let cell = NativeMTPBenchCell(
            slots: qualifiedSlots,
            promptTokens: NativeMTPBenchPolicy.gatedPromptTokens,
            maxTokens: NativeMTPBenchPolicy.gatedMaxTokens
        )
        let nativeFirst = NativeMTPBenchPolicy.nativeFirstOrder(seed: seed, cell: cell, blocks: blocks)
        let plannedBlocks = (0..<blocks).map { index in
            NativeMTPRequestShapeReplayBlock(
                index: index,
                nativeFirst: nativeFirst[index],
                rows: rows.map { $0.withBlock(index) }
            )
        }
        let pending = rows.compactMap(\.pendingReason).first
        return NativeMTPRequestShapeReplayPlan(
            blocks: plannedBlocks,
            pendingReason: pending,
            promptTokenTarget: promptTarget,
            maxCompletionTokens: maxCompletion
        )
    }

    private static func projectedRows(_ shapes: [NativeMTPRequestShapeReplayShape]) throws -> [NativeMTPRequestShapeReplayRow] {
        guard !shapes.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("no shapes to replay")
        }
        let expanded = shapes.enumerated().map { index, shape in
            NativeMTPRequestShapeReplayRow(shape: shape, captureIndex: index, blockIndex: 0)
        }
        guard expanded.count <= qualifiedSlots else {
            return Array(expanded.prefix(qualifiedSlots))
        }
        var rows = expanded
        var index = 0
        while rows.count < qualifiedSlots {
            rows.append(NativeMTPRequestShapeReplayRow(
                shape: shapes[index % shapes.count],
                captureIndex: rows.count,
                blockIndex: 0
            ))
            index += 1
        }
        return rows
    }
}

struct NativeMTPRequestShapeReplayBlock {
    let index: Int
    let nativeFirst: Bool
    let rows: [NativeMTPRequestShapeReplayRow]

    func orderPosition(for path: NativeMTPRequestShapeReplayPath) -> Int {
        switch (nativeFirst, path) {
        case (true, .nativeMTP), (false, .ordinary): return 0
        case (true, .ordinary), (false, .nativeMTP): return 1
        }
    }
}

struct NativeMTPRequestShapeReplayRow {
    let shapeID: String
    let captureIndex: Int
    let blockIndex: Int
    let requestID: String
    let promptTokens: Int
    let requestedMaxCompletionTokens: Int
    let maxCompletionTokens: Int
    let temperature: Double
    let topP: Double
    let conversationCacheOnly: Bool
    let anonymousCacheGroupSHA256: String?
    let requiresCacheProof: Bool
    let pendingReason: String?
    let metricsClass: NativeMTPRequestShapeReplayMetricsClass
    let exportedShape: [String: Any]

    init(shape: NativeMTPRequestShapeReplayShape, captureIndex: Int, blockIndex: Int) {
        self.shapeID = shape.shapeID
        self.captureIndex = captureIndex
        self.blockIndex = blockIndex
        self.requestID = "mixed-b\(blockIndex)-r\(captureIndex)-\(shape.shapeID)"
        self.promptTokens = shape.promptTokens
        self.maxCompletionTokens = max(1, shape.maxCompletionTokens)
        self.temperature = shape.temperature
        self.topP = shape.topP
        self.conversationCacheOnly = shape.conversationCacheOnly
        self.anonymousCacheGroupSHA256 = shape.anonymousCacheGroupSHA256
        self.requiresCacheProof = shape.conversationKeyPresent
        if shape.conversationKeyPresent && shape.anonymousCacheGroupSHA256 == nil {
            self.pendingReason = "cache_shape_missing_anonymous_group:\(shape.shapeID)"
        } else if shape.conversationCacheLease == "hit"
                    || shape.conversationCacheCachedPromptTokens > 0
                    || shape.conversationCacheRetainedHandoff {
            self.pendingReason = "cache_hit_replay_requires_runtime_warmup_proof:\(shape.shapeID)"
        } else {
            self.pendingReason = nil
        }
        self.metricsClass = shape.metricsClass
        self.exportedShape = shape.sanitizedExport
    }

    func withBlock(_ blockIndex: Int) -> NativeMTPRequestShapeReplayRow {
        NativeMTPRequestShapeReplayRow(
            shapeID: shapeID,
            captureIndex: captureIndex,
            blockIndex: blockIndex,
            requestID: "mixed-b\(blockIndex)-r\(captureIndex)-\(shapeID)",
            promptTokens: promptTokens,
            maxCompletionTokens: maxCompletionTokens,
            temperature: temperature,
            topP: topP,
            conversationCacheOnly: conversationCacheOnly,
            anonymousCacheGroupSHA256: anonymousCacheGroupSHA256,
            requiresCacheProof: requiresCacheProof,
            pendingReason: pendingReason,
            metricsClass: metricsClass,
            exportedShape: exportedShape
        )
    }

    private init(
        shapeID: String,
        captureIndex: Int,
        blockIndex: Int,
        requestID: String,
        promptTokens: Int,
        maxCompletionTokens: Int,
        temperature: Double,
        topP: Double,
        conversationCacheOnly: Bool,
        anonymousCacheGroupSHA256: String?,
        requiresCacheProof: Bool,
        pendingReason: String?,
        metricsClass: NativeMTPRequestShapeReplayMetricsClass,
        exportedShape: [String: Any]
    ) {
        self.shapeID = shapeID
        self.captureIndex = captureIndex
        self.blockIndex = blockIndex
        self.requestID = requestID
        self.promptTokens = promptTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.conversationCacheOnly = conversationCacheOnly
        self.anonymousCacheGroupSHA256 = anonymousCacheGroupSHA256
        self.requiresCacheProof = requiresCacheProof
        self.pendingReason = pendingReason
        self.metricsClass = metricsClass
        self.exportedShape = exportedShape
    }
}

enum NativeMTPRequestShapeReplayMetricsClass {
    case ordinaryBaseline
    case mixedIneligible
}

enum NativeMTPRequestShapeReplayPath: String {
    case ordinary
    case nativeMTP = "native_mtp"
}

struct NativeMTPRequestShapeReplayRequestResult {
    let requestID: String
    let startedAt: Date
    let endedAt: Date
    let completion: CompletionResult
    let chunkTimes: [Date]

    var ttftSeconds: Double? {
        chunkTimes.first?.timeIntervalSince(startedAt)
    }

    var interTokenGaps: [Double] {
        zip(chunkTimes.dropFirst(), chunkTimes).map { $0.timeIntervalSince($1) }
    }
}

struct NativeMTPRequestShapeReplayRunResult {
    let blockIndex: Int
    let path: NativeMTPRequestShapeReplayPath
    let orderPosition: Int
    let wallSeconds: Double
    let requests: [NativeMTPRequestShapeReplayRequestResult]
    let ordinaryObservedRequests: Int
    let ordinaryObservedCompletionTokens: Int
    let ordinaryObservedThroughputTPS: Double
    let aggregateCompletionTokens: Int
    let aggregateThroughputTPS: Double
    let admissions: [NativeMTPHardwareAdmissionRecorder.RequestAdmission]
    let missingAdmissionRequestIDs: [String]

    func record(policySHA256: String, captureSHA256: String) -> [String: Any] {
        [
            "schema": NativeMTPRequestShapeReplayRunner.schema,
            "record_type": "run",
            "policy_sha256": policySHA256,
            "capture_sha256": captureSHA256,
            "block_index": blockIndex,
            "path": path.rawValue,
            "order_position": orderPosition,
            "requests": requests.count,
            "wall_seconds": wallSeconds,
            "ordinary_observed_requests": ordinaryObservedRequests,
            "ordinary_observed_completion_tokens": ordinaryObservedCompletionTokens,
            "ordinary_observed_throughput_tps": ordinaryObservedThroughputTPS,
            "aggregate_completion_tokens": aggregateCompletionTokens,
            "aggregate_throughput_tps": aggregateThroughputTPS,
            "admission_observation_complete": missingAdmissionRequestIDs.isEmpty,
            "missing_admission_request_ids": missingAdmissionRequestIDs,
            "completion_tokens_by_request": requests.map { result in
                [
                    "request_id": result.requestID,
                    "completion_tokens": result.completion.completionTokens,
                    "generated_completion_tokens": result.completion.generatedCompletionTokens,
                    "ttft_seconds": result.ttftSeconds as Any,
                    "inter_token_gaps": result.interTokenGaps,
                ] as [String: Any]
            },
            "effective_paths": admissions.map { item in
                [
                    "request_id": item.requestID ?? "",
                    "effective_path": item.admission.effectivePath.rawValue,
                    "selector_reason": item.admission.selection.nativeMTPReason?.rawValue ?? "eligible",
                    "other_active_rows": item.otherActiveRows,
                ] as [String: Any]
            },
        ]
    }
}

final class NativeMTPReplayChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date] = []

    func append(_ date: Date) {
        lock.lock()
        values.append(date)
        lock.unlock()
    }

    func snapshot() -> [Date] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class NativeMTPRequestShapeReplayWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ]) else {
            throw NativeMTPRequestShapeReplayError.assertionFailed("could not create --out")
        }
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ object: [String: Any]) throws {
        let normalized = Self.normalized(object)
        var data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func close() throws {
        try handle.close()
    }

    private static func normalized(_ value: Any) -> Any {
        if isNilOptional(value) {
            return NSNull()
        }
        if let object = value as? [String: Any] {
            return object.mapValues { normalized($0) }
        }
        if let array = value as? [Any] {
            return array.map { normalized($0) }
        }
        return value
    }

    private static func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }
}

enum NativeMTPRequestShapeReplayError: Error, CustomStringConvertible {
    case missingDirectory(String)
    case invalidCapture(String)
    case pending(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .missingDirectory(let path): return "missing directory: \(path)"
        case .invalidCapture(let message): return "invalid capture: \(message)"
        case .pending(let message): return "pending: \(message)"
        case .assertionFailed(let message): return "assertion failed: \(message)"
        }
    }
}
#endif
