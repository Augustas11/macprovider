import Foundation
import XCTest
@testable import macprovider_cli

/// Stager-level coverage for the Build 1 Lane A stage → verify → adopt path.
///
/// The command-level tests cannot reach a successful adoption because the
/// signed Lane A digest is the real snapshot-manifest hash of the Hugging Face
/// revision; these tests exercise the same stager with an authority whose
/// digest matches a small fixture directory instead.
final class Build1LaneAArtifactStagerTests: XCTestCase {
    private struct Roots {
        var hub: URL
        var durable: URL
    }

    func testStageVerifyAdoptRemovesStagingAndLeavesDurableCopy() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "signed-lane-a-bytes")
        let counter = Build1LaneACounter()
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(
                hubRoot: roots.hub,
                durableRoot: roots.durable,
                downloader: Self.fakeDownloader(payload: payload, counter: counter)
            ),
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        )
        var stages: [(Build1LaneAStagingStage, Int64?, Int64?)] = []

        let result = try await stager.stageAndAdopt(authority: authority) { stage, completed, expected in
            stages.append((stage, completed, expected))
        }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(result.sha256, authority.hash)
        XCTAssertEqual(result.adoptedBytes, Int64(payload.utf8.count))
        XCTAssertFalse(result.reusedDurableArtifact)
        XCTAssertFalse(result.stagingCleanupRequired)
        XCTAssertEqual(stages.map(\.0), [.staging, .verified, .adopted])
        XCTAssertEqual(stages[0].1, 0)
        XCTAssertEqual(stages[0].2, Int64(authority.sizeBytes))
        XCTAssertEqual(stages[1].1, Int64(payload.utf8.count))
        XCTAssertEqual(stages[2].1, Int64(payload.utf8.count))

        let store = DurableModelArtifactStore(root: roots.durable)
        let durable = try store.artifactURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), authority.hash)
        XCTAssertEqual(try String(contentsOf: durable.appendingPathComponent("weights.bin")), payload)
        var rootStat = stat()
        XCTAssertEqual(lstat(roots.durable.path, &rootStat), 0)
        XCTAssertEqual(rootStat.st_mode & 0o777, 0o700)
        let staged = stager.resolver.prefetchSnapshotURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "redundant staging copy must be reclaimed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots.durable.appendingPathComponent(Build1LaneAArtifactStager.prepareLockLeaf).path))
    }

    func testReusesVerifiedDurableArtifactWithoutTransfer() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "already-adopted")
        let store = DurableModelArtifactStore(root: roots.durable)
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(
                hubRoot: roots.hub,
                durableRoot: roots.durable,
                downloader: Self.refusingDownloader()
            ),
            diskProbe: { _ in
                XCTFail("reuse must not probe disk")
                return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
            }
        )
        var stages: [Build1LaneAStagingStage] = []

        let result = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }

        XCTAssertTrue(result.reusedDurableArtifact)
        XCTAssertEqual(result.adoptedBytes, Int64(payload.utf8.count))
        XCTAssertEqual(stages, [.verified, .adopted])
    }

    func testAdoptsVerifiedCanonicalSnapshotWithoutDownloadAndKeepsIt() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "canonical-cache-bytes")
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader())
        let canonical = resolver.snapshotURL(modelID: authority.modelID, revision: authority.revision)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: canonical.appendingPathComponent("weights.bin"))
        let stager = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { _ in
            XCTFail("adopting an existing verified snapshot must not probe disk")
            return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
        })
        var stages: [Build1LaneAStagingStage] = []

        let result = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }

        XCTAssertFalse(result.reusedDurableArtifact)
        XCTAssertEqual(stages, [.verified, .adopted])
        XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("weights.bin")), payload, "canonical snapshot must survive")
        let durable = try resolver.durableStore.artifactURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), authority.hash)
    }

    func testReclaimsStaleIsolatedStagingAndRedownloads() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "fresh-bytes")
        let counter = Build1LaneACounter()
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: counter)
        )
        let staged = resolver.prefetchSnapshotURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("stale-bytes".utf8).write(to: staged.appendingPathComponent("weights.bin"))
        let stager = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

        let result = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(result.sha256, authority.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testDigestMismatchRemovesStagingAndNeverAdopts() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "signed-bytes")
        let counter = Build1LaneACounter()
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: "tampered-bytes", counter: counter)
        )
        let stager = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
        var stages: [Build1LaneAStagingStage] = []

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }
            XCTFail("tampered bytes must not adopt")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .verificationFailed(let expected, let actual) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(expected, authority.hash)
            XCTAssertNotEqual(actual, authority.hash)
        }

        XCTAssertEqual(stages, [.staging])
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        let staged = resolver.prefetchSnapshotURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testDiskHeadroomDoublesWhenStagingAndDurableShareVolume() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "bytes", sizeBytes: 1_000)
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter())
        )

        let sharedVolume = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { _ in
            Build1LaneADiskProbe(availableBytes: 1_999, deviceID: 3)
        })
        do {
            _ = try await sharedVolume.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("shared volume must require both copies to fit")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .insufficientDiskSpace(requiredBytes: 2_000, availableBytes: 1_999))
        }

        let separateVolumes = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { url in
            Build1LaneADiskProbe(availableBytes: 1_000, deviceID: url.path.contains("durable") ? 2 : 1)
        })
        let result = try await separateVolumes.stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertEqual(result.sha256, authority.hash)
    }

    func testExpiredDeadlineTimesOutBeforeAnyTransfer() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "bytes")
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) },
            deadline: Date(timeIntervalSinceNow: -1)
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("expired deadline must time out")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
    }

    func testCancelledTaskUnwindsWithoutAdoption() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "bytes")
        let started = expectation(description: "download started")
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: HuggingFaceSnapshotDownloader(
                fetch: { request in
                    let url = try XCTUnwrap(request.url)
                    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                    return (Data(#"{"siblings":[{"rfilename":"weights.bin"}]}"#.utf8), response)
                },
                download: { _ in
                    started.fulfill()
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw URLError(.unknown)
                }
            )
        )
        let stager = Build1LaneAArtifactStager(resolver: resolver, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

        let work = Task {
            try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
        }
        await fulfillment(of: [started], timeout: 5)
        work.cancel()

        do {
            _ = try await work.value
            XCTFail("cancelled staging must not succeed")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        let hubEntries = try FileManager.default.subpathsOfDirectory(atPath: roots.hub.path)
        XCTAssertTrue(hubEntries.allSatisfy { !$0.contains(".download-") && !$0.contains("macprovider-prefetch") }, "\(hubEntries)")
    }

    func testSymlinkedDurableRootIsRefused() async throws {
        let roots = try makeRoots()
        let target = try tempDir()
        let link = roots.durable
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let (authority, _) = try makeAuthority(payload: "bytes")
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: link, downloader: Self.refusingDownloader()),
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("symlinked durable root must be refused")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .rootUnavailable = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: - Helpers

    private func makeRoots() throws -> Roots {
        let base = try tempDir()
        let hub = base.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        return Roots(hub: hub, durable: base.appendingPathComponent("durable", isDirectory: true))
    }

    private func makeAuthority(payload: String, sizeBytes: Int? = nil) throws -> (Build1LaneAArtifactAuthority, String) {
        let expectedDirectory = try tempDir()
        try Data(payload.utf8).write(to: expectedDirectory.appendingPathComponent("weights.bin"))
        let hash = try ModelArtifactVerifier.canonicalArtifactHash(directory: expectedDirectory)
        let authority = Build1LaneAArtifactAuthority(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            hashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            hash: hash,
            sizeBytes: sizeBytes ?? payload.utf8.count,
            feedSHA256: String(repeating: "f", count: 64),
            feedSignerKeyID: "test-signer",
            releaseID: "test-release"
        )
        return (authority, payload)
    }

    private static func fakeDownloader(payload: String, counter: Build1LaneACounter) -> HuggingFaceSnapshotDownloader {
        HuggingFaceSnapshotDownloader(
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(#"{"siblings":[{"rfilename":"weights.bin"}]}"#.utf8), response)
            },
            download: { request in
                counter.increment()
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lane-a-stager-\(UUID().uuidString).bin")
                try Data(payload.utf8).write(to: downloaded)
                let url = try XCTUnwrap(request.url)
                return (downloaded, URLResponse(url: url, mimeType: nil, expectedContentLength: payload.utf8.count, textEncodingName: nil))
            }
        )
    }

    private static func refusingDownloader() -> HuggingFaceSnapshotDownloader {
        HuggingFaceSnapshotDownloader(
            fetch: { _ in
                XCTFail("no transfer expected")
                throw URLError(.cannotConnectToHost)
            },
            download: { _ in
                XCTFail("no transfer expected")
                throw URLError(.cannotConnectToHost)
            }
        )
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-lane-a-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
