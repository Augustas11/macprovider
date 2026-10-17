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

    private func update() -> SelfUpdate {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingMockURLProtocol.self]
        return SelfUpdate(
            currentVersion: "1.8.0",
            releasesAPIURL: nil,
            session: URLSession(configuration: configuration)
        )
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertLessThan(StreamingMockURLProtocol.deliveredBytes(url), total)
    }

    func testBodyExactlyAtTheCapIsAccepted() async throws {
        let url = assetURL("checksums.txt")
        StreamingMockURLProtocol.streams = [url: .init(totalBytes: 64 * 1_024, declareLength: false)]
        let destination = scratch.appendingPathComponent("checksums.txt")

        try await update().downloadReleaseFileForTest(from: url, to: destination, maximumBytes: 64 * 1_024)

        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(size, 64 * 1_024)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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
    nonisolated(unsafe) private static var delivered: [URL: Int] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    private static let lock = NSLock()
    private static let chunkSize = 16 * 1_024

    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        streams = [:]
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
        Self.lock.unlock()
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
