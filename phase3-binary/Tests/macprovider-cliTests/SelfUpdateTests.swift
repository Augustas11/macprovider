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
            }
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
