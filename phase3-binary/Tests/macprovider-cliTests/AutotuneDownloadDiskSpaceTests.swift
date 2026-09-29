import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Autotune downloads every eligible catalog model. Without a free-space
/// check a sweep could fill the provider Mac's disk (observed: 1.2 GB left
/// during a first-run sweep on a 460 GB volume).
final class AutotuneDownloadDiskSpaceTests: XCTestCase {
    private final class DownloadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func downloader(listing: String, status: Int = 200, log: DownloadLog) -> HuggingFaceSnapshotDownloader {
        let tempRoot = root!
        return HuggingFaceSnapshotDownloader(
            fetch: { request in
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(listing.utf8), response)
            },
            download: { request in
                let file = tempRoot.appendingPathComponent("dl-\(UUID().uuidString).tmp")
                try Data("weights".utf8).write(to: file)
                log.record(file)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
                return (file, response)
            }
        )
    }

    private var snapshot: URL {
        root.appendingPathComponent("hub/models--ns--model/snapshots/rev", isDirectory: true)
    }

    func testRefusesDownloadThatWouldLeaveLessThanReserveFree() async throws {
        let log = DownloadLog()
        var hf = downloader(listing: #"{"siblings":[{"rfilename":"model.safetensors","size":4600000000}]}"#, log: log)
        hf.availableDiskBytes = { _ in 6_000_000_000 } // < 4.6 GB + 5 GiB reserve

        do {
            try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", to: snapshot)
            XCTFail("expected insufficientDiskSpace")
        } catch let AutotuneRecommendError.insufficientDiskSpace(modelID, required, available) {
            XCTAssertEqual(modelID, "ns/model")
            XCTAssertEqual(required, 4_600_000_000 + HuggingFaceSnapshotDownloader.downloadFreeSpaceReserveBytes)
            XCTAssertEqual(available, 6_000_000_000)
        }
        XCTAssertTrue(log.all.isEmpty, "no bytes may be fetched once the space check fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path),
                       "no staging directory may be created")
        XCTAssertTrue(
            AutotuneRecommendError.insufficientDiskSpace(modelID: "ns/model", requiredBytes: 10_000_000_000, availableBytes: 1_200_000_000)
                .description.contains("need 10.0 GB, 1.2 GB available")
        )
    }

    func testDownloadsWhenEnoughSpace() async throws {
        let log = DownloadLog()
        var hf = downloader(listing: #"{"siblings":[{"rfilename":"model.safetensors","size":1000}]}"#, log: log)
        hf.availableDiskBytes = { _ in 100_000_000_000 }

        try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", to: snapshot)

        XCTAssertEqual(log.all.count, 1)
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("model.safetensors")), "weights")
    }

    func testListingWithoutSizesKeepsPreviousBehaviour() async throws {
        let log = DownloadLog()
        var hf = downloader(listing: #"{"siblings":[{"rfilename":"model.safetensors"}]}"#, log: log)
        hf.availableDiskBytes = { _ in 0 }

        try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", to: snapshot)

        XCTAssertEqual(log.all.count, 1)
    }

    func testNon2xxDownloadRemovesTemporaryFile() async throws {
        let log = DownloadLog()
        var hf = downloader(listing: #"{"siblings":[{"rfilename":"model.safetensors","size":1000}]}"#, status: 503, log: log)
        hf.availableDiskBytes = { _ in 100_000_000_000 }

        do {
            try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", to: snapshot)
            XCTFail("expected download failure")
        } catch AutotuneRecommendError.invalidArtifact {}
        let temp = try XCTUnwrap(log.all.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "failed download left \(temp.lastPathComponent) behind")
    }
}

/// SPEC-044 `models prepare` enforces its own headroom (2 x size + 1 GiB);
/// the autotune reserve must not apply there, and a disk failure must keep
/// its insufficient_disk_space classification.
final class AutotuneDiskSpaceClassificationTests: XCTestCase {
    func testDiskSpaceErrorSkipsOnlyTheCandidate() {
        let disk = AutotuneRecommendError.insufficientDiskSpace(modelID: "ns/m", requiredBytes: 2, availableBytes: 1)
        XCTAssertNotNil(disk.perCandidateSkipReason)
        XCTAssertEqual(AutotuneRecommendError.invalidArtifact("bad").perCandidateSkipReason, "bad")
        XCTAssertNil(AutotuneRecommendError.noHMACSecret.perCandidateSkipReason, "run-level failures must still end the sweep")
    }

    func testReserveCanBeDisabledForCallersWithTheirOwnBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var hf = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(#"{"siblings":[{"rfilename":"w.bin","size":1000}]}"#.utf8), response)
            },
            download: { request in
                let file = root.appendingPathComponent("dl-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("w".utf8).write(to: file)
                return (file, try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
        )
        hf.availableDiskBytes = { _ in 0 }
        hf.freeSpaceReserveBytes = nil
        try await hf.downloadSnapshot(modelID: "ns/m", revision: "rev", to: root.appendingPathComponent("hub/snap"))
    }
}

/// With fallback sources configured, a disk shortfall must not be retried
/// against every mirror (they all write to the same volume) or be flattened
/// into the generic "no artifact source delivered" string.
final class AutotuneDiskSpaceSourceWalkTests: XCTestCase {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func ok(_ request: URLRequest) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    func testDiskShortfallStopsTheSourceWalkWithTypedError() async throws {
        let seen = Requests()
        var hf = HuggingFaceSnapshotDownloader(
            fetch: { request in
                seen.record(try XCTUnwrap(request.url))
                return (Data(#"{"siblings":[{"rfilename":"model.safetensors","size":17000000000}]}"#.utf8), try self.ok(request))
            },
            download: { _ in throw AutotuneRecommendError.invalidStaticJSON("download must not start") }
        )
        hf.fallbackSources = [.huggingFaceCompatible(URL(string: "https://mirror.example")!)]
        hf.availableDiskBytes = { _ in 2_000_000_000 }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("walk-\(UUID().uuidString)/snap")

        do {
            try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", to: target)
            XCTFail("expected insufficientDiskSpace")
        } catch AutotuneRecommendError.insufficientDiskSpace(let modelID, _, let available) {
            XCTAssertEqual(modelID, "ns/model")
            XCTAssertEqual(available, 2_000_000_000)
        }
        XCTAssertEqual(seen.all.count, 1, "the mirror must not be tried: \(seen.all)")
    }

    func testContentAddressedMirrorChecksManifestSizesBeforeFetchingFiles() async throws {
        let manifest = Data("model.safetensors\n17000000000\n\(String(repeating: "a", count: 64))\n".utf8)
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let seen = Requests()
        var hf = HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                seen.record(url)
                if url.host == "huggingface.co" { throw URLError(.cannotConnectToHost) }
                return (manifest, try self.ok(request))
            },
            download: { _ in throw AutotuneRecommendError.invalidStaticJSON("file download must not start") }
        )
        hf.fallbackSources = [.contentAddressed(URL(string: "https://cas.example/models")!)]
        hf.availableDiskBytes = { _ in 2_000_000_000 }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("cas-\(UUID().uuidString)/snap")

        do {
            try await hf.downloadSnapshot(modelID: "ns/model", revision: "rev", expectedSHA256: digest, to: target)
            XCTFail("expected insufficientDiskSpace")
        } catch AutotuneRecommendError.insufficientDiskSpace(let modelID, let required, _) {
            XCTAssertEqual(modelID, "ns/model")
            XCTAssertEqual(required, 17_000_000_000 + HuggingFaceSnapshotDownloader.downloadFreeSpaceReserveBytes)
        }
        XCTAssertTrue(seen.all.contains { $0.host == "cas.example" }, "manifest should have been fetched: \(seen.all)")
    }
}
