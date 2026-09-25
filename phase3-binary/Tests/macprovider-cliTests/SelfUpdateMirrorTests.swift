import Foundation
import XCTest
@testable import macprovider_cli

/// #1737: a host that cannot reach GitHub resolves a release tag from the
/// download.malibu.tech mirror; the signed release checks stay the authority.
final class SelfUpdateMirrorTests: XCTestCase {
    private let latest = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
    private let vTag = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/v1.9.0")!
    private let mirror = URL(string: "https://download.malibu.tech/releases/v1.9.0/release.json")!

    override func tearDown() {
        MirrorMockURLProtocol.reset()
        super.tearDown()
    }

    private func update(mirrorEnabled: Bool = true) -> SelfUpdate {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirrorMockURLProtocol.self]
        return SelfUpdate(
            currentVersion: "1.8.0",
            releasesAPIURL: latest.absoluteString,
            releaseMirrorEnabled: mirrorEnabled,
            session: URLSession(configuration: configuration)
        )
    }

    private func mirrorRelease(assetURL: String = "https://download.malibu.tech/releases/v1.9.0/checksums.txt") -> Data {
        Data(#"{"tag_name":"v1.9.0","draft":false,"prerelease":false,"assets":[{"name":"checksums.txt","browser_download_url":"\#(assetURL)"}]}"#.utf8)
    }

    func testTagResolvesFromMirrorWhenGitHubIsUnreachable() async throws {
        MirrorMockURLProtocol.failures = [vTag: URLError(.cannotConnectToHost)]
        MirrorMockURLProtocol.responses = [mirror: (200, mirrorRelease())]

        let release = try await update().resolveReleaseByTags(normalizedTarget: "1.9.0")

        XCTAssertEqual(release.tagName, "v1.9.0")
        XCTAssertEqual(release.assets.map(\.name), ["checksums.txt"])
        XCTAssertEqual(MirrorMockURLProtocol.requested, [vTag, mirror])
    }

    func testGitHubNotFoundIsNotOverriddenByTheMirror() async throws {
        let bare = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/1.9.0")!
        MirrorMockURLProtocol.responses = [
            vTag: (404, Data("{}".utf8)),
            bare: (404, Data("{}".utf8)),
            mirror: (200, mirrorRelease()),
        ]

        do {
            _ = try await update().resolveReleaseByTags(normalizedTarget: "1.9.0")
            XCTFail("a GitHub 404 must stay authoritative")
        } catch UpdateError.releaseNotFound {
        }
        XCTAssertFalse(MirrorMockURLProtocol.requested.contains(mirror))
    }

    func testMirrorAssetOutsideItsTagDirectoryIsRejected() async throws {
        MirrorMockURLProtocol.failures = [vTag: URLError(.timedOut)]
        MirrorMockURLProtocol.responses = [
            mirror: (200, mirrorRelease(assetURL: "https://download.malibu.tech/releases/v1.8.0/checksums.txt")),
        ]

        do {
            _ = try await update().resolveReleaseByTags(normalizedTarget: "1.9.0")
            XCTFail("an asset outside the tag directory was accepted")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "the GitHub error is rethrown: \(error)")
        }
    }

    func testMirrorReleaseForAnotherTagIsRejected() async throws {
        MirrorMockURLProtocol.failures = [vTag: URLError(.timedOut)]
        MirrorMockURLProtocol.responses = [
            mirror: (200, Data(#"{"tag_name":"v1.8.9","assets":[]}"#.utf8)),
        ]

        do {
            _ = try await update().resolveReleaseByTags(normalizedTarget: "1.9.0")
            XCTFail("a mirror release for another tag was accepted")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testMirrorDisabledKeepsGitHubOnlyBehavior() async throws {
        MirrorMockURLProtocol.failures = [vTag: URLError(.cannotConnectToHost)]
        MirrorMockURLProtocol.responses = [mirror: (200, mirrorRelease())]

        do {
            _ = try await update(mirrorEnabled: false).resolveReleaseByTags(normalizedTarget: "1.9.0")
            XCTFail("mirror used while disabled")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertFalse(MirrorMockURLProtocol.requested.contains(mirror))
    }

    func testReleaseMirrorURLRejectsNonReleaseTags() {
        XCTAssertEqual(
            try SelfUpdate.releaseMirrorURL(tag: "v1.9.0", file: "checksums.txt").absoluteString,
            "https://download.malibu.tech/releases/v1.9.0/checksums.txt"
        )
        XCTAssertThrowsError(try SelfUpdate.releaseMirrorURL(tag: "../v1.9.0", file: nil))
        XCTAssertThrowsError(try SelfUpdate.releaseMirrorURL(tag: "v1.9.0", file: "../x"))
    }
}

private final class MirrorMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var failures: [URL: URLError] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        responses = [:]
        failures = [:]
        requested = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requested.append(url)
        let failure = Self.failures[url]
        let response = Self.responses[url]
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response else {
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
