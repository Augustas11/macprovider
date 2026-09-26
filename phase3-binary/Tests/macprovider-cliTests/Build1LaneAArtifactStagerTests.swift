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
            reauthorize: { authority },
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

        // The private published-inventory record describes exactly the adopted
        // tuple, bound to this root's identity, with a re-verifiable receipt.
        XCTAssertFalse(result.privateRecord.reusedExistingRecord)
        XCTAssertEqual(result.privateRecord.inventoryGeneration, 1)
        let inventory = try XCTUnwrap(readPrivateInventory(durable: roots.durable))
        XCTAssertEqual(inventory.generation, 1)
        XCTAssertEqual(inventory.record.targets.count, 1)
        let target = try XCTUnwrap(inventory.record.targets.first)
        XCTAssertEqual(target.artifactIdentityDigest, result.privateRecord.artifactIdentityDigest)
        XCTAssertEqual(target.displayModelID, authority.modelID)
        XCTAssertEqual(target.modelRevision, authority.revision)
        XCTAssertEqual(target.artifactID, authority.artifactID)
        XCTAssertEqual(target.releaseID, authority.releaseID)
        XCTAssertEqual(target.modelKey, authority.catalogKey)
        XCTAssertEqual(target.eventModelKey, authority.catalogKey)
        XCTAssertEqual(target.rootIdentityDigest, inventory.locator.rootIdentityDigest)
        XCTAssertEqual(target.rootIdentityDigest, result.privateRecord.rootIdentityDigest)
        XCTAssertEqual(target.receiptSHA256, result.privateRecord.receiptSHA256)
        XCTAssertEqual(target.estimatedBytes, Int64(payload.utf8.count))
        XCTAssertEqual(target.keepSetStatus, .protected)
        XCTAssertEqual(target.protectedReason, Build1LaneAPreparationRecorder.protectedReason)
        XCTAssertFalse(target.cleanup.available)
        XCTAssertNil(target.cleanup.transactionKind)
        XCTAssertNil(target.cleanup.artifactIdentityDigest)
        let receipt = try readPrivateReceipt(durable: roots.durable, artifactIdentityDigest: target.artifactIdentityDigest)
        XCTAssertEqual(receipt.sha256, target.receiptSHA256)
        XCTAssertEqual(receipt.record.root, inventory.locator)
        XCTAssertEqual(receipt.record.eventModelKey, authority.catalogKey)
        XCTAssertEqual(receipt.record.tuple.artifactSHA256, authority.hash)
        XCTAssertEqual(receipt.record.tuple.displayModelID, authority.modelID)
        XCTAssertEqual(receipt.record.tuple.modelRevision, authority.revision)
        XCTAssertEqual(receipt.record.tuple.artifactID, authority.artifactID)
        XCTAssertEqual(receipt.record.tuple.releaseID, authority.releaseID)
        XCTAssertEqual(receipt.record.tuple.estimatedBytes, Int64(authority.sizeBytes))
        XCTAssertEqual(
            try ModelPreparationContracts.artifactIdentityDigest(
                displayModelID: authority.modelID,
                modelRevision: authority.revision,
                artifactID: authority.artifactID,
                releaseID: authority.releaseID,
                rootIdentityDigest: inventory.locator.rootIdentityDigest,
                receiptSHA256: receipt.sha256
            ),
            target.artifactIdentityDigest
        )
        try assertMode(privateInventoryURL(durable: roots.durable), type: S_IFREG, mode: 0o600)
        try assertMode(privateReceiptURL(durable: roots.durable, artifactIdentityDigest: target.artifactIdentityDigest), type: S_IFREG, mode: 0o600)
        try assertMode(roots.durable.appendingPathComponent(Build1LaneAPreparationRecorder.authorityLeaf, isDirectory: true), type: S_IFDIR, mode: 0o700)
        // The durable artifact tree itself is untouched by the record.
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), authority.hash)
        // A digest-only record: no path, nonce, or feed body leaks into it.
        let inventoryBytes = try Data(contentsOf: privateInventoryURL(durable: roots.durable))
        XCTAssertFalse(String(decoding: inventoryBytes, as: UTF8.self).contains(roots.hub.path))
    }

    func testReuseWritesMissingPrivateRecordAndSecondRunReusesIt() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "recorded-on-reuse")
        let store = DurableModelArtifactStore(root: roots.durable)
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertNil(try readPrivateInventory(durable: roots.durable, bootstrapIfMissing: false))
        let makeStager = {
            Build1LaneAArtifactStager(
                resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
                reauthorize: { authority },
                diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
            )
        }

        let first = try await makeStager().stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertTrue(first.reusedDurableArtifact)
        XCTAssertFalse(first.privateRecord.reusedExistingRecord)
        XCTAssertEqual(first.privateRecord.inventoryGeneration, 1)
        let firstBytes = try Data(contentsOf: privateInventoryURL(durable: roots.durable))

        let second = try await makeStager().stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertTrue(second.reusedDurableArtifact)
        XCTAssertTrue(second.privateRecord.reusedExistingRecord)
        XCTAssertEqual(second.privateRecord.inventoryGeneration, 1)
        XCTAssertEqual(second.privateRecord.artifactIdentityDigest, first.privateRecord.artifactIdentityDigest)
        XCTAssertEqual(second.privateRecord.receiptSHA256, first.privateRecord.receiptSHA256)
        XCTAssertEqual(try Data(contentsOf: privateInventoryURL(durable: roots.durable)), firstBytes, "a reused record is never rewritten")
        let inventory = try XCTUnwrap(readPrivateInventory(durable: roots.durable))
        XCTAssertEqual(inventory.record.targets.count, 1)
    }

    func testDistinctReleaseAppendsSecondTargetInDigestOrder() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "two-releases")
        let store = DurableModelArtifactStore(root: roots.durable)
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        var rebound = authority
        rebound.releaseID = "test-release-2"
        let stager = { (a: Build1LaneAArtifactAuthority) in
            Build1LaneAArtifactStager(
                resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
                reauthorize: { a },
                diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
            )
        }

        let first = try await stager(authority).stageAndAdopt(authority: authority) { _, _, _ in }
        let second = try await stager(rebound).stageAndAdopt(authority: rebound) { _, _, _ in }

        XCTAssertEqual(first.privateRecord.inventoryGeneration, 1)
        XCTAssertEqual(second.privateRecord.inventoryGeneration, 2)
        XCTAssertFalse(second.privateRecord.reusedExistingRecord)
        XCTAssertNotEqual(first.privateRecord.artifactIdentityDigest, second.privateRecord.artifactIdentityDigest)
        let inventory = try XCTUnwrap(readPrivateInventory(durable: roots.durable))
        XCTAssertEqual(inventory.generation, 2)
        XCTAssertEqual(inventory.record.targets.map(\.releaseID).sorted(), ["test-release", "test-release-2"])
        XCTAssertEqual(inventory.record.targets.map(\.artifactIdentityDigest), inventory.record.targets.map(\.artifactIdentityDigest).sorted())
    }

    func testRecorderRefusesMismatchedAdoptedDigestOrMissingDurableArtifact() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "mismatch-guard")
        try DurableModelArtifactStore(root: roots.durable).ensureRoot()
        let recorder = Build1LaneAPreparationRecorder(durableRoot: roots.durable)

        // Nothing adopted yet: no durable directory for the tuple.
        var session = try recorder.open()
        XCTAssertThrowsError(try session.record(authority: authority, adoptedSHA256: authority.hash, adoptedBytes: 1)) { error in
            XCTAssertEqual(error as? Build1LaneAPreparationRecordError, .adoptedArtifactMismatch)
        }
        session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateInventoryURL(durable: roots.durable).path))

        // Adopted, but the digest offered for the record is not the signed one.
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try DurableModelArtifactStore(root: roots.durable).adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        session = try recorder.open()
        XCTAssertThrowsError(try session.record(authority: authority, adoptedSHA256: String(repeating: "0", count: 64), adoptedBytes: 1)) { error in
            XCTAssertEqual(error as? Build1LaneAPreparationRecordError, .adoptedArtifactMismatch)
        }
        // A tuple whose durable directory does not exist under this root
        // (different revision) cannot be recorded either.
        var otherRevision = authority
        otherRevision.revision = "0000000000000000000000000000000000000000"
        XCTAssertThrowsError(try session.record(authority: otherRevision, adoptedSHA256: otherRevision.hash, adoptedBytes: 1)) { error in
            XCTAssertEqual(error as? Build1LaneAPreparationRecordError, .adoptedArtifactMismatch)
        }
        var unsupportedProfile = authority
        unsupportedProfile.catalogKey = "other/model-key"
        XCTAssertThrowsError(try session.record(authority: unsupportedProfile, adoptedSHA256: unsupportedProfile.hash, adoptedBytes: 1)) { error in
            XCTAssertEqual(error as? Build1LaneAPreparationRecordError, .adoptedArtifactMismatch)
        }
        session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateInventoryURL(durable: roots.durable).path))
        let objects = roots.durable
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.objectsLeaf, isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: objects.path), [])
    }

    func testDanglingReceiptFailsClosedBeforeTransferWithoutMutatingInventory() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "dangling-receipt")
        let counter = Build1LaneACounter()
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.fakeDownloader(payload: payload, counter: counter))
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
        let result = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
        let before = try Data(contentsOf: privateInventoryURL(durable: roots.durable))
        try FileManager.default.removeItem(at: privateReceiptURL(durable: roots.durable, artifactIdentityDigest: result.privateRecord.artifactIdentityDigest))

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("a recorded tuple whose receipt is gone must not be re-recorded silently")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .privateInventoryInvalid = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(counter.value, 1, "no second transfer")
        XCTAssertEqual(try Data(contentsOf: privateInventoryURL(durable: roots.durable)), before)
    }

    func testCancellationAtCommitBoundaryLeavesDurableCopyWithoutPrivateRecord() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "cancel-after-adopt")
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter()))
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
        let work = Task {
            try await stager.stageAndAdopt(authority: authority) { stage, _, _ in
                // Models SIGINT landing right after the artifact_adopted frame.
                if stage == .adopted { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }

        do {
            _ = try await work.value
            XCTFail("cancellation at the commit boundary must not report success")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .cancelledAfterAdoption)
        }
        let durable = try resolver.durableStore.artifactURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: durable), authority.hash, "durable copy is retained")
        assertNoPrivateRecord(durable: roots.durable)

        // The next run reuses the copy and records it.
        let repaired = try await Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            reauthorize: { authority },
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        ).stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertTrue(repaired.reusedDurableArtifact)
        XCTAssertFalse(repaired.privateRecord.reusedExistingRecord)
        XCTAssertEqual(repaired.privateRecord.inventoryGeneration, 1)
    }

    func testExpiredDeadlineAtCommitBoundaryLeavesDurableCopyWithoutPrivateRecord() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "deadline-after-adopt")
        let store = DurableModelArtifactStore(root: roots.durable)
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        // Leave enough headroom for this test process to bootstrap its private
        // store even when the suite runs every test in parallel. The progress
        // callback then deterministically carries execution past the deadline
        // at the post-adoption commit boundary.
        let deadline = Date(timeIntervalSinceNow: 5)
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            reauthorize: { authority },
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) },
            deadline: deadline
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in
                if stage == .adopted {
                    while Date() < deadline { usleep(10_000) }
                }
            }
            XCTFail("deadline at the commit boundary must not report success")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .timedOutAfterAdoption)
        }
        XCTAssertTrue(store.isModelMaterialized(modelID: authority.modelID))
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testProgressSinkFailureAfterAdoptionLeavesNoPrivateRecord() async throws {
        struct SinkFailure: Error {}
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "sink-fails-after-adopt")
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter()))
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in
                if stage == .adopted { throw SinkFailure() }
            }
            XCTFail("sink failure must propagate")
        } catch is SinkFailure {
        }
        XCTAssertTrue(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testRecorderRefusesDurableBytesThatDoNotHashToAuthority() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "signed-bytes-for-record")
        let store = DurableModelArtifactStore(root: roots.durable)
        try store.ensureRoot()
        // Wrong bytes already sit under the hash-qualified durable path.
        let durable = try store.artifactURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        try FileManager.default.createDirectory(at: durable, withIntermediateDirectories: true)
        try Data("not-the-signed-bytes".utf8).write(to: durable.appendingPathComponent("weights.bin"))
        let recorder = Build1LaneAPreparationRecorder(durableRoot: roots.durable)

        let session = try recorder.open()
        defer { session.close() }
        XCTAssertThrowsError(try session.record(authority: authority, adoptedSHA256: authority.hash, adoptedBytes: 20)) { error in
            XCTAssertEqual(error as? Build1LaneAPreparationRecordError, .adoptedArtifactMismatch)
        }
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testDanglingReceiptOnOlderTargetRefusesBeforeDistinctReleaseTransfer() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "older-target")
        let counter = Build1LaneACounter()
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.fakeDownloader(payload: payload, counter: counter))
        let first = try await Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
            .stageAndAdopt(authority: authority) { _, _, _ in }
        let before = try Data(contentsOf: privateInventoryURL(durable: roots.durable))
        try FileManager.default.removeItem(at: privateReceiptURL(durable: roots.durable, artifactIdentityDigest: first.privateRecord.artifactIdentityDigest))

        var rebound = authority
        rebound.releaseID = "test-release-2"
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            reauthorize: { rebound },
            diskProbe: { _ in
                XCTFail("invalid existing inventory must refuse before probing disk")
                return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
            }
        )
        do {
            _ = try await stager.stageAndAdopt(authority: rebound) { _, _, _ in }
            XCTFail("an inventory with a dangling receipt must not be appended to")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .privateInventoryInvalid = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try Data(contentsOf: privateInventoryURL(durable: roots.durable)), before)
    }

    func testReuseRefusesRecordedTupleWhoseFeedSizeOrBytesDiffer() async throws {
        let cases: [(String, (inout Build1LaneAArtifactAuthority) -> Void, Int64?)] = [
            ("feed size", { $0.sizeBytes = 999_999 }, nil),
            ("measured bytes", { _ in }, 5),
        ]
        for (label, mutate, seededBytes) in cases {
            let roots = try makeRoots()
            let (authority, payload) = try makeAuthority(payload: "reuse-guard-\(label)")
            let store = DurableModelArtifactStore(root: roots.durable)
            let seed = try tempDir()
            try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
            _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
            // Seed a record that binds to the same artifact identity fields but
            // was made with a different feed size or measured byte count.
            var seeded = authority
            mutate(&seeded)
            let recorder = Build1LaneAPreparationRecorder(durableRoot: roots.durable)
            let session = try recorder.open()
            _ = try session.record(authority: seeded, adoptedSHA256: seeded.hash, adoptedBytes: seededBytes ?? Int64(payload.utf8.count))
            session.close()
            let before = try Data(contentsOf: privateInventoryURL(durable: roots.durable))

            let stager = Build1LaneAArtifactStager(
                resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
                reauthorize: { authority },
                diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
            )
            do {
                _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
                XCTFail("\(label): a recorded tuple that does not match the authority must not be reused")
            } catch let error as Build1LaneAArtifactStagingError {
                guard case .privateInventoryInvalid = error else { return XCTFail("\(label): unexpected error \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: privateInventoryURL(durable: roots.durable)), before, label)
        }
    }

    func testPersistedPrivateRecordsCarryRootLocatorButNeverTheRootNonce() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "nonce-boundary")
        let resolver = CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter()))
        let result = try await Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
            .stageAndAdopt(authority: authority) { _, _, _ in }

        let identityURL = roots.durable
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent("root.identity")
        let identity = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: try Data(contentsOf: identityURL),
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        try assertMode(identityURL, type: S_IFREG, mode: 0o600)
        // The inventory is stored inside a private-state envelope (base64
        // payload); inspect both the envelope bytes and the decoded payload.
        let envelopeBytes = try Data(contentsOf: privateInventoryURL(durable: roots.durable))
        let envelope = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: envelopeBytes,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        let inventory = String(decoding: envelope.payload, as: UTF8.self)
        let receipt = String(decoding: try Data(contentsOf: privateReceiptURL(durable: roots.durable, artifactIdentityDigest: result.privateRecord.artifactIdentityDigest)), as: UTF8.self)
        let identityDigest = try identity.digest
        XCTAssertFalse(String(decoding: envelopeBytes, as: UTF8.self).contains(identity.nonceHex))
        for text in [inventory, receipt] {
            XCTAssertFalse(text.contains(identity.nonceHex), "the root nonce stays in root.identity only")
            XCTAssertFalse(text.contains(roots.hub.path), "no staging path")
            XCTAssertTrue(text.contains(identityDigest), "records bind to the root identity digest")
        }
        // SPEC-044 reopening records carry the saved root locator (path, dev, ino).
        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationPublicationReceipt.self,
            from: try Data(contentsOf: privateReceiptURL(durable: roots.durable, artifactIdentityDigest: result.privateRecord.artifactIdentityDigest)),
            maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
        )
        XCTAssertEqual(decoded.root.canonicalPath, try ModelPreparationSecureFilesystem.canonicalPrivatePath(roots.durable))
        XCTAssertEqual(decoded.root.rootIdentityDigest, identityDigest)
        // The returned record is digests only.
        XCTAssertEqual(result.privateRecord.rootIdentityDigest, identityDigest)
        XCTAssertFalse(String(describing: result.privateRecord).contains(roots.durable.lastPathComponent))
    }

    func testHeldPrivateStateLocksRefuseBeforeTransfer() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "locked-state")
        try DurableModelArtifactStore(root: roots.durable).ensureRoot()
        let holder = Build1LaneAPreparationRecorder(durableRoot: roots.durable)
        let custody = try holder.store.bootstrapWithLockCustody().lockCustody
        defer { custody.close() }
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            reauthorize: { authority },
            diskProbe: { _ in
                XCTFail("locked private state must refuse before probing disk")
                return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
            }
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("held private-state locks must refuse")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .operationConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateInventoryURL(durable: roots.durable).path))
    }

    func testDenyOnlyAncestorACLIsTraversableButAllowACLRefusesBeforeTransfer() async throws {
        // macOS stamps `group:everyone deny delete` on `~`, `~/Library`, and
        // `~/Library/Application Support`; a default durable root must still
        // bootstrap its private state. An `allow` entry on an ancestor still
        // fails closed before any transfer.
        let base = try tempDir()
        let ancestor = base.appendingPathComponent("ancestor", isDirectory: true)
        try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try addDenyDeleteACLEntry(to: ancestor)
        let hub = base.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let durable = ancestor.appendingPathComponent("durable", isDirectory: true)
        let (authority, payload) = try makeAuthority(payload: "deny-acl-ancestor")
        let counter = Build1LaneACounter()
        let resolver = CachedModelArtifactResolver(hubRoot: hub, durableRoot: durable, downloader: Self.fakeDownloader(payload: payload, counter: counter))
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

        let result = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertEqual(result.privateRecord.inventoryGeneration, 1)
        XCTAssertNotNil(try readPrivateInventory(durable: durable))

        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try addReadACLEntry(to: allowed)
        let refusingResolver = CachedModelArtifactResolver(hubRoot: hub, durableRoot: allowed.appendingPathComponent("durable", isDirectory: true), downloader: Self.refusingDownloader())
        let refusing = Build1LaneAArtifactStager(resolver: refusingResolver, reauthorize: { authority }, diskProbe: { _ in
            XCTFail("unusable private state must refuse before probing disk")
            return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
        })
        do {
            _ = try await refusing.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("allow ACL on an ancestor must refuse")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .privateStateUnavailable(let detail) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(detail.contains("extended ACL"), detail)
        }
    }

    func testReusesVerifiedDurableArtifactWithoutTransfer() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "already-adopted")
        let store = DurableModelArtifactStore(root: roots.durable)
        let seed = try tempDir()
        try Data(payload.utf8).write(to: seed.appendingPathComponent("weights.bin"))
        _ = try store.adoptVerifiedStaging(staging: seed, modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        let reauthorizationCount = Build1LaneACounter()
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(
                hubRoot: roots.hub,
                durableRoot: roots.durable,
                downloader: Self.refusingDownloader()
            ),
            reauthorize: {
                reauthorizationCount.increment()
                return authority
            },
            diskProbe: { _ in
                XCTFail("reuse must not probe disk")
                return Build1LaneADiskProbe(availableBytes: 0, deviceID: 0)
            }
        )
        var stages: [Build1LaneAStagingStage] = []

        let result = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }

        XCTAssertTrue(result.reusedDurableArtifact)
        XCTAssertEqual(reauthorizationCount.value, 1, "reuse must reauthorize immediately before recording publication")
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
        let probeCount = Build1LaneACounter()
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in
            probeCount.increment()
            return Build1LaneADiskProbe(availableBytes: .max, deviceID: 1)
        })
        var stages: [Build1LaneAStagingStage] = []

        let result = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }

        XCTAssertFalse(result.reusedDurableArtifact)
        XCTAssertEqual(stages, [.verified, .adopted])
        XCTAssertGreaterThanOrEqual(probeCount.value, 1, "publication headroom must be re-checked before adopting an existing source")
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
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

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
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })
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
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testDiskHeadroomRequiresSpecReserveBeforeTransferAndPublication() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "bytes", sizeBytes: 1_000)
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter())
        )

        let reserve = Build1LaneAArtifactStager.publicationReserveBytes
        let sharedVolume = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in
            Build1LaneADiskProbe(availableBytes: 2_000 + reserve - 1, deviceID: 3)
        })
        do {
            _ = try await sharedVolume.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("bound root volume must hold 2 * size + reserve")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .insufficientDiskSpace(requiredBytes: 2_000 + reserve, availableBytes: 2_000 + reserve - 1))
        }

        let stagingTooSmall = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { url in
            url.path.contains("durable")
                ? Build1LaneADiskProbe(availableBytes: 2_000 + reserve, deviceID: 2)
                : Build1LaneADiskProbe(availableBytes: 1_000 + reserve - 1, deviceID: 1)
        })
        do {
            _ = try await stagingTooSmall.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("distinct staging volume must hold size + reserve")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .insufficientDiskSpace(requiredBytes: 1_000 + reserve, availableBytes: 1_000 + reserve - 1))
        }

        let probeCount = Build1LaneACounter()
        let separateVolumes = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { url in
            probeCount.increment()
            return url.path.contains("durable")
                ? Build1LaneADiskProbe(availableBytes: 2_000 + reserve, deviceID: 2)
                : Build1LaneADiskProbe(availableBytes: 1_000 + reserve, deviceID: 1)
        })
        let result = try await separateVolumes.stageAndAdopt(authority: authority) { _, _, _ in }
        XCTAssertEqual(result.sha256, authority.hash)
        XCTAssertEqual(probeCount.value, 4, "headroom is probed before transfer and again before publication")
    }

    func testExpiredDeadlineTimesOutBeforeAnyTransfer() async throws {
        let roots = try makeRoots()
        let (authority, _) = try makeAuthority(payload: "bytes")
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: roots.durable, downloader: Self.refusingDownloader()),
            reauthorize: { authority },
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
        assertNoPrivateRecord(durable: roots.durable)
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
        let stager = Build1LaneAArtifactStager(resolver: resolver, reauthorize: { authority }, diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) })

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
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testSymlinkedDurableRootIsRefused() async throws {
        let roots = try makeRoots()
        let target = try tempDir()
        let link = roots.durable
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let (authority, _) = try makeAuthority(payload: "bytes")
        let stager = Build1LaneAArtifactStager(
            resolver: CachedModelArtifactResolver(hubRoot: roots.hub, durableRoot: link, downloader: Self.refusingDownloader()),
            reauthorize: { authority },
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("symlinked durable root must be refused")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .rootUnavailable = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testOverflowingHeadroomRequirementRefusesBeforeTransfer() throws {
        XCTAssertThrowsError(try Build1LaneAArtifactStager.checkedRequirement(Int64.max / 2 + 1, multiplier: 2)) { error in
            guard case .insufficientDiskSpace = error as? Build1LaneAArtifactStagingError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try Build1LaneAArtifactStager.checkedRequirement(10, multiplier: 2), 20 + Build1LaneAArtifactStager.publicationReserveBytes)
    }

    func testAuthorityDriftBetweenVerificationAndPublicationRefusesAdoption() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "drift-bytes")
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter())
        )
        var drifted = authority
        drifted.releaseID = "rebound-release"
        let stager = Build1LaneAArtifactStager(
            resolver: resolver,
            reauthorize: { drifted },
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        )
        var stages: [Build1LaneAStagingStage] = []

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { stage, _, _ in stages.append(stage) }
            XCTFail("drifted authority must not adopt")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .authorityMismatch)
        }

        XCTAssertEqual(stages, [.staging, .verified])
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        let staged = resolver.prefetchSnapshotURL(modelID: authority.modelID, revision: authority.revision, sha256: authority.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testAuthorityUnavailableBeforePublicationRefusesAdoption() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "revoked-bytes")
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter())
        )
        let stager = Build1LaneAArtifactStager(
            resolver: resolver,
            reauthorize: { throw Build1LaneAArtifactAuthorityError.artifactAuthorityUnavailable(["stale"]) },
            diskProbe: { _ in Build1LaneADiskProbe(availableBytes: .max, deviceID: 1) }
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("unavailable authority must not adopt")
        } catch let error as Build1LaneAArtifactStagingError {
            guard case .authorityUnavailable = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        assertNoPrivateRecord(durable: roots.durable)
    }

    func testPublicationHeadroomRecheckRefusesAdoptionOfVerifiedSource() async throws {
        let roots = try makeRoots()
        let (authority, payload) = try makeAuthority(payload: "recheck-bytes", sizeBytes: 100)
        let resolver = CachedModelArtifactResolver(
            hubRoot: roots.hub,
            durableRoot: roots.durable,
            downloader: Self.fakeDownloader(payload: payload, counter: Build1LaneACounter())
        )
        let probeCount = Build1LaneACounter()
        let reserve = Build1LaneAArtifactStager.publicationReserveBytes
        let stager = Build1LaneAArtifactStager(
            resolver: resolver,
            reauthorize: { authority },
            diskProbe: { _ in
                probeCount.increment()
                // Enough for the transfer preflight, then the volume fills up.
                return Build1LaneADiskProbe(availableBytes: probeCount.value <= 2 ? 200 + reserve : 0, deviceID: 1)
            }
        )

        do {
            _ = try await stager.stageAndAdopt(authority: authority) { _, _, _ in }
            XCTFail("publication must re-check headroom")
        } catch let error as Build1LaneAArtifactStagingError {
            XCTAssertEqual(error, .insufficientDiskSpace(requiredBytes: 200 + reserve, availableBytes: 0))
        }
        XCTAssertFalse(DurableModelArtifactStore(root: roots.durable).isModelMaterialized(modelID: authority.modelID))
        assertNoPrivateRecord(durable: roots.durable)
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

    // MARK: - Private record helpers

    private func privateInventoryURL(durable: URL) -> URL {
        durable
            .appendingPathComponent(Build1LaneAPreparationRecorder.authorityLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.stateLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .publishedInventory))
    }

    private func privateReceiptURL(durable: URL, artifactIdentityDigest: String) -> URL {
        durable
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.objectsLeaf, isDirectory: true)
            .appendingPathComponent(artifactIdentityDigest, isDirectory: true)
            .appendingPathComponent(Build1LaneAPreparationRecorder.receiptLeaf)
    }

    /// Reads the published inventory through the store's own validated path.
    private func readPrivateInventory(
        durable: URL,
        bootstrapIfMissing: Bool = true
    ) throws -> (record: ModelPreparationInventoryRecord, generation: Int, locator: ModelPreparationRootLocator)? {
        if !bootstrapIfMissing, !FileManager.default.fileExists(atPath: privateInventoryURL(durable: durable).path) {
            return nil
        }
        let recorder = Build1LaneAPreparationRecorder(durableRoot: durable)
        let locator = try recorder.store.bootstrap().rootLocator
        guard let current = try recorder.store.readRecordWithGeneration(kind: .publishedInventory, rootLocator: locator) else {
            return nil
        }
        let record = try ModelPreparationContracts.decode(
            ModelPreparationInventoryRecord.self,
            from: current.payload,
            maxBytes: ModelPreparationContracts.inventoryMaxBytes
        )
        return (record, current.generation, locator)
    }

    private func readPrivateReceipt(durable: URL, artifactIdentityDigest: String) throws -> (record: ModelPreparationPublicationReceipt, sha256: String) {
        let bytes = try Data(contentsOf: privateReceiptURL(durable: durable, artifactIdentityDigest: artifactIdentityDigest))
        let record = try ModelPreparationContracts.decode(
            ModelPreparationPublicationReceipt.self,
            from: bytes,
            maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
        )
        return (record, try ModelPreparationContracts.publicationReceiptSHA256(from: bytes))
    }

    private func assertNoPrivateRecord(durable: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateInventoryURL(durable: durable).path), "no private record on failure", file: file, line: line)
        let objects = durable
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.objectsLeaf, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: objects.path)) ?? []
        XCTAssertEqual(entries, [], "no receipt on failure", file: file, line: line)
    }
}
