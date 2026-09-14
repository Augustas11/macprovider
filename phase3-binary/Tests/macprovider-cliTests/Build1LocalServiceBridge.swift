import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

/// Starts only real local Go services and the deterministic WS companion. All
/// provider credentials are disposable protected files below the fixture config.
final class Build1LocalServiceBridge {
    let root: URL
    let process: Process
    let log: FileHandle
    let coordinatorURL: String
    let providerID: String

    private init(root: URL, process: Process, log: FileHandle, coordinatorURL: String, providerID: String) {
        self.root = root; self.process = process; self.log = log
        self.coordinatorURL = coordinatorURL; self.providerID = providerID
    }

    static func start(root: URL, inputs: Build1CommandFixtureInputs, modelID: String, artifactSHA256: String) async throws -> Build1LocalServiceBridge {
        let providerID = "build1-cli-fixture"
        let custody = root.appendingPathComponent("home/.config/macprovider/protected-credentials")
        let identity = try ProtectedFileReceiptKeyStore(rootDirectory: custody)
            .loadOrStoreAdmissionIdentity(providerId: providerID, candidate: Curve25519.Signing.PrivateKey())
        let catalog = try AutotuneStaticInputs.decodeCandidateCatalog(Data(contentsOf: inputs.directory.appendingPathComponent("autotune-candidates")))
        let manifest: [String: Any] = ["root": root.path, "inputs": inputs.directory.path, "model_id": modelID,
            "catalog_key": inputs.catalogKey, "model_hash": artifactSHA256,
            "row_identity": try XCTUnwrap(catalog.rowIdentity(for: inputs.catalogKey)),
            "admission_public_key": identity.publicKey.rawRepresentation.base64EncodedString()]
        let manifestURL = root.appendingPathComponent("service-manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        let go = try XCTUnwrap(["/opt/homebrew/bin/go", "/usr/local/bin/go", "/usr/local/go/bin/go"].first { FileManager.default.isExecutableFile(atPath: $0) })
        let goEnvironment = Process()
        goEnvironment.executableURL = URL(fileURLWithPath: go)
        goEnvironment.arguments = ["env", "-json", "GOMODCACHE", "GOCACHE", "GOROOT"]
        goEnvironment.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        let environmentOutput = Pipe(); goEnvironment.standardOutput = environmentOutput; goEnvironment.standardError = FileHandle.nullDevice
        try goEnvironment.run()
        let environmentDeadline = Date().addingTimeInterval(10)
        while goEnvironment.isRunning && Date() < environmentDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !goEnvironment.isRunning else {
            kill(goEnvironment.processIdentifier, SIGKILL)
            throw URLError(.timedOut)
        }
        guard goEnvironment.terminationStatus == 0 else { throw URLError(.cannotLoadFromNetwork) }
        let environmentBytes = environmentOutput.fileHandleForReading.readDataToEndOfFile()
        let compilerCaches = try XCTUnwrap(JSONSerialization.jsonObject(with: environmentBytes) as? [String: String])
        let logURL = root.appendingPathComponent("service-bridge.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "macprovider_cliTests.Build1CommandBootstrapTests/testServiceBridgeSubprocessEntry",
            Bundle(for: Build1CommandBootstrapTests.self).bundlePath]
        process.currentDirectoryURL = root
        process.environment = compilerCaches.merging(["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.appendingPathComponent("home").path, "TMPDIR": root.path]) { _, new in new }
        process.standardOutput = log; process.standardError = log
        try process.run()
        do {
            let ready = try await awaitFile(root: root, name: "service-ready.json", process: process)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: ready) as? [String: Any])
            let endpoint = try XCTUnwrap(response["coordinator_url"] as? String)
            let id = try XCTUnwrap(response["provider_id"] as? String)
            let token = try XCTUnwrap(response["provider_token"] as? String)
            guard id == providerID else { throw URLError(.badServerResponse) }
            let transport = try transportURLs(endpoint: endpoint)
            try ProtectedFileProviderCredentialStore(rootDirectory: custody).importIfAbsentOrMatches(providerID: id, token: token)
            return Build1LocalServiceBridge(root: root, process: process, log: log, coordinatorURL: transport.logical, providerID: id)
        } catch {
            await shutdown(root: root, process: process)
            try? log.close(); throw error
        }
    }

    /// The parsed command retains its production HTTPS validation. Only this
    /// fixture client maps that exact logical origin to the observed HTTP server.
    /// This exercises real HTTP transport; it provides no TLS evidence.
    static func transportURLs(endpoint: String) throws -> (logical: String, actual: URL) {
        guard var components = URLComponents(string: endpoint),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let actual = components.url, actual.absoluteString == endpoint else {
            throw URLError(.badServerResponse)
        }
        components.scheme = "https"
        guard let logical = components.url?.absoluteString else { throw URLError(.badURL) }
        return (logical, actual)
    }

    func connectProvider() async throws {
        try Data().write(to: root.appendingPathComponent("service-connect"))
        let bytes = try await Self.awaitFile(root: root, name: "service-identity-request.json", process: process)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let custody = root.appendingPathComponent("home/.config/macprovider/protected-credentials")
        let identity = try XCTUnwrap(ProtectedFileReceiptKeyStore(rootDirectory: custody).loadAdmissionIdentity(providerId: providerID))
        let proof = try Self.signIdentityProof(request: request, providerID: providerID, identity: identity)
        let proofURL = root.appendingPathComponent("service-identity-proof.json")
        let temporary = root.appendingPathComponent("service-identity-proof.tmp")
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: proofURL)
        _ = try await Self.awaitFile(root: root, name: "service-connected.json", process: process)
    }
    static func signIdentityProof(request: [String: Any], providerID: String,
                                  identity: Curve25519.Signing.PrivateKey) throws -> [String: String] {
        guard let initial = request["initial"] as? [String: Any],
              let challenge = request["challenge"] as? [String: Any],
              initial["provider_id"] as? String == providerID,
              initial["type"] as? String == "auth_request", initial["stage"] as? String == "initial",
              initial["version"] as? Int == 2,
              let binary = initial["binary_version"] as? String,
              let ecdh = initial["provider_ecdh_public_key"] as? String,
              challenge["type"] as? String == "auth_challenge",
              let attempt = challenge["auth_attempt_id"] as? String, !attempt.isEmpty,
              let session = challenge["assigned_id"] as? String, !session.isEmpty,
              (challenge["admission_identity_public_key"] as? String ?? challenge["bootstrap_identity_public_key"] as? String)
                == identity.publicKey.rawRepresentation.base64EncodedString() else {
            throw URLError(.userAuthenticationRequired)
        }
        let transcript = try CoordinatorClient.initialAuthTranscriptHashBase64(initial)
        // The fixture's advertised binary version belongs to its own transcript.
        // The production Swift signer uses the identical tuple with its binaryVersion.
        let tuple: [String: Any] = ["auth_attempt_id": attempt, "provider_id": providerID,
            "binary_version": binary, "provider_ecdh_public_key": ecdh, "transcript_sha256": transcript]
        let payload = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(tuple))
        return ["identity_signature": try identity.signature(for: payload).base64EncodedString(),
                "identity_signature_transcript_sha256": transcript]
    }

    func verifySettlement() async throws -> [String: Any] {
        try Data().write(to: root.appendingPathComponent("service-verify"))
        let bytes = try await Self.awaitFile(root: root, name: "service-verified.json", process: process)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    func stop() async {
        await Self.shutdown(root: root, process: process)
        try? log.close()
    }
    private static func shutdown(root: URL, process: Process) async {
        try? Data().write(to: root.appendingPathComponent("service-stop"))
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
        let completionDeadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < completionDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    static func runSubprocess() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let manifest = root.appendingPathComponent("service-manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { _exit(93) }
        let parent = getppid()
        Thread.detachNewThread {
            while getppid() == parent { Thread.sleep(forTimeInterval: 0.1) }
            kill(-getpgrp(), SIGTERM)
            _exit(94)
        }
        let go = try XCTUnwrap(["/opt/homebrew/bin/go", "/usr/local/bin/go", "/usr/local/go/bin/go"].first { FileManager.default.isExecutableFile(atPath: $0) })
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let child = Process(); child.executableURL = URL(fileURLWithPath: go)
        child.arguments = ["test", "-run", "^TestBuild1CLIServiceBridge$", "-count=1", "-timeout=180s", "-args", "-build1-cli-manifest=" + manifest.path]
        child.currentDirectoryURL = repo.appendingPathComponent("test/integration")
        child.environment = ProcessInfo.processInfo.environment
        child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
        try child.run()
        let deadline = Date().addingTimeInterval(200)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !child.isRunning else {
            kill(-getpgrp(), SIGTERM)
            _exit(ETIMEDOUT)
        }
        if child.terminationStatus != 0 { kill(-getpgrp(), SIGTERM) }
        _exit(child.terminationStatus)
    }
    // Only bridge assertions we own are exposed; service logs and generated
    // credential material stay private and are deleted with the fixture root.
    private static func failureSummary(root: URL) -> String {
        let text = (try? String(contentsOf: root.appendingPathComponent("service-bridge.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.contains("build1_cli_bridge_test.go:") }
            .suffix(6).map { "\n" + String($0) }.joined()
    }
    private static func awaitFile(root: URL, name: String, process: Process) async throws -> Data {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) { return bytes }
            guard process.isRunning else { throw NSError(domain: "Build1ServiceBridge", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Bridge exited before " + name + Self.failureSummary(root: root)]) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "Build1ServiceBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bridge timed out before " + name])
    }
}
