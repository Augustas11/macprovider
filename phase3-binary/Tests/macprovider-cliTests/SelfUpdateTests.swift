import Foundation
import Darwin
import XCTest
@testable import macprovider_cli

final class SelfUpdateTests: XCTestCase {
    func testDefaultReleaseRepositoryMatchesPublicInstaller() {
        XCTAssertEqual(
            SelfUpdate.defaultReleasesAPIURL,
            "https://api.github.com/repos/Augustas11/macprovider/releases/latest"
        )
    }

    func testReleaseAPIURLIgnoresEnvironmentFallback() {
        withEnvironmentVariable("MACPROVIDER_RELEASES_API_URL", value: "http://attacker.invalid/releases") {
            let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: nil)

            XCTAssertEqual(update.resolvedReleasesAPIURLForTest(), SelfUpdate.defaultReleasesAPIURL)
        }
    }

    func testReleaseAPIURLRejectsUntrustedExplicitOverrideBeforeFetching() async throws {
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: "http://attacker.invalid/releases")

        do {
            try await update.run(checkOnly: true)
            XCTFail("update unexpectedly fetched from an untrusted release API URL")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.untrustedReleaseAPIURL("http://attacker.invalid/releases").description
            )
        }
    }

    func testReleaseSigningKeyIgnoresEnvironmentOverride() {
        let attackerKey = """
        -----BEGIN PUBLIC KEY-----
        attacker-controlled-key
        -----END PUBLIC KEY-----
        """

        withEnvironmentVariable("MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM", value: attackerKey) {
            XCTAssertEqual(SelfUpdate.releaseSigningPublicKeyPEMForTest(), SelfUpdate.checksumPublicKeyPEM)
            XCTAssertNotEqual(SelfUpdate.releaseSigningPublicKeyPEMForTest(), attackerKey)
        }
    }

    func testSemverComparison() {
        XCTAssertEqual(SelfUpdate.compareSemver("1.2.0", "1.2.1"), .orderedAscending)
        XCTAssertEqual(SelfUpdate.compareSemver("v1.2.1", "1.2.1"), .orderedSame)
        XCTAssertEqual(SelfUpdate.compareSemver("1.3.0", "1.2.9"), .orderedDescending)
        XCTAssertEqual(SelfUpdate.compareSemver("1.2", "1.2.0"), .orderedSame)
    }

    func testReleaseTagAndStagedBinaryVersionAreStrictlyBound() throws {
        XCTAssertEqual(try SelfUpdate.validateReleaseTag("v1.2.1"), "1.2.1")
        XCTAssertThrowsError(try SelfUpdate.validateReleaseTag(" v1.2.1 "))
        XCTAssertThrowsError(try SelfUpdate.validateReleaseTag("release-1.2.1"))
        XCTAssertNoThrow(try SelfUpdate.requireStagedBinaryVersion("1.2.1\n", targetVersion: "1.2.1"))
    }

    func testCopiedOlderSignedPayloadCannotMasqueradeAsNewRelease() {
        XCTAssertThrowsError(
            try SelfUpdate.requireStagedBinaryVersion("1.2.0\n", targetVersion: "1.2.1")
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.stagedVersionMismatch(expected: "1.2.1", actual: "1.2.0").description
            )
        }
    }

    func testValidatedUpdateDrainsBeforeReplacingAndRestartingLaunchd() async throws {
        let recorder = UpdateActionRecorder()
        let binary = URL(fileURLWithPath: "/tmp/macprovider-cli-test")
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            drainBeforeReplace: {
                recorder.append("drain_status:starting")
                recorder.append("drain_status:in_progress")
                recorder.append("drain_status:complete")
            },
            replaceBinary: { _ in
                recorder.append("replace")
            },
            restartLaunchd: {
                recorder.append("launchctl_bootstrap")
            },
            postRestartReadiness: { true }
        )

        try await update.applyValidatedUpdateForTest(newBinary: binary)

        XCTAssertEqual(recorder.snapshot(), [
            "drain_status:starting",
            "drain_status:in_progress",
            "drain_status:complete",
            "replace",
            "launchctl_bootstrap",
        ])
    }

    func testRestartFailureReturnsFailureAndRollsBackReplacement() async throws {
        let recorder = UpdateActionRecorder()
        let binary = URL(fileURLWithPath: "/tmp/macprovider-cli-test")
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            drainBeforeReplace: {
                recorder.append("drain")
            },
            replaceBinary: { _ in
                recorder.append("replace")
            },
            rollbackReplacement: {
                recorder.append("rollback")
            },
            restartLaunchd: {
                recorder.append("restart")
                throw UpdateError.processFailed("/bin/launchctl", 5)
            }
        )

        do {
            try await update.applyValidatedUpdateForTest(newBinary: binary)
            XCTFail("restart failure unexpectedly returned success")
        } catch let error as UpdateError {
            XCTAssertTrue(error.description.contains("rollback_restored"))
        }

        XCTAssertEqual(recorder.snapshot(), ["drain", "replace", "restart", "rollback"])
    }

    func testReadinessFailureRollsBackReplacement() async throws {
        let recorder = UpdateActionRecorder()
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            replaceBinary: { _ in recorder.append("replace") },
            rollbackReplacement: { recorder.append("rollback") },
            restartLaunchd: { recorder.append("restart") },
            postRestartReadiness: { false }
        )

        do {
            try await update.applyValidatedUpdateForTest(newBinary: URL(fileURLWithPath: "/tmp/macprovider-cli-test"))
            XCTFail("readiness failure unexpectedly returned success")
        } catch let error as UpdateError {
            XCTAssertTrue(error.description.contains("rollback_restored"))
        }

        XCTAssertEqual(recorder.snapshot(), ["replace", "restart", "rollback", "restart"])
    }

    func testPayloadTransactionRestoresBinaryAndAdjacentResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-payload-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("current", isDirectory: true)
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentBinary = current.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: currentBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: currentBinary.path)
        try Data("old-metal".utf8).write(to: current.appendingPathComponent("mlx.metallib"))
        let oldBundle = current.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: false)
        try Data("old-resource".utf8).write(to: oldBundle.appendingPathComponent("resource"))
        let oldCatalog = current.appendingPathComponent("catalog-release", isDirectory: true)
        try Self.writeCatalogFixture(to: oldCatalog, marker: "old")

        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try Data("new-metal".utf8).write(to: payload.appendingPathComponent("mlx.metallib"))
        let newBundle = payload.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: false)
        try Data("new-resource".utf8).write(to: newBundle.appendingPathComponent("resource"))
        let newCatalog = payload.appendingPathComponent("catalog-release", isDirectory: true)
        try Self.writeCatalogFixture(to: newCatalog, marker: "new")

        let transaction = try ProviderReleasePayloadTransaction(
            currentBinary: currentBinary,
            markerStore: AutoUpdateMarkerStore(homeDirectory: root)
        )
        try transaction.activate(from: payload, newBinary: newBinary)
        XCTAssertEqual(try String(contentsOf: currentBinary), "new-binary")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("mlx.metallib")), "new-metal")
        XCTAssertEqual(try String(contentsOf: oldCatalog.appendingPathComponent("release.json")), "new-release.json")

        try transaction.restore()
        transaction.cleanup()

        XCTAssertEqual(try String(contentsOf: currentBinary), "old-binary")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("mlx.metallib")), "old-metal")
        XCTAssertEqual(try String(contentsOf: oldBundle.appendingPathComponent("resource")), "old-resource")
        XCTAssertEqual(try String(contentsOf: oldCatalog.appendingPathComponent("release.json")), "old-release.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.backupDirectory.path))
    }

    func testPayloadValidationRejectsIncompleteReleaseBeforeActivation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-incomplete-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("macprovider-cli")
        try Data("new-binary".utf8).write(to: binary)

        XCTAssertThrowsError(
            try ProviderReleasePayloadTransaction.validateReleasePayload(at: root, newBinary: binary)
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.missingReleaseResource("mlx.metallib").description
            )
        }
    }

    func testExtractedTreeRejectsNestedSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-symlink-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertThrowsError(try SelfUpdate.validateExtractedTreeForTest(root)) { error in
            XCTAssertTrue(String(describing: error).contains("unsafe entry"))
        }
    }

    private static func writeCatalogFixture(to directory: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in [
            "release.json",
            "trusted-keys.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
        ] {
            try Data("\(marker)-\(name)".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    func testLaunchdRestartUsesKickstartForLoadedService() {
        XCTAssertEqual(
            SelfUpdate.launchdRestartArguments(
                serviceLoaded: true,
                uid: 501,
                plistPath: "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"
            ),
            ["kickstart", "-k", "gui/501/live.streamvc.macprovider"]
        )
    }

    func testLaunchdRestartBootstrapsOnlyWhenServiceIsNotLoaded() {
        let plist = "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"

        XCTAssertEqual(
            SelfUpdate.launchdRestartArguments(serviceLoaded: false, uid: 501, plistPath: plist),
            ["bootstrap", "gui/501", plist]
        )
    }

    func testRestartFailureRecoveryCommandUsesKickstart() {
        XCTAssertEqual(
            SelfUpdate.launchdRestartRecoveryCommand(uid: 501),
            "launchctl kickstart -k gui/501/live.streamvc.macprovider"
        )
    }

    func testRestartFailureRecoveryCommandUsesBootstrapForUnloadedService() {
        let plist = "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"

        XCTAssertEqual(
            SelfUpdate.launchdRestartRecoveryCommand(serviceLoaded: false, uid: 501, plistPath: plist),
            "launchctl bootstrap gui/501 \(plist)"
        )
    }

    func testUpdateRequiresSignedChecksumAsset() async throws {
        let releaseURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        MockURLProtocol.responses = [
            releaseURL: (
                200,
                """
                {
                  "tag_name": "v1.2.1",
                  "assets": [
                    {
                      "name": "macprovider-cli-v1.2.1-darwin-arm64.tar.gz",
                      "browser_download_url": "https://github.com/Augustas11/macprovider/releases/download/v1.2.1/macprovider-cli-v1.2.1-darwin-arm64.tar.gz"
                    },
                    {
                      "name": "checksums.txt",
                      "browser_download_url": "https://github.com/Augustas11/macprovider/releases/download/v1.2.1/checksums.txt"
                    }
                  ]
                }
                """.data(using: .utf8)!
            ),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: releaseURL.absoluteString, session: session)

        do {
            try await update.run(checkOnly: false)
            XCTFail("update unexpectedly accepted a release without checksums.txt.sig")
        } catch let error as UpdateError {
            XCTAssertEqual(error.description, UpdateError.missingAsset.description)
        }
    }
}

private final class UpdateActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String] = []

    func append(_ action: String) {
        lock.lock()
        defer { lock.unlock() }
        actions.append(action)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responses: [URL: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func withEnvironmentVariable(_ name: String, value: String, body: () -> Void) {
    let previous = getenv(name).map { String(cString: $0) }
    setenv(name, value, 1)
    defer {
        if let previous {
            setenv(name, previous, 1)
        } else {
            unsetenv(name)
        }
    }
    body()
}
