#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import MLX
import MLXLMCommon

/// A single ordinary production-scheduler request, never a qualification matrix.
struct GLMPrefillProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glm-prefill-profile", abstract: "Run the bounded lab prefill diagnostic.", shouldDisplay: false
    )
    @Option(name: .customLong("root")) var root: String
    @Option(name: .customLong("model-id")) var modelID: String
    @Option(name: .customLong("provider-commit")) var providerCommit: String
    @Option(name: .customLong("mode")) var mode: GLMPrefillProfileMode
    @Option(name: .customLong("out")) var out: String

    func run() async throws {
        try Self.validate(mode: mode, environment: ProcessInfo.processInfo.environment)
        guard modelID == "zai-org/glm-5.3-flash",
              providerCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ValidationError("profile requires canonical GLM model and lowercase 40-hex source commit")
        }
        let output = URL(fileURLWithPath: out).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ValidationError("profile output must not already exist")
        }
        NativeMTPHardwareE2ERunner.applyServeProcessSetup(rootPath: root)
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        if mode == .census { try LabDispatchCensus.install() }
        let runner = NativeMTPHardwareE2ERunner(
            rootPath: root, modelID: modelID, maxBatch: 2, maxPromptTokens: 16448,
            maxPhysicalBlocks: NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
                slots: 2, promptTokens: 16448, outputTokens: 1
            )
        )
        let fixture = try await runner.loadRuntimeFixture(
            maxContextTokens: 16704, ordinaryAdmissionRecorder: nil, nativeAdmissionRecorder: nil
        )
        let runtime = fixture.runtimes.ordinary
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else { throw ValidationError("profile runtime missing container") }
        let model = modelID
        let thinking = snapshot.templateSupportsThinkingToggle
        let preserve = snapshot.templateSupportsPreserveThinking
        let sized = try await container.perform { context in
            func prompt(_ salts: Int) -> String {
                (0..<salts).reduce("GLM prefill diagnostic deterministic nominal16k prompt.") {
                    $0 + " measurement-\($1) throughput parity tokens"
                }
            }
            func prepared(_ text: String) async throws -> [Int32] {
                let request = try Self.request(model: model, prompt: text)
                return try await ModelRuntime.preparedRequestInput(
                    for: request, context: context,
                    templateSupportsThinkingToggle: thinking,
                    templateSupportsPreserveThinking: preserve,
                    toolSelectionModelID: model
                ).input.text.tokens.asArray(Int32.self)
            }
            let sizing = try await NativeMTPBenchPrompts.fewestReachingSalts(target: 16384, maximumSalts: 8192) {
                try await prepared(prompt($0)).count
            }
            let text = prompt(sizing.salts)
            let ids = try await prepared(text)
            guard (16384...16448).contains(ids.count) else {
                throw ValidationError("prepared nominal16k prompt outside fixed 16384...16448 bound")
            }
            return (text, ids)
        }
        let tokenData = try JSONSerialization.data(withJSONObject: sized.1.map(Int.init))
        let digest = SHA256.hash(data: tokenData).map { String(format: "%02x", $0) }.joined()
        let request = try Self.request(model: modelID, prompt: sized.0)
        GLMPrefillProfileCapture.arm(mode: mode)
        defer { GLMPrefillProfileCapture.disarm() }
        let started = ProcessInfo.processInfo.systemUptime
        let handle = try await runtime.acquireRequestHandle(request)
        let completion: CompletionResult
        do {
            completion = try await runtime.stream(request, with: handle) { _ in }
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await runtime.unregisterInFlight(handle.registrationID)
        let wall = ProcessInfo.processInfo.systemUptime - started
        let chunks = GLMPrefillProfileCapture.snapshot()
        let firstTokens = chunks.compactMap { $0["sampled_token_id"] as? Int }
        let observedIDs = GLMPrefillProfileCapture.observedPromptTokenIDs()
        guard observedIDs == sized.1.map(Int.init), (1...64).contains(chunks.count) else {
            throw ValidationError("actual scheduler prompt differs from prepared prompt or chunk bound")
        }
        var expectedOffset = 0
        for chunk in chunks {
            guard chunk["offset"] as? Int == expectedOffset,
                  let count = chunk["prompt_tokens"] as? Int, count > 0, count <= 512,
                  chunk["valid"] as? Bool == true else {
                throw ValidationError("profile chunk coverage or GPU timing invalid")
            }
            expectedOffset += count
        }
        guard expectedOffset == sized.1.count, firstTokens.count == 1,
              completion.promptTokens == sized.1.count,
              completion.generatedCompletionTokens == 1 else {
            throw ValidationError("profile must cover prepared prompt exactly and sample exactly one token")
        }
        let machine: [String: Any] = [
            "chip": fixture.machine.chip, "ram_gb": fixture.machine.ramGB,
            "os_version": fixture.machine.osVersion, "binary_version": fixture.machine.binaryVersion,
            "host_name": ProcessInfo.processInfo.hostName,
        ]
        var receipt: [String: Any] = [
            "schema": "macprovider.glm-prefill-profile.v1", "status": "pass",
            "evidence_class": "lab_isolated_no_join_diagnostic", "mode": mode.rawValue,
            "provider_commit": providerCommit, "model_id": modelID, "machine": machine,
            "mlx_fork_revision": NativeMTPHardwareE2ERunner.upstreamRevision,
            "target_sha256": fixture.targetIdentity.digest, "mtp_sha256": fixture.mtpIdentity.digest,
            "tokenizer_sha256": fixture.tokenizerSHA256,
            "nominal_prompt_tokens": 16384, "prepared_prompt_tokens": sized.1.count,
            "prepared_prompt_sha256": digest, "prepared_prompt_digest_encoding": "json-int32-array",
            "rows": 1, "completion_tokens": completion.generatedCompletionTokens,
            "first_token_id": firstTokens[0], "request_wall_seconds": wall,
            "attribution_scope": "single_dispatch_command_buffers_partial",
            "cache_writes_attributed": false,
            "gpu_busy_seconds_semantics": "union_of_completed_command_buffer_intervals",
            "chunks": chunks,
        ]
        if mode == .census {
            receipt["census"] = GLMPrefillProfileCapture.censusSummary(chunks)
        }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw ValidationError("cannot create exclusive profile output") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data + Data([10]))
        try file.synchronize()
        try file.close()
        print(String(decoding: data, as: UTF8.self))
    }

    static func validate(mode: GLMPrefillProfileMode, environment: [String: String]) throws {
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            throw ValidationError("profile requires MACPROVIDER_NATIVE_MTP_E2E=1")
        }
        let ops = environment["MLX_MAX_OPS_PER_BUFFER"]
        guard mode == .census ? ops == "0" : ops == nil else {
            throw ValidationError("census requires MLX_MAX_OPS_PER_BUFFER=0; wall-only requires it absent")
        }
    }

    private static func request(model: String, prompt: String) throws -> ChatCompletionRequest {
        let object: [String: Any] = [
            "model": model, "messages": [["role": "user", "content": prompt]],
            "max_tokens": 1, "temperature": 0, "top_p": 1.0, "stream": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(GLMPrefillProfileCapture.requestID)
    }
}

enum GLMPrefillProfileMode: String, ExpressibleByArgument, Sendable {
    case wallOnly = "wall-only"
    case census
}

/// Process-local, lab-only observer. Startup probes and all other requests are excluded.
enum GLMPrefillProfileCapture {
    static let requestID = "glm-prefill-profile"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: GLMPrefillProfileMode?
    nonisolated(unsafe) private static var chunks: [[String: Any]] = []
    nonisolated(unsafe) private static var promptTokenIDs: [Int] = []

    static func arm(mode: GLMPrefillProfileMode) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode; chunks = []; promptTokenIDs = []
    }
    static func disarm() {
        lock.lock(); defer { lock.unlock() }
        mode = nil
    }
    static func snapshot() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }
    static func observedPromptTokenIDs() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return promptTokenIDs
    }
    static func censusSummary(_ chunks: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        let countKeys = ["valid_command_buffers", "invalid_command_buffers", "failed_command_buffers",
                         "orphan_dispatches", "single_dispatch_command_buffers", "multi_dispatch_command_buffers",
                         "unknown_command_buffers"]
        let timeKeys = ["gpu_busy_seconds", "multi_dispatch_seconds", "unknown_seconds"]
        let captures = chunks.compactMap { $0["census"] as? [String: Any] }
        for key in countKeys { result[key] = captures.reduce(0) { $0 + ($1[key] as? Int ?? 0) } }
        for key in timeKeys { result[key] = captures.reduce(0.0) { $0 + ($1[key] as? Double ?? 0) } }
        for key in ["kernel_seconds", "partial_family_seconds"] {
            var values: [String: Double] = [:]
            for capture in captures {
                for (name, seconds) in capture[key] as? [String: Double] ?? [:] {
                    values[name, default: 0] += seconds
                }
            }
            result[key] = values
        }
        return result
    }

    static func begin(requestID: String, offset: Int, tokens: [Int]) -> Scope? {
        lock.lock()
        let selected = requestID == self.requestID ? mode : nil
        if selected != nil { promptTokenIDs.append(contentsOf: tokens) }
        lock.unlock()
        guard let selected else { return nil }
        return Scope(mode: selected, offset: offset, count: tokens.count)
    }

    final class Scope {
        private let mode: GLMPrefillProfileMode
        private let offset: Int
        private let count: Int
        private let started: Double
        init(mode: GLMPrefillProfileMode, offset: Int, count: Int) {
            self.mode = mode; self.offset = offset; self.count = count
            if mode == .census { LabDispatchCensus.begin() }
            started = ProcessInfo.processInfo.systemUptime
        }
        func finish(sampledToken: Int?) {
            let host = ProcessInfo.processInfo.systemUptime - started
            var record: [String: Any] = [
                "offset": offset, "prompt_tokens": count, "backend_host_seconds": host,
                "valid": true,
            ]
            if let sampledToken { record["sampled_token_id"] = sampledToken }
            if mode == .census {
                let census = LabDispatchCensus.finish()
                record["census"] = census
                record["valid"] = census["valid"]
            }
            lock.lock(); defer { lock.unlock() }
            chunks.append(record)
        }
    }
}
#endif
