import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

/// #1737: catalog bytes from hosts other than huggingface.co, verified only
/// by the signed snapshot-manifest.v1 hash.
final class ModelArtifactSourceTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private let modelID = "namespace/model"
    private let mirror = URL(string: "https://mirror.example")!

    // MARK: - source list

    func testProductionFallbacksOrderOperatorMirrorsThenMalibuThenHFEndpoint() {
        let sources = ModelArtifactSource.productionFallbacks(environment: [
            "MACPROVIDER_MODEL_MIRRORS": "https://one.example/models/, http://plain.example ,https://two.example",
            "HF_ENDPOINT": "https://hf-mirror.example",
        ])
        XCTAssertEqual(sources, [
            .contentAddressed(URL(string: "https://one.example/models")!),
            .contentAddressed(URL(string: "https://two.example")!),
            .contentAddressed(ModelArtifactSource.malibuMirror),
            .huggingFaceCompatible(URL(string: "https://hf-mirror.example")!),
        ])
    }

    func testProductionFallbacksIgnoreHuggingFaceEndpointAndUnsafeURLs() {
        let sources = ModelArtifactSource.productionFallbacks(environment: [
            "MACPROVIDER_MODEL_MIRRORS": "https://user:pw@evil.example https://q.example/?x=1 ftp://f.example",
            "HF_ENDPOINT": "https://huggingface.co",
        ])
        XCTAssertEqual(sources, [.contentAddressed(ModelArtifactSource.malibuMirror)])
    }

    // MARK: - manifest

    func testManifestParsesOnlyWhenItHashesToTheSignedHash() throws {
        let manifest = Data("a.bin\n1\n\(sha("a"))\n".utf8)
        let expected = ContentAddressedManifest.sha256Hex(manifest)
        XCTAssertEqual(
            try ContentAddressedManifest.parse(manifest, expectedSHA256: expected),
            [ContentAddressedManifest.Entry(path: "a.bin", size: 1, sha256: sha("a"))]
        )
        XCTAssertThrowsError(
            try ContentAddressedManifest.parse(manifest, expectedSHA256: String(repeating: "0", count: 64))
        )
    }

    func testManifestRejectsUnsafePathEvenWhenHashMatches() {
        let manifest = Data("../escape\n1\n\(sha("a"))\n".utf8)
        let expected = ContentAddressedManifest.sha256Hex(manifest)
        XCTAssertThrowsError(try ContentAddressedManifest.parse(manifest, expectedSHA256: expected))
    }

    func testMirrorManifestIsTheCanonicalSnapshotManifest() throws {
        let snapshot = try makeSnapshot(["config.json": "{}", ".gitattributes": "*.bin lfs", "sub/w.bin": "weights"])
        let (manifest, expected) = try canonicalManifest(of: snapshot)
        XCTAssertEqual(ContentAddressedManifest.sha256Hex(manifest), expected)
        XCTAssertEqual(try ContentAddressedManifest.parse(manifest, expectedSHA256: expected).count, 3)
    }

    // MARK: - downloader fallback

    func testDownloaderFallsBackToContentMirrorWhenHuggingFaceIsUnreachable() async throws {
        let source = try makeSnapshot(["config.json": "{}", ".gitattributes": "x", "sub/w.bin": "weights"])
        let (manifest, expected) = try canonicalManifest(of: source)
        let requests = RequestLog()
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                requests.append(request)
                guard request.url?.host == "mirror.example" else { throw URLError(.cannotConnectToHost) }
                return (manifest, Self.ok(request.url!))
            },
            download: { request in
                requests.append(request)
                return try Self.serve(request, from: source, sha256: expected)
            }
        )
        downloader.fallbackSources = [.contentAddressed(mirror)]
        let target = try tempDir().appendingPathComponent("snapshot", isDirectory: true)

        try await downloader.downloadSnapshot(
            modelID: modelID,
            revision: revision,
            expectedSHA256: expected,
            to: target
        )

        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: target), expected)
        let mirrorRequests = requests.all.filter { $0.url?.host == "mirror.example" }
        XCTAssertEqual(mirrorRequests.count, 4)
        XCTAssertTrue(mirrorRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testLaterSnapshotsSkipAnUnreachableHuggingFaceUntilTheMirrorsFail() async throws {
        let source = try makeSnapshot(["w.bin": "weights"])
        let (manifest, expected) = try canonicalManifest(of: source)
        let requests = RequestLog()
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                requests.append(request)
                guard request.url?.host == "mirror.example" else { throw URLError(.timedOut) }
                return (manifest, Self.ok(request.url!))
            },
            download: { request in
                requests.append(request)
                return try Self.serve(request, from: source, sha256: expected)
            }
        )
        downloader.fallbackSources = [.contentAddressed(mirror)]

        try await downloader.downloadSnapshot(
            modelID: modelID,
            revision: revision,
            expectedSHA256: expected,
            to: try tempDir().appendingPathComponent("first", isDirectory: true)
        )
        let afterFirst = requests.all.filter { $0.url?.host == "huggingface.co" }.count
        try await downloader.downloadSnapshot(
            modelID: modelID,
            revision: revision,
            expectedSHA256: expected,
            to: try tempDir().appendingPathComponent("second", isDirectory: true)
        )

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(requests.all.filter { $0.url?.host == "huggingface.co" }.count, 1, "the second snapshot went straight to the mirror")
    }

    func testDownloaderRejectsMirrorFileThatDoesNotMatchItsManifest() async throws {
        let source = try makeSnapshot(["w.bin": "weights"])
        let (manifest, expected) = try canonicalManifest(of: source)
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                guard request.url?.host == "mirror.example" else { throw URLError(.cannotConnectToHost) }
                return (manifest, Self.ok(request.url!))
            },
            download: { request in
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tampered-\(UUID().uuidString)")
                try Data("tampered".utf8).write(to: temporary)
                return (temporary, Self.ok(request.url!))
            }
        )
        downloader.fallbackSources = [.contentAddressed(mirror)]
        let target = try tempDir().appendingPathComponent("snapshot", isDirectory: true)

        do {
            try await downloader.downloadSnapshot(modelID: modelID, revision: revision, expectedSHA256: expected, to: target)
            XCTFail("tampered mirror bytes were accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("does not match its manifest"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDownloaderSkipsContentMirrorWithoutSignedHash() async throws {
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                XCTAssertEqual(request.url?.host, "huggingface.co")
                throw URLError(.cannotConnectToHost)
            },
            download: { _ in throw URLError(.cannotConnectToHost) }
        )
        downloader.fallbackSources = [.contentAddressed(mirror)]
        let target = try tempDir().appendingPathComponent("snapshot", isDirectory: true)

        do {
            try await downloader.downloadSnapshot(modelID: modelID, revision: revision, to: target)
            XCTFail("download unexpectedly succeeded")
        } catch {
            XCTAssertTrue(String(describing: error).contains("no signed artifact hash"), "\(error)")
        }
    }

    func testDownloaderWithoutFallbacksKeepsTheOriginalError() async throws {
        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            download: { _ in throw URLError(.cannotConnectToHost) }
        )
        let target = try tempDir().appendingPathComponent("snapshot", isDirectory: true)

        do {
            try await downloader.downloadSnapshot(modelID: modelID, revision: revision, to: target)
            XCTFail("download unexpectedly succeeded")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testHuggingFaceCompatibleEndpointIsNeverSentTheToken() async throws {
        setenv("HF_TOKEN", "hf_secret", 1)
        defer { unsetenv("HF_TOKEN") }
        let requests = RequestLog()
        var downloader = HuggingFaceSnapshotDownloader(
            fetch: { request in
                requests.append(request)
                guard request.url?.host == "hf-mirror.example" else { throw URLError(.cannotConnectToHost) }
                return (Data(#"{"siblings":[{"rfilename":"w.bin"}]}"#.utf8), Self.ok(request.url!))
            },
            download: { request in
                requests.append(request)
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hf-compat-\(UUID().uuidString)")
                try Data("weights".utf8).write(to: temporary)
                return (temporary, Self.ok(request.url!))
            }
        )
        downloader.fallbackSources = [.huggingFaceCompatible(URL(string: "https://hf-mirror.example")!)]
        let target = try tempDir().appendingPathComponent("snapshot", isDirectory: true)

        try await downloader.downloadSnapshot(modelID: modelID, revision: revision, to: target)

        let origin = requests.all.filter { $0.url?.host == "huggingface.co" }
        let alternate = requests.all.filter { $0.url?.host == "hf-mirror.example" }
        XCTAssertEqual(origin.first?.value(forHTTPHeaderField: "Authorization"), "Bearer hf_secret")
        XCTAssertEqual(alternate.count, 2)
        XCTAssertTrue(alternate.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(
            alternate.first?.url?.absoluteString,
            "https://hf-mirror.example/api/models/namespace/model/revision/\(revision)?blobs=true"
        )
    }

    func testMirrorRedirectMayLeaveTheMirrorHost() {
        let original = URL(string: "https://mirror.example/abc/files/w.bin")!
        let task = URLSession.shared.dataTask(with: original)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        let waiter = expectation(description: "redirect completion")
        var redirected: URLRequest?
        HFAssetRedirectGuard().urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://bucket.storage.example/w.bin")!)
        ) { request in
            redirected = request
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 1)
        XCTAssertEqual(redirected?.url?.host, "bucket.storage.example")
    }

    // MARK: - resolver

    func testVerifiedArtifactSkipsCandidateOnTransportFailure() async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(
            hubRoot: hub,
            downloader: HuggingFaceSnapshotDownloader(
                fetch: { _ in throw URLError(.timedOut) },
                download: { _ in throw URLError(.timedOut) }
            )
        )

        do {
            _ = try await resolver.verifiedArtifact(for: row(sha256: String(repeating: "b", count: 64)))
            XCTFail("unreachable source unexpectedly verified")
        } catch let error as AutotuneRecommendError {
            guard case .invalidArtifact(let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(message.contains("artifact download failed"), message)
        }
    }

    func testVerifiedArtifactUsesDurableCopyWithoutHuggingFaceSnapshot() async throws {
        let hub = try tempDir()
        let source = try makeSnapshot(["w.bin": "weights"])
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
        let resolver = CachedModelArtifactResolver(
            hubRoot: hub,
            downloader: HuggingFaceSnapshotDownloader(
                fetch: { _ in XCTFail("no network for a verified durable copy"); throw URLError(.badURL) },
                download: { _ in XCTFail("no network for a verified durable copy"); throw URLError(.badURL) }
            )
        )
        let durable = try resolver.durableStore.adoptVerifiedStaging(
            staging: source,
            modelID: modelID,
            revision: revision,
            sha256: expected
        )

        let verified = try await resolver.verifiedArtifact(for: row(sha256: expected))

        XCTAssertEqual(verified.modelArgument, durable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.snapshotURL(modelID: modelID, revision: revision).path))
    }

    func testMismatchedSnapshotIsQuarantinedNotDeletedWhenNoSourceIsReachable() async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(
            hubRoot: hub,
            downloader: HuggingFaceSnapshotDownloader(
                fetch: { _ in throw URLError(.cannotConnectToHost) },
                download: { _ in throw URLError(.cannotConnectToHost) }
            )
        )
        let snapshot = resolver.snapshotURL(modelID: modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("w.bin"))
        try Data("finder".utf8).write(to: snapshot.appendingPathComponent(".DS_Store"))

        do {
            _ = try await resolver.verifiedArtifact(for: row(sha256: String(repeating: "b", count: 64)))
            XCTFail("mismatched snapshot unexpectedly verified")
        } catch {
            XCTAssertTrue(String(describing: error).contains("automatic repair failed"), "\(error)")
        }

        let quarantined = resolver.quarantineURL(modelID: modelID).appendingPathComponent(revision, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: quarantined.appendingPathComponent("w.bin")), Data("weights".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    // MARK: - models import

    func testImportFollowsCacheSymlinksSkipsFinderFilesAndAdopts() throws {
        let hub = try tempDir()
        let reference = try makeSnapshot(["config.json": "{}", "w.bin": "weights"])
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: reference)

        let cache = try tempDir()
        let blobs = cache.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = cache.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: blobs.appendingPathComponent("blob1"))
        try FileManager.default.createSymbolicLink(
            at: snapshot.appendingPathComponent("w.bin"),
            withDestinationURL: blobs.appendingPathComponent("blob1")
        )
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("finder".utf8).write(to: snapshot.appendingPathComponent(".DS_Store"))
        try Data("appledouble".utf8).write(to: snapshot.appendingPathComponent("._w.bin"))

        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let outcome = ModelArtifactImporter.importArtifact(row: row(sha256: expected), from: snapshot, resolver: resolver)

        guard case .adopted(let path, let sha256) = outcome else {
            return XCTFail("unexpected \(outcome)")
        }
        XCTAssertEqual(sha256, expected)
        XCTAssertTrue(resolver.durableStore.contains(path))
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: URL(fileURLWithPath: path)), expected)
    }

    func testImportIgnoresHFLocalDirDownloadState() throws {
        let hub = try tempDir()
        let reference = try makeSnapshot(["config.json": "{}", "w.bin": "weights"])
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: reference)
        let localDir = try makeSnapshot(["config.json": "{}", "w.bin": "weights"])
        let state = localDir.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("*\n".utf8).write(to: localDir.appendingPathComponent(".cache/huggingface/.gitignore"))
        try Data("etag\n".utf8).write(to: state.appendingPathComponent("w.bin.metadata"))

        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let outcome = ModelArtifactImporter.importArtifact(row: row(sha256: expected), from: localDir, resolver: resolver)

        guard case .adopted(_, let sha256) = outcome else {
            return XCTFail("unexpected \(outcome)")
        }
        XCTAssertEqual(sha256, expected)
    }

    func testImportFromMirrorTreeCopiesOnlyManifestFiles() throws {
        let hub = try tempDir()
        let reference = try makeSnapshot(["w.bin": "weights"])
        let (manifest, expected) = try canonicalManifest(of: reference)
        let tree = try tempDir()
        try manifest.write(to: tree.appendingPathComponent("manifest"))
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: tree.appendingPathComponent("files/w.bin"))
        try Data("stray".utf8).write(to: tree.appendingPathComponent("files/stray.txt"))

        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let outcome = ModelArtifactImporter.importArtifact(row: row(sha256: expected), from: tree, resolver: resolver)

        guard case .adopted(_, let sha256) = outcome else {
            return XCTFail("unexpected \(outcome)")
        }
        XCTAssertEqual(sha256, expected)
    }

    func testImportReportsMismatchAndAdoptsNothing() throws {
        let hub = try tempDir()
        let source = try makeSnapshot(["w.bin": "other weights"])
        let expected = String(repeating: "c", count: 64)
        let resolver = CachedModelArtifactResolver(hubRoot: hub)

        let outcome = ModelArtifactImporter.importArtifact(row: row(sha256: expected), from: source, resolver: resolver)

        guard case .mismatch(let wanted, _) = outcome else {
            return XCTFail("unexpected \(outcome)")
        }
        XCTAssertEqual(wanted, expected)
        let durable = try resolver.durableStore.artifactURL(modelID: modelID, revision: revision, sha256: expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.path))
    }

    // MARK: - helpers

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// Serve `<mirror>/<sha>/files/<path>` from a local snapshot.
    private static func serve(_ request: URLRequest, from snapshot: URL, sha256: String) throws -> (URL, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let prefix = "/\(sha256)/files/"
        guard url.host == "mirror.example", url.path.hasPrefix(prefix) else {
            throw URLError(.cannotConnectToHost)
        }
        let relative = String(url.path.dropFirst(prefix.count))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: snapshot.appendingPathComponent(relative), to: temporary)
        return (temporary, ok(url))
    }

    private func row(sha256: String) -> CandidateCatalog.Row {
        CandidateCatalog.Row(
            modelID: modelID,
            modelRevision: revision,
            modelSHA256: sha256,
            minRAMGB: 1,
            minBandwidthTier: .c,
            benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 1, max4KTTFTMS: 1_000),
            runtimeStatus: "recommendable",
            notes: nil
        )
    }

    private func sha(_ text: String) -> String {
        ContentAddressedManifest.sha256Hex(Data(text.utf8))
    }

    private func makeSnapshot(_ files: [String: String]) throws -> URL {
        let dir = try tempDir()
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return dir
    }

    /// The mirror publisher's manifest: what `inspectCanonicalArtifact` hashes.
    private func canonicalManifest(of snapshot: URL) throws -> (Data, String) {
        var entries: [(String, UInt64, String)] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: nil))
        let base = snapshot.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            let measured = try ModelArtifactVerifier.sizeAndSHA256(of: url)
            entries.append((relative, measured.size, measured.sha256))
        }
        let text = entries.sorted { $0.0 < $1.0 }.map { "\($0.0)\n\($0.1)\n\($0.2)\n" }.joined()
        let data = Data(text.utf8)
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        XCTAssertEqual(ContentAddressedManifest.sha256Hex(data), expected)
        return (data, expected)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-artifact-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }
}
