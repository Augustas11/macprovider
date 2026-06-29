import Foundation
import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

final class AutoUpdateTests: XCTestCase {
    func testRecommendedVersionValidationNormalizesAndRejectsOversize() throws {
        XCTAssertEqual(try AutoUpdateRecommendation.validate("v1.7.0").normalized, "1.7.0")
        XCTAssertEqual(try AutoUpdateRecommendation.validate("V1.7.0").normalized, "1.7.0")
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate("1.7")) { error in
            XCTAssertEqual(error as? AutoUpdateValidationError, .invalid)
        }
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate("1.123456789.0")) { error in
            XCTAssertEqual(error as? AutoUpdateValidationError, .componentTooLong)
        }
        let oversized = "v" + String(repeating: "1", count: 40) + ".2.3"
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate(oversized)) { error in
            guard case let AutoUpdateValidationError.versionTooLong(sha)? = error as? AutoUpdateValidationError else {
                return XCTFail("expected versionTooLong, got \(error)")
            }
            XCTAssertEqual(sha.count, 64)
            XCTAssertEqual(sha, AutoUpdateEvent.sha256Hex(oversized))
        }
    }

    func testEventPayloadDropsOptionalFieldsBeforeFallback() {
        let event = AutoUpdateEvent(
            updateID: UUID().uuidString.lowercased(),
            currentVersion: "1.6.1",
            targetVersion: "1.7.0",
            phase: .download,
            outcome: .failure,
            reason: String(repeating: "reason", count: 1200),
            attempt: 2,
            failureClass: .targetReleaseNotFound,
            extraMetadata: ["blob": String(repeating: "x", count: 5000)],
            attemptHistory: [String(repeating: "y", count: 5000)],
            releaseURL: "https://github.com/Augustas11/macprovider/releases/download/v1.7.0/a.tar.gz?token=secret"
        )
        let object = event.wireObject()
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        XCTAssertLessThanOrEqual(data.count, AutoUpdateEvent.maxWireBytes)
        XCTAssertNil(object["extra_metadata"])
        XCTAssertNil(object["attempt_history"])
        XCTAssertNil(object["release_url"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("token=secret"))
    }

    func testAutoupdateOptOutReadsLegacyAndSpecSources() throws {
        let yaml = """
        coordinator_url: wss://example.invalid/ws/provider
        autoupdate:
          enabled: false
        auto_update_enabled: true
        """
        let config = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml }
        )
        XCTAssertFalse(AutoUpdateConfig.enabled(config))

        let env = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_AUTOUPDATE": "off"],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertFalse(AutoUpdateConfig.enabled(env))
    }

    func testCooldownBackoffIsKeyedByTargetAndFailureClass() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let first = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(first.attempt, 1)
        XCTAssertGreaterThan(first.until.timeIntervalSinceNow, 250)
        XCTAssertNil(store.cooldown(target: "1.7.0", failureClass: .signatureInvalid))
        XCTAssertEqual(store.activeCooldown(target: "1.7.0")?.failureClass, .targetReleaseNotFound)
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let second = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(second.attempt, 2)
        XCTAssertGreaterThan(second.until.timeIntervalSince(first.until), 250)
    }

    func testSuccessCleanupWritesSentinelThenClearsPendingBackupAndLock() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        _ = try store.acquireLock()
        let binaryDir = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        try Data("new".utf8).write(to: binary)
        try Data("old".utf8).write(to: backup)
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0",
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: "2026-06-29T15:06:00Z"
        )
        try store.writePending(marker)

        try store.completeSuccessfulUpdate(marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.successSentinelPath(binaryURL: binary, updateID: marker.updateID).path))
    }

    func testSelfUpdateResolvesReleaseByVTagThenBareTag() async throws {
        let latest = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        let vTag = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/v1.7.0")!
        let bare = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/1.7.0")!
        AutoUpdateMockURLProtocol.responses = [
            vTag: (404, Data("{}".utf8)),
            bare: (200, Data(#"{"tag_name":"1.7.0","assets":[]}"#.utf8)),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoUpdateMockURLProtocol.self]
        let update = SelfUpdate(currentVersion: "1.6.1", releasesAPIURL: latest.absoluteString, session: URLSession(configuration: configuration))

        let release = try await update.resolveReleaseByTags(normalizedTarget: "1.7.0")

        XCTAssertEqual(release.tagName, "1.7.0")
    }
}

private final class TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class AutoUpdateMockURLProtocol: URLProtocol {
    static var responses: [URL: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
