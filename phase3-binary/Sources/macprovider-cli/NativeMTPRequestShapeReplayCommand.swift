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

    @Option(name: .customLong("policy"), help: "Frozen post-gateway replay preregistration policy JSON.")
    var policyPath: String

    @Option(name: .customLong("bench-policy"), help: "Frozen Native MTP bench policy JSON for tuple/environment validation.")
    var benchPolicyPath: String

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
            benchPolicyPath: benchPolicyPath,
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
    private let replayPolicyURL: URL
    private let benchPolicyURL: URL
    private let outURL: URL
    private let providerCommit: String
    private let blocks: Int
    private let modelID: String
    private let capture: NativeMTPRequestShapeReplayCapture
    private let replayPolicy: NativeMTPPostGatewayReplayPolicy
    private let benchPolicy: NativeMTPBenchPolicy
    private let captureSHA256: String
    private let policySHA256: String
    private let benchPolicySHA256: String

    init(
        rootPath: String,
        capturePath: String,
        policyPath: String,
        benchPolicyPath: String,
        outPath: String,
        providerCommit: String,
        blocks: Int,
        modelID: String
    ) throws {
        self.root = URL(fileURLWithPath: ConfigLoader.expandTilde(rootPath), isDirectory: true).standardizedFileURL
        self.captureURL = URL(fileURLWithPath: ConfigLoader.expandTilde(capturePath)).standardizedFileURL
        self.replayPolicyURL = URL(fileURLWithPath: ConfigLoader.expandTilde(policyPath)).standardizedFileURL
        self.benchPolicyURL = URL(fileURLWithPath: ConfigLoader.expandTilde(benchPolicyPath)).standardizedFileURL
        self.outURL = URL(fileURLWithPath: ConfigLoader.expandTilde(outPath)).standardizedFileURL
        self.providerCommit = providerCommit
        self.blocks = blocks
        self.modelID = modelID
        self.captureSHA256 = try Self.sha256(of: self.captureURL)
        self.policySHA256 = try Self.sha256(of: self.replayPolicyURL)
        self.benchPolicySHA256 = try Self.sha256(of: self.benchPolicyURL)
        self.capture = try NativeMTPRequestShapeReplayCapture.load(from: self.captureURL)
        self.replayPolicy = try NativeMTPPostGatewayReplayPolicy.load(from: self.replayPolicyURL)
        self.benchPolicy = try NativeMTPBenchPolicy.load(from: self.benchPolicyURL)
    }

    func run() async throws {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let mtpDirectory = root.appendingPathComponent("mtp", isDirectory: true)
        try Self.requireDirectory(targetDirectory)
        try Self.requireDirectory(mtpDirectory)
        let targetIdentity = try MLXSnapshotIdentity.compute(directory: targetDirectory)
        let mtpIdentity = try MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try Self.sha256(of: targetDirectory.appendingPathComponent("tokenizer.json"))
        try benchPolicy.validateObserved(
            modelID: modelID,
            targetSHA256: targetIdentity.digest,
            mtpSHA256: mtpIdentity.digest,
            tokenizerSHA256: tokenizerSHA
        )
        try benchPolicy.validateObserved(environment: NativeMTPBenchEnvironment.capture(providerCommit: providerCommit))

        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let writer = try NativeMTPRequestShapeReplayWriter(url: outURL)
        defer { try? writer.close() }
        let plan = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture,
            blocks: blocks,
            seed: replayPolicy.seed
        )
        let identityMismatches = capture.identityMismatches(targetSHA256: targetIdentity.digest)
        try writer.write(header(targetIdentity: targetIdentity, mtpIdentity: mtpIdentity, tokenizerSHA256: tokenizerSHA))
        if !identityMismatches.isEmpty {
            try writer.write(pendingRecord(reason: "capture_identity_mismatch", plan: plan, identityMismatches: identityMismatches))
            return
        }
        if !plan.sampleCoverageComplete {
            try writer.write(pendingRecord(reason: plan.pendingReason ?? "incomplete_sample_coverage", plan: plan))
            if plan.runnableRowsPerBlock == 0 {
                return
            }
        }

        let fixture = try await loadFixture(maxPromptTokens: plan.promptTokenTarget, maxCompletionTokens: plan.maxCompletionTokens, maxContextTokens: plan.maxContextTokens)
        for block in plan.blocks {
            let paths: [NativeMTPRequestShapeReplayPath] = block.nativeFirst ? [.nativeMTP, .ordinary] : [.ordinary, .nativeMTP]
            for path in paths {
                let runtime = path == .nativeMTP ? fixture.runtimes.native : fixture.runtimes.ordinary
                do {
                    let result = try await runPath(path, block: block, runtime: runtime, fixture: fixture, maxContextTokens: plan.maxContextTokens, sampleCoverageComplete: plan.sampleCoverageComplete)
                    try writer.write(result.record(policySHA256: policySHA256, benchPolicySHA256: benchPolicySHA256, captureSHA256: captureSHA256))
                } catch NativeMTPRequestShapeReplayError.pending(let reason) {
                    try writer.write(pendingRecord(reason: "block_\(block.index)_\(path.rawValue)_pending:\(reason)", plan: plan))
                    return
                }
            }
        }
    }

    private func loadFixture(maxPromptTokens: Int, maxCompletionTokens: Int, maxContextTokens: Int) async throws -> NativeMTPHardwareRuntimeFixture {
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
            maxPromptTokens: benchPolicy.maximumPromptTokens ?? 1_048_576,
            maxPhysicalBlocks: maxBlocks
        )
        return try await runner.loadRuntimeFixture(
            maxContextTokens: maxContextTokens,
            ordinaryAdmissionRecorder: NativeMTPHardwareAdmissionRecorder(),
            nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder()
        )
    }

    private func runPath(
        _ path: NativeMTPRequestShapeReplayPath,
        block: NativeMTPRequestShapeReplayBlock,
        runtime: ModelRuntime,
        fixture: NativeMTPHardwareRuntimeFixture,
        maxContextTokens: Int,
        sampleCoverageComplete: Bool
    ) async throws -> NativeMTPRequestShapeReplayRunResult {
        let started = Date()
        let requests = try await makeRequests(block: block, path: path, runtime: runtime)
        let timingObserver = NativeMTPLabCommittedTokenTimingObserver()
        guard await runtime.installLabNativeMTPCommitTimingObserver(timingObserver) else {
            throw NativeMTPRequestShapeReplayError.pending("committed_token_timing_observer_unavailable:\(path.rawValue)")
        }
        let outputCap = NativeMTPLabDecodeOutputCap(capsByRequestID: Dictionary(
            uniqueKeysWithValues: block.runnableRows.map { ($0.requestID, $0.targetCompletionTokens) }
        ))
        guard await runtime.installLabNativeMTPDecodeOutputCap(outputCap) else {
            _ = await runtime.installLabNativeMTPCommitTimingObserver(nil)
            throw NativeMTPRequestShapeReplayError.pending("decode_output_cap_unavailable:\(path.rawValue)")
        }
        let requestsByID = Dictionary(uniqueKeysWithValues: requests.compactMap { request in
            request.requestID.map { ($0, request) }
        })
        let results: [NativeMTPRequestShapeReplayRequestResult]
        do {
            var waveResults: [NativeMTPRequestShapeReplayRequestResult] = []
            for rowWave in block.runnableWaves {
                let results = try await withThrowingTaskGroup(of: NativeMTPRequestShapeReplayRequestResult.self) { group in
                    for row in rowWave {
                        guard let request = requestsByID[row.requestID] else {
                            throw NativeMTPRequestShapeReplayError.assertionFailed("missing request for \(row.requestID)")
                        }
                        let targetCompletionTokens = block.row(requestID: request.requestID)?.targetCompletionTokens ?? request.maxTokens ?? 0
                        group.addTask {
                            try await Self.runStreamingRequest(
                                request,
                                runtime: runtime,
                                timingObserver: timingObserver,
                                targetCompletionTokens: targetCompletionTokens
                            )
                        }
                    }
                    var values: [NativeMTPRequestShapeReplayRequestResult] = []
                    for try await value in group {
                        values.append(value)
                    }
                    return values
                }
                waveResults.append(contentsOf: results)
            }
            results = waveResults.sorted { $0.requestID < $1.requestID }
        } catch {
            _ = await runtime.installLabNativeMTPDecodeOutputCap(nil)
            _ = await runtime.installLabNativeMTPCommitTimingObserver(nil)
            throw error
        }
        _ = await runtime.installLabNativeMTPDecodeOutputCap(nil)
        _ = await runtime.installLabNativeMTPCommitTimingObserver(nil)
        let ended = Date()
        let timingEvents = Dictionary(grouping: timingObserver.snapshot(), by: \.requestID)
        let timedResults = results.map { result in
            result.withCommitEvents(timingEvents[result.requestID] ?? [])
        }
        let resultIDs = Set(timedResults.map(\.requestID))
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
        let ordinaryAdmissionIDs = Set(admissions.compactMap { admission -> String? in
            guard admission.admission.effectivePath == .ordinary else { return nil }
            return admission.requestID
        })
        let observedRows = timedResults.filter { result in
            ordinaryAdmissionIDs.contains(result.requestID)
        }
        let observedStart = observedRows.map(\.startedAt).min() ?? started
        let observedEnd = observedRows.map(\.endedAt).max() ?? ended
        let observedWall = max(observedEnd.timeIntervalSince(observedStart), 0.000_001)
        let observedCompletion = observedRows.reduce(0) { $0 + $1.completion.completionTokens }
        let allCompletion = timedResults.reduce(0) { $0 + $1.completion.completionTokens }
        let allWall = max(ended.timeIntervalSince(started), 0.000_001)
        let admittedIDs = Set(admissions.compactMap(\.requestID))
        let missingAdmissionIDs = timedResults.map(\.requestID).filter { !admittedIDs.contains($0) }
        let targetMismatchIDs = timedResults.compactMap { result -> String? in
            guard let row = block.row(requestID: result.requestID) else { return result.requestID }
            return result.completion.completionTokens == row.targetCompletionTokens ? nil : result.requestID
        }
        let projections = Self.admissionProjectionRows(
            path: path,
            block: block,
            admissions: admissions,
            requestsByID: requestsByID,
            maxContextTokens: maxContextTokens
        )
        return NativeMTPRequestShapeReplayRunResult(
            blockIndex: block.index,
            path: path,
            orderPosition: block.orderPosition(for: path),
            wallSeconds: allWall,
            requests: timedResults,
            ordinaryObservedRequests: observedRows.count,
            ordinaryObservedCompletionTokens: observedCompletion,
            ordinaryObservedIntervalSeconds: observedWall,
            ordinaryObservedThroughputTPS: Double(observedCompletion) / observedWall,
            aggregateCompletionTokens: allCompletion,
            aggregateThroughputTPS: Double(allCompletion) / allWall,
            admissions: admissions,
            missingAdmissionRequestIDs: missingAdmissionIDs,
            targetMismatchRequestIDs: targetMismatchIDs,
            sampleCoverageComplete: sampleCoverageComplete,
            admissionProjections: projections
        )
    }

    private func makeRequests(
        block: NativeMTPRequestShapeReplayBlock,
        path: NativeMTPRequestShapeReplayPath,
        runtime: ModelRuntime
    ) async throws -> [ChatCompletionRequest] {
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            throw NativeMTPRequestShapeReplayError.assertionFailed("runtime has no loaded container")
        }
        let thinkingToggle = snapshot.templateSupportsThinkingToggle
        let preserveThinking = snapshot.templateSupportsPreserveThinking
        let modelID = self.modelID
        return try await container.perform { context in
            var requests: [ChatCompletionRequest] = []
            for row in block.runnableRows {
                let prompt = try await Self.syntheticPrompt(
                    row: row,
                    modelID: modelID,
                    context: context,
                    thinkingToggle: thinkingToggle,
                    preserveThinking: preserveThinking
                )
                var request = try Self.makeRequest(
                    modelID: modelID,
                    requestID: row.requestID,
                    prompt: prompt,
                    maxTokens: row.requestedMaxCompletionTokens,
                    temperature: row.temperature,
                    topP: row.topP,
                    stream: row.stream
                )
                request = try Self.applySyntheticStandIn(for: row, to: request)
                if let anonymousGroup = row.anonymousCacheGroupSHA256 {
                    let isolatedKey = "lab-cache-b\(block.index)-\(path.rawValue)-\(anonymousGroup)"
                    request = request.withConversationKey(isolatedKey, cacheOnly: row.conversationCacheOnly)
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
            "bench_policy_sha256": benchPolicySHA256,
            "sample_digest_sha256": replayPolicy.sampleDigestSHA256,
            "preregistration_digest_sha256": replayPolicy.preregistrationDigestSHA256,
            "privacy_review_id": replayPolicy.privacyReviewID,
            "capture_sha256": captureSHA256,
            "capture_schema": capture.header.schema,
            "capture_requires_native_mtp_off": capture.header.captureRequiresNativeMTPOff,
            "run_order": "paired_random_counterbalanced",
            "mixed_rows": NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            "max_native_active_rows": NativeMTPRequestShapeReplayPlan.maxNativeActiveRows,
            "cache_key_scope": "paired_block_and_path_isolated",
            "exports_raw_prompt_text": false,
            "exports_recoverable_cache_groups": false,
            "completion_length_binding": "effective_max_output_tokens drives admission; LAB decode output caps bind measured generation to target_completion_tokens without cancellation; exact measured match is required for qualification",
            "target_stop_control": "lab_decode_output_cap_by_request_id",
            "synthetic_stand_ins": NativeMTPReplaySyntheticStandIn.disclosure,
            "run_metrics_version": 1,
            "sample_filter_included_count": capture.shapes.count,
            "sample_filter_excluded_count": 0,
            "request_shapes": capture.shapes.map(\.sanitizedExport),
        ]
    }

    private func pendingRecord(
        reason: String,
        plan: NativeMTPRequestShapeReplayPlan,
        identityMismatches: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "schema": Self.schema,
            "record_type": "pending",
            "status": "pending",
            "pending_reason": reason,
            "policy_sha256": policySHA256,
            "bench_policy_sha256": benchPolicySHA256,
            "capture_sha256": captureSHA256,
            "projected_request_count_per_block": plan.rowsPerBlock,
            "runnable_request_count_per_block": plan.runnableRowsPerBlock,
            "sample_coverage": plan.sampleCoverageExport,
            "identity_mismatches": identityMismatches,
            "blocks": blocks,
            "qualified_slots": NativeMTPRequestShapeReplayPlan.qualifiedSlots,
            "execution_shape": "ordered_waves_max_8_concurrent",
            "max_native_active_rows": NativeMTPRequestShapeReplayPlan.maxNativeActiveRows,
            "cache_key_scope": "paired_block_and_path_isolated",
            "request_shapes": capture.shapes.map(\.sanitizedExport),
        ]
    }

    private static func syntheticPrompt(
        row: NativeMTPRequestShapeReplayRow,
        modelID: String,
        context: ModelContext,
        thinkingToggle: Bool,
        preserveThinking: Bool
    ) async throws -> String {
        func servedCount(_ text: String) async throws -> Int {
            var request = try makeRequest(
                modelID: modelID,
                requestID: row.requestID,
                prompt: text,
                maxTokens: row.requestedMaxCompletionTokens,
                temperature: row.temperature,
                topP: row.topP,
                stream: row.stream
            )
            request = try applySyntheticStandIn(for: row, to: request)
            let input = try ModelRuntime.userInput(
                for: request,
                templateSupportsThinkingToggle: thinkingToggle,
                templateSupportsPreserveThinking: preserveThinking
            )
            return try await context.processor.prepare(input: input).text.tokens.size
        }
        var text = "Native MTP R015 mixed replay synthetic prompt \(row.requestID)."
        var count = try await servedCount(text)
        guard count <= row.promptTokens else {
            throw NativeMTPRequestShapeReplayError.pending(
                "synthetic_prompt_token_count_unavailable:\(row.requestID):wanted_\(row.promptTokens):got_\(count)"
            )
        }
        let fragments = [
            " a", " the", " of", " to", " and", " in", " is", " x", " y", " z",
            " 0", " 1", " 2", " 3", " 4", ".", ",", "\nA", "\nB", " replay"
        ]
        while count < row.promptTokens {
            var best: (fragment: String, count: Int)?
            for fragment in fragments {
                let candidateCount = try await servedCount(text + fragment)
                guard candidateCount > count, candidateCount <= row.promptTokens else { continue }
                if candidateCount == row.promptTokens {
                    best = (fragment, candidateCount)
                    break
                }
                if best == nil || candidateCount > best!.count {
                    best = (fragment, candidateCount)
                }
            }
            guard let selected = best else {
                throw NativeMTPRequestShapeReplayError.pending(
                    "synthetic_prompt_token_count_unavailable:\(row.requestID):wanted_\(row.promptTokens):got_\(count)"
                )
            }
            text += selected.fragment
            count = selected.count
        }
        return text
    }

    static func makeRequest(
        modelID: String,
        requestID: String,
        prompt: String,
        maxTokens: Int?,
        temperature: Double,
        topP: Double,
        stream: Bool = true
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "temperature": temperature,
            "top_p": topP,
            "stream": stream,
        ]
        if let maxTokens {
            object["max_tokens"] = maxTokens
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(requestID)
    }

    static func applySyntheticStandIn(
        for row: NativeMTPRequestShapeReplayRow,
        to request: ChatCompletionRequest
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(Self.messageJSONObject),
            "temperature": row.temperature,
            "top_p": row.topP,
            "stream": row.stream,
        ]
        if let requestedMaxCompletionTokens = row.requestedMaxCompletionTokens {
            object["max_tokens"] = requestedMaxCompletionTokens
        }
        Self.applyCapturedLogitControls(from: row, to: &object)
        if row.boolFeature("structured_output_requested") {
            object["response_format"] = Self.syntheticResponseFormat(for: row)
        }
        if row.boolFeature("tools_present") || row.boolFeature("tool_choice_present") || row.boolFeature("tool_turn_state_present") {
            object["tools"] = Self.syntheticTools(for: row)
            object["messages"] = Self.syntheticMessages(for: row, request: request)
            if row.boolFeature("tool_choice_present") {
                object["tool_choice"] = Self.syntheticToolChoice(for: row)
            }
        }
        if row.boolFeature("logprobs_requested") || row.boolFeature("top_logprobs_requested") {
            object["logprobs"] = true
            if row.boolFeature("top_logprobs_requested"), let value = row.jsonFeature("requested_top_logprobs") {
                object["top_logprobs"] = value
            }
        }
        if row.intFeature("stop_sequences") > 0 {
            object["stop"] = Self.syntheticStopSequences(for: row)
        }
        if row.boolFeature("unknown_top_level_keys_present") {
            object["replay_unknown_selector_field"] = true
        }
        if row.boolFeature("unknown_stream_option_keys_present") {
            object["stream_options"] = ["replay_unknown_stream_option": true]
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
            .withRequestID(request.requestID)
            .withConversationKey(request.conversationKey, cacheOnly: request.conversationCacheOnly)
    }

    private static func syntheticMessages(
        for row: NativeMTPRequestShapeReplayRow,
        request: ChatCompletionRequest
    ) -> [[String: Any]] {
        var messages = request.messages.map(Self.messageJSONObject)
        let assistantCalls = max(0, row.intFeature("assistant_tool_call_count"))
        let toolMessages = max(0, row.intFeature("tool_message_count"))
        guard assistantCalls > 0 || toolMessages > 0 else { return messages }
        let calls: [[String: Any]] = (0..<assistantCalls).map { index in
            [
                "id": String(format: "call_replay%010d", index),
                "type": "function",
                "function": [
                    "name": "replay_tool_0",
                    "arguments": "{}",
                ],
            ]
        }
        messages.append([
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": calls,
        ])
        for index in 0..<toolMessages {
            messages.append([
                "role": "tool",
                "tool_call_id": String(format: "call_replay%010d", index),
                "content": "redacted replay tool result",
            ])
        }
        return messages
    }

    private static func syntheticStopSequences(for row: NativeMTPRequestShapeReplayRow) -> [String] {
        row.intArrayFeature("stop_sequence_utf8_lengths").map { length in
            String(repeating: "x", count: max(1, length))
        }
    }

    private static func syntheticTools(for row: NativeMTPRequestShapeReplayRow) -> [[String: Any]] {
        let count = max(0, row.intFeature("tool_count"))
        let geometries = row.dictionaryArrayFeature("tool_parameter_schema_geometries")
        return (0..<count).map { index in
            let parameters = Self.syntheticJSONSchema(from: geometries.indices.contains(index) ? geometries[index] : [:])
            return [
                "type": "function",
                "function": [
                    "name": "replay_tool_\(index)",
                    "description": "Redacted replay-only tool preserving captured safe geometry.",
                    "parameters": parameters,
                ],
            ]
        }
    }

    private static func syntheticToolChoice(for row: NativeMTPRequestShapeReplayRow) -> Any {
        switch row.stringFeature("tool_choice_kind") {
        case "none", "auto", "required":
            return row.stringFeature("tool_choice_kind") ?? "auto"
        case "function":
            return ["type": "function", "function": ["name": "replay_tool_0"]]
        default:
            return "auto"
        }
    }

    private static func syntheticResponseFormat(for row: NativeMTPRequestShapeReplayRow) -> [String: Any] {
        switch row.stringFeature("response_format_kind") {
        case "json_schema":
            return [
                "type": "json_schema",
                "json_schema": [
                    "name": "replay_schema",
                    "strict": true,
                    "schema": Self.syntheticJSONSchema(from: row.dictionaryFeature("response_schema_geometry") ?? [:]),
                ],
            ]
        default:
            return ["type": "json_object"]
        }
    }

    private static func syntheticJSONSchema(from geometry: [String: Any]) -> [String: Any] {
        let propertyCount = max(0, (geometry["property_count"] as? NSNumber)?.intValue ?? 0)
        let maxDepth = max(0, (geometry["max_depth"] as? NSNumber)?.intValue ?? 0)
        func schemaWithDepth(_ depth: Int) -> [String: Any] {
            guard depth > 3 else { return ["type": "string"] }
            return [
                "type": "object",
                "properties": ["child": schemaWithDepth(depth - 2)],
                "required": ["child"],
                "additionalProperties": false,
            ]
        }
        var properties: [String: Any] = [:]
        var required: [String] = []
        for index in 0..<propertyCount {
            let name = "p\(index)"
            properties[name] = index == 0 ? schemaWithDepth(maxDepth - 2) : ["type": "string"]
            required.append(name)
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }

    private static func applyCapturedLogitControls(
        from row: NativeMTPRequestShapeReplayRow,
        to object: inout [String: Any]
    ) {
        if row.boolFeature("top_k_present"), let value = row.jsonFeature("requested_top_k") {
            object["top_k"] = value
        }
        if row.boolFeature("min_p_nonzero"), let value = row.jsonFeature("requested_min_p") {
            object["min_p"] = value
        }
        if row.boolFeature("presence_penalty_nonzero"), let value = row.jsonFeature("requested_presence_penalty") {
            object["presence_penalty"] = value
        }
        if row.boolFeature("frequency_penalty_nonzero"), let value = row.jsonFeature("requested_frequency_penalty") {
            object["frequency_penalty"] = value
        }
        if row.boolFeature("repetition_penalty_nondefault"), let value = row.jsonFeature("requested_repetition_penalty") {
            object["repetition_penalty"] = value
        }
    }

    private static func messageJSONObject(_ message: ChatMessage) -> [String: Any] {
        var object: [String: Any] = [
            "role": message.role.rawValue,
        ]
        if let content = message.content {
            object["content"] = content
        } else {
            object["content"] = NSNull()
        }
        if let toolCallID = message.toolCallID {
            object["tool_call_id"] = toolCallID
        }
        if let toolCalls = message.toolCalls {
            object["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.functionName,
                        "arguments": call.arguments,
                    ],
                ] as [String: Any]
            }
        }
        return object
    }

    private static func runStreamingRequest(
        _ request: ChatCompletionRequest,
        runtime: ModelRuntime,
        timingObserver: NativeMTPLabCommittedTokenTimingObserver,
        targetCompletionTokens: Int
    ) async throws -> NativeMTPRequestShapeReplayRequestResult {
        guard let requestID = request.requestID else {
            throw NativeMTPRequestShapeReplayError.assertionFailed("request missing id")
        }
        let started = Date()
        let startedMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        let handle = try await runtime.acquireRequestHandle(request)
        let completion: CompletionResult
        do {
            if request.stream {
                completion = try await runtime.stream(
                    request,
                    with: handle,
                    shouldCancel: { false }
                ) { _ in }
            } else {
                let (result, _) = try await runtime.completeWithServedSnapshot(
                    request,
                    with: handle,
                    shouldCancel: { false }
                )
                completion = result
            }
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await runtime.unregisterInFlight(handle.registrationID)
        return NativeMTPRequestShapeReplayRequestResult(
            requestID: requestID,
            startedAt: started,
            startedMonotonicNanoseconds: startedMonotonicNanoseconds,
            endedAt: Date(),
            targetCompletionTokens: targetCompletionTokens,
            targetStopTriggered: false,
            completion: completion,
            commitEvents: []
        )
    }

    static func admissionProjectionRows(
        path: NativeMTPRequestShapeReplayPath,
        block: NativeMTPRequestShapeReplayBlock,
        admissions: [NativeMTPHardwareAdmissionRecorder.RequestAdmission],
        requestsByID: [String: ChatCompletionRequest],
        maxContextTokens: Int
    ) -> [[String: Any]] {
        let admissionsByID = Dictionary(uniqueKeysWithValues: admissions.compactMap { item in
            item.requestID.map { ($0, item) }
        })
        return block.runnableRows.map { row in
            let admission = admissionsByID[row.requestID]
            let expectedReason = path == .ordinary ? NativeMTPSelectorReason.modeOff.rawValue : row.expectedSelectorReason
            let expectedPath = path == .ordinary
                ? DecodePath.ordinary.rawValue
                : (row.expectedSelectorReason == NativeMTPSelectorReason.eligible.rawValue
                    ? DecodePath.nativeMTP.rawValue
                    : DecodePath.ordinary.rawValue)
            let actualReason = admission?.admission.selection.nativeMTPReason?.rawValue ?? "missing"
            let actualPath = admission?.admission.effectivePath.rawValue ?? "missing"
            let actualBudget = Self.resolvedMaxOutputTokens(row: row, maxContextTokens: maxContextTokens)
            let budgetMatches = actualBudget == row.maxCompletionTokens
            let reproductionPending: String?
            if let request = requestsByID[row.requestID] {
                reproductionPending = Self.reproductionPendingReason(row: row, request: request, maxContextTokens: maxContextTokens)
            } else {
                reproductionPending = "request_reproduction_missing_parsed_request:\(row.requestID)"
            }
            let reproduced = reproductionPending == nil
            return [
                "request_id": row.requestID,
                "shape_id": row.shapeID,
                "target_completion_tokens": row.targetCompletionTokens,
                "effective_max_output_tokens": row.maxCompletionTokens,
                "expected_effective_max_output_tokens": row.maxCompletionTokens,
                "actual_effective_max_output_tokens": actualBudget.map { $0 as Any } ?? NSNull(),
                "budget_matches": budgetMatches,
                "expected_selector_reason": expectedReason,
                "actual_selector_reason": actualReason,
                "expected_effective_path": expectedPath,
                "actual_effective_path": actualPath,
                "matches": expectedReason == actualReason && expectedPath == actualPath && budgetMatches && reproduced,
                "reproduced": reproduced,
                "pending_reason": reproductionPending.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]
        }
    }


    private static func resolvedMaxOutputTokens(row: NativeMTPRequestShapeReplayRow, maxContextTokens: Int) -> Int? {
        let remaining = maxContextTokens - row.promptTokens
        guard remaining > 0 else { return nil }
        guard let requested = row.requestedMaxCompletionTokens else { return remaining }
        return min(requested, remaining)
    }

    private static func reproductionPendingReason(
        row: NativeMTPRequestShapeReplayRow,
        request: ChatCompletionRequest,
        maxContextTokens: Int
    ) -> String? {
        if request.maxTokens != row.requestedMaxCompletionTokens {
            return "requested_max_completion_tokens_mismatch:\(row.requestID)"
        }
        guard resolvedMaxOutputTokens(row: row, maxContextTokens: maxContextTokens) == row.maxCompletionTokens else {
            return "effective_max_output_tokens_mismatch:\(row.requestID)"
        }
        guard request.stream == row.stream else {
            return "stream_flag_mismatch:\(row.requestID)"
        }
        guard abs(request.temperature - row.temperature) < 0.000_000_1 else {
            return "temperature_mismatch:\(row.requestID)"
        }
        guard abs(request.topP - row.topP) < 0.000_000_1 else {
            return "top_p_mismatch:\(row.requestID)"
        }
        guard row.intFeature("requested_n") == (jsonInt(request.promptSource.n) ?? 1) else {
            return "requested_n_mismatch:\(row.requestID)"
        }
        let stopLengths = request.stop.map { $0.utf8.count }
        guard stopLengths == row.intArrayFeature("stop_sequence_utf8_lengths") else {
            return "stop_sequence_geometry_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.topK, row: row, key: "requested_top_k") else {
            return "top_k_numeric_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.minP, row: row, key: "requested_min_p") else {
            return "min_p_numeric_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.presencePenalty, row: row, key: "requested_presence_penalty") else {
            return "presence_penalty_numeric_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.frequencyPenalty, row: row, key: "requested_frequency_penalty") else {
            return "frequency_penalty_numeric_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.repetitionPenalty, row: row, key: "requested_repetition_penalty") else {
            return "repetition_penalty_numeric_mismatch:\(row.requestID)"
        }
        if row.boolFeature("logit_bias_present") || isPresent(request.promptSource.logitBias) {
            return "logit_bias_replay_requires_safe_token_geometry:\(row.requestID)"
        }
        guard boolFeatureMatches(isRequestedLogprobs(request.promptSource.logprobs), row: row, key: "logprobs_requested") else {
            return "logprobs_presence_mismatch:\(row.requestID)"
        }
        guard numericFeatureMatches(request.promptSource.topLogprobs, row: row, key: "requested_top_logprobs") else {
            return "top_logprobs_numeric_mismatch:\(row.requestID)"
        }
        guard toolCount(request.promptSource.tools) == row.intFeature("tool_count") else {
            return "tool_count_mismatch:\(row.requestID)"
        }
        guard toolParameterSchemaGeometries(request.promptSource.tools).allSatisfyGeometry(row.dictionaryArrayFeature("tool_parameter_schema_geometries")) else {
            return "tool_schema_geometry_mismatch:\(row.requestID)"
        }
        guard toolChoiceKind(request.promptSource.toolChoice) == (row.stringFeature("tool_choice_kind") ?? "absent") else {
            return "tool_choice_kind_mismatch:\(row.requestID)"
        }
        let actualToolMessages = request.messages.filter { $0.role == .tool }.count
        let actualAssistantToolCalls = request.messages.reduce(0) { $0 + ($1.toolCalls?.count ?? 0) }
        guard actualToolMessages == row.intFeature("tool_message_count") else {
            return "tool_message_count_mismatch:\(row.requestID)"
        }
        guard actualAssistantToolCalls == row.intFeature("assistant_tool_call_count") else {
            return "assistant_tool_call_count_mismatch:\(row.requestID)"
        }
        guard responseFormatKind(request.responseFormat) == (row.stringFeature("response_format_kind") ?? "text") else {
            return "response_format_kind_mismatch:\(row.requestID)"
        }
        guard geometryMatches(responseSchemaGeometry(request.responseFormat), row.dictionaryFeature("response_schema_geometry")) else {
            return "response_schema_geometry_mismatch:\(row.requestID)"
        }
        let unknownTopLevel = !request.topLevelKeys.isSubset(of: NativeMTPSelector.admittedTopLevelKeys)
        guard unknownTopLevel == row.boolFeature("unknown_top_level_keys_present") else {
            return "unknown_top_level_key_mismatch:\(row.requestID)"
        }
        let unknownStreamOptions = !request.streamOptionKeys.isSubset(of: NativeMTPSelector.admittedStreamOptionKeys)
        guard unknownStreamOptions == row.boolFeature("unknown_stream_option_keys_present") else {
            return "unknown_stream_option_key_mismatch:\(row.requestID)"
        }
        return nil
    }

    private static func boolFeatureMatches(_ actual: Bool, row: NativeMTPRequestShapeReplayRow, key: String) -> Bool {
        actual == row.boolFeature(key)
    }

    private static func numericFeatureMatches(_ actual: JSONValue?, row: NativeMTPRequestShapeReplayRow, key: String) -> Bool {
        let expected = row.jsonFeature(key)
        guard let expected else { return jsonNumber(actual) == nil }
        guard let actual = jsonNumber(actual), let expectedNumber = anyNumber(expected) else { return false }
        return abs(actual - expectedNumber) < 0.000_000_1
    }

    private static func jsonNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let int): return Double(int)
        case .double(let double): return double
        default: return nil
        }
    }

    private static func jsonInt(_ value: JSONValue?) -> Int? {
        guard case .int(let int)? = value else { return nil }
        return int
    }

    private static func anyNumber(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func isPresent(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null: return false
        default: return true
        }
    }

    private static func isRequestedLogprobs(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let bool): return bool
        default: return false
        }
    }

    private static func toolCount(_ value: JSONValue?) -> Int {
        guard case .array(let tools)? = value else { return 0 }
        return tools.count
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

    private static func responseFormatKind(_ responseFormat: ResponseFormat) -> String {
        switch responseFormat {
        case .text: return "text"
        case .jsonObject: return "json_object"
        case .jsonSchema(_): return "json_schema"
        }
    }

    private static func responseSchemaGeometry(_ responseFormat: ResponseFormat) -> [String: Any] {
        guard case .jsonSchema(let spec) = responseFormat else {
            return zeroJSONGeometry()
        }
        return jsonGeometry(spec.schema)
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

    private static func jsonGeometry(_ value: JSONValue) -> [String: Any] {
        [
            "byte_count": (try? value.deterministicJSONString().utf8.count) ?? 0,
            "max_depth": jsonContainerDepth(value),
            "object_count": jsonObjectCount(value),
            "array_count": jsonArrayCount(value),
            "property_count": jsonSchemaPropertyCount(value),
        ]
    }

    private static func zeroJSONGeometry() -> [String: Any] {
        ["byte_count": 0, "max_depth": 0, "object_count": 0, "array_count": 0, "property_count": 0]
    }

    private static func jsonContainerDepth(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object): return 1 + (object.values.map(jsonContainerDepth).max() ?? 0)
        case .array(let array): return 1 + (array.map(jsonContainerDepth).max() ?? 0)
        default: return 0
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

    private static func geometryMatches(_ actual: [String: Any], _ expected: [String: Any]?) -> Bool {
        let expected = expected ?? zeroJSONGeometry()
        for key in ["byte_count", "max_depth", "object_count", "array_count", "property_count"] {
            let actualInt = (actual[key] as? NSNumber)?.intValue ?? actual[key] as? Int
            let expectedInt = (expected[key] as? NSNumber)?.intValue ?? expected[key] as? Int
            guard actualInt == expectedInt else { return false }
        }
        return true
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

struct NativeMTPPostGatewayReplayPolicy {
    static let schema = "macprovider.native-mtp-post-gateway-replay-policy.v1"

    let seed: Int
    let sampleDigestSHA256: String
    let preregistrationDigestSHA256: String
    let privacyReviewID: String

    static func load(from url: URL) throws -> NativeMTPPostGatewayReplayPolicy {
        let data = try Data(contentsOf: url)
        try NativeMTPBenchJSON.rejectDuplicateKeys(data, label: "post-gateway replay policy")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("policy must be a JSON object")
        }
        guard object["schema"] as? String == schema else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("post_gateway_replay_policy_schema_invalid")
        }
        guard object["issue"] as? String == "SPEC-048-R015-post-gateway-replay" else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("post_gateway_replay_policy_issue_invalid")
        }
        return NativeMTPPostGatewayReplayPolicy(
            seed: try nonnegativeInt(object, "seed"),
            sampleDigestSHA256: try hex64(object, "sample_digest_sha256"),
            preregistrationDigestSHA256: try hex64(object, "preregistration_digest_sha256"),
            privacyReviewID: try string(object, "privacy_review_id")
        )
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("policy missing string \(key)")
        }
        return value
    }

    private static func hex64(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("policy \(key) must be lowercase 64-hex")
        }
        return value
    }

    private static func nonnegativeInt(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("policy missing int \(key)")
        }
        let int = value.intValue
        guard int >= 0, Double(int) == value.doubleValue else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("policy \(key) must be a nonnegative integer")
        }
        return int
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

    func identityMismatches(targetSHA256: String) -> [[String: Any]] {
        shapes.compactMap { shape in
            guard shape.servedModelHashSHA256 != targetSHA256 else { return nil }
            return [
                "shape_id": shape.shapeID,
                "served_model_hash_sha256": shape.servedModelHashSHA256,
                "target_sha256": targetSHA256,
            ] as [String: Any]
        }
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

    private static func hex64(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be lowercase 64-hex")
        }
        return value
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
    let servedModelHashSHA256: String
    let servedWeightsManifestSHA256: String
    let temperature: Double
    let topP: Double
    let requestedMaxCompletionTokens: Int?
    let maxCompletionTokens: Int
    let promptTokens: Int
    let targetCompletionTokens: Int
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
        self.servedModelHashSHA256 = try Self.hex64(object, "served_model_hash_sha256")
        self.servedWeightsManifestSHA256 = try Self.hex64(object, "served_weights_manifest_sha256")
        self.temperature = try Self.double(object, "requested_temperature")
        self.topP = try Self.double(object, "requested_top_p")
        self.requestedMaxCompletionTokens = try Self.optionalNonnegativeInt(object, "requested_max_completion_tokens")
        self.maxCompletionTokens = try Self.positiveInt(object, "effective_max_output_tokens")
        self.promptTokens = try Self.positiveInt(object, "prompt_tokens")
        self.completionTokens = try Self.nonnegativeInt(object, "completion_tokens")
        self.targetCompletionTokens = self.completionTokens
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
        projectedSelectorReason == NativeMTPSelectorReason.eligible.rawValue ? .ordinaryBaseline : .mixedIneligible
    }

    var selectorBlockingFeatureCount: Int {
        var count = 0
        if boolFeature("sampling_requested") { count += 1 }
        if boolFeature("multiple_completions_requested") { count += 1 }
        if boolFeature("logit_controls_requested") { count += 1 }
        if conversationKeyPresent && !conversationCacheOnly { count += 1 }
        if boolFeature("multimodal_requested") { count += 1 }
        if boolFeature("structured_output_requested") { count += 1 }
        if boolFeature("tools_present") || boolFeature("tool_choice_present") || boolFeature("tool_turn_state_present") { count += 1 }
        if boolFeature("logprobs_requested") || boolFeature("top_logprobs_requested") { count += 1 }
        if boolFeature("unknown_request_fields_present")
            || boolFeature("unknown_top_level_keys_present")
            || boolFeature("unknown_stream_option_keys_present") {
            count += 1
        }
        if boolFeature("reasoning_or_template_model") { count += 1 }
        return count
    }

    var projectedSelectorReason: String {
        if boolFeature("sampling_requested") { return NativeMTPSelectorReason.sampling.rawValue }
        if boolFeature("multiple_completions_requested") { return NativeMTPSelectorReason.multipleCompletions.rawValue }
        if boolFeature("logit_controls_requested") { return NativeMTPSelectorReason.logitControls.rawValue }
        if conversationKeyPresent && !conversationCacheOnly { return NativeMTPSelectorReason.conversationKey.rawValue }
        if boolFeature("multimodal_requested") { return NativeMTPSelectorReason.multimodal.rawValue }
        if boolFeature("structured_output_requested") { return NativeMTPSelectorReason.structuredOutput.rawValue }
        if boolFeature("tools_present") || boolFeature("tool_choice_present") || boolFeature("tool_turn_state_present") {
            return NativeMTPSelectorReason.tools.rawValue
        }
        if boolFeature("logprobs_requested") || boolFeature("top_logprobs_requested") { return NativeMTPSelectorReason.logprobs.rawValue }
        if boolFeature("unknown_request_fields_present")
            || boolFeature("unknown_top_level_keys_present")
            || boolFeature("unknown_stream_option_keys_present") {
            return NativeMTPSelectorReason.unknownRequestField.rawValue
        }
        if boolFeature("reasoning_or_template_model") { return NativeMTPSelectorReason.reasoningOrTemplate.rawValue }
        return NativeMTPSelectorReason.eligible.rawValue
    }

    func boolFeature(_ key: String) -> Bool {
        features[key] as? Bool ?? false
    }

    func intFeature(_ key: String) -> Int {
        (features[key] as? NSNumber)?.intValue ?? 0
    }

    func stringFeature(_ key: String) -> String? {
        features[key] as? String
    }

    func jsonFeature(_ key: String) -> Any? {
        guard let value = features[key], !(value is NSNull) else { return nil }
        return value
    }

    func intArrayFeature(_ key: String) -> [Int] {
        if let values = features[key] as? [Int] { return values }
        guard let values = features[key] as? [Any] else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.intValue }
    }

    func dictionaryFeature(_ key: String) -> [String: Any]? {
        features[key] as? [String: Any]
    }

    func dictionaryArrayFeature(_ key: String) -> [[String: Any]] {
        features[key] as? [[String: Any]] ?? []
    }

    var sanitizedExport: [String: Any] {
        var object: [String: Any] = [
            "shape_id": shapeID,
            "served_model_hash_sha256": servedModelHashSHA256,
            "served_weights_manifest_sha256": servedWeightsManifestSHA256,
            "stream": stream,
            "requested_temperature": temperature,
            "requested_top_p": topP,
            "requested_max_completion_tokens": requestedMaxCompletionTokens as Any,
            "effective_max_output_tokens": maxCompletionTokens,
            "prompt_tokens": promptTokens,
            "target_completion_tokens": targetCompletionTokens,
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
        for (key, value) in features {
            object[key] = value
        }
        return object
    }

    private static func sanitizedFeatures(_ object: [String: Any]) -> [String: Any] {
        let keys = [
            "stop_sequences", "stop_sequence_utf8_lengths", "stop_sequence_utf8_length_buckets",
            "sampling_requested", "multiple_completions_requested",
            "requested_top_k", "requested_min_p", "requested_presence_penalty",
            "requested_frequency_penalty", "requested_repetition_penalty", "requested_n",
            "top_k_present", "min_p_nonzero", "frequency_penalty_nonzero",
            "presence_penalty_nonzero", "repetition_penalty_nondefault",
            "logit_bias_present", "logit_bias_geometry", "tools_present", "tool_count",
            "tool_parameter_schema_geometries",
            "tool_choice_present", "tool_choice_kind", "tool_turn_state_present",
            "tool_message_count", "assistant_tool_call_count",
            "structured_output_requested", "response_format_kind", "response_schema_geometry",
            "logprobs_requested", "top_logprobs_requested", "requested_top_logprobs", "logit_controls_requested",
            "reasoning_or_template_model", "multimodal_requested",
            "unknown_request_fields_present", "unknown_top_level_keys_present",
            "unknown_stream_option_keys_present",
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = object[key] { result[key] = value }
        }
    }

    private static func hex64(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be lowercase 64-hex")
        }
        return value
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
        guard let value = try optionalNonnegativeInt(object, key) else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing int \(key)")
        }
        return value
    }

    private static func optionalNonnegativeInt(_ object: [String: Any], _ key: String) throws -> Int? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("missing int \(key)")
        }
        let int = value.intValue
        guard int >= 0, Double(int) == value.doubleValue else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("\(key) must be a nonnegative integer")
        }
        return int
    }

    private static func optionalHex64(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
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
    let requestedMaxCompletionTokens: Int?
    let maxCompletionTokens: Int
    let maxContextTokens: Int
    let sampleShapeCount: Int
    let omittedSampleShapeCount: Int
    let pendingSampleShapeCount: Int
    let pendingSampleReasons: [String]
    var rowsPerBlock: Int { blocks.first?.rows.count ?? 0 }
    var runnableRowsPerBlock: Int { blocks.first?.runnableRows.count ?? 0 }
    var runnableWavesPerBlock: Int { blocks.first?.runnableWaves.count ?? 0 }
    var sampleCoverageComplete: Bool { omittedSampleShapeCount == 0 && pendingSampleShapeCount == 0 }
    var sampleCoverageExport: [String: Any] {
        [
            "sample_shape_count": sampleShapeCount,
            "sample_weight_total": sampleShapeCount,
            "projected_request_count_per_block": rowsPerBlock,
            "runnable_request_count_per_block": runnableRowsPerBlock,
            "max_concurrent_requests": Self.qualifiedSlots,
            "runnable_waves_per_block": runnableWavesPerBlock,
            "omitted_sample_shape_count": omittedSampleShapeCount,
            "pending_sample_shape_count": pendingSampleShapeCount,
            "reproduced_sample_shape_count": max(0, sampleShapeCount - omittedSampleShapeCount - pendingSampleShapeCount),
            "reproduced_sample_weight": max(0, sampleShapeCount - omittedSampleShapeCount - pendingSampleShapeCount),
            "pending_or_omitted_sample_weight": pendingSampleShapeCount + omittedSampleShapeCount,
            "runnable_coverage_fraction": sampleShapeCount == 0 ? 0.0 : Double(max(0, sampleShapeCount - omittedSampleShapeCount - pendingSampleShapeCount)) / Double(sampleShapeCount),
            "complete": sampleCoverageComplete,
            "pending_reasons": pendingSampleReasons,
        ]
    }

    static func make(
        capture: NativeMTPRequestShapeReplayCapture,
        blocks: Int,
        seed: Int
    ) throws -> NativeMTPRequestShapeReplayPlan {
        let rows = try projectedRows(capture.shapes)
        let sampleShapeCount = capture.shapes.count
        let omittedSampleShapeCount = 0
        let pendingSampleReasons = rows.compactMap(\.pendingReason)
        let pendingSampleShapeCount = pendingSampleReasons.count
        let promptTarget = rows.map(\.promptTokens).max() ?? NativeMTPBenchPolicy.gatedPromptTokens
        let maxCompletion = rows.map(\.maxCompletionTokens).max() ?? NativeMTPBenchPolicy.gatedMaxTokens
        let requestedMaxCompletion = rows.compactMap(\.requestedMaxCompletionTokens).max() ?? maxCompletion
        let maxContext = Self.contextTokenTarget(rows: rows, promptTarget: promptTarget, maxCompletion: maxCompletion)
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
            requestedMaxCompletionTokens: requestedMaxCompletion,
            maxCompletionTokens: maxCompletion,
            maxContextTokens: maxContext,
            sampleShapeCount: sampleShapeCount,
            omittedSampleShapeCount: omittedSampleShapeCount,
            pendingSampleShapeCount: pendingSampleShapeCount,
            pendingSampleReasons: pendingSampleReasons
        )
    }

    private static func contextTokenTarget(
        rows: [NativeMTPRequestShapeReplayRow],
        promptTarget: Int,
        maxCompletion: Int
    ) -> Int {
        let nilRequestedTargets = Set(rows.compactMap { row -> Int? in
            row.requestedMaxCompletionTokens == nil ? row.promptTokens + row.maxCompletionTokens : nil
        })
        if nilRequestedTargets.count == 1,
           let target = nilRequestedTargets.first,
           rows.allSatisfy({ $0.pendingReason != nil || $0.promptTokens + $0.maxCompletionTokens <= target }) {
            return target
        }
        return promptTarget + maxCompletion + 256
    }

    private static func projectedRows(_ shapes: [NativeMTPRequestShapeReplayShape]) throws -> [NativeMTPRequestShapeReplayRow] {
        guard !shapes.isEmpty else {
            throw NativeMTPRequestShapeReplayError.invalidCapture("no shapes to replay")
        }
        let nilRequestedTargets = Set(shapes.compactMap { shape -> Int? in
            shape.requestedMaxCompletionTokens == nil ? shape.promptTokens + max(1, shape.maxCompletionTokens) : nil
        })
        let nilMaxContextCoherent: Bool
        if nilRequestedTargets.isEmpty {
            nilMaxContextCoherent = true
        } else if nilRequestedTargets.count == 1, let target = nilRequestedTargets.first {
            nilMaxContextCoherent = shapes.allSatisfy { shape in
                shape.promptTokens + max(1, shape.maxCompletionTokens) <= target
            }
        } else {
            nilMaxContextCoherent = false
        }
        return shapes.enumerated().map { index, shape in
            NativeMTPRequestShapeReplayRow(
                shape: shape,
                captureIndex: index,
                blockIndex: 0,
                nilMaxContextCoherent: nilMaxContextCoherent
            )
        }
    }
}

struct NativeMTPRequestShapeReplayBlock {
    let index: Int
    let nativeFirst: Bool
    let rows: [NativeMTPRequestShapeReplayRow]
    var runnableRows: [NativeMTPRequestShapeReplayRow] {
        rows.filter { $0.pendingReason == nil }
    }

    var runnableWaves: [[NativeMTPRequestShapeReplayRow]] {
        var waves: [[NativeMTPRequestShapeReplayRow]] = []
        var current: [NativeMTPRequestShapeReplayRow] = []
        var cacheGroupsInCurrentWave: Set<String> = []
        var eligibleRowsInCurrentWave = 0
        for row in runnableRows {
            let cacheGroup = row.anonymousCacheGroupSHA256
            let cacheConflict = cacheGroup.map { cacheGroupsInCurrentWave.contains($0) } ?? false
            let eligibleConflict = row.expectedSelectorReason == NativeMTPSelectorReason.eligible.rawValue
                && eligibleRowsInCurrentWave >= NativeMTPRequestShapeReplayPlan.maxNativeActiveRows
            if !current.isEmpty
                && (current.count >= NativeMTPRequestShapeReplayPlan.qualifiedSlots || cacheConflict || eligibleConflict) {
                waves.append(current)
                current = []
                cacheGroupsInCurrentWave = []
                eligibleRowsInCurrentWave = 0
            }
            current.append(row)
            if row.expectedSelectorReason == NativeMTPSelectorReason.eligible.rawValue {
                eligibleRowsInCurrentWave += 1
            }
            if let cacheGroup {
                cacheGroupsInCurrentWave.insert(cacheGroup)
            }
        }
        if !current.isEmpty {
            waves.append(current)
        }
        return waves
    }

    func row(requestID: String?) -> NativeMTPRequestShapeReplayRow? {
        guard let requestID else { return nil }
        return rows.first { $0.requestID == requestID }
    }

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
    let stream: Bool
    let targetCompletionTokens: Int
    let requestedMaxCompletionTokens: Int?
    let maxCompletionTokens: Int
    let temperature: Double
    let topP: Double
    let conversationCacheOnly: Bool
    let anonymousCacheGroupSHA256: String?
    let requiresCacheProof: Bool
    let pendingReason: String?
    let expectedSelectorReason: String
    let syntheticStandIn: NativeMTPReplaySyntheticStandIn?
    let replayFeatures: [String: Any]
    let metricsClass: NativeMTPRequestShapeReplayMetricsClass
    let exportedShape: [String: Any]

    init(
        shape: NativeMTPRequestShapeReplayShape,
        captureIndex: Int,
        blockIndex: Int,
        nilMaxContextCoherent: Bool = true
    ) {
        self.shapeID = shape.shapeID
        self.captureIndex = captureIndex
        self.blockIndex = blockIndex
        self.requestID = "mixed-b\(blockIndex)-r\(captureIndex)-\(shape.shapeID)"
        self.promptTokens = shape.promptTokens
        self.stream = shape.stream
        self.targetCompletionTokens = shape.targetCompletionTokens
        self.requestedMaxCompletionTokens = shape.requestedMaxCompletionTokens
        self.maxCompletionTokens = max(1, shape.maxCompletionTokens)
        self.temperature = shape.temperature
        self.topP = shape.topP
        self.conversationCacheOnly = shape.conversationCacheOnly
        self.anonymousCacheGroupSHA256 = shape.anonymousCacheGroupSHA256
        self.requiresCacheProof = shape.conversationKeyPresent
        let projectedReason = shape.projectedSelectorReason
        if shape.conversationKeyPresent && shape.anonymousCacheGroupSHA256 == nil {
            self.pendingReason = "cache_shape_missing_anonymous_group:\(shape.shapeID)"
        } else if shape.conversationCacheLease == "hit"
                    || shape.conversationCacheCachedPromptTokens > 0
                    || shape.conversationCacheRetainedHandoff {
            self.pendingReason = "cache_hit_replay_requires_runtime_warmup_proof:\(shape.shapeID)"
        } else if projectedReason == NativeMTPSelectorReason.eligible.rawValue
                    && shape.targetCompletionTokens < 2 {
            self.pendingReason = "ordinary_itl_requires_target_completion_at_least_2:\(shape.shapeID)"
        } else if shape.requestedMaxCompletionTokens == nil && !nilMaxContextCoherent {
            self.pendingReason = "nil_max_replay_requires_single_context_geometry:\(shape.shapeID)"
        } else if projectedReason == NativeMTPSelectorReason.multipleCompletions.rawValue {
            self.pendingReason = "multiple_completions_rejected_by_ingest_validation:\(shape.shapeID)"
        } else if projectedReason == NativeMTPSelectorReason.multimodal.rawValue {
            self.pendingReason = "multimodal_shape_requires_sanitized_part_geometry:\(shape.shapeID)"
        } else if projectedReason == NativeMTPSelectorReason.reasoningOrTemplate.rawValue {
            self.pendingReason = "reasoning_or_template_requires_served_model_family:\(shape.shapeID)"
        } else if let geometryPendingReason = NativeMTPReplaySyntheticStandIn.pendingReason(shape: shape) {
            self.pendingReason = geometryPendingReason
        } else {
            self.pendingReason = nil
        }
        self.expectedSelectorReason = projectedReason
        self.syntheticStandIn = NativeMTPReplaySyntheticStandIn(reason: projectedReason, shape: shape)
        self.replayFeatures = shape.features
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
            stream: stream,
            targetCompletionTokens: targetCompletionTokens,
            requestedMaxCompletionTokens: requestedMaxCompletionTokens,
            maxCompletionTokens: maxCompletionTokens,
            temperature: temperature,
            topP: topP,
            conversationCacheOnly: conversationCacheOnly,
            anonymousCacheGroupSHA256: anonymousCacheGroupSHA256,
            requiresCacheProof: requiresCacheProof,
            pendingReason: pendingReason,
            expectedSelectorReason: expectedSelectorReason,
            syntheticStandIn: syntheticStandIn,
            replayFeatures: replayFeatures,
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
        stream: Bool,
        targetCompletionTokens: Int,
        requestedMaxCompletionTokens: Int?,
        maxCompletionTokens: Int,
        temperature: Double,
        topP: Double,
        conversationCacheOnly: Bool,
        anonymousCacheGroupSHA256: String?,
        requiresCacheProof: Bool,
        pendingReason: String?,
        expectedSelectorReason: String,
        syntheticStandIn: NativeMTPReplaySyntheticStandIn?,
        replayFeatures: [String: Any],
        metricsClass: NativeMTPRequestShapeReplayMetricsClass,
        exportedShape: [String: Any]
    ) {
        self.shapeID = shapeID
        self.captureIndex = captureIndex
        self.blockIndex = blockIndex
        self.requestID = requestID
        self.promptTokens = promptTokens
        self.stream = stream
        self.targetCompletionTokens = targetCompletionTokens
        self.requestedMaxCompletionTokens = requestedMaxCompletionTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.conversationCacheOnly = conversationCacheOnly
        self.anonymousCacheGroupSHA256 = anonymousCacheGroupSHA256
        self.requiresCacheProof = requiresCacheProof
        self.pendingReason = pendingReason
        self.expectedSelectorReason = expectedSelectorReason
        self.syntheticStandIn = syntheticStandIn
        self.replayFeatures = replayFeatures
        self.metricsClass = metricsClass
        self.exportedShape = exportedShape
    }

    func boolFeature(_ key: String) -> Bool {
        replayFeatures[key] as? Bool ?? false
    }

    func intFeature(_ key: String) -> Int {
        (replayFeatures[key] as? NSNumber)?.intValue ?? 0
    }

    func stringFeature(_ key: String) -> String? {
        replayFeatures[key] as? String
    }

    func jsonFeature(_ key: String) -> Any? {
        guard let value = replayFeatures[key], !(value is NSNull) else { return nil }
        return value
    }

    func intArrayFeature(_ key: String) -> [Int] {
        if let values = replayFeatures[key] as? [Int] { return values }
        guard let values = replayFeatures[key] as? [Any] else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.intValue }
    }

    func dictionaryFeature(_ key: String) -> [String: Any]? {
        replayFeatures[key] as? [String: Any]
    }

    func dictionaryArrayFeature(_ key: String) -> [[String: Any]] {
        replayFeatures[key] as? [[String: Any]] ?? []
    }

}

enum NativeMTPReplaySyntheticStandIn {
    static let disclosure: [String: Any] = [
        "logit_controls": "replays exact sanitized numeric top_k/min_p/penalty controls when present; logit_bias rows stay pending because token IDs are not exported",
        "structured_output": "replays json_object exactly; json_schema uses redacted schema preserving captured property arity/depth class where safe",
        "tools": "uses redacted synthetic tool names/messages and parameter schemas preserving captured counts and safe schema geometry",
        "stop_sequence": "uses redacted UTF-8 literals preserving captured exact byte lengths",
        "logprobs": "replays logprobs and exact top_logprobs numeric value when captured",
        "unknown_request_field": [
            "top_level_key": "replay_unknown_selector_field",
            "stream_option_key": "replay_unknown_stream_option",
            "value_type": "boolean",
        ],
        "pending_geometry": [
            "logit_bias": "requires token IDs, which are not exported",
        ],
    ]

    case logitControls
    case structuredOutput
    case tools
    case logprobs
    case stopSequence
    case unknownRequestField

    init?(reason: String, shape: NativeMTPRequestShapeReplayShape) {
        if shape.intFeature("stop_sequences") > 0 {
            self = .stopSequence
            return
        }
        switch reason {
        case NativeMTPSelectorReason.logitControls.rawValue:
            self = .logitControls
        case NativeMTPSelectorReason.structuredOutput.rawValue:
            self = .structuredOutput
        case NativeMTPSelectorReason.tools.rawValue:
            self = .tools
        case NativeMTPSelectorReason.logprobs.rawValue:
            self = .logprobs
        case NativeMTPSelectorReason.unknownRequestField.rawValue:
            self = .unknownRequestField
        default:
            return nil
        }
    }

    static func pendingReason(shape: NativeMTPRequestShapeReplayShape) -> String? {
        if shape.intFeature("stop_sequences") > 0 {
            let stopLengths = shape.intArrayFeature("stop_sequence_utf8_lengths")
            if stopLengths.count != shape.intFeature("stop_sequences") || stopLengths.contains(where: { $0 <= 0 }) {
                return "stop_sequence_replay_requires_exact_length_geometry:\(shape.shapeID)"
            }
        }
        if shape.boolFeature("logit_bias_present") {
            return "logit_bias_replay_requires_safe_token_geometry:\(shape.shapeID)"
        }
        if shape.boolFeature("top_k_present") && shape.jsonFeature("requested_top_k") == nil {
            return "top_k_replay_requires_exact_numeric_value:\(shape.shapeID)"
        }
        if shape.boolFeature("min_p_nonzero") && shape.jsonFeature("requested_min_p") == nil {
            return "min_p_replay_requires_exact_numeric_value:\(shape.shapeID)"
        }
        if shape.boolFeature("presence_penalty_nonzero") && shape.jsonFeature("requested_presence_penalty") == nil {
            return "presence_penalty_replay_requires_exact_numeric_value:\(shape.shapeID)"
        }
        if shape.boolFeature("frequency_penalty_nonzero") && shape.jsonFeature("requested_frequency_penalty") == nil {
            return "frequency_penalty_replay_requires_exact_numeric_value:\(shape.shapeID)"
        }
        if shape.boolFeature("repetition_penalty_nondefault") && shape.jsonFeature("requested_repetition_penalty") == nil {
            return "repetition_penalty_replay_requires_exact_numeric_value:\(shape.shapeID)"
        }
        if shape.boolFeature("tools_present")
            && shape.intFeature("tool_count") > 0
            && shape.dictionaryArrayFeature("tool_parameter_schema_geometries").count != shape.intFeature("tool_count") {
            return "tool_shape_replay_requires_safe_tool_geometry:\(shape.shapeID)"
        }
        if shape.intFeature("tool_message_count") > shape.intFeature("assistant_tool_call_count") {
            return "tool_turn_replay_requires_assistant_call_for_each_tool_message:\(shape.shapeID)"
        }
        if shape.boolFeature("tool_choice_present")
            && shape.stringFeature("tool_choice_kind") == "function"
            && shape.intFeature("tool_count") <= 0 {
            return "tool_choice_replay_requires_tool_fixture:\(shape.shapeID)"
        }
        if shape.boolFeature("structured_output_requested")
            && shape.stringFeature("response_format_kind") == "json_schema"
            && shape.dictionaryFeature("response_schema_geometry") == nil {
            return "response_schema_replay_requires_safe_schema_geometry:\(shape.shapeID)"
        }
        if shape.boolFeature("top_logprobs_requested") && shape.jsonFeature("requested_top_logprobs") == nil {
            return "top_logprobs_replay_requires_exact_value:\(shape.shapeID)"
        }
        return nil
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
    let startedMonotonicNanoseconds: UInt64
    let endedAt: Date
    let targetCompletionTokens: Int
    let targetStopTriggered: Bool
    let completion: CompletionResult
    let commitEvents: [NativeMTPLabCommittedTokenTimingObserver.Event]

    var ttftSeconds: Double? {
        guard let first = commitEvents.first else { return nil }
        return Self.seconds(first.monotonicNanoseconds, since: startedMonotonicNanoseconds)
    }

    var interTokenGaps: [Double] {
        zip(commitEvents.dropFirst(), commitEvents).map {
            Self.seconds($0.monotonicNanoseconds, since: $1.monotonicNanoseconds)
        }
    }

    var committedTimingComplete: Bool {
        commitEvents.count == completion.completionTokens
    }

    var targetCompletionMatched: Bool {
        completion.completionTokens == targetCompletionTokens
    }

    func withCommitEvents(_ events: [NativeMTPLabCommittedTokenTimingObserver.Event]) -> NativeMTPRequestShapeReplayRequestResult {
        NativeMTPRequestShapeReplayRequestResult(
            requestID: requestID,
            startedAt: startedAt,
            startedMonotonicNanoseconds: startedMonotonicNanoseconds,
            endedAt: endedAt,
            targetCompletionTokens: targetCompletionTokens,
            targetStopTriggered: targetStopTriggered,
            completion: completion,
            commitEvents: events.sorted { $0.ordinal < $1.ordinal }
        )
    }

    private static func seconds(_ later: UInt64, since earlier: UInt64) -> Double {
        guard later >= earlier else { return 0 }
        return Double(later - earlier) / 1_000_000_000
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
    let ordinaryObservedIntervalSeconds: Double
    let ordinaryObservedThroughputTPS: Double
    let aggregateCompletionTokens: Int
    let aggregateThroughputTPS: Double
    let admissions: [NativeMTPHardwareAdmissionRecorder.RequestAdmission]
    let missingAdmissionRequestIDs: [String]
    let targetMismatchRequestIDs: [String]
    let sampleCoverageComplete: Bool
    let admissionProjections: [[String: Any]]

    func record(policySHA256: String, benchPolicySHA256: String, captureSHA256: String) -> [String: Any] {
        let projectionMatches = admissionProjections.allSatisfy { row in
            (row["matches"] as? Bool) == true && (row["reproduced"] as? Bool) == true
        }
        let qualified = sampleCoverageComplete
            && missingAdmissionRequestIDs.isEmpty
            && targetMismatchRequestIDs.isEmpty
            && requests.allSatisfy(\.committedTimingComplete)
            && projectionMatches
        return [
            "schema": NativeMTPRequestShapeReplayRunner.schema,
            "record_type": "run",
            "policy_sha256": policySHA256,
            "bench_policy_sha256": benchPolicySHA256,
            "capture_sha256": captureSHA256,
            "block_index": blockIndex,
            "path": path.rawValue,
            "order_position": orderPosition,
            "requests": requests.count,
            "wall_seconds": wallSeconds,
            "ordinary_observed_requests": ordinaryObservedRequests,
            "ordinary_observed_completion_tokens": ordinaryObservedCompletionTokens,
            "ordinary_observed_interval_seconds": ordinaryObservedIntervalSeconds,
            "ordinary_observed_throughput_tps": ordinaryObservedThroughputTPS,
            "aggregate_completion_tokens": aggregateCompletionTokens,
            "aggregate_throughput_tps": aggregateThroughputTPS,
            "qualification_status": qualified ? "qualified" : "pending",
            "sample_coverage_complete": sampleCoverageComplete,
            "admission_observation_complete": missingAdmissionRequestIDs.isEmpty,
            "missing_admission_request_ids": missingAdmissionRequestIDs,
            "target_completion_observation_complete": targetMismatchRequestIDs.isEmpty,
            "target_completion_mismatch_request_ids": targetMismatchRequestIDs,
            "committed_timing_observation_complete": requests.allSatisfy(\.committedTimingComplete),
            "completion_tokens_by_request": requests.map { result in
                [
                    "request_id": result.requestID,
                    "target_completion_tokens": result.targetCompletionTokens,
                    "completion_tokens": result.completion.completionTokens,
                    "target_completion_matched": result.targetCompletionMatched,
                    "target_stop_triggered": result.targetStopTriggered,
                    "generated_completion_tokens": result.completion.generatedCompletionTokens,
                    "committed_timing_events": result.commitEvents.count,
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
            "admission_projection": admissionProjections,
        ]
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

private extension Array where Element == [String: Any] {
    func allSatisfyGeometry(_ expected: [[String: Any]]) -> Bool {
        guard count == expected.count else { return false }
        for index in indices {
            for key in ["byte_count", "max_depth", "object_count", "array_count", "property_count"] {
                let actualInt = (self[index][key] as? NSNumber)?.intValue ?? self[index][key] as? Int
                let expectedInt = (expected[index][key] as? NSNumber)?.intValue ?? expected[index][key] as? Int
                guard actualInt == expectedInt else { return false }
            }
        }
        return true
    }
}
#endif
