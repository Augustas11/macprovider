import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMDiscoveryTests: XCTestCase {
    func testDiscoverCommandEmitsClosedSchemaWithNullableAdvisoryFields() async throws {
        let root = try temporaryDirectory("byom-schema")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespaceDir = root.appendingPathComponent("nsdir", isDirectory: true)
        try FileManager.default.createDirectory(at: namespaceDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespaceDir.path)
        let namespace = namespaceDir.appendingPathComponent("ns")
        try Data(repeating: 0x37, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        let namespaceBefore = try Data(contentsOf: namespace)
        try createMLXSnapshot(
            cacheRoot: cache,
            modelID: "mlx-community/Tiny-1B-4bit",
            configJSON: #"{"max_position_embeddings":4096}"#
        )

        let command = try ModelsDiscoverCommand.parse([
            "--json",
            "--local-discovery-namespace-path", namespace.path,
            "--mlx-cache-dir", cache.path,
            "--skip-ollama",
        ])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        let object = try jsonObject(capture.stdout)
        XCTAssertEqual(object["schema"] as? String, "provider_byom_discovery.v1")
        XCTAssertEqual(object["projection_sequence"] as? Int, 1)
        XCTAssertEqual(object["cli_version"] as? String, CoordinatorClient.binaryVersion)
        let adapters = try XCTUnwrap(object["adapters"] as? [[String: Any]])
        XCTAssertEqual(adapters.first?["runtime_source"] as? String, "mlx_cache")
        let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate["runtime_source"] as? String, "mlx_cache")
        XCTAssertEqual(candidate["served_model_ref"] as? String, "mlx-community/Tiny-1B-4bit")
        XCTAssertTrue((candidate["candidate_id"] as? String)?.hasPrefix("byom_") == true)
        XCTAssertEqual(candidate["locality"] as? String, "local_artifact")
        XCTAssertEqual(candidate["readiness_state"] as? String, "ready")
        XCTAssertEqual(candidate["evaluation_state"] as? String, "not_evaluated")
        XCTAssertEqual(candidate["admission_state_source"] as? String, "local_default")
        XCTAssertEqual(candidate["admission_state"] as? String, "offerable")
        XCTAssertEqual(candidate["context_window_tokens"] as? Int, 4096)
        XCTAssertTrue(candidate.keys.contains("catalog_model_key"))
        let capabilities = try XCTUnwrap(candidate["capabilities"] as? [String: Any])
        XCTAssertTrue(capabilities.keys.contains("tool_call_passthrough"))
        XCTAssertTrue(capabilities["tool_call_passthrough"] is NSNull)
        XCTAssertEqual(capabilities["max_context_tokens"] as? Int, 4096)
        let guidance = try XCTUnwrap(candidate["provider_guidance"] as? [String: Any])
        XCTAssertEqual(guidance["earning_path_class"] as? String, "local_inventory_only")
        // Discovery is read-only: a pre-existing salt is read, never rewritten.
        XCTAssertEqual(try Data(contentsOf: namespace), namespaceBefore)
    }

    func testDiscoverIsReadOnlyWhenNamespaceMissing() async throws {
        let root = try temporaryDirectory("byom-readonly")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("missing-ns")
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        // SPEC-046-R001: discovery MUST NOT provision the salt (no write).
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.path))
        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("candidate_id_unstable"))
    }

    func testMLXWeightSymlinkIntoBlobsIsResolvedAndCounted() async throws {
        let root = try temporaryDirectory("byom-symlink")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        // Mimic a real HF cache: weights live in blobs/ and the snapshot holds
        // relative symlinks into them (the shape H1 must handle).
        let repo = cache.appendingPathComponent("models--mlx-community--Tiny-1B-4bit", isDirectory: true)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: blobs.appendingPathComponent("config-blob"))
        try Data(repeating: 0x7a, count: 4096).write(to: blobs.appendingPathComponent("weights-blob"))
        // Use the path/string API so the destination stays a genuine RELATIVE
        // symlink (the URL API would resolve it against the cwd).
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("config.json").path,
            withDestinationPath: "../../blobs/config-blob"
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weights-blob"
        )
        // An escaping symlink must be ignored, never followed out of the cache.
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("escape.safetensors").path,
            withDestinationPath: "/etc/hosts"
        )

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: root.appendingPathComponent("ns"), mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let candidate = try XCTUnwrap(document.candidates.first)
        // Symlinked config + weights are resolved, so the model reads as ready.
        XCTAssertEqual(candidate.readinessState, "ready")
    }

    func testRuntimeModelReferenceRejectsHostnameAndHostPortShapes() {
        for leak in [
            "coordinator.malibu.tech:443",
            "prod.internal:11434",
            "example.com:8080",
            "macbook.local",
            "gateway.corp",
            "::ffff:127.0.0.1",
            "0x7f.0.0.1",
        ] {
            XCTAssertFalse(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(leak), "must reject \(leak)")
        }
        for ok in ["llama3.2:3b", "mistral:latest", "qwen2.5:7b", "gemma2:9b", "deepseek-r1:14b"] {
            XCTAssertTrue(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(ok), "must allow \(ok)")
        }
    }

    func testDiscoverCommandMirrorsWarningsToStderrInJSONMode() async throws {
        let root = try temporaryDirectory("byom-stderr")
        let command = try ModelsDiscoverCommand.parse([
            "--json",
            "--local-discovery-namespace-path", root.appendingPathComponent("ns").path,
            "--mlx-cache-dir", root.appendingPathComponent("missing-cache", isDirectory: true).path,
            "--skip-ollama",
        ])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertNil(capture.error)
        XCTAssertNoThrow(try jsonObject(capture.stdout))
        XCTAssertTrue(capture.stderr.contains("models discover warning: adapter_unavailable"))
        XCTAssertFalse(capture.stderr.contains(root.path))
    }

    func testDiscoverCommandRequiresJSONFlag() async throws {
        let command = try ModelsDiscoverCommand.parse(["--skip-ollama"])
        let capture = await captureBYOMOutput {
            try await command.run()
        }

        XCTAssertTrue(capture.stdout.isEmpty)
        XCTAssertTrue(capture.stderr.contains("JSON-only"))
        XCTAssertEqual((capture.error as? ExitCode), ExitCode(2))
    }

    func testCandidateIDIsStableWithinNamespaceAndScopedByRuntimeSource() {
        let namespace = Data(repeating: 0x42, count: 32)
        let first = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: "MLX-Community/Tiny-1B"
        )
        let second = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: "mlx-community/tiny-1b"
        )
        let otherRuntime = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "ollama_loopback",
            servedModelRef: "mlx-community/tiny-1b"
        )

        XCTAssertEqual(first.0, second.0)
        XCTAssertNotEqual(first.0, otherRuntime.0)
        XCTAssertEqual(first.1.map(\.rawValue), [])
        XCTAssertTrue(first.0.range(of: #"^byom_[a-z2-7]+$"#, options: .regularExpression) != nil)
    }

    func testInvalidNamespacePermissionsKeepCandidateLocalOnly() async throws {
        let root = try temporaryDirectory("byom-ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try Data(repeating: 0x11, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: namespace.path)
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        XCTAssertTrue(document.warnings.contains("namespace_permission_invalid"))
        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_unstable_"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("candidate_id_unstable"))
        XCTAssertTrue(candidate.warningCodes.contains("namespace_permission_invalid"))
    }

    func testInsecureNamespaceDirectoryKeepsCandidateLocalOnly() async throws {
        let root = try temporaryDirectory("byom-ns-dir")
        let insecureDir = root.appendingPathComponent("insecure", isDirectory: true)
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = insecureDir.appendingPathComponent("ns")
        try FileManager.default.createDirectory(at: insecureDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: insecureDir.path)
        try Data(repeating: 0x11, count: 32).write(to: namespace)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namespace.path)
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")

        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let candidate = try XCTUnwrap(document.candidates.first)
        XCTAssertTrue(document.warnings.contains("namespace_permission_invalid"))
        XCTAssertEqual(candidate.admissionState, "local_only")
        XCTAssertTrue(candidate.warningCodes.contains("namespace_permission_invalid"))
    }

    func testLoopbackOriginValidatorAcceptsOnlyLiteralLoopbackHTTPOrigins() {
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1:11434"))
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.9.8.7:11434"))
        XCTAssertNotNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://[::1]:11434"))

        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("https://127.0.0.1:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://localhost:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://LOCALHOST:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1.example.com:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://0.0.0.0:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://192.168.1.10:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://127.0.0.1"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("http://user:pass@127.0.0.1:11434"))
        XCTAssertNil(BYOMLoopbackOriginValidator.validatedHTTPOrigin("unix:///tmp/ollama.sock"))
    }

    func testOllamaDiscoveryUsesHermeticLoopbackResponseAndRedactsUnsafeFields() async throws {
        let root = try temporaryDirectory("byom-ollama")
        let namespace = root.appendingPathComponent("ns")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let leakedEndpoint = "http://127.0.0.1:11434"
        let secret = "sk-local-secret"
        let body = """
        {"models":[
          {"name":"Tiny-Ollama-1B-Q4","details":{"family":"llama","quantization_level":"Q4_0"}},
          {"name":"/Users/augstar/\(secret)<script>","details":{"family":"bad"}},
          {"name":"http://127.0.0.1:11434/\(secret)?api_key=hidden","details":{"family":"bad"}},
          {"name":"127.0.0.1:11434","details":{"family":"bad"}},
          {"name":"127.0.0.1","details":{"family":"bad"}},
          {"name":"localhost","details":{"family":"bad"}},
          {"name":"[::1]","details":{"family":"bad"}},
          {"name":"sk-local-secret","details":{"family":"bad"}},
          {"name":"ghp_abcdefghijklmnopqrstuvwxyz0123456789","details":{"family":"bad"}},
          {"name":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signature000","details":{"family":"bad"}},
          {"name":"safe-name","details":{"family":"http://127.0.0.1:11434/\(secret)","quantization_level":"api_key=hidden"}}
        ]}
        """
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(body.utf8)
        ))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: namespace,
                mlxCacheRoot: cache,
                ollamaOrigin: leakedEndpoint
            ),
            httpClient: client
        ).discover()
        let encoded = try ModelSwitchingWireCodec.encode(document)

        XCTAssertEqual(document.candidates.count, 2)
        let candidate = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "ollama:Tiny-Ollama-1B-Q4" })
        XCTAssertEqual(candidate.runtimeSource, "ollama_loopback")
        XCTAssertEqual(candidate.servedModelRef, "ollama:Tiny-Ollama-1B-Q4")
        XCTAssertEqual(candidate.capabilities.chatCompletions, true)
        XCTAssertEqual(candidate.capabilities.family, "llama")
        XCTAssertEqual(candidate.capabilities.quantization, "Q4_0")
        let safeNameCandidate = try XCTUnwrap(document.candidates.first { $0.servedModelRef == "ollama:safe-name" })
        XCTAssertNil(safeNameCandidate.capabilities.family)
        XCTAssertNil(safeNameCandidate.capabilities.quantization)
        XCTAssertFalse(encoded.contains(leakedEndpoint))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("/Users/augstar"))
        XCTAssertFalse(encoded.contains("api_key"))
        XCTAssertFalse(encoded.contains("ghp_"))
        XCTAssertFalse(encoded.contains("eyJhbGci"))
        XCTAssertFalse(encoded.lowercased().contains("<script>"))
    }

    func testRejectedAdapterOriginIsReportedWithoutEndpointLeak() async throws {
        let root = try temporaryDirectory("byom-rejected-origin")
        let origin = "http://localhost:11434"
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: origin
            ),
            httpClient: StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: Data()))
        ).discover()
        let encoded = try ModelSwitchingWireCodec.encode(document)

        XCTAssertTrue(document.warnings.contains("adapter_rejected_non_loopback"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "rejected")
        XCTAssertFalse(encoded.contains(origin))
    }

    func testOversizedOllamaResponseIsTruncatedNotParsed() async throws {
        let root = try temporaryDirectory("byom-oversized")
        let body = Data(repeating: UInt8(ascii: "{"), count: BYOMDiscoveryHTTPBounds.maxBodyBytes + 1)
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: body))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_response_truncated"))
        XCTAssertTrue(document.candidates.isEmpty)
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "truncated")
    }

    func testURLSessionClientStopsReadingOversizedLoopbackBody() async throws {
        let bodySize = 16 * 1024
        let server = try OneShotHTTPServer(
            body: Data(repeating: UInt8(ascii: "x"), count: bodySize),
            chunkSize: 256,
            chunkDelayMicroseconds: 2_000
        )

        do {
            _ = try await BYOMURLSessionHTTPClient().get(
                server.url,
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: 1024
            )
            XCTFail("expected oversized streaming response to truncate")
        } catch BYOMDiscoveryAdapterError.truncated {
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(server.bytesAttempted >= 1024)
            XCTAssertLessThan(server.bytesAttempted, bodySize)
        }
    }

    func testURLSessionClientRejectsOversizedLoopbackHeaders() async throws {
        let server = try OneShotHTTPServer(
            headers: [("X-Too-Large", String(repeating: "a", count: BYOMDiscoveryHTTPBounds.maxHeaderBytes + 1))],
            body: Data(#"{"models":[]}"#.utf8)
        )

        do {
            _ = try await BYOMURLSessionHTTPClient().get(
                server.url,
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
            )
            XCTFail("expected oversized response headers to truncate")
        } catch BYOMDiscoveryAdapterError.truncated {
            XCTAssertEqual(server.requestCount, 1)
        }
    }

    func testURLSessionClientRefusesRedirects() async throws {
        let server = try OneShotHTTPServer(
            statusCode: 302,
            headers: [("Location", "http://192.168.1.10:11434/api/tags")],
            body: Data()
        )

        let response = try await BYOMURLSessionHTTPClient().get(
            server.url,
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
        )

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testURLSessionClientUsesDirectNoProxyConfiguration() {
        let configuration = BYOMURLSessionHTTPClient.directLoopbackConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.isEmpty, true)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testTransportFailureIsUnavailableNotMalformed() async throws {
        let root = try temporaryDirectory("byom-transport")
        let client = StubBYOMHTTPClient(error: URLError(.cannotConnectToHost))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_unavailable"))
        XCTAssertFalse(document.warnings.contains("adapter_malformed_response"))
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "unavailable")
    }

    func testMalformedOllamaResponseEmitsWarningNotCandidate() async throws {
        let root = try temporaryDirectory("byom-malformed")
        let client = StubBYOMHTTPClient(response: BYOMHTTPResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"models":[{"name":"unterminated"}"#.utf8)
        ))
        let document = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: root.appendingPathComponent("ns"),
                mlxCacheRoot: root.appendingPathComponent("hf", isDirectory: true),
                ollamaOrigin: "http://127.0.0.1:11434"
            ),
            httpClient: client
        ).discover()

        XCTAssertTrue(document.warnings.contains("adapter_malformed_response"))
        XCTAssertTrue(document.candidates.isEmpty)
        XCTAssertEqual(document.adapters.first { $0.runtimeSource == "ollama_loopback" }?.status, "malformed")
    }

    func testDiscoveryDoesNotMutateModelCache() async throws {
        let root = try temporaryDirectory("byom-readonly")
        let cache = root.appendingPathComponent("hf", isDirectory: true)
        let namespace = root.appendingPathComponent("ns")
        try createMLXSnapshot(cacheRoot: cache, modelID: "mlx-community/Tiny-1B-4bit")
        let before = try recursiveRelativePaths(cache)

        _ = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(namespaceURL: namespace, mlxCacheRoot: cache, ollamaOrigin: nil)
        ).discover()

        let after = try recursiveRelativePaths(cache)
        XCTAssertEqual(before, after)
    }

    private func createMLXSnapshot(
        cacheRoot: URL,
        modelID: String,
        configJSON: String = #"{"max_position_embeddings":2048}"#
    ) throws {
        let repo = cacheRoot
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0123456789abcdef0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(configJSON.utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0x7a, count: 128).write(to: repo.appendingPathComponent("model.safetensors"))
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonObject(_ stdout: String) throws -> [String: Any] {
        let line = try XCTUnwrap(stdout.split(whereSeparator: \.isNewline).first { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func recursiveRelativePaths(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            result.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return result.sorted()
    }
}

private final class StubBYOMHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    let response: BYOMHTTPResponse?
    let error: Error?

    init(response: BYOMHTTPResponse) {
        self.response = response
        self.error = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        if let error {
            throw error
        }
        return try XCTUnwrap(response)
    }
}

private final class OneShotHTTPServer {
    let url: URL
    private let socketFD: Int32
    private let lock = NSLock()
    private var attempted = 0

    var bytesAttempted: Int {
        lock.withLock { attempted }
    }

    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    init(
        statusCode: Int = 200,
        headers: [(String, String)] = [],
        body: Data,
        chunkSize: Int = 512,
        chunkDelayMicroseconds: useconds_t = 0
    ) throws {
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
        guard Darwin.listen(fd, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: bound.sin_port))/api/tags"))

        DispatchQueue.global(qos: .userInitiated).async { [fd, weak self] in
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }

            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = Darwin.read(client, &buffer, buffer.count)

            self?.recordRequest()

            var responseHeaders = [
                "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))",
                "Content-Type: application/json",
                "Content-Length: \(body.count)",
                "Connection: close",
            ]
            responseHeaders.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
            let header = responseHeaders.joined(separator: "\r\n") + "\r\n\r\n"
            guard Self.writeAll(data: Data(header.utf8), to: client) else { return }
            var offset = 0
            while offset < body.count {
                let next = min(offset + chunkSize, body.count)
                let chunk = body[offset..<next]
                self?.recordAttempt(chunk.count)
                guard Self.writeAll(data: Data(chunk), to: client) else { return }
                offset = next
                if chunkDelayMicroseconds > 0 {
                    usleep(chunkDelayMicroseconds)
                }
            }
        }
    }

    deinit {
        Darwin.close(socketFD)
    }

    private func recordAttempt(_ count: Int) {
        lock.withLock {
            attempted += count
        }
    }

    private func recordRequest() {
        lock.withLock {
            requests += 1
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 302:
            return "Found"
        default:
            return "Status"
        }
    }

    private static func writeAll(data: Data, to fd: Int32) -> Bool {
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

private struct BYOMCapturedOutput {
    let stdout: String
    let stderr: String
    let error: Error?
}

private func captureBYOMOutput(_ body: () async throws -> Void) async -> BYOMCapturedOutput {
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
    return BYOMCapturedOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        error: error
    )
}
