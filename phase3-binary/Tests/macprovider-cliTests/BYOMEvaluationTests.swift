import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMEvaluationTests: XCTestCase {
    func testEvaluateCommandRequiresJSONFlag() async throws {
        let command = try ModelsEvaluateCommand.parse(["ollama:Tiny-Ollama-1B-Q4", "--skip-ollama"])
        let capture = await captureBYOMEvaluationOutput {
            try await command.run()
        }

        XCTAssertTrue(capture.stdout.isEmpty)
        XCTAssertTrue(capture.stderr.contains("JSON-only"))
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testEvaluateCommandRunsHermeticLoopbackRuntimeWithoutMutation() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-loopback")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: """
            {"models":[{"name":"Tiny-Ollama-1B-Q4","details":{"family":"llama","quantization_level":"Q4_0"}}]}
            """,
            chatStatusCode: 200,
            chatBody: """
            {"id":"chatcmpl-local","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
            """
        )

        let command = try ModelsEvaluateCommand.parse([
            "ollama:Tiny-Ollama-1B-Q4",
            "--json",
            "--local-discovery-namespace-path", namespace.path,
            "--mlx-cache-dir", cache.path,
            "--ollama-origin", runtime.origin,
        ])
        let capture = await captureBYOMEvaluationOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["schema"] as? String, "provider_byom_evaluation.v1")
        XCTAssertEqual(object["runtime_source"] as? String, "ollama_loopback")
        XCTAssertEqual(object["served_model_ref"] as? String, "ollama:Tiny-Ollama-1B-Q4")
        XCTAssertEqual(object["adapter_identity"] as? String, "openai_compatible_loopback")
        XCTAssertEqual(object["health_result"] as? String, "passed")
        XCTAssertEqual(object["request_count"] as? Int, 1)
        XCTAssertEqual(object["completion_tokens"] as? Int, 2)
        XCTAssertEqual(object["usage_reporting_source"] as? String, "runtime_reported")
        XCTAssertEqual(object["offer_preconditions_appear_satisfied"] as? Bool, true)
        let mutations = try XCTUnwrap(object["mutation_summary"] as? [String: Any])
        XCTAssertEqual(mutations["production_config_mutated"] as? Bool, false)
        XCTAssertEqual(mutations["coordinator_state_mutated"] as? Bool, false)
        XCTAssertEqual(mutations["production_model_switched"] as? Bool, false)
        XCTAssertEqual(mutations["runtime_started"] as? Bool, false)
        XCTAssertEqual(mutations["downloads_started"] as? Bool, false)
        let guidance = try XCTUnwrap(object["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")
        let encoded = capture.stdout + capture.stderr
        XCTAssertFalse(encoded.contains("MacProvider BYOM local evaluation health probe"))
        XCTAssertFalse(encoded.contains("\"content\":\"ok\""))
        XCTAssertFalse(encoded.contains(runtime.origin))
        XCTAssertEqual(runtime.requestPaths, ["/api/tags", "/v1/chat/completions"])
    }

    func testEvaluateMLXCandidateBlocksWithoutCacheMutation() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-mlx")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try createBYOMMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let before = try recursiveBYOMEvaluationPaths(cache)

        let document = await BYOMEvaluationRunner(
            target: "mlx-community/Tiny-1B-4bit",
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).evaluate()

        XCTAssertEqual(document.schema, "provider_byom_evaluation.v1")
        XCTAssertEqual(document.runtimeSource, "mlx_cache")
        XCTAssertEqual(document.healthResult, "blocked")
        XCTAssertEqual(document.requestCount, 0)
        XCTAssertEqual(document.mutationSummary.downloadsStarted, false)
        XCTAssertEqual(document.mutationSummary.productionModelSwitched, false)
        XCTAssertTrue(document.warnings.contains("requires_preparation"))
        let after = try recursiveBYOMEvaluationPaths(cache)
        XCTAssertEqual(before, after)
    }

    func testEvaluateRuntimeTimeoutFailsClosed() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-timeout")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postError: URLError(.timedOut)
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "timed_out")
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_timeout"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
        XCTAssertEqual(document.mutationSummary.coordinatorStateMutated, false)
    }

    func testEvaluateMalformedRuntimeResponseFailsClosedAndHashesBody() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-malformed")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"choices":[]}"#.utf8))
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertNotNil(document.diagnosticHashes.responseBodySHA256)
    }

    func testEvaluateMalformedNonemptyChoicesFailClosed() async throws {
        let malformedBodies = [
            #"{"choices":[{}]}"#,
            #"{"choices":[{"message":{}}]}"#,
            #"{"choices":[{"message":{"role":"tool","content":"ok"}}]}"#,
            #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#,
        ]

        for body in malformedBodies {
            let root = try temporaryBYOMEvaluationDirectory("byom-eval-malformed-choice")
            let client = BYOMEvaluationStubHTTPClient(
                tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
                postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
            )

            let document = await BYOMEvaluationRunner(
                target: "ollama:Tiny-Ollama-1B-Q4",
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: "http://127.0.0.1:11434"
                ),
                httpClient: client
            ).evaluate()

            XCTAssertEqual(document.healthResult, "failed", body)
            XCTAssertFalse(document.offerPreconditionsAppearSatisfied, body)
            XCTAssertTrue(document.warnings.contains("adapter_malformed_response"), body)
            XCTAssertTrue(document.warnings.contains("evaluation_failed"), body)
            XCTAssertEqual(document.capabilityResults["chat_completions"]?.result, "not_tested", body)
        }
    }

    func testEvaluateRejectsMalformedOrOverLimitUsageTokens() async throws {
        let malformedBodies = [
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completion_tokens":1e20}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completion_tokens":9}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"completionTokens":"2"}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"output_tokens":-1}}"#,
        ]

        for body in malformedBodies {
            let root = try temporaryBYOMEvaluationDirectory("byom-eval-usage-bound")
            let client = BYOMEvaluationStubHTTPClient(
                tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
                postResponse: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
            )

            let document = await BYOMEvaluationRunner(
                target: "ollama:Tiny-Ollama-1B-Q4",
                environment: BYOMDiscoveryEnvironment(
                    namespaceURL: root.appendingPathComponent("ns"),
                    mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                    ollamaOrigin: "http://127.0.0.1:11434"
                ),
                httpClient: client
            ).evaluate()

            XCTAssertEqual(document.healthResult, "failed", body)
            XCTAssertNil(document.completionTokens, body)
            XCTAssertNil(document.tokensPerSecond, body)
            XCTAssertEqual(document.usageReportingSource, "not_evaluated", body)
            XCTAssertTrue(document.warnings.contains("adapter_malformed_response"), body)
            XCTAssertTrue(document.warnings.contains("evaluation_failed"), body)
        }
    }

    func testEvaluateRejectsInvalidOriginBeforeRuntimePost() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-origin")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://localhost:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.healthResult, "blocked")
        XCTAssertEqual(client.postCount, 0)
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
    }

    func testEvaluateUnknownCandidateDoesNotReflectUnsafeTarget() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-unknown")
        let client = BYOMEvaluationStubHTTPClient(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#
        )

        let document = await BYOMEvaluationRunner(
            target: "http://192.168.1.10:11434/private-model",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).evaluate()

        XCTAssertEqual(document.candidateID, "unknown")
        XCTAssertEqual(document.servedModelRef, "unknown")
        XCTAssertEqual(document.runtimeSource, "unknown")
        XCTAssertEqual(client.postCount, 0)
        XCTAssertFalse(document.diagnosticHashes.promptSHA256.isEmpty)
        XCTAssertNil(document.diagnosticHashes.responseBodySHA256)
    }

    func testURLSessionEvaluationPostRejectsNonLoopbackURLBeforeDispatch() async throws {
        do {
            _ = try await BYOMURLSessionHTTPClient().post(
                URL(string: "http://192.168.1.10:11434/v1/chat/completions")!,
                jsonBody: Data(#"{"model":"x"}"#.utf8),
                maxHeaderBytes: 1024,
                maxBodyBytes: 1024
            )
            XCTFail("non-loopback evaluation URL must be rejected before dispatch")
        } catch BYOMDiscoveryAdapterError.rejectedNonLoopback {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await BYOMURLSessionHTTPClient().post(
                URL(string: "http://127.0.0.1:11434/v1/chat/completions?next=http://192.168.1.10")!,
                jsonBody: Data(#"{"model":"x"}"#.utf8),
                maxHeaderBytes: 1024,
                maxBodyBytes: 1024
            )
            XCTFail("query-bearing evaluation URL must be rejected before dispatch")
        } catch BYOMDiscoveryAdapterError.rejectedNonLoopback {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEvaluateRedirectResponseDoesNotFollowNonLoopbackTarget() async throws {
        let root = try temporaryBYOMEvaluationDirectory("byom-eval-redirect")
        let runtime = try BYOMEvaluationLoopbackRuntime(
            tagsBody: #"{"models":[{"name":"Tiny-Ollama-1B-Q4"}]}"#,
            chatStatusCode: 302,
            chatHeaders: [("Location", "http://192.168.1.10:11434/v1/chat/completions")],
            chatBody: ""
        )

        let document = await BYOMEvaluationRunner(
            target: "ollama:Tiny-Ollama-1B-Q4",
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: runtime.origin
            )
        ).evaluate()

        XCTAssertEqual(document.healthResult, "failed")
        XCTAssertEqual(runtime.requestPaths, ["/api/tags", "/v1/chat/completions"])
        XCTAssertFalse(document.offerPreconditionsAppearSatisfied)
        XCTAssertTrue(document.warnings.contains("adapter_rejected_non_loopback"))
        XCTAssertTrue(document.warnings.contains("evaluation_failed"))
    }

    private func temporaryBYOMEvaluationDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createBYOMMLXSnapshot(cacheRoot: URL, modelID: String) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":2048}"#.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }

    private func recursiveBYOMEvaluationPaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            result.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return result.sorted()
    }

    private func jsonObject(_ stdout: String) throws -> [String: Any] {
        let line = try XCTUnwrap(stdout.split(whereSeparator: \.isNewline).first { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private final class BYOMEvaluationStubHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let tagsBody: String
    private let postResponse: BYOMHTTPResponse?
    private let postError: Error?
    private var posts = 0

    var postCount: Int {
        lock.withLock { posts }
    }

    init(tagsBody: String, postResponse: BYOMHTTPResponse? = nil, postError: Error? = nil) {
        self.tagsBody = tagsBody
        self.postResponse = postResponse
        self.postError = postError
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 200, headers: [("content-type", "application/json")], body: Data(tagsBody.utf8))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            posts += 1
        }
        if let postError {
            throw postError
        }
        return postResponse ?? BYOMHTTPResponse(statusCode: 200, headers: [], body: Data())
    }
}

private final class BYOMEvaluationLoopbackRuntime {
    let origin: String
    private let socketFD: Int32
    private let tagsBody: Data
    private let chatStatusCode: Int
    private let chatHeaders: [(String, String)]
    private let chatBody: Data
    private let lock = NSLock()
    private var paths: [String] = []

    var requestPaths: [String] {
        lock.withLock { paths }
    }

    init(
        tagsBody: String,
        chatStatusCode: Int,
        chatHeaders: [(String, String)] = [],
        chatBody: String
    ) throws {
        self.tagsBody = Data(tagsBody.utf8)
        self.chatStatusCode = chatStatusCode
        self.chatHeaders = chatHeaders
        self.chatBody = Data(chatBody.utf8)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard Darwin.listen(fd, 2) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        origin = "http://127.0.0.1:\(UInt16(bigEndian: bound.sin_port))"

        DispatchQueue.global(qos: .userInitiated).async { [weak self, fd] in
            for _ in 0..<2 {
                guard let self else { return }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                self.handle(client)
            }
        }
    }

    deinit {
        Darwin.close(socketFD)
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let request = String(decoding: buffer.prefix(count), as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        record(path)
        if path == "/api/tags" {
            write(statusCode: 200, headers: [], body: tagsBody, to: client)
        } else {
            write(statusCode: chatStatusCode, headers: chatHeaders, body: chatBody, to: client)
        }
    }

    private func record(_ path: String) {
        lock.withLock {
            paths.append(path)
        }
    }

    private func write(statusCode: Int, headers: [(String, String)], body: Data, to client: Int32) {
        var responseHeaders = [
            "HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Found")",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        responseHeaders.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        let head = responseHeaders.joined(separator: "\r\n") + "\r\n\r\n"
        _ = writeAll(Data(head.utf8), to: client)
        _ = writeAll(body, to: client)
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent)
                if result <= 0 {
                    return false
                }
                sent += result
            }
            return true
        }
    }
}

private struct BYOMEvaluationCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMEvaluationOutput(_ body: () async throws -> Void) async -> BYOMEvaluationCapturedOutput {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let error: Error?
    do {
        try await body()
        error = nil
    } catch let caught {
        error = caught
    }

    fflush(stdout)
    fflush(stderr)
    dup2(savedStdout, STDOUT_FILENO)
    dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return BYOMEvaluationCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
