import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MacProviderCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
import zlib
@testable import macprovider_cli

private final class ConsumeStubUpstreamClient: ConsumeUpstreamClient, @unchecked Sendable {
    private let resolver: @Sendable (String, EventLoop) -> EventLoopFuture<String>
    private let handler: @Sendable (ConsumeUpstreamRequest, EventLoop) -> EventLoopFuture<ConsumeUpstreamResponse>

    init(
        resolver: @escaping @Sendable (String, EventLoop) -> EventLoopFuture<String> = { _, eventLoop in
            eventLoop.makeSucceededFuture("8.8.8.8")
        },
        handler: @escaping @Sendable (ConsumeUpstreamRequest, EventLoop) -> EventLoopFuture<ConsumeUpstreamResponse>
    ) {
        self.resolver = resolver
        self.handler = handler
    }

    func resolveChatCompletionsEndpoint(
        origin: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<String> {
        resolver(origin, eventLoop)
    }

    func forwardChatCompletions(
        request: ConsumeUpstreamRequest,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ConsumeUpstreamResponse> {
        handler(request, eventLoop)
    }
}

private final class ConsumeUpstreamRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConsumeUpstreamRequest] = []

    func append(_ request: ConsumeUpstreamRequest) {
        lock.lock()
        values.append(request)
        lock.unlock()
    }

    func snapshot() -> [ConsumeUpstreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ConsumeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ConsumeUpstreamPromiseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<ConsumeUpstreamResponse>?

    func set(_ promise: EventLoopPromise<ConsumeUpstreamResponse>) {
        lock.lock()
        self.promise = promise
        lock.unlock()
    }

    func succeed(_ response: ConsumeUpstreamResponse) {
        lock.lock()
        let current = promise
        lock.unlock()
        current?.succeed(response)
    }
}

private final class ConsumeEndpointPromiseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<String>?

    func set(_ promise: EventLoopPromise<String>) {
        lock.lock()
        self.promise = promise
        lock.unlock()
    }

    func succeed(_ endpoint: String) {
        lock.lock()
        let current = promise
        lock.unlock()
        current?.succeed(endpoint)
    }
}

private final class ConsumeDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func get() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

final class ConsumeCommandTests: XCTestCase {
    func testBindValidationAcceptsLoopbackAndRejectsPublicInputs() throws {
        XCTAssertEqual(try ConsumeEndpointConfig.normalizeBindAddress("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(try ConsumeEndpointConfig.normalizeBindAddress("127.0.0.2"), "127.0.0.2")
        XCTAssertEqual(try ConsumeEndpointConfig.normalizeBindAddress("localhost"), "127.0.0.1")
        XCTAssertEqual(try ConsumeEndpointConfig.normalizeBindAddress("::1"), "::1")
        XCTAssertEqual(ConsumeEndpointConfig.localBaseURL(bindAddress: "::1", port: 11435), "http://[::1]:11435")
        XCTAssertEqual(ConsumeEndpointConfig.localBaseURL(bindAddress: "127.0.0.1", port: 11435), "http://127.0.0.1:11435")
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeBindAddress("0.0.0.0"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeBindAddress("192.168.1.10"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeBindAddress("example.com"))
    }

    func testUpstreamOriginValidationRejectsNonOrigins() throws {
        XCTAssertEqual(
            try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://api.malibu.tech/"),
            "https://api.malibu.tech"
        )
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("http://api.malibu.tech"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://user:pass@api.malibu.tech"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://api.malibu.tech/v1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://api.malibu.tech?x=1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://localhost"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://127.0.0.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://10.1.2.3"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://172.16.0.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://192.168.1.10"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://169.254.1.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://100.64.0.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://192.0.2.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://192.88.99.2"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://224.0.0.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[fc00::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[fe80::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[fec0::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[5f00::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[2001:db8::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[::ffff:192.168.1.10]"))
    }

    func testLocalTokenVerifierAcceptsOnlyOneAcceptedHeader() throws {
        let token = try ConsumeLocalToken.generate()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        XCTAssertTrue(token.verifier.verify(headers: headers))

        headers.add(name: "api-key", value: token.value)
        XCTAssertFalse(token.verifier.verify(headers: headers))

        var apiKey = HTTPHeaders()
        apiKey.add(name: "api-key", value: token.value)
        XCTAssertTrue(token.verifier.verify(headers: apiKey))

        var malformed = HTTPHeaders()
        malformed.add(name: "Authorization", value: "Bearer \(token.value) trailing")
        XCTAssertFalse(token.verifier.verify(headers: malformed))
    }

    func testCredentialSourceOrderPrefersExplicitThenEnvFileThenDefaultThenEnvironment() throws {
        let home = try makeTemporaryDirectory()
        let explicit = try writeCredential("explicit", under: home, name: "explicit.key")
        let envFile = try writeCredential("env-file", under: home, name: "env.key")
        let defaultDir = home.appendingPathComponent(".config/macprovider", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultFile = defaultDir.appendingPathComponent("buyer-api-key")
        try Data("default\n".utf8).write(to: defaultFile)
        chmod(defaultFile.path, 0o600)

        let env = [
            "MACPROVIDER_HTTP2_API_KEY_FILE": envFile.path,
            "MACPROVIDER_HTTP2_API_KEY": "raw-env",
            "MP_API_KEY": "mp-env",
            "BUYER_TOKEN": "buyer-env",
        ]

        XCTAssertEqual(
            try ConsumeCredentialLoader.load(explicitCredentialFile: explicit.path, environment: env, homeDirectory: home).sourceClass,
            .explicitFile
        )
        let envLoaded = try ConsumeCredentialLoader.load(explicitCredentialFile: nil, environment: env, homeDirectory: home)
        XCTAssertEqual(envLoaded.sourceClass, .explicitFile)
        XCTAssertEqual(String(decoding: envLoaded.bytes, as: UTF8.self), "env-file")

        let defaultLoaded = try ConsumeCredentialLoader.load(
            explicitCredentialFile: nil,
            environment: ["MACPROVIDER_HTTP2_API_KEY": "raw-env"],
            homeDirectory: home
        )
        XCTAssertEqual(defaultLoaded.sourceClass, .defaultConfigFile)
        XCTAssertEqual(String(decoding: defaultLoaded.bytes, as: UTF8.self), "default")

        try FileManager.default.removeItem(at: defaultFile)
        let rawLoaded = try ConsumeCredentialLoader.load(
            explicitCredentialFile: nil,
            environment: ["MP_API_KEY": "mp-env", "BUYER_TOKEN": "buyer-env"],
            homeDirectory: home
        )
        XCTAssertEqual(rawLoaded.sourceClass, .environment)
        XCTAssertEqual(String(decoding: rawLoaded.bytes, as: UTF8.self), "mp-env")
    }

    func testCredentialFileRejectsRawCredentialFlagValues() throws {
        XCTAssertThrowsError(
            try ConsumeCredentialLoader.load(
                explicitCredentialFile: "sk-abcdefghijklmnopqrstuvwxyz123456",
                environment: [:],
                homeDirectory: try makeTemporaryDirectory()
            )
        ) { error in
            XCTAssertEqual((error as? ConsumeCredentialError)?.redactedCode, "local_credential_flag_rejected")
        }
    }

    func testCredentialLoaderRejectsEmbeddedHeaderControlCharacters() throws {
        XCTAssertThrowsError(
            try ConsumeCredentialLoader.load(
                explicitCredentialFile: nil,
                environment: ["MACPROVIDER_HTTP2_API_KEY": "buyer-token\r\nX-Injected: yes"],
                homeDirectory: try makeTemporaryDirectory()
            )
        ) { error in
            XCTAssertEqual((error as? ConsumeCredentialError)?.redactedCode, "local_credential_missing")
        }

        let home = try makeTemporaryDirectory()
        let credential = try writeCredential("buyer-token\nX-Injected: yes", under: home, name: "credential.key")
        XCTAssertThrowsError(
            try ConsumeCredentialLoader.load(explicitCredentialFile: credential.path, environment: [:], homeDirectory: home)
        ) { error in
            XCTAssertEqual((error as? ConsumeCredentialError)?.redactedCode, "local_credential_file_rejected")
        }
    }

    func testCredentialFileRejectsGroupReadableFileAndSymlink() throws {
        let home = try makeTemporaryDirectory()
        let unsafe = home.appendingPathComponent("unsafe.key")
        try Data("secret".utf8).write(to: unsafe)
        chmod(unsafe.path, 0o640)
        XCTAssertThrowsError(try ConsumeCredentialLoader.load(explicitCredentialFile: unsafe.path, environment: [:], homeDirectory: home))

        let safe = try writeCredential("secret", under: home, name: "safe.key")
        let link = home.appendingPathComponent("link.key")
        symlink(safe.path, link.path)
        XCTAssertThrowsError(try ConsumeCredentialLoader.load(explicitCredentialFile: link.path, environment: [:], homeDirectory: home))

        let groupWritableParent = home.appendingPathComponent("group-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: groupWritableParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o770])
        let grouped = try writeCredential("secret", under: groupWritableParent, name: "grouped.key")
        XCTAssertThrowsError(try ConsumeCredentialLoader.load(explicitCredentialFile: grouped.path, environment: [:], homeDirectory: home))
        chmod(groupWritableParent.path, 0o700)

        let aclParent = home.appendingPathComponent("acl-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: aclParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try addReadACLEntry(to: aclParent)
        let aclParentCredential = try writeCredential("secret", under: aclParent, name: "credential.key")
        XCTAssertThrowsError(try ConsumeCredentialLoader.load(explicitCredentialFile: aclParentCredential.path, environment: [:], homeDirectory: home))
    }

    func testCredentialFileRejectsExtendedACLAndRevalidatesDeletion() throws {
        let home = try makeTemporaryDirectory()
        let credential = try writeCredential("secret", under: home, name: "credential.key")
        let loaded = try ConsumeCredentialLoader.load(explicitCredentialFile: credential.path, environment: [:], homeDirectory: home)
        XCTAssertEqual(loaded.status.currentState(), .loaded)
        try FileManager.default.removeItem(at: credential)
        XCTAssertEqual(loaded.status.currentState(), .missing)

        let aclCredential = try writeCredential("secret", under: home, name: "acl.key")
        try addReadACLEntry(to: aclCredential)
        XCTAssertThrowsError(try ConsumeCredentialLoader.load(explicitCredentialFile: aclCredential.path, environment: [:], homeDirectory: home))
    }

    func testDescriptorWriteIsUserPrivateAndStatusPayloadIsRedacted() throws {
        let home = try makeTemporaryDirectory()
        let store = ConsumeActiveEndpointStore(homeDirectory: home)
        let lock = try store.acquireLock()
        let token = "local-token-secret"
        let descriptor = ConsumeEndpointDescriptor(
            boundURL: "http://127.0.0.1:11435",
            processID: Int(getpid()),
            launchID: UUID().uuidString.lowercased(),
            startedAt: ConsumeEndpointStatus.iso8601(Date()),
            ledgerPathClass: nil,
            localToken: token
        )

        try store.writeDescriptor(descriptor, lock: lock)
        XCTAssertEqual(octalMode(store.root), 0o700)
        XCTAssertEqual(octalMode(store.descriptorURL), 0o600)
        XCTAssertEqual(try store.readLiveDescriptor(), descriptor)

        let runtime = ConsumeEndpointRuntime(
            launchID: descriptor.launchID,
            boundURL: descriptor.boundURL,
            upstreamOrigin: "https://api.malibu.tech",
            credentialSourceClass: "missing",
            credentialStatus: .missing,
            modelAllowlist: [],
            tokenVerifier: ConsumeLocalTokenVerifier(expectedToken: token, key: Data("key".utf8))
        )
        let status = runtime.statusPayload()
        let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(token))
        XCTAssertTrue(json.contains("local_consumer_endpoint.status.v1"))
    }

    func testReadLiveDescriptorReturnsNilWhenDescriptorIsMissing() throws {
        let store = ConsumeActiveEndpointStore(homeDirectory: try makeTemporaryDirectory())
        XCTAssertNil(try store.readLiveDescriptor())
    }

    func testRunCommandStartsThenStopsWithRedactedSetupOutput() async throws {
        let home = try makeTemporaryDirectory()
        let port = try nextLoopbackPort()
        var command = try ConsumeRunCommand.parse(["--port", "\(port)", "--allow-model", "llama-test"])
        command.environmentForTesting = [:]
        command.homeDirectoryForTesting = home

        let capture = await captureStatusOutput {
            try await command.run(stopAfterListeningForTesting: true)
        }

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("local_consumer_endpoint=started"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("base_url=http://127.0.0.1:\(port)"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("local_token="), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("upstream_gateway_origin=https://api.malibu.tech"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("model_allowlist=count=1 sample=llama-test"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("credential_source_class=missing"), capture.stderr)
        XCTAssertFalse(capture.stderr.contains(home.path), capture.stderr)

        let store = ConsumeActiveEndpointStore(homeDirectory: home)
        XCTAssertNil(try store.readLiveDescriptor())
    }

    func testRunCommandPortCollisionUsesRedactedBindError() async throws {
        let reserved = try reserveLoopbackPort()
        defer { close(reserved.fd) }
        var command = try ConsumeRunCommand.parse(["--port", "\(reserved.port)"])
        command.environmentForTesting = [:]
        command.homeDirectoryForTesting = try makeTemporaryDirectory()

        let capture = await captureStatusOutput {
            try await command.run(stopAfterListeningForTesting: true)
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(2))
        XCTAssertEqual(capture.stderr, "local_bind_rejected\n")
    }

    func testStatusCommandNoEndpointUsesRedactedError() async throws {
        var command = ConsumeStatusCommand()
        command.homeDirectoryForTesting = try makeTemporaryDirectory()

        let capture = await captureStatusOutput {
            try await command.run()
        }

        XCTAssertEqual(capture.error as? ExitCode, ExitCode(4))
        XCTAssertEqual(capture.stderr, "local_endpoint_not_running\n")
    }

    func testActiveDescriptorLockSerializesInstances() throws {
        let store = ConsumeActiveEndpointStore(homeDirectory: try makeTemporaryDirectory())
        let lock = try store.acquireLock()
        XCTAssertThrowsError(try store.acquireLock())
        _ = lock
    }

    func testActiveDescriptorRejectsGroupWritableParent() throws {
        let home = try makeTemporaryDirectory()
        chmod(home.path, 0o770)
        defer { chmod(home.path, 0o700) }
        let store = ConsumeActiveEndpointStore(homeDirectory: home)
        XCTAssertThrowsError(try store.acquireLock())
    }

    func testActiveDescriptorRejectsExtendedACLOnPrivateRoot() throws {
        let home = try makeTemporaryDirectory()
        let store = ConsumeActiveEndpointStore(homeDirectory: home)
        var lock: ConsumeActiveEndpointLock? = try store.acquireLock()
        XCTAssertNotNil(lock)
        lock = nil
        try addReadACLEntry(to: store.root)
        XCTAssertThrowsError(try store.acquireLock())
    }

    func testActiveDescriptorRejectsExtendedACLOnParentDirectory() throws {
        let home = try makeTemporaryDirectory()
        try addReadACLEntry(to: home)
        let store = ConsumeActiveEndpointStore(homeDirectory: home)
        XCTAssertThrowsError(try store.acquireLock())
    }

    func testStaleDescriptorWithDeadProcessIsIgnored() throws {
        let store = ConsumeActiveEndpointStore(homeDirectory: try makeTemporaryDirectory())
        let lock = try store.acquireLock()
        let descriptor = ConsumeEndpointDescriptor(
            boundURL: "http://127.0.0.1:11435",
            processID: Int(Int32.max),
            launchID: UUID().uuidString.lowercased(),
            startedAt: ConsumeEndpointStatus.iso8601(Date()),
            ledgerPathClass: nil,
            localToken: "local-token"
        )
        try store.writeDescriptor(descriptor, lock: lock)
        XCTAssertNil(try store.readLiveDescriptor())
    }

    func testDescriptorWithLivePIDButReleasedLockIsIgnored() throws {
        let store = ConsumeActiveEndpointStore(homeDirectory: try makeTemporaryDirectory())
        var lock: ConsumeActiveEndpointLock? = try store.acquireLock()
        let descriptor = ConsumeEndpointDescriptor(
            boundURL: "http://127.0.0.1:11435",
            processID: Int(getpid()),
            launchID: UUID().uuidString.lowercased(),
            startedAt: ConsumeEndpointStatus.iso8601(Date()),
            ledgerPathClass: nil,
            localToken: "local-token"
        )
        try store.writeDescriptor(descriptor, lock: lock!)
        lock = nil
        XCTAssertNil(try store.readLiveDescriptor())
    }

    func testStatusHandlerRequiresAuthSetsNoStoreAndRedacts() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = ConsumeEndpointRuntime(
            launchID: "launch-status-test",
            boundURL: "http://127.0.0.1:11435",
            upstreamOrigin: "https://api.malibu.tech",
            credentialSourceClass: "environment",
            credentialStatus: .environmentLoaded,
            modelAllowlist: ["llama-test"],
            tokenVerifier: token.verifier
        )
        XCTAssertTrue(runtime.beginRequest())
        defer { runtime.endRequest() }

        let missingAuthHeaders = HTTPHeaders()
        let unauthorized = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: missingAuthHeaders)
        )
        XCTAssertEqual(unauthorized.status, HTTPResponseStatus.unauthorized)
        XCTAssertEqual(unauthorized.headers.first(name: "cache-control"), "no-store")
        XCTAssertFalse(unauthorized.body.contains(token.value))
        XCTAssertFalse(unauthorized.body.contains("llama-test"))
        let unauthorizedError = try localError(from: unauthorized.body)
        XCTAssertEqual(unauthorizedError["code"] as? String, "local_auth_required")
        XCTAssertTrue(unauthorizedError["param"] is NSNull)

        let unauthorizedHead = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/v1/status", headers: HTTPHeaders())
        )
        XCTAssertEqual(unauthorizedHead.status, HTTPResponseStatus.methodNotAllowed)
        XCTAssertEqual(unauthorizedHead.headers.first(name: "content-length"), "0")
        XCTAssertEqual(unauthorizedHead.body, "")

        var authorizedHeaders = HTTPHeaders()
        authorizedHeaders.add(name: "Authorization", value: "Bearer \(token.value)")
        let authorized = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: authorizedHeaders)
        )
        XCTAssertEqual(authorized.status, HTTPResponseStatus.ok)
        XCTAssertEqual(authorized.headers.first(name: "cache-control"), "no-store")
        XCTAssertTrue(authorized.body.contains("\"process_launch_id\":\"launch-status-test\""), authorized.body)
        XCTAssertTrue(authorized.body.contains("\"model_allowlist\":[\"llama-test\"]"), authorized.body)
        XCTAssertTrue(authorized.body.contains("\"active_request_count\":2"), authorized.body)
        XCTAssertFalse(authorized.body.contains(token.value))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(authorized.body.utf8)) as? [String: Any])
        XCTAssertNotNil(object["error_ring"] as? [Any])

        let wrongPath = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/chat/completions", headers: authorizedHeaders)
        )
        XCTAssertEqual(wrongPath.status, HTTPResponseStatus.methodNotAllowed)
        let wrongPathError = try localError(from: wrongPath.body)
        XCTAssertEqual(wrongPathError["code"] as? String, "local_endpoint_unsupported")
        XCTAssertTrue(wrongPathError["param"] is NSNull)

        let wrongPathHead = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/v1/chat/completions", headers: authorizedHeaders)
        )
        XCTAssertEqual(wrongPathHead.status, HTTPResponseStatus.methodNotAllowed)
        XCTAssertEqual(wrongPathHead.headers.first(name: "content-length"), "0")
        XCTAssertEqual(wrongPathHead.body, "")

        let wrongMethod = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/status", headers: authorizedHeaders)
        )
        XCTAssertEqual(wrongMethod.status, HTTPResponseStatus.methodNotAllowed)

        let head = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/v1/status", headers: authorizedHeaders)
        )
        XCTAssertEqual(head.status, HTTPResponseStatus.methodNotAllowed)
        XCTAssertEqual(head.headers.first(name: "content-length"), "0")
        XCTAssertEqual(head.body, "")
    }

    func testPhase2RejectsUnsafeTargetsFramingAndBrowserOrigins() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = consumeRuntime(token: token)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let query = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/models?limit=1", headers: headers)
        )
        XCTAssertEqual(query.status, .badRequest)
        XCTAssertEqual(try localError(from: query.body)["code"] as? String, "local_invalid_request")

        let encodedPath = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/%6dodels", headers: headers)
        )
        XCTAssertEqual(encodedPath.status, .badRequest)
        XCTAssertEqual(try localError(from: encodedPath.body)["code"] as? String, "local_invalid_request")

        let encodedDot = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/%2e/status", headers: headers)
        )
        XCTAssertEqual(encodedDot.status, .badRequest)

        var duplicateLength = headers
        duplicateLength.add(name: "Content-Length", value: "1")
        duplicateLength.add(name: "Content-Length", value: "1")
        let duplicateLengthResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: duplicateLength),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(duplicateLengthResponse.status, .badRequest)

        var commaLength = headers
        commaLength.add(name: "Content-Length", value: "1,")
        let commaLengthResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: commaLength),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(commaLengthResponse.status, .badRequest)

        var trailingTransferCoding = headers
        trailingTransferCoding.add(name: "Transfer-Encoding", value: "chunked,")
        let trailingTransferCodingResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: trailingTransferCoding),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(trailingTransferCodingResponse.status, .badRequest)

        var leadingTransferCoding = headers
        leadingTransferCoding.add(name: "Transfer-Encoding", value: ",chunked")
        let leadingTransferCodingResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: leadingTransferCoding),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(leadingTransferCodingResponse.status, .badRequest)

        var originNull = headers
        originNull.add(name: "Origin", value: "null")
        let nullOrigin = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: originNull)
        )
        XCTAssertEqual(nullOrigin.status, .badRequest)

        var commaOrigin = headers
        commaOrigin.add(name: "Origin", value: "http://127.0.0.1:11435, http://127.0.0.1:11436")
        let commaOriginResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: commaOrigin)
        )
        XCTAssertEqual(commaOriginResponse.status, .badRequest)

        var leadingCommaOrigin = headers
        leadingCommaOrigin.add(name: "Origin", value: ",http://127.0.0.1:11435")
        let leadingCommaOriginResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: leadingCommaOrigin)
        )
        XCTAssertEqual(leadingCommaOriginResponse.status, .badRequest)

        var multipleOrigins = headers
        multipleOrigins.add(name: "Origin", value: "http://127.0.0.1:11435")
        multipleOrigins.add(name: "Origin", value: "http://127.0.0.1:11435")
        let multipleOriginResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: multipleOrigins)
        )
        XCTAssertEqual(multipleOriginResponse.status, .badRequest)

        var exactOrigin = headers
        exactOrigin.add(name: "Origin", value: "http://127.0.0.1:11435")
        exactOrigin.add(name: "Sec-Fetch-Site", value: "same-origin")
        let exactOriginResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: exactOrigin)
        )
        XCTAssertEqual(exactOriginResponse.status, .ok)
    }

    func testPhase2NIOHTTPDecoderLimitsMatchLocalPolicy() {
        let configuration = ConsumeLocalLimits.httpDecoderLimitConfiguration
        XCTAssertEqual(configuration.maxHeaderFieldSize, ConsumeLocalLimits.headerBytes)
        XCTAssertEqual(configuration.maxHeaderListSize, ConsumeLocalLimits.headerBytes)
        XCTAssertEqual(configuration.maxHeaderFieldCount, ConsumeLocalLimits.headerCount)
    }

    func testPhase2RawPipelineRejectsOversizedStartLineBeforeHTTPDecoder() throws {
        let token = try ConsumeLocalToken.generate()

        let oversizedTargetRuntime = consumeRuntime(token: token)
        let oversizedTargetChannel = try rawConsumeChannel(runtime: oversizedTargetRuntime)
        let oversizedTarget = "/" + String(repeating: "a", count: ConsumeLocalLimits.requestTargetBytes + 1)
        try writeRawRequest(
            "GET \(oversizedTarget) HTTP/1.1\r\nHost: 127.0.0.1:11435\r\n\r\n",
            to: oversizedTargetChannel
        )
        oversizedTargetChannel.embeddedEventLoop.run()
        XCTAssertFalse(oversizedTargetChannel.isActive)
        XCTAssertEqual(oversizedTargetRuntime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertNil(try oversizedTargetChannel.readOutbound(as: HTTPServerResponsePart.self))

        let oversizedLineRuntime = consumeRuntime(token: token)
        let oversizedLineChannel = try rawConsumeChannel(runtime: oversizedLineRuntime)
        let oversizedLine = String(repeating: "A", count: ConsumeLocalLimits.requestLineBytes + 1)
        try writeRawRequest(
            "\(oversizedLine)\r\nHost: 127.0.0.1:11435\r\n\r\n",
            to: oversizedLineChannel
        )
        oversizedLineChannel.embeddedEventLoop.run()
        XCTAssertFalse(oversizedLineChannel.isActive)
        XCTAssertEqual(oversizedLineRuntime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertNil(try oversizedLineChannel.readOutbound(as: HTTPServerResponsePart.self))

        let splitLineRuntime = consumeRuntime(token: token)
        let splitLineChannel = try rawConsumeChannel(runtime: splitLineRuntime)
        try writeRawRequest(
            "GET /" + String(repeating: "b", count: ConsumeLocalLimits.requestLineBytes - 6),
            to: splitLineChannel
        )
        XCTAssertTrue(splitLineChannel.isActive)
        XCTAssertEqual(splitLineRuntime.statusPayload()["active_request_count"] as? Int, 0)
        try writeRawRequest("bb", to: splitLineChannel)
        splitLineChannel.embeddedEventLoop.run()
        XCTAssertFalse(splitLineChannel.isActive)
        XCTAssertEqual(splitLineRuntime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertNil(try splitLineChannel.readOutbound(as: HTTPServerResponsePart.self))

        let malformedVersionRuntime = consumeRuntime(token: token)
        let malformedVersionChannel = try rawConsumeChannel(runtime: malformedVersionRuntime)
        try writeRawRequest(
            "GET /v1/status HTTP/2.0\r\nHost: 127.0.0.1:11435\r\n\r\n",
            to: malformedVersionChannel
        )
        malformedVersionChannel.embeddedEventLoop.run()
        XCTAssertFalse(malformedVersionChannel.isActive)
        XCTAssertEqual(malformedVersionRuntime.statusPayload()["active_request_count"] as? Int, 0)

        let malformedMethodRuntime = consumeRuntime(token: token)
        let malformedMethodChannel = try rawConsumeChannel(runtime: malformedMethodRuntime)
        try writeRawRequest(
            "get /v1/status HTTP/1.1\r\nHost: 127.0.0.1:11435\r\n\r\n",
            to: malformedMethodChannel
        )
        malformedMethodChannel.embeddedEventLoop.run()
        XCTAssertFalse(malformedMethodChannel.isActive)
        XCTAssertEqual(malformedMethodRuntime.statusPayload()["active_request_count"] as? Int, 0)
    }

    func testPhase2EnforcesLocalResourceCapsBeforeBuffering() throws {
        let token = try ConsumeLocalToken.generate()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        var declaredTooLarge = headers
        declaredTooLarge.add(name: "Content-Length", value: "\(ConsumeLocalLimits.bodyBytes + 1)")
        let declaredTooLargeResponse = try response(
            from: consumeRuntime(token: token),
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: declaredTooLarge)
        )
        XCTAssertEqual(declaredTooLargeResponse.status, .payloadTooLarge)
        XCTAssertEqual(try localError(from: declaredTooLargeResponse.body)["code"] as? String, "local_request_too_large")

        let activeSaturated = try response(
            from: consumeRuntime(
                token: token,
                requestCounter: ConsumeEndpointRequestCounter(maxActiveRequests: 0)
            ),
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: headers)
        )
        XCTAssertEqual(activeSaturated.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: activeSaturated.body)["code"] as? String, "local_endpoint_busy")

        let bodyBufferSaturated = try response(
            from: consumeRuntime(
                token: token,
                requestCounter: ConsumeEndpointRequestCounter(maxBufferedBodyBytes: 1)
            ),
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(bodyBufferSaturated.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: bodyBufferSaturated.body)["code"] as? String, "local_endpoint_busy")

        let counter = ConsumeEndpointRequestCounter(maxIncompleteConnections: 1, maxActiveRequests: 1, maxBufferedBodyBytes: 2)
        XCTAssertTrue(counter.beginIncompleteConnection())
        XCTAssertFalse(counter.beginIncompleteConnection())
        counter.completePreAuthConnection()
        XCTAssertTrue(counter.beginIncompleteConnection())
        counter.endIncompleteConnection()
        XCTAssertTrue(counter.begin())
        XCTAssertFalse(counter.begin())
        counter.end()
        XCTAssertTrue(counter.reserveBodyBytes(2))
        XCTAssertFalse(counter.reserveBodyBytes(1))
        counter.releaseBodyBytes(2)
        XCTAssertTrue(counter.reserveBodyBytes(1))
        counter.releaseBodyBytes(1)

        let resourceReservation = try XCTUnwrap(counter.reserveUpstreamExchange(responseSpoolBytes: ConsumeLocalLimits.bodyBytes))
        var snapshot = counter.resourceSnapshot()
        XCTAssertEqual(snapshot.responseSpoolBytes, ConsumeLocalLimits.bodyBytes)
        XCTAssertEqual(snapshot.upstreamWorkerTasks, 1)
        XCTAssertEqual(snapshot.upstreamSocketDescriptors, 1)
        counter.releaseUpstreamExchange(resourceReservation)
        snapshot = counter.resourceSnapshot()
        XCTAssertEqual(snapshot.responseSpoolBytes, 0)
        XCTAssertEqual(snapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(snapshot.upstreamSocketDescriptors, 0)

        let streamingCounter = ConsumeEndpointRequestCounter(maxOpenStreamingResponses: 1)
        XCTAssertTrue(streamingCounter.beginStreamingResponse())
        XCTAssertFalse(streamingCounter.beginStreamingResponse())
        XCTAssertEqual(streamingCounter.resourceSnapshot().openStreamingResponses, 1)
        streamingCounter.endStreamingResponse()
        XCTAssertEqual(streamingCounter.resourceSnapshot().openStreamingResponses, 0)
        let streamingReservation = try XCTUnwrap(streamingCounter.reserveUpstreamExchange(
            responseSpoolBytes: 0,
            openStreamingResponse: true
        ))
        XCTAssertFalse(streamingCounter.reserveUpstreamExchange(responseSpoolBytes: 0, openStreamingResponse: true) != nil)
        XCTAssertEqual(streamingCounter.resourceSnapshot().openStreamingResponses, 1)
        streamingCounter.releaseUpstreamExchange(streamingReservation)
        XCTAssertEqual(streamingCounter.resourceSnapshot().openStreamingResponses, 0)
    }

    func testPhase2PostHeaderIdleTimeoutReleasesActiveCapacity() throws {
        let token = try ConsumeLocalToken.generate()
        let counter = ConsumeEndpointRequestCounter(maxActiveRequests: 1)
        let runtime = consumeRuntime(token: token, requestCounter: counter)
        let channel = try rawConsumeChannel(runtime: runtime)

        let request = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1:11435\r\n"
            + "Authorization: Bearer \(token.value)\r\n"
            + "Content-Length: 2\r\n"
            + "\r\n"
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 1)

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let saturated = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: headers)
        )
        XCTAssertEqual(saturated.status, .serviceUnavailable)

        channel.embeddedEventLoop.advanceTime(by: ConsumeLocalLimits.bodyIdleTimeout)
        channel.embeddedEventLoop.run()

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)

        let recovered = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: headers)
        )
        XCTAssertEqual(recovered.status, .ok)
    }

    func testPhase2ChatValidatesBodyBeforeBudgetRequiredFailure() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = consumeRuntime(token: token)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let valid = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )
        XCTAssertEqual(valid.status, .badRequest)
        let validError = try localError(from: valid.body)
        XCTAssertEqual(validError["code"] as? String, "local_budget_required")
        XCTAssertEqual(try localForwardedFlag(from: valid.body), false)

        let duplicateKey = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"a","model":"b"}"#.utf8)
        )
        XCTAssertEqual(duplicateKey.status, .badRequest)
        XCTAssertEqual(try localError(from: duplicateKey.body)["code"] as? String, "local_invalid_request")

        for invalidTopLevelJSON in ["[]", #""text""#, "true", "null"] {
            let invalid = try response(
                from: runtime,
                head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
                body: Data(invalidTopLevelJSON.utf8)
            )
            XCTAssertEqual(invalid.status, .badRequest, invalidTopLevelJSON)
            XCTAssertEqual(try localError(from: invalid.body)["code"] as? String, "local_invalid_request")
        }

        var gzip = headers
        gzip.add(name: "Content-Encoding", value: "gzip")
        let compressed = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: gzip),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(compressed.status.code, 415)
        XCTAssertEqual(try localError(from: compressed.body)["code"] as? String, "local_content_encoding_unsupported")
    }

    func testPhase3BudgetFlagsParseAndRejectInvalidCombinations() throws {
        XCTAssertEqual(try ConsumeMicroUSD.parsePositiveUSD("1.234567")?.rawValue, 1_234_567)
        XCTAssertEqual(try ConsumeMicroUSD.parsePositiveUSD("12")?.rawValue, 12_000_000)

        for invalid in ["0", "-1", "nan", "1.0000001"] {
            XCTAssertThrowsError(try ConsumeMicroUSD.parsePositiveUSD(invalid)) { error in
                XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_flag_rejected")
            }
        }

        XCTAssertThrowsError(
            try ConsumeBudgetConfig.parse(
                budgetUSD: nil,
                maxRequestUSD: nil,
                noBudget: false,
                ledgerPath: "ledger.jsonl",
                allowUnpriced: false,
                runID: "run",
                homeDirectory: try makeTemporaryDirectory(),
                startupDirectory: try makeTemporaryDirectory()
            )
        ) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_flag_rejected")
        }

        XCTAssertThrowsError(
            try ConsumeBudgetConfig.parse(
                budgetUSD: "1",
                maxRequestUSD: nil,
                noBudget: true,
                ledgerPath: nil,
                allowUnpriced: false,
                runID: "run",
                homeDirectory: try makeTemporaryDirectory(),
                startupDirectory: try makeTemporaryDirectory()
            )
        ) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_flag_rejected")
        }

        let noBudgetHome = try makeTemporaryDirectory()
        let noBudgetConfig = try ConsumeBudgetConfig.parse(
            budgetUSD: nil,
            maxRequestUSD: nil,
            noBudget: true,
            ledgerPath: nil,
            allowUnpriced: false,
            runID: "run",
            homeDirectory: noBudgetHome,
            startupDirectory: noBudgetHome
        )
        XCTAssertEqual(noBudgetConfig.mode, .noBudget)
        XCTAssertNil(noBudgetConfig.ledger)
        XCTAssertNil(noBudgetConfig.ledgerPathClass)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: noBudgetHome
                .appendingPathComponent("Library/Application Support/macprovider/consume/ledgers/default.jsonl")
                .path
        ))

        let explicitNoBudgetLedger = noBudgetHome.appendingPathComponent("explicit-no-budget.jsonl")
        let explicitNoBudgetConfig = try ConsumeBudgetConfig.parse(
            budgetUSD: nil,
            maxRequestUSD: nil,
            noBudget: true,
            ledgerPath: explicitNoBudgetLedger.path,
            allowUnpriced: false,
            runID: "run",
            homeDirectory: noBudgetHome,
            startupDirectory: noBudgetHome
        )
        XCTAssertEqual(explicitNoBudgetConfig.mode, .noBudget)
        XCTAssertNotNil(explicitNoBudgetConfig.ledger)
        XCTAssertEqual(explicitNoBudgetConfig.ledgerPathClass, "explicit_absolute")
    }

    func testPhase3LedgerPathResolutionClassifiesDefaultAbsoluteAndRelative() throws {
        let home = try makeTemporaryDirectory()
        let startup = home.appendingPathComponent("startup")
        let defaultResolution = try ConsumeBudgetLedger.resolve(
            ledgerPath: "default",
            homeDirectory: home,
            startupDirectory: startup
        )
        XCTAssertEqual(defaultResolution.pathClass, "default_user_state")
        XCTAssertEqual(
            defaultResolution.url.path,
            home.appendingPathComponent("Library/Application Support/macprovider/consume/ledgers/default.jsonl").path
        )

        let absoluteURL = home.appendingPathComponent("absolute-ledger.jsonl")
        let absoluteResolution = try ConsumeBudgetLedger.resolve(
            ledgerPath: absoluteURL.path,
            homeDirectory: home,
            startupDirectory: startup
        )
        XCTAssertEqual(absoluteResolution.pathClass, "explicit_absolute")
        XCTAssertEqual(absoluteResolution.url.path, absoluteURL.standardizedFileURL.path)

        let relativeName = "relative-\(UUID().uuidString)/budget.jsonl"
        let relativeResolution = try ConsumeBudgetLedger.resolve(
            ledgerPath: relativeName,
            homeDirectory: home,
            startupDirectory: startup
        )
        XCTAssertEqual(relativeResolution.pathClass, "explicit_relative")
        XCTAssertEqual(
            relativeResolution.url.path,
            startup.appendingPathComponent(relativeName).standardizedFileURL.path
        )
    }

    func testPhase3RunCommandStartupReportsBudgetMode() async throws {
        let home = try makeTemporaryDirectory()
        let port = try nextLoopbackPort()
        var command = try ConsumeRunCommand.parse([
            "--port", "\(port)",
            "--allow-model", "llama-test",
            "--budget-usd", "1.25",
            "--allow-unpriced",
        ])
        command.environmentForTesting = [:]
        command.homeDirectoryForTesting = home
        command.startupDirectoryForTesting = home
        command.skipTrustedPricingLoadForTesting = true

        let capture = await captureStatusOutput {
            try await command.run(stopAfterListeningForTesting: true)
        }

        XCTAssertNil(capture.error)
        XCTAssertTrue(capture.stderr.contains("budget_mode=budget"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("unpriced_override=true"), capture.stderr)
        XCTAssertTrue(capture.stderr.contains("warnings=unpriced_override"), capture.stderr)
        XCTAssertFalse(capture.stderr.contains(home.path), capture.stderr)
    }

    func testPhase3ChatRejectsDisallowedModelBeforeBudget() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = consumeRuntime(token: token, allowedModels: ["llama-test"])
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"other-model","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status, .badRequest)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_model_not_allowed")
    }

    func testPhase3BTrustedPricingAdmitsNoBudgetRequestButStillFailsClosedBeforeForwarding() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedPricing = ConsumeTrustedPricingState.available(phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z"))
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: trustedPricing,
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-10T00:00:00Z")! }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, .unauthorized)
        let error = try localError(from: response.body)
        XCTAssertEqual(error["code"] as? String, "local_credential_missing")
        XCTAssertFalse(try localForwardedFlag(from: response.body))
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget")
    }

    func testPhase3BDefaultTierDoesNotAdmitWithoutTrustedModelVisibility() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedPricing = ConsumeTrustedPricingState.available(phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z"))
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            allowedModels: ["missing-but-allowed"],
            budget: budget,
            trustedPricing: trustedPricing,
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-10T00:00:00Z")! }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"missing-but-allowed","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget")
    }

    func testPhase3BUnavailableTrustedPricingKeepsPricingUnavailableFailure() throws {
        let token = try ConsumeLocalToken.generate()
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .unavailable(reason: .invalidSignature)
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget")
    }

    func testPhase3BExpiredTrustedPricingIsDemotedAtAdmissionTime() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedPricing = ConsumeTrustedPricingState.available(phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z"))
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: trustedPricing,
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-01T00:00:01Z")! }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget")
        XCTAssertEqual(runtime.statusPayload()["pricing_trust_state"] as? String, "unavailable")
    }

    func testPhase3BExpiredTrustedPricingStaysUnavailableAfterClockRollback() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedPricing = ConsumeTrustedPricingState.available(phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z"))
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let clock = LockedTestDate(ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-01T00:00:01Z")!)
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: trustedPricing,
            now: { clock.now }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let expiredResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )
        clock.now = ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-10T00:00:00Z")!
        let rolledBackResponse = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )

        XCTAssertEqual(expiredResponse.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: expiredResponse.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(rolledBackResponse.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: rolledBackResponse.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(runtime.statusPayload()["pricing_trust_state"] as? String, "unavailable")
    }

    func testPhase3BStaleTrustedPricingIsMarkedAtAdmissionTime() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedPricing = ConsumeTrustedPricingState.available(phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z"))
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: trustedPricing,
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-20T00:00:00Z")! }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, .unauthorized)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_credential_missing")
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget,stale_pricing")
        XCTAssertEqual(runtime.statusPayload()["pricing_warning_codes"] as? [String], ["stale_pricing"])
    }

    func testPhase3BStatusReportsTrustedPricingAvailabilityAndWarnings() throws {
        let token = try ConsumeLocalToken.generate()
        var trustedRateCard = phase3BTrustedRateCard(generatedAt: "2026-08-01T00:00:00Z")
        trustedRateCard = ConsumeTrustedRateCard(
            version: trustedRateCard.version,
            policyVersion: trustedRateCard.policyVersion,
            generatedAt: trustedRateCard.generatedAt,
            signerKeyID: trustedRateCard.signerKeyID,
            projection: trustedRateCard.projection,
            stale: true
        )
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard)
        )
        let status = runtime.statusPayload()

        XCTAssertEqual(status["pricing_trust_state"] as? String, "trusted")
        XCTAssertEqual(status["pricing_warning_codes"] as? [String], ["stale_pricing"])
    }

    func testPhase3CPricedEstimateUsesGrossRatesAndRoundsUp() throws {
        let rateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 2_000_000,
            promptCacheHitRatePerMtok: 1,
            completionRatePerMtok: 4_000_000,
            providerShareBPS: 1,
            globalMultiplierPPM: 500_000,
            usdPerMillionCredits: 1.0
        )
        let match = try XCTUnwrap(rateCard.match(model: "llama-test"))

        let estimate = try ConsumePricedExposureEstimator.estimate(
            promptTokenUpperBound: 3,
            completionTokenUpperBound: 5,
            match: match,
            projection: rateCard.projection
        )

        XCTAssertEqual(estimate.amount.rawValue, 13)
        XCTAssertEqual(estimate.rateCardKey, "llama-test")

        let tinyRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1,
            completionRatePerMtok: 0,
            usdPerMillionCredits: 1.0
        )
        let tinyMatch = try XCTUnwrap(tinyRateCard.match(model: "llama-test"))
        let rounded = try ConsumePricedExposureEstimator.estimate(
            promptTokenUpperBound: 1,
            completionTokenUpperBound: 1,
            match: tinyMatch,
            projection: tinyRateCard.projection
        )
        XCTAssertEqual(rounded.amount.rawValue, 1)
    }

    func testPhase3DBudgetedTrustedPricingRejectsMissingCredentialBeforeReservation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let counter = ConsumeEndpointRequestCounter()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
        }
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
            ,
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.unauthorized)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_credential_missing")
        XCTAssertNil(response.headers.first(name: "x-macprovider-warning"))
        XCTAssertEqual(recorder.snapshot().count, 0)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.heldReservationCount, 0)
        XCTAssertEqual(runtime.statusPayload()["budget_remaining_micro_usd"] as? String, "100000000")
    }

    func testPhase3DBudgetExceededWinsOverMissingCredentialWithoutMutation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let existingReservation = try ledger.reserve(
            runID: "prior-run",
            amount: ConsumeMicroUSD(rawValue: 100),
            reason: "prior_reserved"
        )
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 402))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_budget_exceeded")
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 100)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, 0)
        XCTAssertEqual(existingReservation.count, 32)
    }

    func testPhase3DDispatchedTransportFailureHoldsReservation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let counter = ConsumeEndpointRequestCounter()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertEqual(recorder.snapshot().count, 1)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.heldReservationCount, 1)
        let resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 0)
    }

    func testPhase3DPreDispatchTransportFailureSettlesReservationToZero() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let counter = ConsumeEndpointRequestCounter()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.preDispatchUnavailable)
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertFalse(try localForwardedFlag(from: response.body))
        XCTAssertEqual(recorder.snapshot().count, 1)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, 0)
        XCTAssertEqual(summary.heldReservationCount, 0)
        let resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 0)
    }

    func testPhase3DSendFailureIsPreDispatch() throws {
        let classification = ConsumePinnedUpstreamClient.sendFailureClassificationForTesting(
            ConsumeUpstreamForwardError.dispatchedUnavailable
        )
        guard case .preDispatchUnavailable = classification else {
            return XCTFail("send failure must not be treated as forwarded upstream")
        }
    }

    func testPhase3DResolverFailureStopsBeforeReservationAndForwarding() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let counter = ConsumeEndpointRequestCounter()
        let upstreamClient = ConsumeStubUpstreamClient(
            resolver: { _, eventLoop in
                eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.preDispatchUnavailable)
            },
            handler: { request, eventLoop in
                recorder.append(request)
                return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
            }
        )
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertFalse(try localForwardedFlag(from: response.body))
        XCTAssertEqual(recorder.snapshot().count, 0)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, 0)
        XCTAssertEqual(summary.heldReservationCount, 0)
        let resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 0)
    }

    func testPhase3EAggregateUpstreamResourceLimitsRejectBeforeResolverLedgerAndForwarding() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let cases: [(name: String, counter: ConsumeEndpointRequestCounter)] = [
            ("worker", ConsumeEndpointRequestCounter(maxUpstreamWorkerTasks: 0)),
            ("socket", ConsumeEndpointRequestCounter(maxUpstreamSocketDescriptors: 0)),
            ("spool", ConsumeEndpointRequestCounter(maxResponseSpoolBytes: ConsumeLocalLimits.nonStreamingResponseSpoolBytes - 1)),
        ]
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        for testCase in cases {
            let home = try makeTemporaryDirectory()
            let ledgerURL = home.appendingPathComponent("budget-\(testCase.name).jsonl")
            let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
            let budget = ConsumeBudgetConfig(
                mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
                maxRequestMicroUSD: nil,
                allowUnpriced: false,
                ledger: ledger,
                ledgerPathClass: ledger.pathClass
            )
            let resolverCalls = ConsumeInvocationCounter()
            let recorder = ConsumeUpstreamRequestRecorder()
            let upstreamClient = ConsumeStubUpstreamClient(
                resolver: { _, eventLoop in
                    resolverCalls.increment()
                    return eventLoop.makeSucceededFuture("8.8.8.8")
                },
                handler: { request, eventLoop in
                    recorder.append(request)
                    return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
                }
            )
            let runtime = consumeRuntime(
                token: token,
                budget: budget,
                trustedPricing: .available(trustedRateCard),
                upstreamClient: upstreamClient,
                now: { ConsumeCommandTests.phase3CTestNow },
                requestCounter: testCase.counter
            )

            let response = try response(
                from: runtime,
                head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
                body: body
            )

            XCTAssertEqual(response.status, .serviceUnavailable, testCase.name)
            XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_endpoint_busy", testCase.name)
            XCTAssertFalse(try localForwardedFlag(from: response.body), testCase.name)
            XCTAssertEqual(resolverCalls.snapshot(), 0, testCase.name)
            XCTAssertEqual(recorder.snapshot().count, 0, testCase.name)
            let summary = try ledger.summary()
            XCTAssertEqual(summary.reserved.rawValue, 0, testCase.name)
            XCTAssertEqual(summary.held.rawValue, 0, testCase.name)
            XCTAssertEqual(summary.settled.rawValue, 0, testCase.name)
            XCTAssertEqual(summary.heldReservationCount, 0, testCase.name)
        }
    }

    func testPhase3EUpstreamResourceReservationsAreHeldWhileForwardingAndReleasedAfterSuccess() throws {
        let token = try ConsumeLocalToken.generate()
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let counter = ConsumeEndpointRequestCounter(
            maxResponseSpoolBytes: ConsumeLocalLimits.nonStreamingResponseSpoolBytes,
            maxUpstreamWorkerTasks: 1,
            maxUpstreamSocketDescriptors: 1
        )
        let pendingPromise = ConsumeUpstreamPromiseBox()
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            let promise = eventLoop.makePromise(of: ConsumeUpstreamResponse.self)
            pendingPromise.set(promise)
            return promise.futureResult
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        let firstChannel = EmbeddedChannel()
        try firstChannel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        try firstChannel.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers)
        ))
        var firstBuffer = firstChannel.allocator.buffer(capacity: body.count)
        firstBuffer.writeBytes(body)
        try firstChannel.writeInbound(HTTPServerRequestPart.body(firstBuffer))
        try firstChannel.writeInbound(HTTPServerRequestPart.end(nil))
        firstChannel.embeddedEventLoop.run()

        XCTAssertEqual(recorder.snapshot().count, 1)
        var snapshot = counter.resourceSnapshot()
        XCTAssertEqual(snapshot.responseSpoolBytes, ConsumeLocalLimits.nonStreamingResponseSpoolBytes)
        XCTAssertEqual(snapshot.upstreamWorkerTasks, 1)
        XCTAssertEqual(snapshot.upstreamSocketDescriptors, 1)
        let status = runtime.statusPayload()
        XCTAssertEqual(status["response_spool_bytes"] as? Int, ConsumeLocalLimits.nonStreamingResponseSpoolBytes)
        XCTAssertEqual(status["upstream_worker_task_count"] as? Int, 1)
        XCTAssertEqual(status["upstream_socket_descriptor_count"] as? Int, 1)

        let saturated = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: body
        )
        XCTAssertEqual(saturated.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: saturated.body)["code"] as? String, "local_endpoint_busy")
        XCTAssertFalse(try localForwardedFlag(from: saturated.body))
        XCTAssertEqual(recorder.snapshot().count, 1)

        pendingPromise.succeed(ConsumeUpstreamResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        ))
        firstChannel.embeddedEventLoop.run()
        let forwarded = try drainResponse(from: firstChannel)
        XCTAssertEqual(forwarded.status, .ok)
        snapshot = counter.resourceSnapshot()
        XCTAssertEqual(snapshot.responseSpoolBytes, 0)
        XCTAssertEqual(snapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(snapshot.upstreamSocketDescriptors, 0)
    }

    func testPhase3DForwardingKeepsActiveCapacityUntilUpstreamCompletes() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let counter = ConsumeEndpointRequestCounter(maxActiveRequests: 1)
        let pendingPromise = ConsumeUpstreamPromiseBox()
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            let promise = eventLoop.makePromise(of: ConsumeUpstreamResponse.self)
            pendingPromise.set(promise)
            return promise.futureResult
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        let firstChannel = EmbeddedChannel()
        try firstChannel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        try firstChannel.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers)
        ))
        var firstBuffer = firstChannel.allocator.buffer(capacity: body.count)
        firstBuffer.writeBytes(body)
        try firstChannel.writeInbound(HTTPServerRequestPart.body(firstBuffer))
        try firstChannel.writeInbound(HTTPServerRequestPart.end(nil))
        firstChannel.embeddedEventLoop.run()

        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 1)
        let saturated = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/status", headers: headers)
        )
        XCTAssertEqual(saturated.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: saturated.body)["code"] as? String, "local_endpoint_busy")

        pendingPromise.succeed(ConsumeUpstreamResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            body: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        ))
        firstChannel.embeddedEventLoop.run()
        _ = try drainResponse(from: firstChannel)
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)
    }

    func testPhase3DResolverSuccessAfterDisconnectReleasesCapacityWithoutReservation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let endpointPromise = ConsumeEndpointPromiseBox()
        let recorder = ConsumeUpstreamRequestRecorder()
        let counter = ConsumeEndpointRequestCounter(
            maxResponseSpoolBytes: ConsumeLocalLimits.nonStreamingResponseSpoolBytes,
            maxUpstreamWorkerTasks: 1,
            maxUpstreamSocketDescriptors: 1
        )
        let upstreamClient = ConsumeStubUpstreamClient(
            resolver: { _, eventLoop in
                let promise = eventLoop.makePromise(of: String.self)
                endpointPromise.set(promise)
                return promise.futureResult
            },
            handler: { request, eventLoop in
                recorder.append(request)
                return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
            }
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        try channel.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers)
        ))
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        channel.embeddedEventLoop.run()
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 1)
        var resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, ConsumeLocalLimits.nonStreamingResponseSpoolBytes)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 1)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 1)

        try channel.close().wait()
        channel.embeddedEventLoop.run()
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)
        resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 0)

        endpointPromise.succeed("8.8.8.8")
        channel.embeddedEventLoop.run()

        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertEqual(recorder.snapshot().count, 0)
        resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
        XCTAssertEqual(resourceSnapshot.upstreamWorkerTasks, 0)
        XCTAssertEqual(resourceSnapshot.upstreamSocketDescriptors, 0)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, 0)
    }

    func testPhase3DEstimateExceededWhileResolverPendingStopsBeforeReservation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let pricingAdmissionGate = ConsumePricingAdmissionGate()
        let endpointPromise = ConsumeEndpointPromiseBox()
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamClient = ConsumeStubUpstreamClient(
            resolver: { _, eventLoop in
                let promise = eventLoop.makePromise(of: String.self)
                endpointPromise.set(promise)
                return promise.futureResult
            },
            handler: { request, eventLoop in
                recorder.append(request)
                return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(statusCode: 200, headers: [], body: Data()))
            }
        )
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            pricingAdmissionGate: pricingAdmissionGate,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        try channel.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers)
        ))
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        channel.embeddedEventLoop.run()
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 1)

        pricingAdmissionGate.stopForEstimateExceeded()
        endpointPromise.succeed("8.8.8.8")
        channel.embeddedEventLoop.run()
        let response = try drainResponse(from: channel)

        XCTAssertEqual(response.status, HTTPResponseStatus.serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_estimate_exceeded")
        XCTAssertEqual(recorder.snapshot().count, 0)
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertEqual(try ledger.summary(), .empty)
    }

    func testPhase3DPricingExpirationWhileResolverPendingStopsBeforeReservation() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let nowBox = ConsumeDateBox(ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-18T00:00:00Z")!)
        let endpointPromise = ConsumeEndpointPromiseBox()
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamClient = ConsumeStubUpstreamClient(
            resolver: { _, eventLoop in
                let promise = eventLoop.makePromise(of: String.self)
                endpointPromise.set(promise)
                return promise.futureResult
            },
            handler: { request, eventLoop in
                recorder.append(request)
                return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(statusCode: 200, headers: [], body: Data()))
            }
        )
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { nowBox.get() }
        )
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        try channel.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers)
        ))
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        channel.embeddedEventLoop.run()
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 1)

        nowBox.set(ISO8601DateFormatter.autotuneInternet.date(from: "2026-09-20T00:00:00Z")!)
        endpointPromise.succeed("8.8.8.8")
        channel.embeddedEventLoop.run()
        let response = try drainResponse(from: channel)

        XCTAssertEqual(response.status, HTTPResponseStatus.serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(recorder.snapshot().count, 0)
        XCTAssertEqual(runtime.statusPayload()["active_request_count"] as? Int, 0)
        XCTAssertEqual(try ledger.summary(), .empty)
    }

    func testPhase3FCompressedUpstreamResponseDecodesBeforeSettlementAndLocalSuccess() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let decodedBody = Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        let compressedBody = try gzipData(decodedBody)
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip"),
                    ("content-length", "999999"),
                    ("x-request-id", "upstream-request-id"),
                ],
                body: compressedBody
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expectedSettlement = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1,
            completionTokens: 1,
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.body, String(decoding: decodedBody, as: UTF8.self))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        XCTAssertEqual(response.headers.first(name: "content-length"), "\(decodedBody.count)")
        XCTAssertEqual(response.headers.first(name: "x-request-id"), "upstream-request-id")
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expectedSettlement.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3FInvalidCompressedUpstreamResponseFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip"),
                ],
                body: Data("not-gzip".utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3FInvalidCompressedUpstreamResponseWithLedgerWriteFailureKeepsForwardedProvenance() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            try! FileManager.default.removeItem(at: ledgerURL)
            try! Data().write(to: ledgerURL)
            chmod(ledgerURL.path, 0o600)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip"),
                ],
                body: Data("not-gzip".utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: body
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_budget_ledger_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
    }

    func testPhase3FDecodedUpstreamResponseWithLedgerWriteFailureKeepsForwardedProvenance() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let decodedBody = Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        let compressedBody = try gzipData(decodedBody)
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            try! FileManager.default.removeItem(at: ledgerURL)
            try! Data().write(to: ledgerURL)
            chmod(ledgerURL.path, 0o600)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip"),
                ],
                body: compressedBody
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: body
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_budget_ledger_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
    }

    func testPhase3FDispatchedUpstreamFailureWithLedgerWriteFailureKeepsForwardedProvenance() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            try! FileManager.default.removeItem(at: ledgerURL)
            try! Data().write(to: ledgerURL)
            chmod(ledgerURL.path, 0o600)
            return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: body
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_budget_ledger_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
    }

    func testPhase3FAmbiguousCompressedUpstreamResponseFailsClosedAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip, identity"),
                ],
                body: Data()
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3FNonHTTPWhitespaceCompressedUpstreamResponseFailsClosedAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "\u{00a0}gzip"),
                ],
                body: Data()
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3FDuplicateIdentityUpstreamResponseFailsClosedAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "identity"),
                    ("content-encoding", "identity"),
                ],
                body: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3FOversizedCompressedUpstreamResponseFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let oversizedBody = Data(repeating: UInt8(ascii: "x"), count: ConsumeLocalLimits.bodyBytes + 1)
        let compressedBody = try gzipData(oversizedBody)
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("content-encoding", "gzip"),
                ],
                body: compressedBody
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3GStreamingResponseRelaysAfterDoneAndSettlesUsage() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let sseBody = """
        data: {"id":"chunk-1","choices":[{"delta":{"content":"hello"}}]}

        data: {"id":"chunk-2","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}

        data: [DONE]

        """
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "text/event-stream; charset=utf-8"),
                    ("content-length", "999999"),
                    ("x-request-id", "stream-request-id"),
                ],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expectedSettlement = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1,
            completionTokens: 2,
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.body, sseBody)
        XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertEqual(response.headers.first(name: "content-length"), "\(Data(sseBody.utf8).count)")
        XCTAssertNil(response.headers.first(name: "content-encoding"))
        XCTAssertEqual(response.headers.first(name: "x-request-id"), "stream-request-id")
        let forwarded = try XCTUnwrap(recorder.snapshot().first)
        XCTAssertTrue(forwarded.streaming)
        XCTAssertEqual(forwarded.body, Data(body.utf8))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expectedSettlement.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
        let resourceSnapshot = runtime.requestCounter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.openStreamingResponses, 0)
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
    }

    func testPhase3GNoBudgetExplicitLedgerRecordsAndSettlesStreamingAuditRows() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("no-budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let sseBody = """
        data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2}}

        data: [DONE]

        """
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "text/event-stream"),
                    ("x-macprovider-warning", "upstream_notice"),
                ],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expectedSettlement = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1,
            completionTokens: 2,
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.body, sseBody)
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "upstream_notice,no_budget")
        XCTAssertTrue(try XCTUnwrap(recorder.snapshot().first).streaming)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expectedSettlement.rawValue)
    }

    func testPhase3GStreamingSlotSaturationRejectsBeforeResolverLedgerAndForwarding() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let resolverCalls = ConsumeInvocationCounter()
        let forwardCalls = ConsumeInvocationCounter()
        let upstreamClient = ConsumeStubUpstreamClient(
            resolver: { _, eventLoop in
                resolverCalls.increment()
                return eventLoop.makeSucceededFuture("8.8.8.8")
            },
            handler: { _, eventLoop in
                forwardCalls.increment()
                return eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
            }
        )
        let counter = ConsumeEndpointRequestCounter(maxOpenStreamingResponses: 0)
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow },
            requestCounter: counter
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_endpoint_busy")
        XCTAssertFalse(try localForwardedFlag(from: response.body))
        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(forwardCalls.snapshot(), 0)
        XCTAssertEqual(try ledger.summary(), .empty)
        let resourceSnapshot = counter.resourceSnapshot()
        XCTAssertEqual(resourceSnapshot.openStreamingResponses, 0)
        XCTAssertEqual(resourceSnapshot.responseSpoolBytes, 0)
    }

    func testPhase3GStreamingMissingDoneFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let sseBody = """
        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":10}}

        """
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("content-type", "text/event-stream")],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GCompressedStreamingResponseFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let sseBody = "data: [DONE]\n\n"
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "text/event-stream"),
                    ("content-encoding", "gzip"),
                ],
                body: try! self.gzipData(Data(sseBody.utf8))
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GWrongStreamingContentTypeFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("content-type", "application/json")],
                body: Data("data: [DONE]\n\n".utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GMalformedStreamingEventFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let sseBody = """
        data: not json

        data: [DONE]

        """
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("content-type", "text/event-stream")],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GStreamingPostDoneEventFailsBeforeLocalSuccessAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let sseBody = """
        data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}

        data: [DONE]

        event: keepalive

        """
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("content-type", "text/event-stream")],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GStreamingLedgerWriteFailureKeepsForwardedProvenance() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let sseBody = """
        data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}

        data: [DONE]

        """
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            try! FileManager.default.removeItem(at: ledgerURL)
            try! Data().write(to: ledgerURL)
            chmod(ledgerURL.path, 0o600)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("content-type", "text/event-stream")],
                body: Data(sseBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_budget_ledger_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        XCTAssertNil(response.headers.first(name: "content-encoding"))
    }

    func testPhase3DCloseDelimitedUpstreamParserWaitsForEOF() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".utf8)
        XCTAssertNil(try ConsumePinnedUpstreamClient.parseCompleteHTTPResponseForTesting(
            partial,
            maxBodyBytes: ConsumeLocalLimits.bodyBytes,
            allowCloseDelimitedBody: false
        ))

        let complete = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}".utf8)
        let response = try XCTUnwrap(try ConsumePinnedUpstreamClient.parseCompleteHTTPResponseForTesting(
            complete,
            maxBodyBytes: ConsumeLocalLimits.bodyBytes,
            allowCloseDelimitedBody: true
        ))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"usage":{"prompt_tokens":1,"completion_tokens":2}}"#)
    }

    func testPhase3DUpstreamParserRejectsInformationalResponsesAndHugeChunks() throws {
        for status in ["100 Continue", "101 Switching Protocols"] {
            XCTAssertThrowsError(try ConsumePinnedUpstreamClient.parseCompleteHTTPResponseForTesting(
                Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n".utf8),
                maxBodyBytes: ConsumeLocalLimits.bodyBytes,
                allowCloseDelimitedBody: true
            ))
        }

        XCTAssertThrowsError(try ConsumePinnedUpstreamClient.parseCompleteHTTPResponseForTesting(
            Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n".utf8),
            maxBodyBytes: ConsumeLocalLimits.bodyBytes,
            allowCloseDelimitedBody: true
        ))
    }

    func testPhase3DUpstreamParserRejectsHeaderControlCharacters() throws {
        for rawHeader in [
            "X-Request-Id: ok\nInjected: yes",
            "X-Request-Id: ok\rInjected: yes",
            "X-Request-Id: ok\u{7f}",
            "Content-Encoding:\u{0b}gzip",
            "Bad Header: value",
        ] {
            XCTAssertThrowsError(try ConsumePinnedUpstreamClient.parseCompleteHTTPResponseForTesting(
                Data("HTTP/1.1 200 OK\r\n\(rawHeader)\r\nContent-Length: 2\r\n\r\n{}".utf8),
                maxBodyBytes: ConsumeLocalLimits.bodyBytes,
                allowCloseDelimitedBody: true
            ))
        }
    }

    func testPhase3DBudgetedTrustedPricingForwardsAndSettlesToUsageBeforeResponse() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamBody = #"{"id":"chatcmpl-test","object":"chat.completion","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [
                    ("content-type", "application/json"),
                    ("set-cookie", "session=blocked"),
                    ("location", "https://example.invalid/redirect"),
                ],
                body: Data(upstreamBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let match = try XCTUnwrap(trustedRateCard.match(model: "llama-test"))
        let expected = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1,
            completionTokens: 2,
            match: match,
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.ok)
        XCTAssertEqual(response.body, upstreamBody)
        XCTAssertEqual(response.headers.first(name: "content-type"), "application/json")
        XCTAssertNil(response.headers.first(name: "set-cookie"))
        XCTAssertNil(response.headers.first(name: "location"))
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.origin, "https://api.malibu.tech")
        XCTAssertEqual(requests.first?.bearerToken, "buyer-token")
        XCTAssertEqual(requests.first?.body, Data(body.utf8))
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.rawValue)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
        XCTAssertEqual(runtime.statusPayload()["budget_remaining_micro_usd"] as? String, "\(100_000_000 - expected.rawValue)")
    }

    func testPhase3DTrustedPricingFallsBackToAdmissionEstimateWhenUsageMissing() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [],
                body: Data(#"{"id":"chatcmpl-test","choices":[]}"#.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.ok)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.reserved.rawValue, 0)
    }

    func testPhase3DTrustedPricingFallsBackToAdmissionEstimateWhenUsageIsUnpriceable() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [],
                body: Data(#"{"usage":{"prompt_tokens":-1,"completion_tokens":2}}"#.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.ok)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.estimateExceeded.rawValue, 0)
    }

    func testPhase3DNoBudgetExplicitLedgerRecordsAndSettlesForwardedRequest() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("no-budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let upstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [("x-macprovider-warning", "upstream_notice")],
                body: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":2}}"#.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let expected = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1,
            completionTokens: 2,
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus.ok)
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "upstream_notice,no_budget")
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.rawValue)
    }

    func testPhase3DEstimateExceededStopsLaterChargeableAdmission() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 1_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 200,
                headers: [],
                body: Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":20}}"#.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":1}"#
        let expected = try ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: 1000,
            completionTokens: 20,
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let first = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )
        XCTAssertEqual(first.status, HTTPResponseStatus.ok)
        let afterFirst = try ledger.summary()
        XCTAssertEqual(afterFirst.estimateExceeded.rawValue, expected.rawValue)
        XCTAssertEqual(runtime.statusPayload()["pricing_trust_state"] as? String, "estimate_exceeded")

        let second = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(second.status, HTTPResponseStatus.serviceUnavailable)
        XCTAssertEqual(try localError(from: second.body)["code"] as? String, "local_estimate_exceeded")
        XCTAssertEqual(recorder.snapshot().count, 1)
        let afterSecond = try ledger.summary()
        XCTAssertEqual(afterSecond.estimateExceeded.rawValue, expected.rawValue)
        XCTAssertEqual(afterSecond.reserved.rawValue, 0)
        XCTAssertEqual(runtime.statusPayload()["pricing_warning_codes"] as? [String], [])
    }

    func testPhase3GStreamingRequestRequiresEventStreamUpstreamBeforeLocalSuccess() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(statusCode: 200, headers: [], body: Data()))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 502))
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertTrue(try localForwardedFlag(from: response.body))
        let forwarded = try XCTUnwrap(recorder.snapshot().first)
        XCTAssertTrue(forwarded.streaming)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3GStreamingUpstreamErrorResponseIsPreservedAndSettlesEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let recorder = ConsumeUpstreamRequestRecorder()
        let upstreamBody = #"{"error":{"message":"rate limited","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"},"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
        let upstreamClient = ConsumeStubUpstreamClient { request, eventLoop in
            recorder.append(request)
            return eventLoop.makeSucceededFuture(ConsumeUpstreamResponse(
                statusCode: 429,
                headers: [
                    ("content-type", "application/json"),
                    ("retry-after", "3"),
                    ("x-request-id", "stream-error-request-id"),
                ],
                body: Data(upstreamBody.utf8)
            ))
        }
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            upstreamClient: upstreamClient,
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10,"stream":true}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status, HTTPResponseStatus(statusCode: 429))
        XCTAssertEqual(response.body, upstreamBody)
        XCTAssertEqual(response.headers.first(name: "content-type"), "application/json")
        XCTAssertEqual(response.headers.first(name: "retry-after"), "3")
        XCTAssertEqual(response.headers.first(name: "x-request-id"), "stream-error-request-id")
        XCTAssertTrue(try XCTUnwrap(recorder.snapshot().first).streaming)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.settled.rawValue, expected.amount.rawValue)
    }

    func testPhase3CPricedEstimateCapRejectsBeforeLedgerAppend() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let body = #"{"model":"llama-test","messages":[],"max_tokens":10}"#
        let expected = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: Data(body.utf8).count,
            request: StrictJSONParser.parse(body),
            match: XCTUnwrap(trustedRateCard.match(model: "llama-test")),
            projection: trustedRateCard.projection
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: ConsumeMicroUSD(rawValue: expected.amount.rawValue - 1),
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )

        XCTAssertEqual(response.status.code, 402)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_request_cap_exceeded")
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
    }

    func testPhase3CDefaultPricingTierDoesNotReservePricedEstimate() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0,
            includeModelRow: false
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(try ledger.summary().held.rawValue, 0)
    }

    func testPhase3COversizedOutputBoundFailsClosedBeforeLedgerAppend() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":9223372036854775808}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(try ledger.summary().held.rawValue, 0)
    }

    func testPhase3CMaxCompletionTokensAloneFailsClosedBeforeLedgerAppend() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_completion_tokens":1}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(try ledger.summary().held.rawValue, 0)
    }

    func testPhase3CNonUnitCreditConversionFailsClosedBeforeLedgerAppend() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.5
        )
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 100_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            budget: budget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[],"max_tokens":10}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
        XCTAssertEqual(try ledger.summary().held.rawValue, 0)
    }

    func testPhase3CMissingOutputBoundFailsClosedOrFallsBackToUnpricedOverride() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let trustedRateCard = phase3CTrustedRateCard(
            promptRatePerMtok: 1_000_000,
            completionRatePerMtok: 2_000_000,
            usdPerMillionCredits: 1.0
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        let body = #"{"model":"llama-test","messages":[]}"#

        do {
            let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
            let budget = ConsumeBudgetConfig(
                mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
                maxRequestMicroUSD: nil,
                allowUnpriced: false,
                ledger: ledger,
                ledgerPathClass: ledger.pathClass
            )
            let runtime = consumeRuntime(
                token: token,
                budget: budget,
                trustedPricing: .available(trustedRateCard),
                now: { ConsumeCommandTests.phase3CTestNow }
            )
            let response = try response(
                from: runtime,
                head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
                body: Data(body.utf8)
            )
            XCTAssertEqual(response.status, .serviceUnavailable)
            XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_pricing_unavailable")
            XCTAssertEqual(try ledger.summary().held.rawValue, 0)
        }

        let fallbackLedgerURL = home.appendingPathComponent("fallback-budget.jsonl")
        let fallbackLedger = try ConsumeBudgetLedger.open(ledgerPath: fallbackLedgerURL.path, homeDirectory: home, startupDirectory: home)
        let fallbackBudget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: fallbackLedger,
            ledgerPathClass: fallbackLedger.pathClass
        )
        let fallbackRuntime = consumeRuntime(
            token: token,
            budget: fallbackBudget,
            trustedPricing: .available(trustedRateCard),
            now: { ConsumeCommandTests.phase3CTestNow }
        )
        let fallbackResponse = try response(
            from: fallbackRuntime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(body.utf8)
        )
        XCTAssertEqual(fallbackResponse.status, .unauthorized)
        XCTAssertEqual(try localError(from: fallbackResponse.body)["code"] as? String, "local_credential_missing")
        XCTAssertNil(fallbackResponse.headers.first(name: "x-macprovider-warning"))
        XCTAssertEqual(try fallbackLedger.summary().held.rawValue, 0)
    }

    func testPhase3NoBudgetStatusUsesNullBudgetAmounts() throws {
        let token = try ConsumeLocalToken.generate()
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: false,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        let status = runtime.statusPayload()

        XCTAssertEqual(status["no_budget"] as? Bool, true)
        XCTAssertTrue(status["budget_configured_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_used_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_held_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_remaining_micro_usd"] is NSNull)
        XCTAssertTrue(status["pricing_warning_codes"] as? [String] == [])
    }

    func testPhase3NoBudgetStatusDoesNotTrustIneffectiveAllowUnpriced() throws {
        let token = try ConsumeLocalToken.generate()
        let budget = ConsumeBudgetConfig(
            mode: .noBudget,
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        let status = runtime.statusPayload()

        XCTAssertEqual(status["no_budget"] as? Bool, true)
        XCTAssertEqual(status["unpriced_override"] as? Bool, true)
        XCTAssertEqual(status["pricing_trust_state"] as? String, "unavailable")
    }

    func testPhase3UnconfiguredStatusDoesNotTrustAllowUnpriced() throws {
        let token = try ConsumeLocalToken.generate()
        let budget = ConsumeBudgetConfig(
            mode: .unconfigured,
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: nil,
            ledgerPathClass: nil
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        let status = runtime.statusPayload()

        XCTAssertEqual(status["pricing_trust_state"] as? String, "unavailable")
        XCTAssertEqual(status["unpriced_override"] as? Bool, true)
        XCTAssertTrue(status["budget_configured_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_ledger_state"] is NSNull)
    }

    func testPhase3BudgetStatusDoesNotMaskCorruptLedger() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("corrupt.jsonl")
        try Data("not-json\n".utf8).write(to: ledgerURL)
        chmod(ledgerURL.path, 0o600)
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        let status = runtime.statusPayload()

        XCTAssertEqual(status["pricing_trust_state"] as? String, "unavailable")
        XCTAssertEqual(status["budget_ledger_state"] as? String, "unavailable")
        XCTAssertTrue(status["budget_used_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_held_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_remaining_micro_usd"] is NSNull)
    }

    func testPhase3BudgetStatusDoesNotTrapOnOverflowingCommittedExposure() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("overflow.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "\(Int64.max)",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:00Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-b",
                    "reservation_id": "reservation-2",
                    "admission_estimate_micro_usd": "\(Int64.max)",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:01Z",
                ],
            ],
            to: ledgerURL
        )
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        let status = runtime.statusPayload()

        XCTAssertEqual(status["pricing_trust_state"] as? String, "unavailable")
        XCTAssertEqual(status["budget_ledger_state"] as? String, "unavailable")
        XCTAssertTrue(status["budget_used_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_held_micro_usd"] is NSNull)
        XCTAssertTrue(status["budget_remaining_micro_usd"] is NSNull)
    }

    func testPhase3LedgerRejectsMalformedJSONAndUnsupportedTransitions() throws {
        let home = try makeTemporaryDirectory()

        let blankLineURL = home.appendingPathComponent("blank-line.jsonl")
        try Data("\n".utf8).write(to: blankLineURL)
        chmod(blankLineURL.path, 0o600)
        let blankLineLedger = try ConsumeBudgetLedger.open(
            ledgerPath: blankLineURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try blankLineLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let duplicateKeyURL = home.appendingPathComponent("duplicate-key.jsonl")
        try Data("""
        {"schema_version":"\(ConsumeBudgetLedger.schemaVersion)","transition":"reserved","state":"reserved","run_id":"run-a","reservation_id":"reservation-1","admission_estimate_micro_usd":"100","admission_estimate_micro_usd":"200","reason":"test","created_at":"2026-08-23T00:00:00Z"}

        """.utf8).write(to: duplicateKeyURL)
        chmod(duplicateKeyURL.path, 0o600)
        let duplicateKeyLedger = try ConsumeBudgetLedger.open(
            ledgerPath: duplicateKeyURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try duplicateKeyLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let invalidUTF8URL = home.appendingPathComponent("invalid-utf8.jsonl")
        try Data([0xff, 0x0a]).write(to: invalidUTF8URL)
        chmod(invalidUTF8URL.path, 0o600)
        let invalidUTF8Ledger = try ConsumeBudgetLedger.open(
            ledgerPath: invalidUTF8URL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try invalidUTF8Ledger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let tornRowURL = home.appendingPathComponent("torn-row.jsonl")
        try Data("""
        {"schema_version":"\(ConsumeBudgetLedger.schemaVersion)","transition":"reserved","state":"reserved","run_id":"run-a","reservation_id":"reservation-1","admission_estimate_micro_usd":"100","reason":"test","created_at":"2026-08-23T00:00:00Z"}
        """.trimmingCharacters(in: .newlines).utf8).write(to: tornRowURL)
        chmod(tornRowURL.path, 0o600)
        let tornRowLedger = try ConsumeBudgetLedger.open(
            ledgerPath: tornRowURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try tornRowLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let settledTransitionURL = home.appendingPathComponent("settled.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:00Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "settled",
                    "state": "settled",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:01Z",
                ],
            ],
            to: settledTransitionURL
        )
        let settledTransitionLedger = try ConsumeBudgetLedger.open(
            ledgerPath: settledTransitionURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try settledTransitionLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let interiorBlankURL = home.appendingPathComponent("interior-blank.jsonl")
        try Data("""
        {"schema_version":"\(ConsumeBudgetLedger.schemaVersion)","transition":"reserved","state":"reserved","run_id":"run-a","reservation_id":"reservation-1","admission_estimate_micro_usd":"100","reason":"test","created_at":"2026-08-23T00:00:00Z"}


        """.utf8).write(to: interiorBlankURL)
        chmod(interiorBlankURL.path, 0o600)
        let interiorBlankLedger = try ConsumeBudgetLedger.open(
            ledgerPath: interiorBlankURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try interiorBlankLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let unsupportedTransitionURL = home.appendingPathComponent("estimate-exceeded.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:00Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "estimate_exceeded",
                    "state": "estimate_exceeded",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:01Z",
                ],
            ],
            to: unsupportedTransitionURL
        )
        let unsupportedTransitionLedger = try ConsumeBudgetLedger.open(
            ledgerPath: unsupportedTransitionURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try unsupportedTransitionLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }
    }

    func testPhase3LedgerRejectsPathReplacementAfterOpen() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)

        try FileManager.default.removeItem(at: ledgerURL)
        try Data("".utf8).write(to: ledgerURL)
        chmod(ledgerURL.path, 0o600)

        XCTAssertThrowsError(try ledger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

    }

    func testPhase3LedgerRejectsParentReplacementAfterOpen() throws {
        let home = try makeTemporaryDirectory()
        let parent = home.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ledgerURL = parent.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        XCTAssertNoThrow(try ledger.summary())

        let movedParent = home.appendingPathComponent("moved-parent", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: movedParent)

        XCTAssertThrowsError(try ledger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }
    }

    func testPhase3LedgerRejectsLockReplacementAfterOpen() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let lockURL = URL(fileURLWithPath: ledgerURL.path + ".lock")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)

        try FileManager.default.removeItem(at: lockURL)
        try Data("".utf8).write(to: lockURL)
        chmod(lockURL.path, 0o600)

        XCTAssertThrowsError(try ledger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

    }

    func testPhase3LedgerRejectsConcurrentOpenOnSameLock() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        _ = ledger

        XCTAssertThrowsError(try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }
    }

    func testPhase3LedgerRejectsUnsafeExistingLedgerOrLockMode() throws {
        let home = try makeTemporaryDirectory()
        let unsafeLedgerURL = home.appendingPathComponent("unsafe-ledger.jsonl")
        try Data("".utf8).write(to: unsafeLedgerURL)
        chmod(unsafeLedgerURL.path, 0o640)
        XCTAssertThrowsError(try ConsumeBudgetLedger.open(ledgerPath: unsafeLedgerURL.path, homeDirectory: home, startupDirectory: home)) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let unsafeLockLedgerURL = home.appendingPathComponent("unsafe-lock.jsonl")
        let unsafeLockURL = URL(fileURLWithPath: unsafeLockLedgerURL.path + ".lock")
        try Data("".utf8).write(to: unsafeLockURL)
        chmod(unsafeLockURL.path, 0o640)
        XCTAssertThrowsError(try ConsumeBudgetLedger.open(ledgerPath: unsafeLockLedgerURL.path, homeDirectory: home, startupDirectory: home)) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }
    }

    func testPhase3LedgerCreationFailuresAreRedacted() throws {
        let home = try makeTemporaryDirectory()
        let blockingFile = home.appendingPathComponent("root")
        try Data("not-a-directory".utf8).write(to: blockingFile)
        chmod(blockingFile.path, 0o600)
        let sensitiveLedger = blockingFile
            .appendingPathComponent("sensitive-user")
            .appendingPathComponent("budget.jsonl")

        XCTAssertThrowsError(try ConsumeBudgetLedger.open(ledgerPath: sensitiveLedger.path, homeDirectory: home, startupDirectory: home)) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
            XCTAssertFalse(String(describing: error).contains("sensitive-user"))
        }
    }

    func testPhase3LedgerRejectsRunIDAndAmountMutation() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-a",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:00Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "held",
                    "state": "held",
                    "run_id": "run-b",
                    "reservation_id": "reservation-1",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:01Z",
                ],
            ],
            to: ledgerURL
        )
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)

        XCTAssertThrowsError(try ledger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }

        let amountMutationURL = home.appendingPathComponent("amount-mutation.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "run-a",
                    "reservation_id": "reservation-2",
                    "admission_estimate_micro_usd": "100",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:02Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.schemaVersion,
                    "transition": "held",
                    "state": "held",
                    "run_id": "run-a",
                    "reservation_id": "reservation-2",
                    "admission_estimate_micro_usd": "200",
                    "reason": "test",
                    "created_at": "2026-08-23T00:00:03Z",
                ],
            ],
            to: amountMutationURL
        )
        let amountMutationLedger = try ConsumeBudgetLedger.open(
            ledgerPath: amountMutationURL.path,
            homeDirectory: home,
            startupDirectory: home
        )
        XCTAssertThrowsError(try amountMutationLedger.summary()) { error in
            XCTAssertEqual((error as? ConsumeBudgetError)?.code, "local_budget_ledger_unavailable")
        }
    }

    func testPhase3LedgerReadsPhase3ACompatRowsBeforeFinalWrites() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("legacy-budget.jsonl")
        try writeLedgerRows(
            [
                [
                    "schema_version": ConsumeBudgetLedger.phase3ALegacySchemaVersion,
                    "transition": "reserved",
                    "state": "reserved",
                    "run_id": "legacy-run",
                    "reservation_id": "legacy-reservation",
                    "amount_micro_usd": "250",
                    "reason": "legacy_reserved",
                    "created_at": "2026-08-22T00:00:00Z",
                ],
                [
                    "schema_version": ConsumeBudgetLedger.phase3ALegacySchemaVersion,
                    "transition": "held",
                    "state": "held",
                    "run_id": "legacy-run",
                    "reservation_id": "legacy-reservation",
                    "amount_micro_usd": "250",
                    "reason": "legacy_held",
                    "created_at": "2026-08-22T00:00:01Z",
                ],
            ],
            to: ledgerURL
        )
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)

        var summary = try ledger.summary()
        XCTAssertEqual(summary.held.rawValue, 250)
        XCTAssertEqual(summary.heldReservationCount, 1)
        XCTAssertEqual(summary.reserved.rawValue, 0)

        XCTAssertEqual(try ledger.releaseHeld(runID: "legacy-run"), 1)
        summary = try ledger.summary()
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.released.rawValue, 250)
        XCTAssertEqual(summary.heldReservationCount, 0)
        XCTAssertTrue(try String(contentsOf: ledgerURL).contains(ConsumeBudgetLedger.schemaVersion))
    }

    func testPhase3ConcurrentUnpricedAdmissionSerializesFullBudget() throws {
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let resultLock = NSLock()
        var results: [ConsumeBudgetAdmissionResult] = []
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                let result = try ledger.reserveAndHoldUnpricedRemaining(
                    runID: "run-\(index)",
                    budget: ConsumeMicroUSD(rawValue: 1_000_000),
                    maxRequest: nil
                )
                resultLock.lock()
                results.append(result)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(error)
                resultLock.unlock()
            }
        }

        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(results.filter { if case .held = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(results.filter { $0 == .budgetExceeded }.count, 7)
        let summary = try ledger.summary()
        XCTAssertEqual(summary.held.rawValue, 1_000_000)
        XCTAssertEqual(summary.heldReservationCount, 1)
    }

    func testPhase3BudgetedUnpricedRequestIsHeldUntilRelease() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
            maxRequestMicroUSD: nil,
            allowUnpriced: true,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(
            token: token,
            credentialStatus: .environmentLoaded,
            credentialCustody: consumeCredentialCustody("buyer-token"),
            budget: budget
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_upstream_unavailable")
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "unpriced_override")
        var summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 1_000_000)
        XCTAssertEqual(summary.heldReservationCount, 1)
        XCTAssertEqual(runtime.statusPayload()["budget_remaining_micro_usd"] as? String, "0")

        XCTAssertEqual(try ledger.releaseHeld(runID: "wrong-run"), 0)
        summary = try ledger.summary()
        XCTAssertEqual(summary.held.rawValue, 1_000_000)
        XCTAssertEqual(summary.released.rawValue, 0)

        XCTAssertEqual(try ledger.releaseHeld(runID: "launch-phase2-test"), 1)
        summary = try ledger.summary()
        XCTAssertEqual(summary.held.rawValue, 0)
        XCTAssertEqual(summary.released.rawValue, 1_000_000)
    }

    func testPhase3PerRequestCapRejectsBeforeLedgerAppend() throws {
        let token = try ConsumeLocalToken.generate()
        let home = try makeTemporaryDirectory()
        let ledgerURL = home.appendingPathComponent("budget.jsonl")
        let ledger = try ConsumeBudgetLedger.open(ledgerPath: ledgerURL.path, homeDirectory: home, startupDirectory: home)
        let budget = ConsumeBudgetConfig(
            mode: .budget(ConsumeMicroUSD(rawValue: 1_000_000)),
            maxRequestMicroUSD: ConsumeMicroUSD(rawValue: 100_000),
            allowUnpriced: true,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
        let runtime = consumeRuntime(token: token, budget: budget)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let response = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[]}"#.utf8)
        )

        XCTAssertEqual(response.status.code, 402)
        XCTAssertEqual(try localError(from: response.body)["code"] as? String, "local_request_cap_exceeded")
        let summary = try ledger.summary()
        XCTAssertEqual(summary.reserved.rawValue, 0)
        XCTAssertEqual(summary.held.rawValue, 0)
    }

    func testPhase2ModelsReturnsOnlyLocalAllowlistEntries() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = consumeRuntime(
            token: token,
            allowedModels: ["llama-test", "mistral-test"]
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        headers.add(name: "Cookie", value: "local=secret")
        headers.add(name: "Forwarded", value: "for=127.0.0.1")

        let models = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/models", headers: headers)
        )

        XCTAssertEqual(models.status, .ok)
        XCTAssertEqual(models.headers.first(name: "cache-control"), "no-store")
        XCTAssertNil(models.headers.first(name: "set-cookie"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(models.body.utf8)) as? [String: Any])
        XCTAssertEqual(object["object"] as? String, "list")
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.compactMap { $0["id"] as? String }, ["llama-test", "mistral-test"])
        XCTAssertEqual(data.compactMap { $0["object"] as? String }, ["model", "model"])
    }

    func testPhase2ModelsDefaultEmptyAllowlistReturnsEmptyList() throws {
        let token = try ConsumeLocalToken.generate()
        let runtime = consumeRuntime(
            token: token,
            allowedModels: []
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")

        let models = try response(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/models", headers: headers)
        )

        XCTAssertEqual(models.status, .ok)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(models.body.utf8)) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 0)
    }

    private func localError(from body: String) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try XCTUnwrap(object["error"] as? [String: Any])
    }

    private func localForwardedFlag(from body: String) throws -> Bool {
        let macprovider = try XCTUnwrap(localError(from: body)["macprovider"] as? [String: Any])
        return try XCTUnwrap(macprovider["forwarded_upstream"] as? Bool)
    }

    private func gzipData(_ data: Data) throws -> Data {
        guard data.count <= Int(UInt32.max) else {
            throw NSError(domain: "ConsumeCommandTests.gzip", code: -1)
        }
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            16 + MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw NSError(domain: "ConsumeCommandTests.gzip", code: Int(initStatus))
        }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(data.count)
            var output = Data()
            let chunkSize = 32 * 1024
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                status = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw NSError(domain: "ConsumeCommandTests.gzip", code: Int(status))
                }
            } while status != Z_STREAM_END
            return output
        }
    }

    private func writeCredential(_ value: String, under directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((value + "\n").utf8).write(to: url)
        chmod(url.path, 0o600)
        return url
    }

    private func writeLedgerRows(_ rows: [[String: Any]], to url: URL) throws {
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try data.write(to: url)
        chmod(url.path, 0o600)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/mp-consume-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(base.path, 0o700)
        let dir = base
            .appendingPathComponent("mp-consume-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func octalMode(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o777)
    }

    private struct CapturedStatusOutput {
        let stderr: String
        let error: Error?
    }

    private final class LockedTestDate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    private func captureStatusOutput(_ body: () async throws -> Void) async -> CapturedStatusOutput {
        var stderr = ""
        let restore = ConsumeEndpointStatus.replaceStderrSinkForTesting { stderr += $0 }
        defer { restore() }
        let error: Error?
        do {
            try await body()
            error = nil
        } catch let caught {
            error = caught
        }
        return CapturedStatusOutput(stderr: stderr, error: error)
    }

    private func nextLoopbackPort() throws -> Int {
        let reserved = try reserveLoopbackPort()
        close(reserved.fd)
        return reserved.port
    }

    private func reserveLoopbackPort() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fd)
            throw POSIXError(.EIO)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    private func addReadACLEntry(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }

    private static let phase3CTestNow = ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-23T00:00:00Z")!

    private func consumeRuntime(
        token: ConsumeLocalToken,
        credentialStatus: ConsumeCredentialStatus = .missing,
        credentialCustody: ConsumeCredentialCustody? = nil,
        allowedModels: [String] = ["llama-test"],
        budget: ConsumeBudgetConfig = .unconfigured,
        trustedPricing: ConsumeTrustedPricingState = .notLoaded,
        upstreamClient: ConsumeUpstreamClient = ConsumeStubUpstreamClient { _, eventLoop in
            eventLoop.makeFailedFuture(ConsumeUpstreamForwardError.dispatchedUnavailable)
        },
        pricingAdmissionGate: ConsumePricingAdmissionGate = ConsumePricingAdmissionGate(),
        now: @escaping @Sendable () -> Date = { Date() },
        requestCounter: ConsumeEndpointRequestCounter = ConsumeEndpointRequestCounter()
    ) -> ConsumeEndpointRuntime {
        ConsumeEndpointRuntime(
            launchID: "launch-phase2-test",
            boundURL: "http://127.0.0.1:11435",
            upstreamOrigin: "https://api.malibu.tech",
            credentialSourceClass: credentialStatus.state == .loaded ? "environment" : "missing",
            credentialStatus: credentialStatus,
            modelAllowlist: allowedModels,
            tokenVerifier: token.verifier,
            credentialCustody: credentialCustody,
            budget: budget,
            trustedPricing: trustedPricing,
            upstreamClient: upstreamClient,
            pricingAdmissionGate: pricingAdmissionGate,
            now: now,
            requestCounter: requestCounter
        )
    }

    private func consumeCredentialCustody(_ token: String) -> ConsumeCredentialCustody {
        ConsumeCredentialCustody(credential: ConsumeCredential(
            bytes: Data(token.utf8),
            sourceClass: .environment,
            status: .environmentLoaded
        ))
    }

    private func phase3BTrustedRateCard(generatedAt: String) -> ConsumeTrustedRateCard {
        let generatedDate = ISO8601DateFormatter.autotuneInternet.date(from: generatedAt)!
        let rows: [String: RateCardProjection.Row] = [
            "default": RateCardProjection.Row(
                promptRatePerMtok: 500_000,
                promptCacheHitRatePerMtok: 125_000,
                completionRatePerMtok: 1_000_000,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
            "llama-test": RateCardProjection.Row(
                promptRatePerMtok: 10,
                promptCacheHitRatePerMtok: 5,
                completionRatePerMtok: 20,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]
        var projection = RateCardProjection(
            version: "",
            policyVersion: "consume-test-policy",
            generatedAt: generatedDate,
            usdPerMillionCredits: 1.0,
            rows: rows
        )
        projection.version = projection.projectionHash
        return ConsumeTrustedRateCard(
            version: projection.version,
            policyVersion: projection.policyVersion,
            generatedAt: generatedDate,
            signerKeyID: "consume-test-key",
            projection: projection,
            stale: false
        )
    }

    private func phase3CTrustedRateCard(
        promptRatePerMtok: Int64,
        promptCacheHitRatePerMtok: Int64? = nil,
        completionRatePerMtok: Int64,
        providerShareBPS: Int64 = 9_000,
        globalMultiplierPPM: Int64 = 1_000_000,
        usdPerMillionCredits: Double,
        includeModelRow: Bool = true
    ) -> ConsumeTrustedRateCard {
        let generatedDate = ISO8601DateFormatter.autotuneInternet.date(from: "2026-08-20T00:00:00Z")!
        var rows: [String: RateCardProjection.Row] = [
            "default": RateCardProjection.Row(
                promptRatePerMtok: promptRatePerMtok,
                promptCacheHitRatePerMtok: promptCacheHitRatePerMtok,
                completionRatePerMtok: completionRatePerMtok,
                providerShareBPS: providerShareBPS,
                globalMultiplierPPM: globalMultiplierPPM
            ),
        ]
        if includeModelRow {
            rows["llama-test"] = RateCardProjection.Row(
                promptRatePerMtok: promptRatePerMtok,
                promptCacheHitRatePerMtok: promptCacheHitRatePerMtok,
                completionRatePerMtok: completionRatePerMtok,
                providerShareBPS: providerShareBPS,
                globalMultiplierPPM: globalMultiplierPPM
            )
        }
        var projection = RateCardProjection(
            version: "",
            policyVersion: "consume-test-policy",
            generatedAt: generatedDate,
            usdPerMillionCredits: usdPerMillionCredits,
            rows: rows
        )
        projection.version = projection.projectionHash
        return ConsumeTrustedRateCard(
            version: projection.version,
            policyVersion: projection.policyVersion,
            generatedAt: generatedDate,
            signerKeyID: "consume-test-key",
            projection: projection,
            stale: false
        )
    }

    private func rawConsumeChannel(runtime: ConsumeEndpointRuntime) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeStartLineLimitHandler()).wait()
        try channel.pipeline.configureHTTPServerPipeline(
            withDecoderLimitConfiguration: ConsumeLocalLimits.httpDecoderLimitConfiguration
        ).wait()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 11435)).wait()
        return channel
    }

    private func writeRawRequest(_ request: String, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try channel.writeInbound(buffer)
    }

    private func response(
        from runtime: ConsumeEndpointRuntime,
        head: HTTPRequestHead,
        body requestBody: Data = Data()
    ) throws -> (status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var responseHead: HTTPResponseHead?
        var responseBody = Data()

        try channel.writeInbound(HTTPServerRequestPart.head(head))
        if !requestBody.isEmpty {
            var buffer = channel.allocator.buffer(capacity: requestBody.count)
            buffer.writeBytes(requestBody)
            try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        }
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        channel.embeddedEventLoop.run()

        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head):
                responseHead = head
            case .body(.byteBuffer(var buffer)):
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    responseBody.append(contentsOf: bytes)
                }
            case .end:
                guard let responseHead else {
                    XCTFail("response head was not emitted")
                    return (.internalServerError, HTTPHeaders(), "")
                }
                return (responseHead.status, responseHead.headers, String(decoding: responseBody, as: UTF8.self))
            default:
                break
            }
        }

        XCTFail("response end was not emitted")
        return (.internalServerError, HTTPHeaders(), String(decoding: responseBody, as: UTF8.self))
    }

    private func drainResponse(from channel: EmbeddedChannel) throws -> (status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
        var responseHead: HTTPResponseHead?
        var responseBody = Data()
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head):
                responseHead = head
            case .body(.byteBuffer(var buffer)):
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    responseBody.append(contentsOf: bytes)
                }
            case .end:
                guard let responseHead else {
                    XCTFail("response head was not emitted")
                    return (.internalServerError, HTTPHeaders(), "")
                }
                return (responseHead.status, responseHead.headers, String(decoding: responseBody, as: UTF8.self))
            default:
                break
            }
        }
        XCTFail("response end was not emitted")
        return (.internalServerError, HTTPHeaders(), String(decoding: responseBody, as: UTF8.self))
    }
}
