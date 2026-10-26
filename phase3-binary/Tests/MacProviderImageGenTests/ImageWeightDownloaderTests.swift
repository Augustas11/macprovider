import Foundation
import XCTest
@testable import MacProviderImageGen

final class ImageWeightDownloaderTests: XCTestCase {
    private let source = URL(string: "https://example.invalid/pinned-weight")!

    private func fixture(size: Int64 = 10) throws -> (ImageFileDownload, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ImageFileDownload(source: source,
                                  destination: directory.appendingPathComponent("weight.partial"),
                                  resume: directory.appendingPathComponent("weight.resume"),
                                  expectedSize: size, progress: { _ in }), directory)
    }

    func testOversizedUnknownLengthStreamCancelsBeforeCompletionAndDiscardsResume() throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = WeightDownloadTask(response: response())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        download.urlSession(session, downloadTask: task, didWriteData: 8,
                            totalBytesWritten: 8, totalBytesExpectedToWrite: -1)
        XCTAssertFalse(task.wasCancelled)
        download.urlSession(session, downloadTask: task, didWriteData: 3,
                            totalBytesWritten: 11, totalBytesExpectedToWrite: -1)
        XCTAssertTrue(task.wasCancelled, "Streaming must stop without waiting for didFinishDownloading")
        try Data([1]).write(to: download.resume)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSURLSessionDownloadTaskResumeData: Data([2])])
        download.urlSession(session, task: task, didCompleteWithError: error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.resume.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.destination.path))
    }

    func testResumedPrefixCountsTowardStreamingLimit() throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = WeightDownloadTask(response: response(status: 206, headers: [
            "Content-Range": "bytes 8-9/10", "Content-Length": "2"
        ]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        download.urlSession(session, downloadTask: task, didResumeAtOffset: 8, expectedTotalBytes: 10)
        download.urlSession(session, downloadTask: task, didWriteData: 2,
                            totalBytesWritten: 2, totalBytesExpectedToWrite: 2)
        XCTAssertFalse(task.wasCancelled)
        download.urlSession(session, downloadTask: task, didWriteData: 1,
                            totalBytesWritten: 3, totalBytesExpectedToWrite: 2)
        XCTAssertTrue(task.wasCancelled)
    }

    func testDeclaredLengthAndContentRangeMustMatchManifest() throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try download.validate(response: response(headers: ["Content-Length": "10"])))
        XCTAssertThrowsError(try download.validate(response: response(headers: ["Content-Length": "11"])))
        XCTAssertThrowsError(try download.validate(response: response(headers: ["Content-Length": "9"])))
        for range in ["bytes 0-10/11", "bytes 0-8/10", "bytes 1-9/10", "bytes */10", "bytes 0-9/*"] {
            XCTAssertThrowsError(try download.validate(response: response(status: 206, headers: ["Content-Range": range])))
        }
        XCTAssertThrowsError(try download.validate(response: response(status: 206)))
        XCTAssertNoThrow(try download.validate(response: response(status: 206, headers: [
            "Content-Range": "bytes 0-9/10", "Content-Length": "10"
        ])))
    }

    func testInvalidResumeIsConsumedAndRetriedFromPinnedSourceOnce() async throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = Data("stale checkpoint".utf8)
        try invalid.write(to: download.resume)
        var attempts: [Data?] = []
        try await download.run { data in
            attempts.append(data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: download.resume.path))
            if data != nil { throw URLError(.unknown) }
            XCTAssertEqual(download.source, self.source)
            try Data(repeating: 1, count: 10).write(to: download.destination)
        }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], invalid)
        XCTAssertNil(attempts[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.resume.path))
    }

    func testScratchFailureDoesNotLoopAndNextRequestHasNoPoisonedCheckpoint() async throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: download.resume)
        var count = 0
        do {
            try await download.run { _ in count += 1; throw URLError(.unknown) }
            XCTFail("Both attempts should fail")
        } catch { }
        XCTAssertEqual(count, 2)
        let fresh = ImageFileDownload(source: source, destination: download.destination,
                                      resume: download.resume, expectedSize: 10, progress: { _ in })
        try await fresh.run { data in XCTAssertNil(data) }
    }

    func testNetworkFailureKeepsReplacementCheckpointInsteadOfRetryingItImmediately() async throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: download.resume)
        let replacement = Data([2, 3])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                            userInfo: [NSURLSessionDownloadTaskResumeData: replacement])
        var attempts = 0
        do {
            try await download.run { _ in
                attempts += 1
                let session = URLSession(configuration: .ephemeral)
                download.urlSession(session, task: WeightDownloadTask(response: self.response()),
                                    didCompleteWithError: error)
                throw error
            }
            XCTFail("Network failure should propagate")
        } catch { }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try Data(contentsOf: download.resume), replacement)
    }

    func testStreamingViolationNeverRetriesOrKeepsReplacementResume() async throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: download.resume)
        var attempts = 0
        do {
            try await download.run { _ in
                attempts += 1
                let session = URLSession(configuration: .ephemeral)
                let task = WeightDownloadTask(response: self.response())
                download.urlSession(session, downloadTask: task, didWriteData: 11,
                                    totalBytesWritten: 11, totalBytesExpectedToWrite: -1)
                let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                    userInfo: [NSURLSessionDownloadTaskResumeData: Data([2])])
                download.urlSession(session, task: task, didCompleteWithError: error)
                throw error
            }
            XCTFail("Manifest violation should propagate")
        } catch { }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.resume.path))
    }

    func testCancellationDoesNotRetryStaleResume() async throws {
        let (download, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: download.resume)
        var attempts = 0
        do {
            try await download.run { _ in
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Cancellation should propagate")
        } catch is CancellationError { }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.resume.path))
    }

    private func response(status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: source, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private final class WeightDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let fixtureResponse: URLResponse
    private(set) var wasCancelled = false
    init(response: URLResponse) { fixtureResponse = response; super.init() }
    override var response: URLResponse? { fixtureResponse }
    override func cancel() { wasCancelled = true }
}
