import ArgumentParser
import Darwin
import Foundation
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import macprovider_cli

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
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://224.0.0.1"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[fc00::1]"))
        XCTAssertThrowsError(try ConsumeEndpointConfig.normalizeUpstreamOrigin("https://[fe80::1]"))
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
        runtime.beginRequest()
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
        XCTAssertEqual(wrongPath.status, HTTPResponseStatus.notFound)
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

    private func localError(from body: String) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try XCTUnwrap(object["error"] as? [String: Any])
    }

    private func writeCredential(_ value: String, under directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((value + "\n").utf8).write(to: url)
        chmod(url.path, 0o600)
        return url
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

    private func response(
        from runtime: ConsumeEndpointRuntime,
        head: HTTPRequestHead
    ) throws -> (status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
        var responseHead: HTTPResponseHead?
        var body = Data()

        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head):
                responseHead = head
            case .body(.byteBuffer(var buffer)):
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    body.append(contentsOf: bytes)
                }
            case .end:
                guard let responseHead else {
                    XCTFail("response head was not emitted")
                    return (.internalServerError, HTTPHeaders(), "")
                }
                return (responseHead.status, responseHead.headers, String(decoding: body, as: UTF8.self))
            default:
                break
            }
        }

        XCTFail("response end was not emitted")
        return (.internalServerError, HTTPHeaders(), String(decoding: body, as: UTF8.self))
    }
}
