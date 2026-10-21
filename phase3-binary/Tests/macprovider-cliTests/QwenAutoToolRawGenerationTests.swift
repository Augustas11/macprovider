import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// Offline diagnostic, NOT tool-calling acceptance. Run this test alone on the
/// designated Studio: its hard 180-second watchdog exits the test process (124).
/// Nothing starts a server, joins a coordinator, or invokes the output parser.
final class QwenAutoToolRawGenerationTests: XCTestCase {
    private struct Profile: Sendable {
        let id: String
        let artifactVariable: String
        let templateSHA: String
        let snapshotSHA: String

        static let all = [
            Profile(id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                    artifactVariable: "MACPROVIDER_QWEN_CODER_ARTIFACT_DIR",
                    templateSHA: "672e747c77e990320152343b0a4951222e40de5645297905d89afba05586d827",
                    snapshotSHA: "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0"),
            Profile(id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
                    artifactVariable: "MACPROVIDER_QWEN_INSTRUCT2507_ARTIFACT_DIR",
                    templateSHA: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541",
                    snapshotSHA: "a0ca3d59f301f08ae4c4c2010b07f80b890d35f4e8562c213b1d01aed8328e42"),
        ]
    }

    /// Opt in with MACPROVIDER_QWEN_RAW_DIAGNOSTIC=1, PRIVATE_MODEL (an exact
    /// profile), PRIVATE_REQUEST (unchanged Chat Completions body), the profile's
    /// ARTIFACT_DIR, and PRIVATE_OUTPUT_DIR (existing owned canonical 0700 dir).
    /// Each invocation creates one new 0600 qwen-raw-UUID.jsonl. A missing final
    /// event means incomplete evidence; earlier prompt/token events survive timeout.
    func testStudioOfflineRawAutoGeneration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_QWEN_RAW_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("MACPROVIDER_QWEN_RAW_DIAGNOSTIC is not enabled")
        }
        do {
            try Self.requireStudio()
            guard let profile = Profile.all.first(where: { $0.id == environment["MACPROVIDER_QWEN_PRIVATE_MODEL"] }),
                  let artifactPath = environment[profile.artifactVariable],
                  let requestPath = environment["MACPROVIDER_QWEN_PRIVATE_REQUEST"],
                  let outputPath = environment["MACPROVIDER_QWEN_PRIVATE_OUTPUT_DIR"] else {
                throw DiagnosticError.configuration
            }
            let sink = try PrivateSink.open(directory: outputPath)
            defer { close(sink.fd) }
            let watchdog = DispatchWorkItem { _exit(124) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 180, execute: watchdog)
            defer { watchdog.cancel() }
            let deadline = Date().addingTimeInterval(180)
            let started = ProcessInfo.processInfo.systemUptime
            try sink.append(["event": "started", "diagnostic_only": true, "model": profile.id,
                             "maximum_seconds": 180, "maximum_context_tokens": 16_384])

            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: requestPath))
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: ChatCompletionRequest.rawBodyByteCap + 1) ?? Data()
            let request = try ChatCompletionRequest.parse(data: bytes)
            guard try ToolSelectionPolicy.selection(request.promptSource.toolChoice) == .auto,
                  let maximum = request.maxTokens, (1...1024).contains(maximum),
                  !request.containsNonTextMessageContentPart,
                  ModelRuntime.hasEnabledTools(request.promptSource.tools) else {
                throw DiagnosticError.requestBounds
            }
            try ModelRuntime.validateNativeSamplingPenalties(request)
            let directory = URL(fileURLWithPath: artifactPath).standardizedFileURL
            let template = try Data(contentsOf: directory.appendingPathComponent("chat_template.jinja"))
            guard Self.hash(template) == profile.templateSHA else { throw DiagnosticError.artifactIdentity }
            // Full immutable snapshot pin, not a filename/model-ID assertion.
            let identity = try MLXSnapshotIdentity.compute(directory: directory, deadline: deadline)
            guard identity.digest == profile.snapshotSHA else { throw DiagnosticError.artifactIdentity }
            let thinking = ModelRuntime.chatTemplateSupportsThinkingToggle(in: directory)
            let preserve = ModelRuntime.chatTemplateSupportsPreserveThinking(in: directory)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: ChatTemplateCompatTokenizerLoader()
            )
            guard identity.isCurrent(deadline: deadline) else { throw DiagnosticError.artifactIdentity }
            try await container.perform { context in
                let prepared = try await ModelRuntime.preparedRequestInput(
                    for: request, context: context,
                    templateSupportsThinkingToggle: thinking,
                    templateSupportsPreserveThinking: preserve,
                    toolSelectionModelID: profile.id
                )
                let prompt = prepared.input.text.tokens.asArray(Int.self)
                guard prepared.toolCallPrefill == nil, !prompt.isEmpty,
                      prompt.count + maximum <= 16_384 else { throw DiagnosticError.requestBounds }
                try sink.append(["event": "prompt", "request_sha256": Self.hash(bytes),
                                 "snapshot_sha256": identity.digest, "template_sha256": profile.templateSHA,
                                 "prompt_token_ids": prompt, "max_tokens": maximum,
                                 "temperature": request.temperature, "top_p": request.topP,
                                 "forced_prefill": false, "prefill_step_size": 512,
                                 "cache": "fresh_serial", "parser": "bypassed"])
                let parameters = try ModelRuntime.makeServeGenerateParameters(
                    model: context.model, maxTokens: maximum, promptTokens: prompt.count,
                    maxContextTokens: 16_384, kvBitsOverride: nil, prefillStepSize: 512,
                    temperature: Float(request.temperature), topP: Float(request.topP)
                )
                let cache = try ModelRuntime.serveCache(model: context.model, baseParameters: parameters, forceSimpleKV: false)
                var iterator = try TokenIterator(
                    input: prepared.input, model: context.model, cache: cache,
                    parameters: ModelRuntime.serveIteratorParameters(parameters, forceSimpleKV: false, reusedCache: false, cache: cache)
                )
                var eos = context.configuration.eosTokenIds
                if let token = context.tokenizer.eosTokenId { eos.insert(token) }
                for marker in context.configuration.extraEOSTokens {
                    if let token = context.tokenizer.convertTokenToId(marker) { eos.insert(token) }
                }
                var raw: [Int] = []
                var reason = "length"
                while raw.count < maximum, let token = iterator.next() {
                    raw.append(token)
                    // Include terminal tokens: these are actual iterator output,
                    // before the serving loop strips EOS or the parser sees text.
                    try sink.append(["event": "raw_token", "index": raw.count - 1, "token_id": token])
                    if eos.contains(token) || token == context.tokenizer.unknownTokenId {
                        reason = "eos_or_unknown"
                        break
                    }
                    if !request.stop.isEmpty {
                        let text = context.tokenizer.decode(tokenIds: raw, skipSpecialTokens: false)
                        if request.stop.contains(where: { !$0.isEmpty && text.contains($0) }) {
                            reason = "request_stop"
                            break
                        }
                    }
                }
                Stream().synchronize()
                try sink.append(["event": "complete", "raw_token_ids": raw,
                                 "raw_text": context.tokenizer.decode(tokenIds: raw, skipSpecialTokens: false),
                                 "stop_reason": reason, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
                                 "serial_tool_parser_stop": "intentionally_bypassed"])
            }
        } catch let error as DiagnosticError {
            XCTFail("Offline Qwen diagnostic refused: \(error.rawValue)")
        } catch {
            // Model/request/template errors may contain private prompt material.
            XCTFail("Offline Qwen diagnostic failed; private data and error details withheld")
        }
    }

    private static func requireStudio() throws {
        var hostname = [CChar](repeating: 0, count: 256)
        guard gethostname(&hostname, hostname.count) == 0,
              String(cString: hostname) == "1deMac-Studio.local" else { throw DiagnosticError.host }
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0, length <= 256 else {
            throw DiagnosticError.host
        }
        var model = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &model, &length, nil, 0) == 0,
              String(cString: model) == "Mac15,14" else { throw DiagnosticError.host }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum DiagnosticError: String, Error {
        case configuration, host, requestBounds, artifactIdentity, output
    }

    private struct PrivateSink: Sendable {
        let fd: Int32

        static func open(directory path: String) throws -> PrivateSink {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard path.hasPrefix("/"), url.standardizedFileURL.path == path,
                  url.resolvingSymlinksInPath().path == path else { throw DiagnosticError.output }
            var root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw DiagnosticError.output }
            defer { close(root) }
            // Anchor every component: a parent symlink swap cannot redirect the
            // output between the canonical-path check and exclusive file creation.
            for component in path.split(separator: "/") {
                let next = openat(root, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DiagnosticError.output }
                close(root)
                root = next
            }
            var info = stat()
            guard fstat(root, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else {
                throw DiagnosticError.output
            }
            let fd = openat(root, "qwen-raw-\(UUID().uuidString.lowercased()).jsonl",
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw DiagnosticError.output }
            guard fchmod(fd, mode_t(0o600)) == 0 else {
                close(fd)
                throw DiagnosticError.output
            }
            return PrivateSink(fd: fd)
        }

        func append(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            bytes.append(0x0a)
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw DiagnosticError.output }
                    offset += count
                }
            }
        }
    }
}
