import Foundation
import XCTest
@testable import macprovider_cli

/// #2036: every release file streams under a hard byte cap. An oversized body
/// is cancelled while it streams and leaves no file behind.
final class SelfUpdateDownloadCapTests: XCTestCase {
    private let tag = "v1.9.0"
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfupdate-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StreamingMockURLProtocol.reset()
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func update(coordinatorURL: String? = nil) -> SelfUpdate {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingMockURLProtocol.self]
        return SelfUpdate(
            currentVersion: "1.8.0",
            releasesAPIURL: nil,
            coordinatorURL: coordinatorURL,
            session: URLSession(configuration: configuration)
        )
    }

    /// The hidden file the downloader streams into before the final move.
    private func partial(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
    }

    private func assertNoFiles(_ destination: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial(destination).path), file: file, line: line)
    }

    private func assetURL(_ name: String) -> URL {
        URL(string: "https://github.com/Augustas11/macprovider/releases/download/\(tag)/\(name)")!
    }

    func testCapsBoundTheLargestCurrentAssetsWithMargin() {
        // The largest release asset (the Malibu DMG) is under 50 MB today.
        XCTAssertEqual(SelfUpdate.maxReleaseAssetBytes, 256 * 1_024 * 1_024)
        XCTAssertGreaterThanOrEqual(SelfUpdate.maxReleaseAssetBytes, 4 * 50_000_000)
        XCTAssertEqual(SelfUpdate.maxReleaseMirrorMetadataBytes, 256 * 1_024)
    }

    func testOversizedStreamWithoutContentLengthIsCancelledMidStream() async throws {
        let url = assetURL("macprovider-cli-\(tag)-darwin-arm64.tar.gz")
        let total = 64 * 1_024 * 1_024
        StreamingMockURLProtocol.streams = [url: .init(totalBytes: total, declareLength: false)]
        let destination = scratch.appendingPathComponent("tarball")

        do {
            try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 256 * 1_024)
            XCTFail("an oversized stream must be refused")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.downloadTooLarge("macprovider-cli-\(tag)-darwin-arm64.tar.gz", limit: 256 * 1_024).description
            )
        }
        assertNoFiles(destination)
        XCTAssertLessThan(StreamingMockURLProtocol.deliveredBytes(url), total, "the transfer was not cancelled while streaming")
    }

    func testDeclaredOversizeIsCancelledBeforeTheBody() async throws {
        let url = assetURL("Malibu-\(tag).dmg")
        let total = 64 * 1_024 * 1_024
        StreamingMockURLProtocol.streams = [url: .init(totalBytes: total, declareLength: true)]
        let destination = scratch.appendingPathComponent("dmg")

        do {
            try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)
            XCTFail("a declared oversize must be refused")
        } catch let error as UpdateError {
            guard case .downloadTooLarge(let name, let limit) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(name, "Malibu-\(tag).dmg")
            XCTAssertEqual(limit, 64 * 1_024)
        }
        assertNoFiles(destination)
        XCTAssertLessThan(StreamingMockURLProtocol.deliveredBytes(url), total)
    }

    func testBodyExactlyAtTheCapIsAccepted() async throws {
        let url = assetURL("checksums.txt")
        StreamingMockURLProtocol.streams = [url: .init(totalBytes: 64 * 1_024, declareLength: false)]
        let destination = scratch.appendingPathComponent("checksums.txt")

        try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)

        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(size, 64 * 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial(destination).path))
    }

    func testRedirectThatLeavesHTTPSIsRefused() async throws {
        let url = assetURL("Malibu-\(tag).dmg")
        let plaintext = URL(string: "http://download.example/Malibu-\(tag).dmg")!
        StreamingMockURLProtocol.redirects = [url: plaintext]
        StreamingMockURLProtocol.streams = [plaintext: .init(totalBytes: 1_024, declareLength: true)]
        let destination = scratch.appendingPathComponent("redirected.dmg")

        do {
            try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)
            XCTFail("a redirect off HTTPS must be refused")
        } catch {
            // The redirect is refused; the transport reports it as a failed load.
        }
        assertNoFiles(destination)
        XCTAssertFalse(StreamingMockURLProtocol.requested.contains(plaintext), "the plaintext redirect target was fetched")
    }

    func testRedirectToAnUnlistedHostIsRefused() async throws {
        let url = assetURL("Malibu-\(tag).dmg")
        let elsewhere = URL(string: "https://internal.example/Malibu-\(tag).dmg")!
        StreamingMockURLProtocol.redirects = [url: elsewhere]
        StreamingMockURLProtocol.streams = [elsewhere: .init(totalBytes: 1_024, declareLength: true)]
        let destination = scratch.appendingPathComponent("elsewhere.dmg")

        do {
            try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)
            XCTFail("a redirect to an unlisted host must be refused")
        } catch {}
        assertNoFiles(destination)
        XCTAssertFalse(StreamingMockURLProtocol.requested.contains(elsewhere), "the unlisted redirect target was fetched")
    }

    func testRedirectToTheGitHubAssetHostIsFollowed() async throws {
        let url = assetURL("checksums.txt")
        let cdn = URL(string: "https://release-assets.githubusercontent.com/checksums.txt")!
        StreamingMockURLProtocol.redirects = [url: cdn]
        StreamingMockURLProtocol.streams = [cdn: .init(totalBytes: 2_048, declareLength: true)]
        let destination = scratch.appendingPathComponent("cdn-checksums.txt")

        try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)

        XCTAssertEqual(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, 2_048)
    }

    func testRedirectPolicy() {
        let github = URL(string: "https://github.com/Augustas11/macprovider/releases/download/v1/x")!
        func allows(_ target: String?, mirror: Bool = true) -> Bool {
            ReleaseRedirectPolicy.allows(from: github, to: target.flatMap(URL.init(string:)), mirrorAllowed: mirror)
        }
        XCTAssertTrue(allows("https://objects.githubusercontent.com/x"))
        XCTAssertTrue(allows("https://download.malibu.tech/releases/v1/x"))
        XCTAssertFalse(allows("https://download.malibu.tech/releases/v1/x", mirror: false), "a fork never reaches the mirror")
        XCTAssertFalse(allows("http://objects.githubusercontent.com/x"))
        XCTAssertFalse(allows("https://objects.githubusercontent.com:8443/x"))
        XCTAssertFalse(allows("https://169.254.169.254/latest"))
        XCTAssertFalse(allows("https://githubusercontent.com.evil.example/x"))
        XCTAssertFalse(allows(nil))
    }

    func testOversizedCoordinatorAdvertisementIsCancelledMidStream() async throws {
        let healthz = URL(string: "https://coordinator.example/healthz")!
        let total = 64 * 1_024 * 1_024
        StreamingMockURLProtocol.streams = [healthz: .init(totalBytes: total, declareLength: false)]

        do {
            _ = try await update(coordinatorURL: "wss://coordinator.example/ws/provider")
                .coordinatorAdvertisedReleaseVersion()
            XCTFail("an oversized advertisement must be refused")
        } catch let error as UpdateError {
            XCTAssertEqual(error.description, UpdateError.invalidReleaseVersion("coordinator advertised no release").description)
        }
        XCTAssertLessThan(StreamingMockURLProtocol.deliveredBytes(healthz), total)
    }

    func testHTTPErrorLeavesNoFile() async throws {
        let url = assetURL("checksums.txt.sig")
        StreamingMockURLProtocol.streams = [url: .init(totalBytes: 16, declareLength: true, status: 503)]
        let destination = scratch.appendingPathComponent("checksums.txt.sig")

        do {
            try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 1_024)
            XCTFail("an HTTP error must fail the download")
        } catch UpdateError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        assertNoFiles(destination)
    }

    func testPreparedUpdateRefusesAnOversizedChecksumsFile() async throws {
        let names = [
            "macprovider-cli-\(tag)-darwin-arm64.tar.gz",
            "Malibu-\(tag).dmg",
            "compatibility-artifact-index.json",
            "checksums.txt",
            "checksums.txt.sig",
        ]
        let assets = names.map { #"{"name":"\#($0)","browser_download_url":"\#(assetURL($0).absoluteString)"}"# }
        let json = #"{"tag_name":"\#(tag)","draft":false,"prerelease":false,"assets":[\#(assets.joined(separator: ","))]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        let checksums = assetURL("checksums.txt")
        let total = 64 * 1_024 * 1_024
        StreamingMockURLProtocol.streams = [checksums: .init(totalBytes: total, declareLength: false)]

        do {
            _ = try await update().prepareValidatedUpdate(from: release)
            XCTFail("an oversized checksums.txt must be refused")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.downloadTooLarge("checksums.txt", limit: Int64(SelfUpdate.maxReleaseMirrorMetadataBytes)).description
            )
            XCTAssertEqual(AutoUpdater.redactedReason(for: error), "download_too_large")
        }
        XCTAssertLessThan(StreamingMockURLProtocol.deliveredBytes(checksums), total)
        XCTAssertEqual(StreamingMockURLProtocol.requested, [checksums], "nothing after the refused file was fetched")
    }
}

/// Streams a body of zero bytes in 16 KiB chunks (about 16 MB/s) from a
/// background queue and stops as soon as the task is cancelled, so the bytes
/// delivered show where the downloader gave up.
private final class StreamingMockURLProtocol: URLProtocol {
    struct Stream {
        var totalBytes: Int
        var declareLength: Bool
        var status: Int = 200
    }

    nonisolated(unsafe) static var streams: [URL: Stream] = [:]
    nonisolated(unsafe) static var redirects: [URL: URL] = [:]
    nonisolated(unsafe) private static var delivered: [URL: Int] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    private static let lock = NSLock()
    private static let chunkSize = 16 * 1_024

    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        streams = [:]
        redirects = [:]
        delivered = [:]
        requested = []
        lock.unlock()
    }

    static func deliveredBytes(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered[url] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requested.append(url)
        let stream = Self.streams[url]
        let redirect = Self.redirects[url]
        Self.lock.unlock()
        if let redirect {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let stream else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var headers: [String: String] = [:]
        if stream.declareLength {
            headers["Content-Length"] = String(stream.totalBytes)
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: stream.status, httpVersion: "HTTP/1.1", headerFields: headers)!,
            cacheStoragePolicy: .notAllowed
        )
        DispatchQueue.global().async { [self] in
            var sent = 0
            while sent < stream.totalBytes {
                if stopped() { return }
                let count = min(Self.chunkSize, stream.totalBytes - sent)
                client?.urlProtocol(self, didLoad: Data(count: count))
                sent += count
                Self.lock.lock()
                Self.delivered[url, default: 0] += count
                Self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !stopped() {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
    }

    private func stopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopped || (task.map { $0.state != .running } ?? false)
    }
}
