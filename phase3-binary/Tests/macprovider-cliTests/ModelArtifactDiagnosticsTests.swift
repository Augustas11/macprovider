import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelArtifactDiagnosticsTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private let otherRevision = String(repeating: "b", count: 40)
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
        cleanup = []
        super.tearDown()
    }

    // MARK: Classification

    func testMatchWhenPinnedSnapshotHashesToSignedRow() throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .match)
        XCTAssertEqual(diagnosis.likelySource, .none)
        XCTAssertEqual(diagnosis.locationKind, .hfSnapshot)
        XCTAssertEqual(diagnosis.computedSHA256, row.sha256)
    }

    func testRevisionMismatchWhenOnlyAnotherRevisionIsCached() throws {
        let (resolver, _) = try makeResolver()
        try writeCompleteSnapshot(at: resolver.snapshotURL(modelID: "namespace/model", revision: otherRevision))
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .missing)
        XCTAssertEqual(diagnosis.likelySource, .revisionPin)
        XCTAssertEqual(diagnosis.otherLocalRevisions, [otherRevision])
    }

    func testRevisionMismatchWhenConfiguredPathIsAnotherRevision() throws {
        let (resolver, _) = try makeResolver()
        let configured = resolver.snapshotURL(modelID: "namespace/model", revision: otherRevision)
        try writeCompleteSnapshot(at: configured)
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(
            row: row,
            resolver: resolver,
            configuredArtifactPath: configured.path
        )

        XCTAssertEqual(diagnosis.verdict, .mismatch)
        XCTAssertEqual(diagnosis.likelySource, .revisionPin)
        XCTAssertEqual(diagnosis.locationKind, .configuredPath)
    }

    func testPartialDownloadWhenOnlyInterruptedStagingExists() throws {
        let (resolver, _) = try makeResolver()
        let staging = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
            .deletingLastPathComponent()
            .appendingPathComponent(".download-\(revision)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: staging.appendingPathComponent("config.json"))
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .missing)
        XCTAssertEqual(diagnosis.likelySource, .localDownload)
        XCTAssertEqual(diagnosis.partials.map(\.kind), [.hfDownloadStaging])
    }

    func testPartialDownloadWhenIndexedShardIsMissing() throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        try Data(#"{"weight_map":{"w":"model.safetensors","v":"model-00002.safetensors"}}"#.utf8)
            .write(to: snapshot.appendingPathComponent("model.safetensors.index.json"))
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .mismatch)
        XCTAssertEqual(diagnosis.likelySource, .localDownload)
        XCTAssertTrue(
            diagnosis.evidence.contains("index references missing shard: model-00002.safetensors"),
            "\(diagnosis.evidence)"
        )
    }

    func testPartialDownloadWhenSafetensorsIsTruncated() throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot, truncateWeights: true)
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .mismatch)
        XCTAssertEqual(diagnosis.likelySource, .localDownload)
        XCTAssertTrue(diagnosis.evidence.contains { $0.hasPrefix("truncated safetensors model.safetensors") })
    }

    func testPartialDownloadWhenSnapshotHasNoWeights() throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.likelySource, .localDownload)
        XCTAssertTrue(diagnosis.evidence.contains("no weight files present"))
    }

    func testCatalogRowSuspectWhenCompleteBytesAtPinnedRevisionHashDifferently() throws {
        let (resolver, _) = try makeResolver()
        try writeCompleteSnapshot(at: resolver.snapshotURL(modelID: "namespace/model", revision: revision))
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertEqual(diagnosis.verdict, .mismatch)
        XCTAssertEqual(diagnosis.likelySource, .catalogRow)
        XCTAssertNotNil(diagnosis.computedSHA256)
        XCTAssertTrue(ModelArtifactDiagnostics.nextStep(diagnosis).contains("do not re-download"))
    }

    // MARK: Redacted report

    func testRedactedReportCarriesRowFieldsWithoutLocalPathsOrProviderIdentity() throws {
        let (resolver, root) = try makeResolver()
        try writeCompleteSnapshot(at: resolver.snapshotURL(modelID: "namespace/model", revision: revision))
        var row = makeRow(sha256: String(repeating: "1", count: 64))
        row.buyerModelKey = "namespace/model"
        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        let report = ModelArtifactDiagnostics.reportBlock(diagnosis)
        let json = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ModelArtifactDiagnostics.jsonObject(diagnosis)),
            encoding: .utf8
        ))

        for field in ["catalog_key: namespace/model", "pinned_revision: \(revision)", "signed_hash: \(row.sha256)",
                      "computed_hash: \(diagnosis.computedSHA256!)", "catalog_digest: \(row.catalogDigest)",
                      "likely_source: catalog_row", "local_path: <hf_cache>/models--namespace--model/snapshots/\(revision)"] {
            XCTAssertTrue(report.contains(field), "missing \(field) in\n\(report)")
        }
        for output in [report, json] {
            XCTAssertFalse(output.contains(root.path), output)
            XCTAssertFalse(output.contains(NSHomeDirectory()), output)
            XCTAssertFalse(output.lowercased().contains("provider_id"), output)
            XCTAssertFalse(output.lowercased().contains("token"), output)
        }
        let home = NSHomeDirectory()
        XCTAssertEqual(
            ModelArtifactDiagnostics.redact("\(home)/Library/x", hubRoot: root, durableRoot: root),
            "~/Library/x"
        )
    }

    // MARK: Prepare

    func testRepairCacheRemovesOnlyTargetModelPartials() async throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        let snapshots = snapshot.deletingLastPathComponent()
        let targetStaging = snapshots.appendingPathComponent(".download-\(revision)-\(UUID().uuidString)")
        let targetBlob = snapshots.deletingLastPathComponent().appendingPathComponent("blobs/abc.incomplete")
        let otherStaging = resolver.snapshotURL(modelID: "namespace/other", revision: revision)
            .deletingLastPathComponent()
            .appendingPathComponent(".download-\(revision)-\(UUID().uuidString)")
        let durableRevision = try resolver.durableStore
            .artifactURL(modelID: row.modelID, revision: revision, sha256: row.sha256)
            .deletingLastPathComponent()
        let durableTemp = durableRevision.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let parkedBackup = durableRevision.appendingPathComponent(".tmp-replaced-\(UUID().uuidString)")
        for directory in [targetStaging, otherStaging, durableTemp, parkedBackup] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("f"))
        }
        try FileManager.default.createDirectory(at: targetBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: targetBlob)

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: true)

        XCTAssertEqual(outcome.finalState, .readyVerified)
        XCTAssertEqual(outcome.partialsFound.count, 3)
        XCTAssertEqual(outcome.partialsRemoved.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherStaging.path), "other model partial must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkedBackup.path), "parked durable copy must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path), "verified snapshot must survive")
    }

    func testPrepareWithoutRepairLeavesPartialsAndReportsThem() async throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        let staging = snapshot.deletingLastPathComponent().appendingPathComponent(".download-\(revision)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertEqual(outcome.finalState, .readyVerified)
        XCTAssertEqual(outcome.partialsFound.count, 1)
        XCTAssertEqual(outcome.partialsRemoved.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(ModelCatalogPreparation.humanText(outcome).contains("pass --repair-cache"))
    }

    func testPrepareDownloadsThroughResolverAndReportsReadyVerified() async throws {
        let expectedDirectory = try tempDir()
        try writeCompleteSnapshot(at: expectedDirectory)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: expectedDirectory))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: expectedDirectory))

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertTrue(outcome.downloadAttempted)
        XCTAssertEqual(outcome.finalState, .readyVerified)
        XCTAssertEqual(outcome.finalLine, "ready (verified)")
        XCTAssertEqual(outcome.diagnosis.locationKind, .durableStore)
        XCTAssertEqual(outcome.jsonObject["final_state"] as? String, "ready_verified")
    }

    func testPrepareReportsHashMismatchAfterCompleteDownload() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertTrue(outcome.downloadAttempted)
        XCTAssertEqual(outcome.finalState, .hashMismatch)
        XCTAssertEqual(outcome.finalLine, "downloaded but hash mismatch (see verify-artifact)")
        XCTAssertNil(outcome.retryCommand)
    }

    func testPrepareReportsIncompleteWithExactRetryWhenDownloadFails() async throws {
        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            download: { _ in throw URLError(.notConnectedToInternet) }
        )
        let (resolver, _) = try makeResolver(downloader: downloader)
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let outcome = await ModelCatalogPreparation.prepare(
            row: row,
            resolver: resolver,
            repairCache: false,
            config: "/etc/provider.yaml"
        )

        XCTAssertEqual(outcome.finalState, .incomplete)
        XCTAssertEqual(
            outcome.finalLine,
            "incomplete (retry: malibu-cli models prepare namespace/model --repair-cache --config /etc/provider.yaml)"
        )
        XCTAssertNotNil(outcome.error)
    }

    func testRetryCommandShellQuotesArgumentsThatNeedIt() {
        XCTAssertEqual(
            ModelCatalogPreparation.retryCommand(catalogKey: "namespace/model", config: "/Users/o'brien/My Config/config.yaml"),
            #"malibu-cli models prepare namespace/model --repair-cache --config '/Users/o'\''brien/My Config/config.yaml'"#
        )
        XCTAssertEqual(
            ModelCatalogPreparation.retryCommand(catalogKey: "key; rm -rf ~", config: nil),
            #"malibu-cli models prepare 'key; rm -rf ~' --repair-cache"#
        )
        XCTAssertEqual(ModelCatalogPreparation.retryCommand(catalogKey: "", config: nil), "malibu-cli models prepare '' --repair-cache")
    }

    func testPrepareRefusesToDownloadWithoutDiskSpace() async throws {
        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { _ in
                XCTFail("must not fetch without disk space")
                throw URLError(.cancelled)
            },
            download: { _ in throw URLError(.cancelled) }
        )
        let (resolver, _) = try makeResolver(downloader: downloader)
        var row = makeRow(sha256: String(repeating: "1", count: 64))
        row.artifactSizeBytes = 1_000_000

        let outcome = await ModelCatalogPreparation.prepare(
            row: row,
            resolver: resolver,
            repairCache: false,
            freeSpace: { _ in 10 }
        )

        XCTAssertEqual(outcome.finalState, .incomplete)
        XCTAssertFalse(outcome.downloadAttempted)
        XCTAssertEqual(outcome.availableBytes, 10)
        XCTAssertTrue(outcome.error?.hasPrefix("insufficient_disk_space") == true)
    }

    func testPrepareLeavesUnverifiablePinnedSnapshotWithoutRepairFlag() async throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot, truncateWeights: true)
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertEqual(outcome.finalState, .incomplete)
        XCTAssertFalse(outcome.downloadAttempted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("model.safetensors").path))
        XCTAssertTrue(outcome.finalLine.contains("--repair-cache"))
    }

    func testPrepareWithoutRepairNeverReplacesAnIncompleteDurableSnapshot() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: served))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))
        let durable = try resolver.durableStore.artifactURL(modelID: row.modelID, revision: revision, sha256: row.sha256)
        try writeCompleteSnapshot(at: durable, truncateWeights: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: resolver.snapshotURL(modelID: row.modelID, revision: revision).path
        ), "no HF snapshot: only the durable copy is present")
        let before = try directoryBytes(durable)

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertEqual(outcome.finalState, .incomplete)
        XCTAssertFalse(outcome.downloadAttempted, "no download may replace a failing pinned location without --repair-cache")
        XCTAssertTrue(outcome.finalLine.hasPrefix("incomplete (retry: "), outcome.finalLine)
        XCTAssertTrue(outcome.finalLine.contains("--repair-cache"), outcome.finalLine)
        XCTAssertEqual(try directoryBytes(durable), before, "the durable snapshot is byte-identical")
    }

    /// A durable copy that hashes differently while a valid Hugging Face
    /// snapshot exists: serve loads the existing durable copy and fails its
    /// hash, so diagnostics must report that copy, not the fallback bytes.
    private func corruptDurableBesideValidSnapshot() throws -> (CachedModelArtifactResolver, ModelArtifactSignedRow, URL) {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        let durable = try resolver.durableStore.artifactURL(modelID: row.modelID, revision: revision, sha256: row.sha256)
        try writeCompleteSnapshot(at: durable)
        try Data("drift".utf8).write(to: durable.appendingPathComponent("extra.txt"))
        XCTAssertNotEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), row.sha256)
        return (resolver, row, durable)
    }

    func testCorruptDurableCopyIsWhatVerifyReportsEvenWhenTheHFSnapshotVerifies() throws {
        let (resolver, row, durable) = try corruptDurableBesideValidSnapshot()

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver)

        XCTAssertNotEqual(diagnosis.verdict, .match, "verify-artifact exits non-zero on anything but match")
        XCTAssertEqual(diagnosis.verdict, .mismatch)
        XCTAssertEqual(diagnosis.locationKind, .durableStore)
        XCTAssertEqual(diagnosis.localPath?.path, durable.standardizedFileURL.path)
        XCTAssertEqual(diagnosis.likelySource, .localDownload, "a durable copy was verified when adopted; drift is local")
        XCTAssertTrue(ModelArtifactDiagnostics.nextStep(diagnosis).contains("--repair-cache"))
    }

    func testPrepareWithoutRepairReportsACorruptDurableCopyIncompleteAndLeavesIt() async throws {
        let (resolver, row, durable) = try corruptDurableBesideValidSnapshot()
        let before = try directoryBytes(durable)

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false)

        XCTAssertEqual(outcome.finalState, .incomplete)
        XCTAssertFalse(outcome.downloadAttempted)
        XCTAssertEqual(outcome.diagnosis.locationKind, .durableStore)
        XCTAssertTrue(outcome.finalLine.hasPrefix("incomplete (retry: "), outcome.finalLine)
        XCTAssertTrue(outcome.finalLine.contains("--repair-cache"), outcome.finalLine)
        XCTAssertEqual(try directoryBytes(durable), before, "the durable copy is untouched without --repair-cache")
    }

    func testPrepareWithRepairReplacesACorruptDurableCopyFromVerifiedBytes() async throws {
        let (resolver, row, durable) = try corruptDurableBesideValidSnapshot()

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: true)

        XCTAssertEqual(outcome.finalState, .readyVerified, outcome.error ?? "")
        XCTAssertEqual(outcome.diagnosis.locationKind, .durableStore)
        XCTAssertEqual(outcome.diagnosis.localPath?.path, durable.standardizedFileURL.path)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), row.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.appendingPathComponent("extra.txt").path))
    }

    // MARK: Studio E2E findings (#1689 Loop A)

    /// F4: a partial `--repair-cache` could not remove stays visible after
    /// the artifact verifies, and the hint does not repeat the flag.
    func testRepairCacheCleanupFailureStaysVisibleWhenTheArtifactVerifies() async throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        let stuck = snapshot.deletingLastPathComponent().appendingPathComponent(".download-labstuck", isDirectory: true)
        let locked = stuck.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("f"))
        XCTAssertEqual(chmod(locked.path, 0o500), 0)
        defer { _ = chmod(locked.path, 0o700) }

        let outcome = await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: true)

        XCTAssertEqual(outcome.finalState, .readyVerified)
        XCTAssertEqual(outcome.partialsRemoved.count, 0)
        XCTAssertEqual(outcome.cleanupFailures.count, 1)
        let failed = try XCTUnwrap(outcome.jsonObject["cleanup_failed"] as? [String])
        XCTAssertEqual(failed.count, 1)
        XCTAssertTrue(failed[0].hasPrefix(".download-labstuck"), failed[0])
        let text = ModelCatalogPreparation.humanText(outcome)
        XCTAssertTrue(text.contains("warning:   --repair-cache could not remove 1 interrupted download artifact(s)"), text)
        XCTAssertFalse(text.contains("pass --repair-cache"), text)
        XCTAssertTrue(text.contains("final:     ready (verified)"), text)
    }

    /// F5: a verified Hugging Face snapshot is not what serve loads when the
    /// config names the durable copy, so prepare adopts it before `ready`.
    func testPrepareAdoptsAVerifiedHFSnapshotIntoTheDurableStoreServeLoads() async throws {
        let (resolver, _) = try makeResolver()
        let snapshot = resolver.snapshotURL(modelID: "namespace/model", revision: revision)
        try writeCompleteSnapshot(at: snapshot)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        let durable = try resolver.durableStore.artifactURL(modelID: row.modelID, revision: revision, sha256: row.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durable.path))

        let outcome = await ModelCatalogPreparation.prepare(
            row: row,
            resolver: resolver,
            repairCache: false,
            configuredArtifactPath: durable.path
        )

        XCTAssertEqual(outcome.finalState, .readyVerified, outcome.error ?? "")
        XCTAssertFalse(outcome.downloadAttempted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.path), "prepare created the durable copy")
        XCTAssertEqual(outcome.diagnosis.locationKind, .durableStore)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), row.sha256)
        guard case .configured(let path) = ServeCommand.pinnedArtifactLoadCandidate(
            configuredPath: durable.path,
            modelID: row.modelID,
            revision: row.revision,
            expectedSHA256: row.sha256,
            artifactResolver: resolver
        ) else {
            return XCTFail("serve must find the configured durable copy")
        }
        XCTAssertEqual(path, durable.path)
    }

    // MARK: Trust path

    func testSignedRowResolvesFromBakedSignedCatalogByModelID() async throws {
        let inputs = AutotuneStaticInputs(fetch: { _ in throw URLError(.notConnectedToInternet) })

        let row = try await ModelArtifactSignedRowResolver.resolve(
            key: "mlx-community/Qwen3.6-27B-4bit",
            staticInputs: inputs
        )

        XCTAssertEqual(row.catalogKey, "qwen/qwen3.6-27b")
        XCTAssertEqual(row.catalogSource, "baked_signed")
        XCTAssertEqual(row.modelID, "mlx-community/Qwen3.6-27B-4bit")
        XCTAssertEqual(row.sha256.count, 64)
        XCTAssertEqual(row.catalogDigest.count, 64)
    }

    func testSignedRowResolverRejectsUnknownKeyAndUnsignedFeed() async throws {
        let offline = AutotuneStaticInputs(fetch: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await ModelArtifactSignedRowResolver.resolve(key: "nobody/not-a-model", staticInputs: offline)
            XCTFail("unknown key must be refused")
        } catch let error as ModelArtifactSignedRowError {
            XCTAssertEqual(error, .unknownModel("nobody/not-a-model"))
        }

        let unsigned = AutotuneStaticInputs(fetch: { url in
            url.path.hasSuffix(".sig") ? Data("{}".utf8) : Data(#"{"version":"forged","rows":{}}"#.utf8)
        })
        do {
            _ = try await ModelArtifactSignedRowResolver.resolve(key: "qwen/qwen3.6-27b", staticInputs: unsigned)
            XCTFail("an unsigned feed must be refused")
        } catch let error as ModelArtifactSignedRowError {
            XCTAssertEqual(error, .catalogUntrusted("catalog_integrity_failure"))
        }
    }

    // MARK: Identity

    func testServedIdentityMapsStatusCatalogBlock() {
        let hash = String(repeating: "c", count: 64)
        let identity = ModelServedIdentity(status: [
            "model": "qwen/qwen3.6-27b",
            "model_hash": hash,
            "model_hash_algorithm": ModelArtifactIdentity.snapshotManifestV1,
            "coordinator": ["identity_admission_mode": "catalog"],
            "catalog": [
                "state": "live_verified",
                "catalog_key": "qwen/qwen3.6-27b",
                "model_id": "mlx-community/Qwen3.6-27B-4bit",
                "model_revision": revision,
                "artifact_sha256": hash,
                "release_id": "published-x",
                "digest": String(repeating: "d", count: 64),
            ],
        ])

        XCTAssertEqual(identity.buyerModelKey, "qwen/qwen3.6-27b")
        XCTAssertEqual(identity.catalogModelID, "mlx-community/Qwen3.6-27B-4bit")
        XCTAssertEqual(identity.identityAdmissionMode, "catalog")
        XCTAssertEqual(identity.hashesAgree, true)
        XCTAssertTrue(identity.humanText.contains("hashes agree:           yes"))
        XCTAssertNil(ModelServedIdentity(status: [:]).hashesAgree)
    }

    // MARK: Commands

    func testCommandsAreRegisteredWithHelp() throws {
        let names = ModelsCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("verify-artifact"))
        XCTAssertTrue(names.contains("identity"))
        XCTAssertTrue(names.contains("prepare"))

        let verify = try ModelsVerifyArtifactCommand.parse(["qwen/qwen3.6-27b", "--json"])
        XCTAssertEqual(verify.model, "qwen/qwen3.6-27b")
        XCTAssertTrue(verify.emitJSON)
        XCTAssertTrue(ModelsVerifyArtifactCommand.helpMessage().contains("revision_pin"))

        let prepare = try ModelsPrepareCommand.parse(["qwen/qwen3.6-27b", "--repair-cache"])
        XCTAssertTrue(prepare.repairCache)
        XCTAssertNil(prepare.profile)
        XCTAssertTrue(ModelsPrepareCommand.helpMessage().contains("--repair-cache"))
    }

    func testLaneAProfileRejectsRepairCache() async throws {
        let command = try ModelsPrepareCommand.parse([
            Build1LaneAPrepareProfile.catalogKey,
            "--json",
            "--yes",
            "--profile", Build1LaneAPrepareProfile.profile,
            "--repair-cache",
            "--coordinator-url", "ws://127.0.0.1:19090/ws/provider",
        ])
        do {
            try await command.run()
            XCTFail("lane A must refuse --repair-cache")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(2))
        }
    }

    // MARK: Serve resolution order, config errors, redaction (#1689 audit)

    func testConfiguredPathIsWhatIsVerifiedEvenWhenTheDurableCopyVerifies() throws {
        let (resolver, root) = try makeResolver()
        let good = root.appendingPathComponent("good", isDirectory: true)
        try writeCompleteSnapshot(at: good)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: good))
        let durable = try resolver.durableStore.artifactURL(modelID: row.modelID, revision: row.revision, sha256: row.sha256)
        try FileManager.default.createDirectory(at: durable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: good, to: durable)
        let configured = root.appendingPathComponent("configured", isDirectory: true)
        try writeCompleteSnapshot(at: configured)
        try Data("extra".utf8).write(to: configured.appendingPathComponent("extra.txt"))

        let diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver, configuredArtifactPath: configured.path)

        XCTAssertEqual(diagnosis.verdict, .mismatch, "serve loads an existing configured path and never falls back")
        XCTAssertEqual(diagnosis.locationKind, .configuredPath)
        XCTAssertEqual(diagnosis.localPath?.path, configured.path)
    }

    func testMissingConfiguredPathFallsBackToTheDurableCopyLikeServe() throws {
        let (resolver, root) = try makeResolver()
        let good = root.appendingPathComponent("good", isDirectory: true)
        try writeCompleteSnapshot(at: good)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: good))
        let durable = try resolver.durableStore.artifactURL(modelID: row.modelID, revision: row.revision, sha256: row.sha256)
        try FileManager.default.createDirectory(at: durable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: good, to: durable)

        let diagnosis = ModelArtifactDiagnostics.diagnose(
            row: row,
            resolver: resolver,
            configuredArtifactPath: root.appendingPathComponent("gone").path
        )

        XCTAssertEqual(diagnosis.verdict, .match)
        XCTAssertEqual(diagnosis.locationKind, .durableStore)
    }

    func testVerifyArtifactRefusesAMalformedExplicitConfig() async throws {
        let config = try tempDir().appendingPathComponent("config.yaml")
        try Data("model: [unterminated\n".utf8).write(to: config)
        let command = try ModelsVerifyArtifactCommand.parse(["qwen/qwen3.6-27b", "--config", config.path])

        do {
            try await command.run()
            XCTFail("a malformed explicit config must refuse")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(2))
        }
    }

    func testCatalogPrepareRefusesAMalformedExplicitConfigBeforeAnyWork() async throws {
        let config = try tempDir().appendingPathComponent("config.yaml")
        try Data("model_artifact_root: [unterminated\n".utf8).write(to: config)
        let command = try ModelsPrepareCommand.parse(["qwen/qwen3.6-27b", "--repair-cache", "--config", config.path])

        do {
            try await command.run()
            XCTFail("a malformed explicit config must refuse before repair or download")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(2))
        }
    }

    func testCatalogProfileRejectsLaneAOnlyOptions() async throws {
        for extra in [["--timeout-seconds", "30"], ["--coordinator-url", "ws://127.0.0.1:19090/ws/provider"], ["--yes"]] {
            let command = try ModelsPrepareCommand.parse(["qwen/qwen3.6-27b", "--profile", "catalog"] + extra)
            do {
                try await command.run()
                XCTFail("\(extra[0]) does not apply to --profile catalog and must be refused")
            } catch let exit as ExitCode {
                XCTAssertEqual(exit, ExitCode(2), extra[0])
            }
        }
    }

    func testHumanOutputRedactsLocalPathsAndEvidence() throws {
        let (resolver, root) = try makeResolver()
        let configured = root.appendingPathComponent("elsewhere", isDirectory: true)
        try writeCompleteSnapshot(at: configured)
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        var diagnosis = ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver, configuredArtifactPath: configured.path)
        diagnosis.evidence.append("canonical hash failed at \(configured.path)/model.safetensors")
        diagnosis.evidence.append("home copy at \(NSHomeDirectory())/models/x")

        let text = ModelArtifactDiagnostics.humanText(diagnosis)

        XCTAssertFalse(text.contains(configured.path), text)
        XCTAssertFalse(text.contains(NSHomeDirectory() + "/"), text)
        XCTAssertTrue(text.contains("<external>/elsewhere"), text)
    }

    // MARK: prepare-catalog (SPEC-010-R008 v1.17, SPEC-044-R014-4)

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ModelPreparationTransactionEvent] = []
        var events: [ModelPreparationTransactionEvent] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func append(_ event: ModelPreparationTransactionEvent) {
            lock.lock(); stored.append(event); lock.unlock()
        }
    }

    private static let prepareTransactionID = "3f0c6b1e-8c2d-4f6a-9b1e-2d3c4b5a6f70"

    private func prepareCatalog(
        row: ModelArtifactSignedRow?,
        resolver: CachedModelArtifactResolver,
        cancellation: ModelsPrepareCatalogCancellation = ModelsPrepareCatalogCancellation(),
        configuredArtifactPath: @escaping @Sendable (String) -> String? = { _ in nil },
        prepare: (@Sendable (ModelArtifactSignedRow, CachedModelArtifactResolver, String?, String?) async -> ModelPrepareOutcome)? = nil,
        runLock: (@Sendable () -> (@Sendable () -> Void)?)? = nil
    ) async -> (Int32, [ModelPreparationTransactionEvent]) {
        let log = EventLog()
        let sink = ModelsPrepareCatalogEventSink(transactionID: Self.prepareTransactionID) { log.append($0) }
        var dependencies = ModelsPrepareCatalogRunner.Dependencies.live
        dependencies.resolveRow = { key in
            guard let row else { throw ModelArtifactSignedRowError.unknownModel(key) }
            return row
        }
        if let prepare { dependencies.prepare = prepare }
        dependencies.acquireRunLock = runLock ?? { { } }
        dependencies.progressIntervalNanoseconds = 10_000_000
        let exit = await ModelsPrepareCatalogRunner.run(
            key: "namespace/model",
            resolver: resolver,
            config: nil,
            configuredArtifactPath: configuredArtifactPath,
            sink: sink,
            cancellation: cancellation,
            dependencies: dependencies
        )
        return (exit, log.events)
    }

    private func assertOneTransaction(_ events: [ModelPreparationTransactionEvent], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(events.map(\.eventSequence), Array(1...max(1, events.count)), file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.transactionID == Self.prepareTransactionID }, file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.transactionKind == .prepareModel }, file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.modelKey == "namespace/model" }, file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.schema == "model_catalog_transaction_event.v1" }, file: file, line: line)
    }

    func testPrepareCatalogDownloadsAndReportsQueuedRunningSucceeded() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: served))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))

        let (exit, events) = await prepareCatalog(row: row, resolver: resolver)

        XCTAssertEqual(exit, 0)
        assertOneTransaction(events)
        XCTAssertEqual(events.first?.state, .queued)
        XCTAssertEqual(events.dropFirst().first?.state, .running)
        XCTAssertEqual(events.dropFirst().first?.progress?.stageLabelKey, "downloading")
        XCTAssertEqual(events.dropFirst().first?.progress?.heartbeat, true)
        XCTAssertEqual(events.last?.state, .succeeded)
        XCTAssertEqual(events.filter { [.succeeded, .failed, .cancelled, .timedOut].contains($0.state) }.count, 1)
        XCTAssertEqual(ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver).locationKind, .durableStore)
    }

    func testPrepareCatalogReportsHashMismatchAsVerificationFailure() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))

        let (exit, events) = await prepareCatalog(row: row, resolver: resolver)

        XCTAssertEqual(exit, 5)
        assertOneTransaction(events)
        XCTAssertEqual(events.last?.state, .failed)
        XCTAssertEqual(events.last?.errorCode, .verificationFailed)
    }

    func testPrepareCatalogReportsATransferFailure() async throws {
        let downloader = HuggingFaceSnapshotDownloader(
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            download: { _ in throw URLError(.notConnectedToInternet) }
        )
        let (resolver, _) = try makeResolver(downloader: downloader)
        let row = makeRow(sha256: String(repeating: "1", count: 64))

        let (exit, events) = await prepareCatalog(row: row, resolver: resolver)

        XCTAssertEqual(exit, 4)
        assertOneTransaction(events)
        XCTAssertEqual(events.last?.state, .failed)
        XCTAssertEqual(events.last?.errorCode, .transferFailed)
    }

    func testPrepareCatalogRefusesAnUnknownKeyBeforeAnyWork() async throws {
        let (resolver, _) = try makeResolver()

        let (exit, events) = await prepareCatalog(row: nil, resolver: resolver)

        XCTAssertEqual(exit, 4)
        XCTAssertEqual(events.map(\.state), [.failed])
        XCTAssertEqual(events.first?.errorCode, .authorityUnavailable)
    }

    func testPrepareCatalogCancelStopsTheDownloadRemovesPartialsAndReportsCancelled() async throws {
        let (resolver, _) = try makeResolver()
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let cancellation = ModelsPrepareCatalogCancellation()
        let started = expectation(description: "download started")
        let (exit, events) = await withTaskGroup(of: (Int32, [ModelPreparationTransactionEvent])?.self) { group in
            group.addTask {
                await self.prepareCatalog(
                    row: row,
                    resolver: resolver,
                    cancellation: cancellation,
                    prepare: { row, resolver, _, config in
                        started.fulfill()
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 5_000_000)
                        }
                        return await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false, config: config)
                    }
                )
            }
            group.addTask {
                await self.fulfillment(of: [started], timeout: 5)
                try? await Task.sleep(nanoseconds: 30_000_000)
                cancellation.request()
                return nil
            }
            var result: (Int32, [ModelPreparationTransactionEvent]) = (-1, [])
            for await value in group { if let value { result = value } }
            return result
        }

        XCTAssertEqual(exit, 130)
        assertOneTransaction(events)
        XCTAssertEqual(Array(events.suffix(2).map(\.state)), [.cancelRequested, .cancelled])
        XCTAssertFalse(events.dropLast(2).contains { $0.state == .cancelRequested || $0.state == .cancelled })
        XCTAssertNil(events.last?.warningCode, "nothing is left behind")
    }

    func testPrepareCatalogNeverDeletesLeftoversAndReportsThem() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: served))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))
        let snapshots = resolver.snapshotURL(modelID: row.modelID, revision: row.revision).deletingLastPathComponent()
        let old = snapshots.appendingPathComponent(".download-\(revision)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        let (exit, events) = await prepareCatalog(row: row, resolver: resolver)
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(events.last?.state, .succeeded)
        XCTAssertEqual(events.last?.warningCode, .stagingCleanupRequired, "an earlier run's leftover is reported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "and never deleted")

        // Another run's staging that appears while this one is cancelled is
        // never this command's to delete either.
        try FileManager.default.removeItem(at: old)
        let other = snapshots.appendingPathComponent(".download-\(revision)-\(UUID().uuidString)", isDirectory: true)
        let cancellation = ModelsPrepareCatalogCancellation()
        let (cancelExit, cancelEvents) = await prepareCatalog(
            row: makeRow(sha256: String(repeating: "1", count: 64)),
            resolver: resolver,
            cancellation: cancellation,
            prepare: { _, _, _, _ in
                try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                cancellation.request()
                return ModelPrepareOutcome(
                    finalState: .incomplete,
                    diagnosis: ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver),
                    requiredBytes: nil,
                    availableBytes: nil,
                    partialsFound: [],
                    partialsRemoved: [],
                    downloadAttempted: true,
                    error: "cancelled",
                    retryCommand: nil
                )
            }
        )
        XCTAssertEqual(cancelExit, 130)
        assertOneTransaction(cancelEvents)
        XCTAssertEqual(Array(cancelEvents.suffix(2).map(\.state)), [.cancelRequested, .cancelled])
        XCTAssertEqual(cancelEvents.last?.warningCode, .stagingCleanupRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testPrepareCatalogRefusesASymlinkedModelCachePath() async throws {
        let (resolver, _) = try makeResolver()
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let repository = resolver.snapshotURL(modelID: row.modelID, revision: row.revision)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outside = try tempDir()
        try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)

        let (exit, events) = await prepareCatalog(row: row, resolver: resolver)

        XCTAssertEqual(exit, 4)
        XCTAssertEqual(events.map(\.state), [.failed])
        XCTAssertEqual(events.first?.errorCode, .unsafeFilesystemObject)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [], "nothing is written outside the cache")
    }

    func testPrepareCatalogRunsOneAtATime() async throws {
        let (resolver, _) = try makeResolver()
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let (exit, events) = await prepareCatalog(row: row, resolver: resolver, runLock: { nil })
        XCTAssertEqual(exit, 4)
        XCTAssertEqual(events.map(\.state), [.failed])
        XCTAssertEqual(events.first?.errorCode, .operationConflict)

        let lock = ModelsPrepareCatalogRunner.Dependencies.live.acquireRunLock
        let release = try XCTUnwrap(lock())
        XCTAssertNil(lock(), "a second run is refused while the first holds the lock")
        release()
        let again = try XCTUnwrap(lock())
        again()
    }

    func testPrepareCatalogHonoursAConfiguredServingArtifact() async throws {
        let served = try tempDir()
        try writeCompleteSnapshot(at: served)
        let row = makeRow(sha256: try ModelArtifactVerifier.canonicalArtifactHash(directory: served))
        let (resolver, _) = try makeResolver(downloader: try fakeDownloader(serving: served))
        let corrupt = try tempDir().appendingPathComponent(revision, isDirectory: true)
        try writeCompleteSnapshot(at: corrupt, truncateWeights: true)

        let (exit, events) = await prepareCatalog(
            row: row,
            resolver: resolver,
            configuredArtifactPath: { $0 == "namespace/model" ? corrupt.path : nil }
        )
        XCTAssertNotEqual(exit, 0, "serve loads the configured copy, so a verified durable copy is not ready")
        XCTAssertEqual(events.last?.state, .failed)
    }

    func testDownloaderDiskSpaceFailureIsReportedAsDiskSpace() throws {
        let (resolver, _) = try makeResolver()
        let row = makeRow(sha256: String(repeating: "1", count: 64))
        let outcome = ModelPrepareOutcome(
            finalState: .incomplete,
            diagnosis: ModelArtifactDiagnostics.diagnose(row: row, resolver: resolver),
            requiredBytes: nil,
            availableBytes: nil,
            partialsFound: [],
            partialsRemoved: [],
            downloadAttempted: true,
            error: "not enough free disk space to download namespace/model: need 9 GB, 2 GB available",
            retryCommand: nil
        )
        let (code, exit) = ModelsPrepareCatalogRunner.failure(outcome)
        XCTAssertEqual(code, .insufficientDiskSpace)
        XCTAssertEqual(exit, 4)
    }

    func testPrepareCatalogCommandParsesAndRefusesBadInputBeforeWork() async throws {
        let names = ModelsCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("prepare-catalog"))
        let command = try ModelsPrepareCatalogCommand.parse([
            "qwen/qwen3-8b", "--transaction-id", Self.prepareTransactionID, "--json",
        ])
        XCTAssertEqual(command.catalogKey, "qwen/qwen3-8b")
        XCTAssertTrue(command.emitJSON)
        XCTAssertThrowsError(try ModelsPrepareCatalogCommand.parse(["qwen/qwen3-8b", "--json"]))

        for arguments in [
            ["qwen/qwen3-8b", "--transaction-id", Self.prepareTransactionID],
            ["qwen/qwen3-8b", "--transaction-id", "not-a-uuid", "--json"],
            ["qwen/qwen3-8b", "--transaction-id", Self.prepareTransactionID.uppercased(), "--json"],
        ] {
            let refused = try ModelsPrepareCatalogCommand.parse(arguments)
            do {
                try await refused.run()
                XCTFail("expected refusal for \(arguments)")
            } catch let error as ExitCode {
                XCTAssertEqual(error.rawValue, 2)
            }
        }
    }

    // MARK: Fixtures

    private func makeRow(sha256: String) -> ModelArtifactSignedRow {
        ModelArtifactSignedRow(
            catalogKey: "namespace/model",
            buyerModelKey: nil,
            catalogRow: CandidateCatalog.Row(
                modelID: "namespace/model",
                modelRevision: revision,
                modelSHA256: sha256,
                minRAMGB: 1,
                minBandwidthTier: .c,
                benchGate: CandidateCatalog.BenchGate(minSustainedTPS: 1, max4KTTFTMS: 1_000),
                runtimeStatus: "recommendable",
                notes: nil
            ),
            catalogVersion: "published-test",
            catalogDigest: String(repeating: "e", count: 64),
            catalogSignerKeyID: "test-signer",
            catalogSource: "baked_signed",
            artifactSizeBytes: nil,
            artifactFeedReleaseID: nil,
            artifactFeedSHA256: nil
        )
    }

    private func directoryBytes(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url.resolvingSymlinksInPath()
    }

    private func makeResolver(
        downloader: HuggingFaceSnapshotDownloader = HuggingFaceSnapshotDownloader(
            fetch: { _ in throw URLError(.cancelled) },
            download: { _ in throw URLError(.cancelled) }
        )
    ) throws -> (CachedModelArtifactResolver, URL) {
        let root = try tempDir()
        let hub = root.appendingPathComponent("hub", isDirectory: true)
        let durable = root.appendingPathComponent("durable", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        return (CachedModelArtifactResolver(hubRoot: hub, durableRoot: durable, downloader: downloader), root)
    }

    private static let safetensorsHeader = Data(#"{"w":{"dtype":"F32","shape":[4],"data_offsets":[0,16]}}"#.utf8)

    private func writeCompleteSnapshot(at directory: URL, truncateWeights: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Self.safetensorsBytes(truncated: truncateWeights)
            .write(to: directory.appendingPathComponent("model.safetensors"))
    }

    private static func safetensorsBytes(truncated: Bool) -> Data {
        var length = UInt64(safetensorsHeader.count).littleEndian
        var data = Data(bytes: &length, count: 8)
        data.append(safetensorsHeader)
        data.append(Data(repeating: 7, count: truncated ? 8 : 16))
        return data
    }

    private func fakeDownloader(serving directory: URL) throws -> HuggingFaceSnapshotDownloader {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        let siblings = try names.map { name -> [String: Any] in
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            let size = try XCTUnwrap(attributes[.size] as? NSNumber)
            return ["rfilename": name, "size": size]
        }
        let listing = try JSONSerialization.data(withJSONObject: ["siblings": siblings])
        return HuggingFaceSnapshotDownloader(
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (listing, response)
            },
            download: { request in
                let name = request.url!.lastPathComponent
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-diagnostics-download-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: temporary)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (temporary, response)
            }
        )
    }
}
