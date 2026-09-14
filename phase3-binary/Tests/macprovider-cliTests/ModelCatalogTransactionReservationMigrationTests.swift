import Foundation
import XCTest
@testable import macprovider_cli

final class ModelCatalogTransactionReservationMigrationTests: XCTestCase {
    private enum Injected: Error { case stop }

    func testR4PrimaryFirstDepartureCrashRepairsBeforeWriterReceipt() throws {
        let authority = try fixtureAuthority()
        let boundaries = [
            "reservation_publication_receipt",
            "reservation_publication_intent",
            "reservation_class_published",
            "reservation_left_published",
            "reservation_publication_complete",
        ]
        for boundary in boundaries {
            let store = try makeStore()
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID,
                target: authority.row.modelID, kind: "prepare_model",
                operationGeneration: operation.operationGeneration)
            let receipt = try store.captureActiveReceipt(selector: selector)
            var running = receipt.record
            running.startedAt = Date()
            store.append(&running, state: "running", stage: "downloading")

            var interrupted = store
            interrupted.retentionBoundary = { if $0 == boundary { throw Injected.stop } }
            XCTAssertThrowsError(try interrupted.commit(record: running, receipt: receipt), boundary)

            let restarted = ModelCatalogTransactionStore(root: store.root)
            let repaired = try restarted.captureActiveReceipt(selector: selector)
            XCTAssertEqual(repaired.record.events.last?.state, "running", boundary)
            XCTAssertTrue(try XCTUnwrap(repaired.reservation).isPermanentlyNonreusable, boundary)
            let entry = try XCTUnwrap(restarted.loadActiveIndexLocked().entries.first { $0.id == operation.transactionID })
            let leftHash = try XCTUnwrap(entry.leftSHA256)
            XCTAssertEqual(restarted.digest(try restarted.readPrivate(
                restarted.root.appendingPathComponent(operation.transactionID + ".reservation-left"))), leftHash, boundary)

            var heartbeat = repaired.record
            restarted.append(&heartbeat, state: "running", stage: "verifying")
            XCTAssertNoThrow(try restarted.commit(record: heartbeat, receipt: repaired), boundary)
        }
    }

    func testR4MigrationCrashBoundariesResumeExactGraph() throws {
        let authority = try fixtureAuthority()
        let boundaries = [
            "reservation_migration_source",
            "reservation_migration_format",
            "reservation_migration_progress",
            "reservation_migration_index",
            "reservation_publication_receipt",
            "reservation_publication_intent",
            "reservation_class_published",
            "reservation_left_published",
            "reservation_progress_acknowledged",
            "reservation_publication_complete",
            "reservation_migration_progress_complete",
            "reservation_migration_install_prepared",
            "reservation_migration_finalizing",
            "reservation_migration_complete",
        ]
        for boundary in boundaries {
            let store = try makeStore()
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            var running = try store.load(operation.transactionID, target: authority.row.modelID)
            running.startedAt = Date()
            store.append(&running, state: "running", stage: "downloading")
            try store.write(running)
            try resetReservationGraphToV3(store)

            var interrupted = store
            interrupted.retentionBoundary = { if $0 == boundary { throw Injected.stop } }
            XCTAssertThrowsError(try interrupted.initializeRetention(), boundary)

            let restarted = ModelCatalogTransactionStore(root: store.root)
            let receipt = try restarted.initializeRetention()
            XCTAssertEqual(receipt.index.schema, "model_catalog_active_index.v4", boundary)
            XCTAssertEqual(receipt.index.reservationPhase, "complete", boundary)
            let entry = try XCTUnwrap(receipt.index.entries.first { $0.id == operation.transactionID })
            let classHash = try XCTUnwrap(entry.classSHA256)
            let leftHash = try XCTUnwrap(entry.leftSHA256)
            XCTAssertEqual(restarted.digest(try restarted.readPrivate(
                restarted.root.appendingPathComponent(operation.transactionID + ".reservation-class"))), classHash, boundary)
            XCTAssertEqual(restarted.digest(try restarted.readPrivate(
                restarted.root.appendingPathComponent(operation.transactionID + ".reservation-left"))), leftHash, boundary)
            XCTAssertNoThrow(try restarted.captureReservationMigrationCompletion(indexReceipt: receipt), boundary)
        }
    }

    func testR4PhaseMatrixAcceptsOnlyAdmissibleEntryShapes() throws {
        let hash = String(repeating: "a", count: 64)
        let id = UUID().uuidString.lowercased()
        let active = ModelTransactionActiveIndex.Entry(id: id, phase: "active", originSHA256: hash,
            provenance: "allocated", classSHA256: hash)
        let unclassified = ModelTransactionActiveIndex.Entry(id: id, phase: "active", originSHA256: hash,
            provenance: "allocated")
        var pending = unclassified
        pending.reservationPublication = hash
        var left = active
        left.leftSHA256 = hash
        var activePending = active
        activePending.reservationPublication = hash
        let allocating = ModelTransactionActiveIndex.Entry(id: id, phase: "allocating", originSHA256: hash,
            provenance: "allocated", classSHA256: hash, allocatedGeneration: UUID().uuidString.lowercased(),
            initialPrimarySHA256: hash)

        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "classifying", entry: unclassified)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "classifying", entry: pending)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "finalizing", entry: active)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "complete", entry: active)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "complete", entry: left)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "complete", entry: allocating)))
        XCTAssertNoThrow(try storeForShapeValidation().validateReservationIndexShape(index(phase: "complete", entry: activePending)))

        var unclassifiedLeft = unclassified
        unclassifiedLeft.leftSHA256 = hash
        var leftPending = left
        leftPending.reservationPublication = hash
        var legacyLeft = left
        legacyLeft.provenance = "legacy_snapshot"
        var allocatingLeft = allocating
        allocatingLeft.leftSHA256 = hash
        var finalizingPending = active
        finalizingPending.reservationPublication = hash
        let invalid = [
            index(phase: "complete", entry: unclassified),
            index(phase: "classifying", entry: unclassifiedLeft),
            index(phase: "classifying", entry: leftPending),
            index(phase: "complete", entry: legacyLeft),
            index(phase: "complete", entry: allocatingLeft),
            index(phase: "finalizing", entry: finalizingPending),
            index(phase: "classifying", entry: allocating),
        ]
        for value in invalid {
            XCTAssertThrowsError(try storeForShapeValidation().validateReservationIndexShape(value))
        }
    }

    func testR4LargestAcceptedOriginFitsReservationClassEnvelope() throws {
        let store = storeForShapeValidation()
        let id = UUID().uuidString.lowercased()
        let generation = UUID().uuidString.lowercased()
        func origin(signerLength: Int) throws -> (ModelTransactionOrigin, Data) {
            var record = ModelCatalogTransactionRecord(transactionID: id, target: "fixture/model",
                modelKey: "fixture-model", kind: "prepare_model", revision: String(repeating: "b", count: 40),
                sha256: String(repeating: "c", count: 64), candidateDigest: String(repeating: "d", count: 64),
                artifactDigest: String(repeating: "e", count: 64), signerKeyID: String(repeating: "s", count: signerLength),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            record.operationGeneration = generation
            let value = try ModelTransactionOrigin.allocated(record, primarySHA256: String(repeating: "f", count: 64))
            return (value, try store.bindingBytes(value))
        }

        var low = 0, high = 20_000
        while low < high {
            let middle = (low + high + 1) / 2
            if (try? origin(signerLength: middle)) != nil { low = middle } else { high = middle - 1 }
        }
        let (largest, originBytes) = try origin(signerLength: low)
        XCTAssertLessThanOrEqual(originBytes.count, 16_384)
        XCTAssertThrowsError(try origin(signerLength: low + 1))
        let classification = try store.reservationClass(origin: largest, originSHA256: store.digest(originBytes))
        XCTAssertLessThanOrEqual(try store.canonicalData(classification).count,
                                 ModelCatalogTransactionStore.reservationClassLimit)
    }

    private func resetReservationGraphToV3(_ store: ModelCatalogTransactionStore) throws {
        var index = try store.loadActiveIndexLocked()
        index.schema = "model_catalog_active_index.v3"
        index.reservationMigrationID = nil
        index.reservationSourceSHA256 = nil
        index.reservationProgressSHA256 = nil
        index.reservationPhase = nil
        index.reservationInstallID = nil
        index.reservationInstallReceiptSHA256 = nil
        for position in index.entries.indices {
            index.entries[position].classSHA256 = nil
            index.entries[position].leftSHA256 = nil
            index.entries[position].reservationPublication = nil
            index.entries[position].allocatedGeneration = nil
            index.entries[position].initialPrimarySHA256 = nil
        }
        let root = try ModelTransactionDirectory.current(store.root)
        if try root.metadata(".reservation-migration") != nil {
            try FileManager.default.removeItem(at: store.root.appendingPathComponent(".reservation-migration"))
        }
        let retention = try store.retentionDirectory()
        try retention.write(try store.canonicalData(index), name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
        try retention.write(try store.canonicalData(ModelTransactionRetentionFormat(schema: "model_catalog_retention.v2")),
                            name: "format.json", maxBytes: 4_096)
        for entry in index.entries {
            for suffix in [".reservation-class", ".reservation-left"] {
                let name = entry.id + suffix
                if try root.metadata(name) != nil {
                    guard unlinkat(root.fd, name, 0) == 0 else { throw ModelCatalogRetentionError.storage }
                }
            }
        }
        guard fsync(root.fd) == 0 else { throw ModelCatalogRetentionError.storage }
    }

    private func index(phase: String, entry: ModelTransactionActiveIndex.Entry) -> ModelTransactionActiveIndex {
        ModelTransactionActiveIndex(schema: "model_catalog_active_index.v4",
            migrationID: UUID().uuidString.lowercased(), migrationSourceSHA256: String(repeating: "b", count: 64),
            reservationMigrationID: UUID().uuidString.lowercased(), reservationSourceSHA256: String(repeating: "c", count: 64),
            reservationProgressSHA256: String(repeating: "d", count: 64), reservationPhase: phase,
            reservationInstallID: phase == "classifying" ? nil : UUID().uuidString.lowercased(),
            reservationInstallReceiptSHA256: phase == "finalizing" ? String(repeating: "e", count: 64) : nil,
            generation: 1, entries: [entry])
    }

    private func storeForShapeValidation() -> ModelCatalogTransactionStore {
        ModelCatalogTransactionStore(root: FileManager.default.temporaryDirectory)
    }

    private func makeStore() throws -> ModelCatalogTransactionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogReservationMigrationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ModelCatalogTransactionStore(root: root.appendingPathComponent(".transactions"))
    }

    private func fixtureAuthority() throws -> ModelCatalogTransactionAuthority {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let candidate = try JSONSerialization.data(withJSONObject: corpus["candidate"]!,
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        var feed = try XCTUnwrap(corpus["feed"] as? [String: Any])
        feed["candidate_catalog_sha256"] = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate)
        let feedBytes = try JSONSerialization.data(withJSONObject: feed,
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "fixture-only"
        let qualified = try XCTUnwrap(AutotuneStaticInputs.usableArtifactFeed(bakedBytes: feedBytes,
            bakedSignerKeyID: signer, candidateBytes: candidate, candidateSignerKeyID: signer,
            now: ISO8601DateFormatter().date(from: "2026-07-11T00:00:00Z")!))
        let demand = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let rate = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        let inputs: ModelCatalogRecommendationInputs = (
            .init(value: try AutotuneStaticInputs.decodeDemandRank(demand), selectedBytes: demand,
                  warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidate), selectedBytes: candidate,
                  warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeRateCard(rate), selectedBytes: rate,
                  warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: qualified, selectedBytes: feedBytes, warnings: [], usedFallback: false, signerKeyID: signer))
        return try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
    }
}
