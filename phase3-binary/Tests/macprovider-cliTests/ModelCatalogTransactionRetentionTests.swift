import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelCatalogTransactionRetentionTests: XCTestCase {
    private enum Injected: Error { case stop }

    func testMoreThanLifetimeCapCancelledAndCompletedHistoryRemainsReadable() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var retained: [(String, Data)] = []
        for index in 0..<2_052 {
            let kind = index % 2 == 0 ? "prepare_model" : "evaluate_model"
            let state = ["succeeded", "failed", "cancelled", "timed_out"][(index / 2) % 4]
            let operation = try store.reserveOperation(authority: authority, kind: kind)
            try terminalFixture(store, operation: operation, authority: authority, inputs: inputs, kind: kind,
                state: state, committed: state == "succeeded" || index % 16 >= 8)
            if [0, 1, 1_024, 2_051].contains(index) {
                retained.append((operation.transactionID, try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))))
            }
        }
        try store.maintainRetention()
        XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, 0)
        let restarted = ModelCatalogTransactionStore(root: store.root)
        XCTAssertNoThrow(try restarted.reserveOperation(authority: authority, kind: "prepare_model"))
        for (id, bytes) in retained {
            XCTAssertEqual(try restarted.readPrivate(store.root.appendingPathComponent(id + ".json")), bytes)
            XCTAssertTrue(try restarted.load(id, target: authority.row.modelID).terminal)
        }
    }

    func testAllocationCrashIntentsRecoverWithoutLosingExposedRecord() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for point in ["allocation_intent", "allocation_record", "allocation_origin", "allocation_class", "allocation_active"] {
            let plain = try makeStore()
            var failing = plain
            failing.retentionBoundary = { if $0 == point { throw Injected.stop } }
            XCTAssertThrowsError(try failing.reserveOperation(authority: authority, kind: "prepare_model"))
            let before = try plain.locked { try plain.activeSnapshotLocked() }
            XCTAssertEqual(before.count, 1)
            let recovered = try plain.reserveOperation(authority: authority, kind: "prepare_model")
            if point != "allocation_intent" { XCTAssertEqual(recovered.transactionID, before.first) }
            else if let unexposed = before.first {
                XCTAssertNil(try ModelTransactionDirectory.current(plain.root).metadata(".owner-" + unexposed))
            }
            XCTAssertEqual(try plain.locked { try plain.activeSnapshotLocked().count }, 1)
        }
    }

    func testRepeatedPollingExpirationRetainsTimedOutTruthAndFreshReuse() throws {
        let store = try makeStore()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let start = Date()
        let first = try store.reserveOperation(authority: authority, kind: "prepare_model", now: start)
        XCTAssertEqual(first.transactionID, try store.reserveOperation(authority: authority, kind: "prepare_model", now: start.addingTimeInterval(1)).transactionID)
        for index in 1...4 {
            _ = try store.reserveOperation(authority: authority, kind: "prepare_model", now: start.addingTimeInterval(Double(index) * 1_801))
        }
        XCTAssertEqual(try store.load(first.transactionID, target: authority.row.modelID).events.last?.state, "timed_out")
        XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, 1)
    }

    func testQueuedSuccessorNeverHidesCompletedResultIncludingRestartAndCleanup() throws {
        for priorPointer in [false, true] {
            let store = try makeStore(), inputs = try fixtureInputs()
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            if priorPointer {
                let older = try store.reserveOperation(authority: authority, kind: "evaluate_model", now: Date().addingTimeInterval(-20))
                try completeEvaluation(store, operation: older, authority: authority, inputs: inputs, index: true)
                try store.maintainRetention()
            }
            let a = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            let startReceipt = try store.captureActiveReceipt(selector: .init(transactionID: a.transactionID,
                target: authority.row.modelID, kind: "evaluate_model",
                operationGeneration: a.operationGeneration))
            var owner: ModelCatalogFileLock? = try store.ownerLock(a.transactionID)
            var record = startReceipt.record
            record.startedAt = Date(); store.append(&record, state: "running")
            try store.commit(record: record, receipt: startReceipt)
            let b = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            XCTAssertNotEqual(a.transactionID, b.transactionID)
            try completeEvaluation(store, operation: a, authority: authority, inputs: inputs, index: false, cleanup: true)
            withExtendedLifetime(owner) {}; owner = nil
            let restarted = ModelCatalogTransactionStore(root: store.root)
            XCTAssertEqual(b.transactionID, try restarted.reserveOperation(authority: authority, kind: "evaluate_model").transactionID)
            let selected = try restarted.indexedRecommendation(authority: authority, inputs: inputs, chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")
            XCTAssertEqual(selected?.transactionID, a.transactionID)
            let pointerBefore = try pointerFiles(restarted)
            let resultBefore = try restarted.readPrivate(restarted.root.appendingPathComponent(a.transactionID + ".result"))
            let terminalBefore = try restarted.load(a.transactionID, target: authority.row.modelID).events.last
            // The cleanup owner changes only the original cleanup flag and its
            // separate stream. The retained success commitment stays identical.
            let cleanup = try restarted.reserveCleanup(id: a.transactionID, target: authority.row.modelID)
            try restarted.locked {
                var stream = try restarted.load(a.transactionID, target: authority.row.modelID, cleanup: true)
                XCTAssertEqual(stream.operationGeneration, cleanup.operationGeneration)
                stream.startedAt = Date(); restarted.append(&stream, state: "running")
                restarted.append(&stream, state: "succeeded"); try restarted.write(stream)
                var original = try restarted.load(a.transactionID, target: authority.row.modelID)
                original.cleanupRequired = false; try restarted.write(original)
            }
            let afterCleanup = ModelCatalogTransactionStore(root: restarted.root)
            XCTAssertEqual(try afterCleanup.indexedRecommendation(authority: authority, inputs: inputs,
                chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")?.transactionID, a.transactionID)
            try afterCleanup.maintainRetention()
            XCTAssertFalse(try afterCleanup.locked { try afterCleanup.isActiveLocked(a.transactionID) })
            XCTAssertEqual(try pointerFiles(afterCleanup), pointerBefore)
            XCTAssertEqual(try afterCleanup.readPrivate(afterCleanup.root.appendingPathComponent(a.transactionID + ".result")), resultBefore)
            XCTAssertEqual(try afterCleanup.load(a.transactionID, target: authority.row.modelID).events.last, terminalBefore)
        }
    }

    func testPointerSubstitutionCannotBeOverwrittenAndKeepsActiveEvidence() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
        try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
        let before = try pointerFiles(store)
        let path = store.root.appendingPathComponent(operation.transactionID + ".result")
        try store.writePrivate(Data("substituted".utf8), to: path)
        XCTAssertThrowsError(try store.indexedRecommendation(authority: authority, inputs: inputs, chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture"))
        try store.maintainRetention()
        XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) })
        XCTAssertEqual(try pointerFiles(store), before)
        XCTAssertEqual(try store.readPrivate(path), Data("substituted".utf8))
    }

    func testPointerFailurePreservesResultAndNextProjectionRepairsOnlyMissingPointer() throws {
        let plain = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try plain.reserveOperation(authority: authority, kind: "evaluate_model")
        var failing = plain
        failing.retentionBoundary = { if $0 == "pointer_before_publish" { throw Injected.stop } }
        XCTAssertThrowsError(try completeEvaluation(failing, operation: operation, authority: authority, inputs: inputs, index: true))
        XCTAssertEqual(try plain.load(operation.transactionID, target: authority.row.modelID).events.last?.state, "succeeded")
        XCTAssertEqual(try plain.indexedRecommendation(authority: authority, inputs: inputs,
            chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")?.transactionID, operation.transactionID)
    }

    func testCC01CompleteInventoryRejectsEveryMissingActivePrimaryAndKeepsValidEmptyControl() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let budget = ModelTransactionWorkBudget()
        let control = try store.captureCompleteCleanupInventory(budget: budget)
        XCTAssertTrue(control.records.isEmpty)
        try control.validate(store: store, budget: budget)

        let primary = store.root.appendingPathComponent(operation.transactionID + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        try FileManager.default.removeItem(at: primary)
        XCTAssertThrowsError(try store.captureCompleteCleanupInventory(budget: .init()))

        let boundaryStore = try makeStore()
        let boundaryOperation = try boundaryStore.reserveOperation(authority: authority, kind: "prepare_model")
        _ = try boundaryStore.initializeRetention()
        var deleting = boundaryStore
        let deletion = OneShotProbe()
        deleting.retentionBoundary = { point in
            if point == "index_decode", deletion.take() {
                try FileManager.default.removeItem(at: boundaryStore.root.appendingPathComponent(boundaryOperation.transactionID + ".json"))
            }
        }
        XCTAssertThrowsError(try deleting.captureCompleteCleanupInventory(budget: .init()))
        XCTAssertTrue(deletion.happened)
    }

    func testCC02PreReconcileDiscoversAbandonedEvaluationCleanupBeforeProjection() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
        let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID,
            target: authority.row.modelID, kind: "evaluate_model",
            operationGeneration: operation.operationGeneration)
        try store.locked {
            var record = try store.load(selector)
            record.startedAt = Date().addingTimeInterval(-10)
            store.append(&record, state: "running")
            try store.write(record)
            try FileManager.default.createDirectory(at: store.stagingURL(operation.transactionID),
                                                    withIntermediateDirectories: false)
        }
        let readBudget = ModelCatalogReadBudget(mode: .quick)
        let workBudget = try readBudget.transactionBudget()
        _ = try store.prepareRecommendationIndex(target: authority.row.modelID, budget: workBudget,
                                                 readBudget: readBudget, requireComplete: true)
        let inventory = try store.captureCompleteCleanupInventory(budget: workBudget)
        XCTAssertEqual(inventory.records.map(\.transactionID), [operation.transactionID])
        XCTAssertEqual(inventory.records.first?.events.last?.state, "failed")
        XCTAssertTrue(inventory.records.first?.cleanupRequired == true)
    }

    func testCC03FinalInventoryWitnessRejectsPrimaryChangeWithoutIndexMembershipChange() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let budget = ModelTransactionWorkBudget()
        let inventory = try store.captureCompleteCleanupInventory(budget: budget)
        try store.locked {
            var record = try store.load(operation.transactionID, target: authority.row.modelID)
            record.cancelRequested = true
            store.append(&record, state: "cancel_requested", stage: "cancelling")
            try store.write(record)
        }
        XCTAssertThrowsError(try inventory.validate(store: store, budget: budget))
        XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) })
    }

    func testCC04PointerFailureReportsDurableTruthAndLaterBoundedReadValidatesDurablePointer() throws {
        for point in ["pointer_before_publish", "pointer_renamed", "pointer_durable", "pointer_published", "pointer_acknowledged"] {
            let plain = try makeStore(), inputs = try fixtureInputs()
            let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
            let operation = try plain.reserveOperation(authority: authority, kind: "evaluate_model")
            try completeEvaluation(plain, operation: operation, authority: authority, inputs: inputs, index: false)
            var failing = plain
            failing.retentionBoundary = { if $0 == point { throw Injected.stop } }
            do {
                try failing.indexCompletedEvaluation(
                    failing.load(operation.transactionID, target: authority.row.modelID), budget: .init())
                XCTFail("expected injected pointer failure at \(point)")
            } catch let failure as ModelRecommendationPointerPublicationError {
                XCTAssertEqual(failure.truth, point == "pointer_before_publish" ? .notPublished : .mayOrDidPublish)
            }
            if point != "pointer_before_publish" {
                XCTAssertFalse(try pointerFiles(plain).isEmpty)
                XCTAssertEqual(try plain.indexedRecommendation(authority: authority, inputs: inputs,
                    chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")?.transactionID,
                    operation.transactionID)
            }
        }
    }

    func testCC04BothReconcilePublicationSitesPropagatePointerFailure() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)

        // Newly committed success: reconciliation owns the first publication.
        do {
            let plain = try makeStore()
            let operation = try plain.reserveOperation(authority: authority, kind: "evaluate_model")
            let selector = try prepareCommittedEvaluation(plain, operation: operation, authority: authority, inputs: inputs)
            var failing = plain
            failing.retentionBoundary = { if $0 == "pointer_before_publish" { throw Injected.stop } }
            XCTAssertThrowsError(try failing.reconcile(selector, workBudget: .init(),
                                                        requireRecommendationPublication: true)) { error in
                XCTAssertEqual((error as? ModelRecommendationPointerPublicationError)?.truth, .notPublished)
            }
            XCTAssertEqual(try plain.load(selector).events.last?.state, "succeeded")
        }

        // A binding-referenced pending success exercises the recovery publication.
        do {
            let plain = try makeStore()
            let operation = try plain.reserveOperation(authority: authority, kind: "evaluate_model")
            let selector = try prepareCommittedEvaluation(plain, operation: operation, authority: authority, inputs: inputs)
            let receipt = try plain.captureActiveReceipt(selector: selector)
            let terminal = try plain.evaluationSuccessTerminal(preterminal: receipt.record, cleanupRequired: false)
            var interrupted = plain
            interrupted.retentionBoundary = { if $0 == "success_binding_referenced" { throw Injected.stop } }
            XCTAssertThrowsError(try interrupted.commitEvaluationSuccess(preterminal: receipt, terminal: terminal,
                result: plain.evidence(operation.transactionID + ".result", budget: .init())))
            var failing = plain
            failing.retentionBoundary = { if $0 == "pointer_before_publish" { throw Injected.stop } }
            XCTAssertThrowsError(try failing.reconcile(selector, workBudget: .init(),
                                                        requireRecommendationPublication: true)) { error in
                XCTAssertEqual((error as? ModelRecommendationPointerPublicationError)?.truth, .notPublished)
            }
            XCTAssertEqual(try plain.load(selector).events.last?.state, "succeeded")
        }
    }

    func testCC05StrictRecommendationPreparationHandlesAbsentLiveAndExpiredBudget() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)

        let empty = try makeStore()
        let readBudget = ModelCatalogReadBudget(mode: .quick)
        XCTAssertNil(try empty.indexedRecommendation(authority: authority, inputs: inputs,
            chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture",
            budget: try readBudget.transactionBudget(), readBudget: readBudget, requireComplete: true))

        let live = try makeStore()
        let operation = try live.reserveOperation(authority: authority, kind: "evaluate_model")
        let startReceipt = try live.captureActiveReceipt(selector: .init(transactionID: operation.transactionID,
            target: authority.row.modelID, kind: "evaluate_model",
            operationGeneration: operation.operationGeneration))
        let owner = try live.ownerLock(operation.transactionID)
        var record = startReceipt.record
        record.startedAt = Date(); live.append(&record, state: "running")
        try live.commit(record: record, receipt: startReceipt)
        let liveReadBudget = ModelCatalogReadBudget(mode: .quick)
        XCTAssertNil(try live.indexedRecommendation(authority: authority, inputs: inputs,
            chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture",
            budget: try liveReadBudget.transactionBudget(), readBudget: liveReadBudget, requireComplete: true))
        withExtendedLifetime(owner) {}

        let committed = try makeStore()
        let completed = try committed.reserveOperation(authority: authority, kind: "evaluate_model")
        try completeEvaluation(committed, operation: completed, authority: authority, inputs: inputs, index: true)
        let committedReadBudget = ModelCatalogReadBudget(mode: .quick)
        XCTAssertEqual(try committed.indexedRecommendation(authority: authority, inputs: inputs,
            chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture",
            budget: try committedReadBudget.transactionBudget(), readBudget: committedReadBudget,
            requireComplete: true)?.transactionID, completed.transactionID)

        XCTAssertThrowsError(try empty.prepareRecommendationIndex(target: authority.row.modelID,
            budget: .init(seconds: 0), readBudget: ModelCatalogReadBudget(mode: .quick), requireComplete: true))
    }

    func testCleanupGenerationsRetainHistoryAndRecoverySelectsOldestPerTarget() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        var ids: [String] = []
        for offset in [-10.0, -5.0] {
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model", now: Date().addingTimeInterval(offset))
            ids.append(operation.transactionID)
            try store.locked {
                var record = try store.load(operation.transactionID, target: authority.row.modelID)
                record.cleanupRequired = true; store.append(&record, state: "failed"); try store.write(record)
            }
        }
        let recoveries = makeModelCatalogRecoveries(store: store)
        XCTAssertEqual(recoveries.count, 1); XCTAssertEqual(recoveries.first?.action.transactionID, ids[0])
        let first = try store.reserveCleanup(id: ids[0], target: authority.row.modelID)
        XCTAssertEqual(first.operationGeneration, try store.reserveCleanup(id: ids[0], target: authority.row.modelID).operationGeneration)
        try store.locked {
            var record = try store.load(ids[0], target: authority.row.modelID, cleanup: true)
            store.append(&record, state: "failed"); try store.write(record)
        }
        let bytes = try store.readPrivate(store.root.appendingPathComponent(ids[0] + ".cleanup"))
        let next = try store.reserveCleanup(id: ids[0], target: authority.row.modelID)
        XCTAssertNotEqual(first.operationGeneration, next.operationGeneration)
        XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(ids[0] + ".cleanup-" + first.operationGeneration)), bytes)
        let stale = ModelCatalogTransactionSelector(transactionID: ids[0], target: authority.row.modelID,
            kind: "cleanup_staging", operationGeneration: first.operationGeneration)
        XCTAssertThrowsError(try store.captureActiveReceipt(selector: stale))
    }

    func testCorruptIndexNeverRebuildsAndDirectTerminalEvidenceSurvives() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: operation.operationGeneration)
        _ = try store.reconcile(selector, cancel: true)
        let path = store.root.appendingPathComponent(".retention-v2/active.json")
        try Data("corrupt-index".utf8).write(to: path)
        XCTAssertThrowsError(try store.reserveOperation(authority: authority, kind: "prepare_model"))
        XCTAssertTrue(try store.load(operation.transactionID, target: authority.row.modelID).terminal)
        XCTAssertEqual(try Data(contentsOf: path), Data("corrupt-index".utf8))
    }

    func testPinnedDirectoryAndUnsafeSidecarRejectReplacementWithoutMutation() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        try store.locked {
            var record = try store.load(operation.transactionID, target: authority.row.modelID)
            store.append(&record, state: "cancelled"); try store.write(record)
        }
        let result = store.root.appendingPathComponent(operation.transactionID + ".result")
        XCTAssertEqual(symlink("missing", result.path), 0)
        try store.maintainRetention()
        XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) })
        let moved = store.root.deletingLastPathComponent().appendingPathComponent("moved")
        XCTAssertThrowsError(try store.locked {
            try FileManager.default.moveItem(at: store.root, to: moved)
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try store.writePrivate(Data("unsafe".utf8), to: store.root.appendingPathComponent("new-file"))
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("new-file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(operation.transactionID + ".json").path))
    }

    func testFullActiveIndexAllowsReuseAndSupportedResolutionRestoresCapacity() throws {
        var store = try makeStore()
        let phases = ReservationPhaseProbe()
        store.retentionBoundary = { phases.observe($0) }
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        try store.secure()
        var first: ModelCatalogTransactionSelector?
        var unresolvedBytes: [String: Data] = [:]
        try store.initializeRetention()
        var activeIndex = try store.snapshotIndex()
        let directory = try ModelTransactionDirectory(store.root)
        for index in 0..<ModelCatalogTransactionStore.activeTransactionLimit {
            let id = UUID().uuidString.lowercased()
            var record = ModelCatalogTransactionRecord(transactionID: id, target: authority.row.modelID,
                modelKey: authority.modelKey, kind: "prepare_model", revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!,
                candidateDigest: authority.candidateDigest, artifactDigest: authority.artifactDigest,
                signerKeyID: authority.signerKeyID, createdAt: Date())
            store.append(&record, state: "queued")
            let queuedBytes = try JSONEncoder().encode(record)
            let origin = try ModelTransactionOrigin.allocated(record, primarySHA256: store.digest(queuedBytes))
            let originBytes = try store.bindingBytes(origin)
            let classBytes = try store.canonicalData(store.reservationClass(origin: origin,
                originSHA256: store.digest(originBytes)))
            try directory.write(queuedBytes, name: id + ".json", exclusive: true)
            try directory.write(originBytes, name: id + ".origin", exclusive: true, maxBytes: 16_384)
            try directory.write(classBytes, name: id + ".reservation-class", exclusive: true,
                                maxBytes: ModelCatalogTransactionStore.reservationClassLimit)
            var leftHash: String?
            if index != 0 {
                record.startedAt = Date(); store.append(&record, state: "running")
                let bytes = try JSONEncoder().encode(record)
                try directory.write(bytes, name: id + ".json")
                unresolvedBytes[id] = bytes
                let left = ModelTransactionReservationLeft(schema: "model_catalog_reservation_left.v1",
                    transactionID: id, operationGeneration: try XCTUnwrap(record.operationGeneration),
                    originSHA256: store.digest(originBytes), classSHA256: store.digest(classBytes),
                    firstObservedNonreusablePrimarySHA256: store.digest(bytes), reason: "started")
                let leftBytes = try store.canonicalData(left)
                try directory.write(leftBytes, name: id + ".reservation-left", exclusive: true,
                                    maxBytes: ModelCatalogTransactionStore.reservationLeftLimit)
                leftHash = store.digest(leftBytes)
            }
            activeIndex.entries.append(.init(id: id, phase: "active", originSHA256: store.digest(originBytes),
                provenance: "allocated", classSHA256: store.digest(classBytes), leftSHA256: leftHash))
            if index == 0 { first = record.selector }
        }
        activeIndex.generation += 1; activeIndex.entries.sort { $0.id < $1.id }
        try store.retentionDirectory().write(store.canonicalData(activeIndex), name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
        let queued = try XCTUnwrap(first)
        XCTAssertEqual(try store.reserveOperation(authority: authority, kind: "prepare_model").transactionID, queued.transactionID)
        XCTAssertThrowsError(try store.reserveOperation(authority: authority, kind: "evaluate_model"))
        _ = try store.reconcile(queued, cancel: true)
        var allocated: ModelCatalogTransactionReservation?
        let deadline = DispatchTime.now().uptimeNanoseconds + 64_000_000_000
        for _ in 0..<8 where DispatchTime.now().uptimeNanoseconds < deadline {
            do { allocated = try store.reserveOperation(authority: authority, kind: "evaluate_model"); break }
            catch ModelCatalogTransactionError.busy { }
            catch ModelCatalogRetentionError.capacity { }
        }
        print("RETENTION_RESERVATION_PHASES \(phases.summary)")
        let fresh = try XCTUnwrap(allocated, "bounded reservation passes must advance the retirement cursor; " + phases.summary)
        XCTAssertNotEqual(fresh.transactionID, queued.transactionID)
        XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, ModelCatalogTransactionStore.activeTransactionLimit)
        XCTAssertFalse(try store.locked { try store.isActiveLocked(queued.transactionID) })
        XCTAssertTrue(try store.load(queued.transactionID, target: authority.row.modelID).terminal)
        XCTAssertEqual(unresolvedBytes.count, 1_023)
        for (id, bytes) in unresolvedBytes {
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), bytes)
            XCTAssertNil(try directory.metadata(id + ".retired"))
        }
    }

    func testProcessExitAtDurableAllocationPointerAndRetirementBoundaries() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for point in ["allocation_intent", "allocation_record", "allocation_origin", "allocation_active", "pointer_before_publish", "pointer_published", "retirement_captured", "retirement_certificate", "retirement_before_commit", "retirement_committed", "index_before_recapture", "index_recaptured"] {
            let store = try makeStore()
            var original: ModelCatalogTransactionReservation?
            var originalBytes: Data?
            if point.hasPrefix("pointer") {
                let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
                try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: false)
                original = operation
                originalBytes = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".result"))
            } else if point.hasPrefix("retirement") || point.hasPrefix("index_") {
                let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
                _ = try store.reconcile(.init(transactionID: operation.transactionID, target: authority.row.modelID,
                    kind: "prepare_model", operationGeneration: operation.operationGeneration), cancel: true)
                original = operation
                originalBytes = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionRetentionTests/testRetentionCrashSubprocessEntry", Bundle(for: Self.self).bundlePath]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": store.root.deletingLastPathComponent().path,
                "BUILD1_RETENTION_ROOT": store.root.path, "BUILD1_RETENTION_POINT": point]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(15)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate(); XCTFail("retention subprocess timed out at " + point) }
            guard !child.isRunning else { throw ModelCatalogTransactionError.timedOut }
            XCTAssertEqual(child.terminationStatus, 91, point)
            let restarted = ModelCatalogTransactionStore(root: store.root)
            if point.hasPrefix("pointer"), let original {
                XCTAssertEqual(try restarted.indexedRecommendation(authority: authority, inputs: inputs,
                    chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")?.transactionID, original.transactionID)
                XCTAssertEqual(try restarted.readPrivate(store.root.appendingPathComponent(original.transactionID + ".result")), originalBytes)
            } else if (point.hasPrefix("retirement") || point.hasPrefix("index_")), let original {
                XCTAssertEqual(try restarted.readPrivate(store.root.appendingPathComponent(original.transactionID + ".json")), originalBytes)
                XCTAssertEqual(try restarted.locked { try restarted.isActiveLocked(original.transactionID) }, ["retirement_captured", "retirement_certificate", "retirement_before_commit"].contains(point))
            }
            XCTAssertNoThrow(try restarted.reserveOperation(authority: authority, kind: "prepare_model"), point)
        }
    }

    func testRetentionCrashSubprocessEntry() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["BUILD1_RETENTION_ROOT"], let point = environment["BUILD1_RETENTION_POINT"] else { return }
        var store = ModelCatalogTransactionStore(root: URL(fileURLWithPath: root))
        store.retentionBoundary = { if $0 == point { _exit(91) } }
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        if point == "concurrent_allocate" { _ = try store.reserveOperation(authority: authority, kind: "prepare_model"); _exit(91) }
        if point.hasPrefix("allocation") { _ = try store.reserveOperation(authority: authority, kind: "prepare_model") }
        else if point.hasPrefix("pointer") { try store.prepareRecommendationIndex(target: authority.row.modelID) }
        else { try store.maintainRetention() }
        _exit(92)
    }

    func testUntouchedReservationWithSidecarOrUnknownFieldIsNeverReusedOrReclaimed() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for suffix in [".result", ".cleanup", ".seal", ".success-binding", ".retired", "unknown_field", "unknown_schema"] {
            let store = try makeStore()
            let now = Date()
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model", now: now)
            let primary = store.root.appendingPathComponent(operation.transactionID + ".json")
            if suffix == "unknown_field" || suffix == "unknown_schema" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.readPrivate(primary)) as? [String: Any])
                if suffix == "unknown_schema" { object["schema"] = "unknown.v9" }
                else { object["unrecognized_evidence"] = "retained" }
                try store.writePrivate(JSONSerialization.data(withJSONObject: object), to: primary)
            } else {
                XCTAssertEqual(symlink("missing", store.root.appendingPathComponent(operation.transactionID + suffix).path), 0)
            }
            let bytes = try store.readPrivate(primary)
            XCTAssertThrowsError(try store.reserveOperation(authority: authority, kind: "prepare_model",
                                                            now: now.addingTimeInterval(1)), suffix)
            XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, 1, suffix)
            try store.maintainRetention(now: now.addingTimeInterval(2_000))
            XCTAssertEqual(try store.readPrivate(primary), bytes)
            XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) })
        }
    }

    func testInitializedIndexNeverScansGrowingHistoricalDirectory() throws {
        let store = try makeStore()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        _ = try store.reconcile(.init(transactionID: operation.transactionID, target: authority.row.modelID,
            kind: "prepare_model", operationGeneration: operation.operationGeneration), cancel: true)
        var noScan = store
        noScan.retentionBoundary = { if $0 == "migration_scan" { throw Injected.stop } }
        XCTAssertNoThrow(try noScan.reserveOperation(authority: authority, kind: "prepare_model"))
        XCTAssertNoThrow(try noScan.cleanupRecords())
        XCTAssertTrue(try noScan.load(operation.transactionID, target: authority.row.modelID).terminal)
    }

    func testImmutableSuccessCommitmentRejectsIdentityAndTerminalSubstitution() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for field in ["transactionID", "operationGeneration", "schema", "kind", "createdAt", "startedAt", "target", "modelKey", "revision", "sha256", "candidateDigest",
                      "artifactDigest", "signerKeyID", "committed", "resultSHA256", "terminal", "failed", "cancelled", "generation_removed"] {
            let store = try makeStore()
            let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
            let originalPointers = try pointerFiles(store)
            let path = store.root.appendingPathComponent(operation.transactionID + ".json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.readPrivate(path)) as? [String: Any])
            switch field {
            case "operationGeneration", "transactionID": object[field] = UUID().uuidString.lowercased()
            case "createdAt", "startedAt": object[field] = 0
            case "generation_removed": object.removeValue(forKey: "operationGeneration")
            case "failed", "cancelled":
                var events = try XCTUnwrap(object["events"] as? [[String: Any]])
                events[events.count - 1]["state"] = field; object["events"] = events
            case "revision": object[field] = String(repeating: "f", count: 40)
            case "sha256", "candidateDigest", "artifactDigest", "resultSHA256": object[field] = String(repeating: "f", count: 64)
            case "committed": object[field] = false
            case "terminal":
                var events = try XCTUnwrap(object["events"] as? [[String: Any]])
                events[events.count - 1]["emitted_at"] = "2026-01-01T00:00:00Z"
                object["events"] = events
            default: object[field] = "substituted"
            }
            let substituted = try JSONSerialization.data(withJSONObject: object)
            try store.writePrivate(substituted, to: path)
            XCTAssertThrowsError(try store.indexedRecommendation(authority: authority, inputs: inputs,
                chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture"), field)
            try store.maintainRetention()
            XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) }, field)
            let after = try pointerFiles(store)
            XCTAssertEqual(after, originalPointers, field)
            for (name, bytes) in originalPointers { XCTAssertEqual(after[name], bytes, field) }
            XCTAssertEqual(try store.readPrivate(path), substituted, field)
        }
    }

    func testRetirementPreservesValidSealAndProtectsSubstitutedSeal() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for corrupt in [false, true] {
            let store = try makeStore()
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            let sealPath = store.root.appendingPathComponent(operation.transactionID + ".seal")
            try store.locked {
                var record = try store.load(operation.transactionID, target: authority.row.modelID)
                record.startedAt = Date(); store.append(&record, state: "running")
                // Historical storage fixture, not evidence of an actual preparation.
                let snapshot = ModelCatalogArtifactSnapshot(root: .init(try ModelTransactionDirectory.current(store.root).info()), entries: [])
                let bytes = try JSONEncoder().encode(ModelCatalogArtifactSeal(record: record, snapshot: snapshot))
                try store.writePrivate(bytes, to: sealPath)
                record.artifactSealSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                record.committed = true; store.append(&record, state: "succeeded"); try store.write(record)
            }
            if corrupt { try store.writePrivate(Data("corrupt".utf8), to: sealPath) }
            let bytes = try store.readPrivate(sealPath)
            try store.maintainRetention()
            XCTAssertEqual(try store.locked { try store.isActiveLocked(operation.transactionID) }, corrupt)
            XCTAssertEqual(try store.readPrivate(sealPath), bytes)
            XCTAssertTrue(try store.load(operation.transactionID, target: authority.row.modelID).terminal)
        }
    }

    func testCapturedActiveReceiptRejectsReplacedAndInPlaceChangedPrimary() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for inPlace in [false, true] {
            let store = try makeStore()
            let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID, target: authority.row.modelID,
                kind: "prepare_model", operationGeneration: operation.operationGeneration)
            let receipt = try store.captureActiveReceipt(selector: selector)
            let path = store.root.appendingPathComponent(operation.transactionID + ".json")
            let original = try store.readPrivate(path)
            if inPlace {
                let handle = try FileHandle(forWritingTo: path)
                try handle.seek(toOffset: 0); try handle.write(contentsOf: Data("[".utf8)); try handle.synchronize(); try handle.close()
            } else { try store.writePrivate(original, to: path) }
            let changed = try store.readPrivate(path)
            var proposed = receipt.record; proposed.cancelRequested = true
            store.append(&proposed, state: "cancel_requested")
            XCTAssertThrowsError(try store.commit(record: proposed, receipt: receipt))
            XCTAssertEqual(try store.readPrivate(path), changed)
        }
    }

    func testNearLimitSealValidationRunsOutsideJournalAndIsPreserved() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        var store = try makeStore()
        let operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
        var record = try store.load(operation.transactionID, target: authority.row.modelID)
        record.startedAt = Date(); store.append(&record, state: "running")
        let snapshot = ModelCatalogArtifactSnapshot(root: .init(try ModelTransactionDirectory.current(store.root).info()), entries: [])
        var seal = try JSONEncoder().encode(ModelCatalogArtifactSeal(record: record, snapshot: snapshot))
        seal.append(Data(repeating: 0x20, count: 4_194_304 - seal.count))
        record.artifactSealSHA256 = SHA256.hash(data: seal).map { String(format: "%02x", $0) }.joined()
        record.committed = true; store.append(&record, state: "succeeded")
        try store.writePrivate(seal, to: store.root.appendingPathComponent(operation.transactionID + ".seal"))
        try store.write(record)
        store.retentionBoundary = { point in
            if point == "bulk_read" { XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory) }
        }
        try store.maintainRetention()
        XCTAssertFalse(try store.locked { try store.isActiveLocked(operation.transactionID) })
        XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".seal")), seal)
    }

    func testSupportedLegacyHistoryRetiresWithoutInventingOperationGeneration() throws {
        var store = try makeStore()
        let lockProbe = MigrationLockProbe()
        store.retentionBoundary = { lockProbe.observe($0) }
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        try store.secure()
        let result = try fixtureResult(authority, inputs: inputs)
        let resultHash = SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined()
        var history: [(String, Data)] = []
        for _ in 0..<ModelCatalogTransactionStore.activeTransactionLimit {
            let id = UUID().uuidString.lowercased()
            var record = ModelCatalogTransactionRecord(transactionID: id, target: authority.row.modelID,
                modelKey: authority.modelKey, kind: "evaluate_model", revision: authority.row.modelRevision!,
                sha256: authority.row.modelSHA256!, candidateDigest: authority.candidateDigest,
                artifactDigest: authority.artifactDigest, signerKeyID: authority.signerKeyID, createdAt: Date())
            record.operationGeneration = nil; record.schema = nil; record.startedAt = Date()
            store.append(&record, state: "queued"); store.append(&record, state: "running")
            record.committed = true; record.resultSHA256 = resultHash; store.append(&record, state: "succeeded")
            let bytes = try JSONEncoder().encode(record)
            try store.writePrivate(bytes, to: store.root.appendingPathComponent(id + ".json"))
            try store.writePrivate(result, to: store.root.appendingPathComponent(id + ".result"))
            history.append((id, bytes))
        }
        // Exhaust three real eight-second migration budgets after acknowledged
        // pages. Subsequent calls resume the durable prefix, not its bodies.
        var previousPrefix = 0
        for _ in 0..<3 {
            var bounded = store
            let probe = MigrationBudgetProbe()
            bounded.retentionBoundary = { lockProbe.observe($0); probe.observe($0) }
            let began = Date()
            XCTAssertThrowsError(try bounded.initializeRetention()) { error in
                guard case ModelCatalogTransactionError.busy = error else { return XCTFail("wrong migration deadline: \(error)") }
            }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 8)
            let progressURL = store.root.appendingPathComponent(".binding-migration/progress.json")
            let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as? [String: Any])
            let prefix = try XCTUnwrap(progress["entries"] as? [[String: Any]])
            XCTAssertGreaterThan(prefix.count, previousPrefix)
            previousPrefix = prefix.count
        }
        // Reservation migration has its own durable prefix and budget after the
        // binding graph reaches v3. Complete that structural pass explicitly so
        // the maintenance assertions below measure retirement rather than a
        // different migration phase.
        for pass in 0..<32 {
            let phase = (try? store.loadActiveIndexLocked().reservationPhase) ?? "binding"
            if phase == "complete" { break }
            let began = Date()
            var outcome = "complete"
            do { _ = try store.initializeRetention() }
            catch ModelCatalogTransactionError.busy { outcome = "busy" }
            let current = (try? store.loadActiveIndexLocked().reservationPhase) ?? "binding"
            print("RETENTION_RESERVATION_MIGRATION_PASS pass=\(pass) outcome=\(outcome) phase=\(current) seconds=\(Date().timeIntervalSince(began))")
        }
        XCTAssertEqual(try store.loadActiveIndexLocked().reservationPhase, "complete")
        // Bounded passes may stop on their deadline; committed retirement and
        // the cursor make the next pass progress without scanning history.
        for pass in 0..<16 {
            let decodedBefore = lockProbe.indexDecodes
            let began = Date()
            var outcome = "complete"
            do { try store.maintainRetention() }
            catch ModelCatalogTransactionError.busy { outcome = "busy" }
            catch ModelTransactionIndexPublicationError.interrupted { outcome = "interrupted" }
            XCTAssertEqual(lockProbe.indexDecodes - decodedBefore, 2,
                "v4 maintenance decodes its initial receipt and recaptured post-retirement index")
            let remaining = try store.locked { try store.activeSnapshotLocked().count }
            print("RETENTION_LEGACY_PASS pass=\(pass) outcome=\(outcome) remaining=\(remaining) seconds=\(Date().timeIntervalSince(began)) decodes=\(lockProbe.indexDecodes - decodedBefore)")
            if remaining == 0 { break }
        }
        XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, 0)
        XCTAssertTrue(try pointerFiles(store).isEmpty)
        let completion = try store.captureMigrationCompletion()
        let decoded = lockProbe.count
        for _ in 0..<3 { _ = try store.snapshotIndex(migration: completion) }
        XCTAssertEqual(lockProbe.count, decoded, "receipt reuse must not decode the full ledger again")
        XCTAssertGreaterThan(decoded, 0)
        let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
        XCTAssertNotNil(UUID(uuidString: operation.operationGeneration))
        for (id, bytes) in history {
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), bytes)
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".result")), result)
            XCTAssertNil(try store.load(id, target: authority.row.modelID).selector)
        }
    }

    func testAtomicReplacementAfterOpenIsChangedButHardlinkRemainsUnsafe() throws {
        let store = try makeStore(); try store.secure()
        let directory = try ModelTransactionDirectory.current(store.root)
        try directory.write(Data("original".utf8), name: "observation")
        XCTAssertThrowsError(try directory.openFile("observation", flags: O_RDONLY, afterOpen: {
            try directory.write(Data("replaced".utf8), name: "observation")
        })) { error in
            guard case ModelCatalogRetentionError.changed = error else { return XCTFail("wrong replacement classification: \(error)") }
        }
        XCTAssertEqual(try directory.read("observation"), Data("replaced".utf8))
        XCTAssertEqual(linkat(directory.fd, "observation", directory.fd, "hardlink", 0), 0)
        XCTAssertThrowsError(try directory.openFile("observation", flags: O_RDONLY)) { error in
            guard case ModelCatalogRetentionError.unsafe = error else { return XCTFail("hardlink was not rejected: \(error)") }
        }
    }

    func testMissingBindingAndOriginDowngradesStayProtectedAfterArchive() throws {
        let inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for archived in [false, true] {
            for corruption in ["binding", "origin", "downgrade", "certificate", "index"] where archived || corruption != "certificate" {
                let store = try makeStore()
                let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
                try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
                let id = operation.transactionID, directory = try ModelTransactionDirectory.current(store.root)
                if archived { try store.maintainRetention() }
                let pointer = try pointerFiles(store)
                let original = try store.load(id, target: authority.row.modelID)
                switch corruption {
                case "binding": XCTAssertEqual(unlinkat(directory.fd, id + ".success-binding", 0), 0)
                case "origin": XCTAssertEqual(unlinkat(directory.fd, id + ".origin", 0), 0)
                case "certificate": XCTAssertEqual(unlinkat(directory.fd, id + ".retired", 0), 0)
                case "index":
                    try Data("invalid".utf8).write(to: store.root.appendingPathComponent(".retention-v2/active.json"))
                default:
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.readPrivate(store.root.appendingPathComponent(id + ".json"))) as? [String: Any])
                    object.removeValue(forKey: "schema"); object.removeValue(forKey: "operationGeneration")
                    var events = try XCTUnwrap(object["events"] as? [[String: Any]])
                    for offset in events.indices { events[offset]["operation_generation"] = NSNull() }
                    object["events"] = events
                    let bytes = try JSONSerialization.data(withJSONObject: object)
                    try store.writePrivate(bytes, to: store.root.appendingPathComponent(id + ".json"))
                    let falseOrigin = ModelTransactionOrigin(schema: "model_catalog_transaction_origin.v1", transactionID: id,
                        provenance: .legacySnapshot(primarySHA256: store.digest(bytes)))
                    try store.writePrivate(store.bindingBytes(falseOrigin), to: store.root.appendingPathComponent(id + ".origin"))
                }
                XCTAssertThrowsError(try store.validateOriginalBindingEvidence(original), corruption)
                XCTAssertThrowsError(try store.indexedRecommendation(authority: authority, inputs: inputs,
                    chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture"), corruption)
                if corruption != "index" {
                    try store.maintainRetention()
                    XCTAssertEqual(try store.locked { try store.isActiveLocked(id) }, !archived)
                }
                XCTAssertEqual(try pointerFiles(store), pointer)
                if corruption == "binding" { XCTAssertNil(try directory.metadata(id + ".success-binding")) }
                if corruption == "origin" { XCTAssertNil(try directory.metadata(id + ".origin")) }
                if corruption == "certificate" { XCTAssertNil(try directory.metadata(id + ".retired")) }
            }
        }
    }

    func testPendingAndAcknowledgedMigrationNeverReclassifyChangedPrimary() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for point in ["binding_migration_decision", "binding_migration_origin", "binding_migration_acknowledged"] {
            let store = try makeStore()
            let id = try seedHistoricalRecord(store, authority: authority, generated: true)
            var interrupted = store
            interrupted.retentionBoundary = { if $0 == point { throw Injected.stop } }
            XCTAssertThrowsError(try interrupted.initializeRetention())
            let directory = try ModelTransactionDirectory.current(store.root)
            if try directory.metadata(id + ".origin") != nil { XCTAssertEqual(unlinkat(directory.fd, id + ".origin", 0), 0) }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.readPrivate(store.root.appendingPathComponent(id + ".json"))) as? [String: Any])
            object.removeValue(forKey: "schema"); object.removeValue(forKey: "operationGeneration")
            var events = try XCTUnwrap(object["events"] as? [[String: Any]])
            for position in events.indices { events[position]["operation_generation"] = NSNull() }
            object["events"] = events
            try store.writePrivate(JSONSerialization.data(withJSONObject: object), to: store.root.appendingPathComponent(id + ".json"))
            XCTAssertThrowsError(try store.initializeRetention(), point)
            XCTAssertNil(try directory.metadata(id + ".origin"), point)
        }
    }

    func testMigrationFinalIndexMustMatchPinnedCompleteContents() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for mutation in ["omitted", "phase", "origin", "source", "migration", "duplicate", "missing_progress"] {
            let store = try makeStore()
            _ = try seedHistoricalRecord(store, authority: authority, generated: false)
            var interrupted = store
            interrupted.retentionBoundary = { if $0 == "binding_migration_index" { throw Injected.stop } }
            XCTAssertThrowsError(try interrupted.initializeRetention())
            let indexURL = store.root.appendingPathComponent(".retention-v2/active.json")
            if mutation == "missing_progress" {
                let directory = try ModelTransactionDirectory.current(store.root).child(".binding-migration")
                XCTAssertEqual(unlinkat(directory.fd, "progress.json", 0), 0)
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                switch mutation {
                case "omitted": entries = []
                case "phase": entries[0]["phase"] = "allocating"
                case "origin": entries[0]["originSHA256"] = String(repeating: "f", count: 64)
                case "source": object["migrationSourceSHA256"] = String(repeating: "f", count: 64)
                case "migration": object["migrationID"] = UUID().uuidString.lowercased()
                default: entries.append(entries[0])
                }
                object["entries"] = entries
                try JSONSerialization.data(withJSONObject: object).write(to: indexURL)
            }
            XCTAssertThrowsError(try store.initializeRetention(), mutation)
            XCTAssertThrowsError(try store.reserveOperation(authority: authority, kind: "prepare_model"), mutation)
        }
    }

    func testActualMigrationAndCertificateCrashBoundariesResumeExactly() throws {
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        for point in ["binding_migration_initial_source", "binding_migration_initial_progress", "binding_migration_prepared",
                      "binding_migration_decision", "binding_migration_origin", "binding_migration_acknowledged",
                      "binding_migration_finalizing", "binding_migration_index", "binding_migration_complete"] {
            let store = try makeStore()
            let id = try seedHistoricalRecord(store, authority: authority, generated: false)
            let primary = try store.readPrivate(store.root.appendingPathComponent(id + ".json"))
            try retentionChild(store, point: point)
            let restarted = ModelCatalogTransactionStore(root: store.root)
            try restarted.initializeRetention()
            let originBefore = try restarted.readPrivate(restarted.root.appendingPathComponent(id + ".origin"))
            try restarted.maintainRetention()
            XCTAssertEqual(try restarted.readPrivate(restarted.root.appendingPathComponent(id + ".json")), primary)
            XCTAssertEqual(try restarted.readPrivate(restarted.root.appendingPathComponent(id + ".origin")), originBefore)
            XCTAssertFalse(try restarted.locked { try restarted.isActiveLocked(id) })
            XCTAssertNoThrow(try restarted.validateOriginalBindingEvidence(restarted.load(id, target: authority.row.modelID)))
        }
    }

    func testRetirementCertificateRejectsEveryLaterMutationAndMissingEvidence() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for kind in ["prepare_model", "evaluate_model"] {
            for state in ["succeeded", "failed", "cancelled", "timed_out"] {
                let store = try makeStore()
                let operation = try store.reserveOperation(authority: authority, kind: kind)
                try terminalFixture(store, operation: operation, authority: authority, inputs: inputs, kind: kind,
                    state: state, committed: state == "succeeded")
                var interrupted = store
                interrupted.retentionBoundary = { if $0 == "retirement_certificate" { throw Injected.stop } }
                XCTAssertThrowsError(try interrupted.maintainRetention()) // Partial publication stops this pass.
                XCTAssertTrue(try store.locked { try store.isActiveLocked(operation.transactionID) })
                let record = try store.load(operation.transactionID, target: authority.row.modelID)
                XCTAssertNotNil(try ModelTransactionDirectory.current(store.root).metadata(operation.transactionID + ".retired"))
                XCTAssertThrowsError(try store.captureActiveReceipt(selector: XCTUnwrap(record.selector)))
                try store.maintainRetention()
                XCTAssertFalse(try store.locked { try store.isActiveLocked(operation.transactionID) })
                XCTAssertNoThrow(try store.validateOriginalBindingEvidence(record))
                if kind == "prepare_model" || state != "succeeded" {
                    var changed = record; changed.cancelRequested.toggle()
                    try store.writePrivate(JSONEncoder().encode(changed), to: store.root.appendingPathComponent(operation.transactionID + ".json"))
                    XCTAssertThrowsError(try store.validateOriginalBindingEvidence(changed))
                }
            }
        }
    }

    private func terminalFixture(_ store: ModelCatalogTransactionStore, operation: ModelCatalogTransactionReservation,
                                 authority: ModelCatalogTransactionAuthority, inputs: ModelCatalogRecommendationInputs,
                                 kind: String, state: String, committed: Bool) throws {
        if kind == "evaluate_model", state == "succeeded" {
            try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
            return
        }
        var record = try store.load(operation.transactionID, target: authority.row.modelID)
        if state != "timed_out" || committed { record.startedAt = Date(); store.append(&record, state: "running") }
        if committed {
            let suffix: String, bytes: Data
            if kind == "prepare_model" {
                let snapshot = ModelCatalogArtifactSnapshot(root: .init(try ModelTransactionDirectory.current(store.root).info()), entries: [])
                bytes = try JSONEncoder().encode(ModelCatalogArtifactSeal(record: record, snapshot: snapshot)); suffix = ".seal"
                record.artifactSealSHA256 = store.digest(bytes)
            } else {
                bytes = try fixtureResult(authority, inputs: inputs); suffix = ".result"; record.resultSHA256 = store.digest(bytes)
            }
            try store.writePrivate(bytes, to: store.root.appendingPathComponent(operation.transactionID + suffix))
            record.committed = true
        }
        store.append(&record, state: state)
        try store.writePrivate(JSONEncoder().encode(record), to: store.root.appendingPathComponent(operation.transactionID + ".json"))
    }

    private func seedHistoricalRecord(_ store: ModelCatalogTransactionStore, authority: ModelCatalogTransactionAuthority,
                                      generated: Bool) throws -> String {
        try store.secure()
        let id = UUID().uuidString.lowercased()
        var record = ModelCatalogTransactionRecord(transactionID: id, target: authority.row.modelID,
            modelKey: authority.modelKey, kind: "prepare_model", revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!,
            candidateDigest: authority.candidateDigest, artifactDigest: authority.artifactDigest,
            signerKeyID: authority.signerKeyID, createdAt: Date())
        if !generated { record.operationGeneration = nil; record.schema = nil }
        store.append(&record, state: "queued"); store.append(&record, state: "cancelled")
        try store.writePrivate(JSONEncoder().encode(record), to: store.root.appendingPathComponent(id + ".json"))
        return id
    }

    private func retentionChild(_ store: ModelCatalogTransactionStore, point: String) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogTransactionRetentionTests/testRetentionCrashSubprocessEntry", Bundle(for: Self.self).bundlePath]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": store.root.deletingLastPathComponent().path,
            "BUILD1_RETENTION_ROOT": store.root.path, "BUILD1_RETENTION_POINT": point]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(15)
        while child.isRunning && Date() < deadline { usleep(10_000) }
        guard !child.isRunning else {
            child.terminate(); XCTFail("retention helper timed out at " + point)
            throw ModelCatalogTransactionError.timedOut
        }
        XCTAssertEqual(child.terminationStatus, 91, point)
    }

    func testCompletedMigrationReceiptRejectsChangedFilesBeforePrimaryMutation() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for name in ["source.json", "progress.json"] {
            for mutation in ["replace", "in_place", "remove", "hardlink", "symlink", "mode", "lineage"] {
                let store = try makeStore(), operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
                let record = try store.load(operation.transactionID, target: authority.row.modelID)
                let receipt = try store.captureActiveReceipt(selector: XCTUnwrap(record.selector))
                let directory = try ModelTransactionDirectory.current(store.root).child(".binding-migration")
                let before = try directory.read(name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                let primary = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))
                switch mutation {
                case "replace": try directory.write(before, name: name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                case "in_place":
                    let descriptor = try directory.openFile(name, flags: O_WRONLY | O_APPEND)
                    XCTAssertEqual(Darwin.write(descriptor, " ", 1), 1); close(descriptor)
                case "remove": XCTAssertEqual(unlinkat(directory.fd, name, 0), 0)
                case "hardlink": XCTAssertEqual(linkat(directory.fd, name, directory.fd, "copy", 0), 0)
                case "symlink":
                    try directory.write(before, name: "copy", maxBytes: ModelCatalogTransactionStore.indexLimit)
                    XCTAssertEqual(unlinkat(directory.fd, name, 0), 0)
                    XCTAssertEqual(symlinkat("copy", directory.fd, name), 0)
                case "mode": XCTAssertEqual(fchmodat(directory.fd, name, 0o644, 0), 0)
                default:
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
                    object["migrationID"] = UUID().uuidString.lowercased()
                    try directory.write(JSONSerialization.data(withJSONObject: object), name: name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                }
                var changed = record; store.append(&changed, state: "cancelled")
                XCTAssertThrowsError(try store.commit(record: changed, receipt: receipt), name + ":" + mutation)
                XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json")), primary)
                if mutation == "replace" || (name == "progress.json" && mutation == "in_place") {
                    XCTAssertNoThrow(try store.captureMigrationCompletion())
                } else { XCTAssertThrowsError(try store.captureMigrationCompletion()) }
            }
        }
    }

    func testReusedMigrationReceiptKeepsOriginalOperationDeadline() throws {
        let store = try makeStore()
        try store.initializeRetention()
        let budget = ModelTransactionWorkBudget(seconds: 1)
        let receipt = try store.captureMigrationCompletion(budget: budget)
        _ = try store.snapshotIndex(budget: budget, migration: receipt)
        Thread.sleep(forTimeInterval: 1.05)
        XCTAssertThrowsError(try store.snapshotIndex(migration: receipt)) { error in
            guard case ModelCatalogTransactionError.busy = error else { return XCTFail("receipt refreshed its deadline: \(error)") }
        }
    }

    func testMigrationRetainedStateRejectsChangesAtDecisionAndAcknowledgment() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for point in ["migration_decision_captured", "migration_acknowledgment_captured"] {
            for name in ["source.json", "progress.json", "active.json"] {
                let store = try makeStore()
                let id = try seedHistoricalRecord(store, authority: authority, generated: false)
                let primary = try store.readPrivate(store.root.appendingPathComponent(id + ".json"))
                var interrupted = store
                interrupted.retentionBoundary = { event in
                    guard event == point else { return }
                    XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory)
                    let directory = try ModelTransactionDirectory.current(store.root).child(name == "active.json" ? ".retention-v2" : ".binding-migration")
                    let bytes = try directory.read(name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                    try directory.write(bytes, name: name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                }
                XCTAssertThrowsError(try interrupted.initializeRetention())
                XCTAssertNil(try ModelTransactionDirectory.current(store.root).metadata(id + ".origin"))
                XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), primary)
                // Replacement invalidates the old descriptor, while unchanged
                // durable bytes remain valid for a fresh bounded restart.
                try store.initializeRetention()
                XCTAssertEqual(try store.snapshotIndex().entries.first?.provenance, "legacy_snapshot")
                XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), primary)
            }
        }
    }

    func testMigrationRejectsProgressChangedAfterFsyncBeforeRecapture() throws {
        let store = try makeStore(), inputs = try fixtureInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let id = try seedHistoricalRecord(store, authority: authority, generated: false)
        var interrupted = store
        interrupted.retentionBoundary = { event in
            guard event == "migration_before_progress_recapture" else { return }
            XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory)
            let directory = try ModelTransactionDirectory.current(store.root).child(".binding-migration")
            var bytes = try directory.read("progress.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
            bytes.append(Data(" ".utf8))
            try directory.write(bytes, name: "progress.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
        }
        XCTAssertThrowsError(try interrupted.initializeRetention())
        XCTAssertNil(try ModelTransactionDirectory.current(store.root).metadata(id + ".origin"))
        let directory = try ModelTransactionDirectory.current(store.root).child(".binding-migration")
        let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: directory.read("progress.json", maxBytes: ModelCatalogTransactionStore.indexLimit)) as? [String: Any])
        XCTAssertNotNil(progress["pending"])
        XCTAssertEqual((progress["entries"] as? [Any])?.count, 0)
        try store.initializeRetention()
        XCTAssertEqual(try store.snapshotIndex().entries.first?.provenance, "legacy_snapshot")
    }

    func testSameGenerationProvenanceReferenceChangesRejectCapturedMutation() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for field in ["origin", "provenance", "binding", "remove_binding"] {
            let store = try makeStore()
            let kind = field == "remove_binding" ? "evaluate_model" : "prepare_model"
            let operation = try store.reserveOperation(authority: authority, kind: kind)
            if kind == "evaluate_model" {
                try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
            }
            let record = try store.load(operation.transactionID, target: authority.row.modelID)
            let receipt = try store.captureActiveReceipt(selector: XCTUnwrap(record.selector))
            let originalBytes = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))
            var index = try store.snapshotIndex()
            let position = try XCTUnwrap(index.entries.firstIndex { $0.id == operation.transactionID })
            switch field {
            case "origin": index.entries[position].originSHA256 = String(repeating: "a", count: 64)
            case "provenance": index.entries[position].provenance = "protected_snapshot"
            case "binding": index.entries[position].bindingSHA256 = String(repeating: "b", count: 64)
            default: index.entries[position].bindingSHA256 = nil
            }
            let tampered = try store.canonicalData(index)
            try store.retentionDirectory().write(tampered, name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
            var changed = record
            if record.terminal { changed.cleanupRequired = true }
            else { store.append(&changed, state: "cancelled") }
            XCTAssertThrowsError(try store.commit(record: changed, receipt: receipt)) { error in
                switch error {
                case ModelCatalogRetentionError.unsafe, ModelCatalogRetentionError.changed: break
                default: XCTFail("wrong reference mismatch: \(error)")
                }
            }
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json")), originalBytes)
            XCTAssertEqual(try store.retentionDirectory().read("active.json", maxBytes: ModelCatalogTransactionStore.indexLimit), tampered)
        }
    }

    func testSameGenerationLegacyReferenceChangeCannotRetireCapturedEvidence() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for field in ["origin", "provenance", "binding"] {
            let store = try makeStore()
            let id = try seedHistoricalRecord(store, authority: authority, generated: false)
            try store.initializeRetention()
            let original = try store.readPrivate(store.root.appendingPathComponent(id + ".json"))
            var interrupted = store
            interrupted.retentionBoundary = { point in
                guard point == "retirement_captured" else { return }
                var index = try store.snapshotIndex()
                let position = try XCTUnwrap(index.entries.firstIndex { $0.id == id })
                switch field {
                case "origin": index.entries[position].originSHA256 = String(repeating: "a", count: 64)
                case "provenance": index.entries[position].provenance = "protected_snapshot"
                default: index.entries[position].bindingSHA256 = String(repeating: "b", count: 64)
                }
                try store.retentionDirectory().write(store.canonicalData(index), name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
            }
            XCTAssertThrowsError(try interrupted.maintainRetention())
            XCTAssertTrue(try store.locked { try store.isActiveLocked(id) })
            XCTAssertNil(try ModelTransactionDirectory.current(store.root).metadata(id + ".retired"))
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), original)
        }
    }

    func testNewSidecarCorruptionAndStaleReceiptsNeverAuthorizeArchive() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for suffix in [".origin", ".success-binding", ".retired"] {
            for mutation in ["unknown", "duplicate", "oversized", "symlink", "hardlink", "mode", "in_place", "replaced"] {
                let store = try makeStore()
                let operation = try store.reserveOperation(authority: authority, kind: "evaluate_model")
                try completeEvaluation(store, operation: operation, authority: authority, inputs: inputs, index: true)
                if suffix == ".retired" { try store.maintainRetention() }
                let id = operation.transactionID, path = store.root.appendingPathComponent(id + suffix)
                let record = try store.load(id, target: authority.row.modelID)
                let observation = try store.evidence(id + suffix, budget: .init(), maxBytes: 16_384)
                let bytes = try XCTUnwrap(observation.bytes)
                switch mutation {
                case "unknown":
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    object["unrecognized"] = true
                    try store.writePrivate(JSONSerialization.data(withJSONObject: object), to: path)
                case "duplicate":
                    var changed = Data("{\"schema\":\"invalid\",".utf8); changed.append(bytes.dropFirst())
                    try store.writePrivate(changed, to: path)
                case "oversized": try store.writePrivate(Data(repeating: 0x20, count: 16_385), to: path)
                case "symlink":
                    let saved = path.appendingPathExtension("saved")
                    try FileManager.default.moveItem(at: path, to: saved)
                    XCTAssertEqual(symlink(saved.path, path.path), 0)
                case "hardlink": XCTAssertEqual(link(path.path, path.appendingPathExtension("copy").path), 0)
                case "mode": XCTAssertEqual(chmod(path.path, 0o644), 0)
                case "in_place":
                    let handle = try FileHandle(forWritingTo: path)
                    try handle.write(contentsOf: Data("[".utf8)); try handle.synchronize(); try handle.close()
                default: try store.writePrivate(bytes, to: path)
                }
                XCTAssertThrowsError(try observation.validate(), suffix + mutation)
                if mutation != "replaced" { XCTAssertThrowsError(try store.validateOriginalBindingEvidence(record), suffix + mutation) }
                // Identical-byte replacement may be freshly read as the same
                // immutable value, but the old in-flight receipt never survives.
            }
        }
    }

    func testHistoricalMatchingPointerCannotUpgradeUnboundGeneratedSuccess() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        let reference = try makeStore()
        let operation = try reference.reserveOperation(authority: authority, kind: "evaluate_model")
        try completeEvaluation(reference, operation: operation, authority: authority, inputs: inputs, index: true)
        let store = try makeStore(); try store.secure()
        let id = operation.transactionID
        var primary = try reference.readPrivate(reference.root.appendingPathComponent(id + ".json"))
        primary.append(Data(" \n".utf8)) // Historical serialization has no preterminal-byte proof.
        try store.writePrivate(primary, to: store.root.appendingPathComponent(id + ".json"))
        try store.writePrivate(reference.readPrivate(reference.root.appendingPathComponent(id + ".result")), to: store.root.appendingPathComponent(id + ".result"))
        let retention = try ModelTransactionDirectory.current(store.root).child(".retention-v2", create: true)
        let index = ModelTransactionActiveIndex(schema: "model_catalog_active_index.v2", generation: 1, entries: [.init(id: id, phase: "active")])
        try retention.write(store.canonicalData(index), name: "active.json", exclusive: true)
        try retention.write(Data("{\"schema\":\"model_catalog_retention.v2\"}".utf8), name: "format.json", exclusive: true)
        let pointers = try pointerFiles(reference)
        for (name, data) in pointers {
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            old["schema"] = "model_catalog_recommendation_pointer.v1"
            old.removeValue(forKey: "originSHA256"); old.removeValue(forKey: "bindingSHA256")
            let directory = try retention.child("recommendations", create: true).child(String(name.prefix(2)), create: true)
            try directory.write(JSONSerialization.data(withJSONObject: old), name: name, exclusive: true)
        }
        let before = try pointerFiles(store)
        try store.initializeRetention(); try store.maintainRetention()
        XCTAssertEqual(try store.snapshotIndex().entries.first?.provenance, "protected_snapshot")
        XCTAssertTrue(try store.locked { try store.isActiveLocked(id) })
        XCTAssertThrowsError(try store.indexedRecommendation(authority: authority, inputs: inputs,
            chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture"))
        XCTAssertNil(try ModelTransactionDirectory.current(store.root).metadata(id + ".success-binding"))
        XCTAssertEqual(try pointerFiles(store), before)
        XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), primary)
    }

    func testPublicMaintenanceSharesOneIndexDecodeThroughRecoveryAndArchivedPointer() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for recoverAllocation in [false, true] {
            var store = try makeStore()
            let older = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            try completeEvaluation(store, operation: older, authority: authority, inputs: inputs, index: true)
            try store.maintainRetention()
            let next = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            try completeEvaluation(store, operation: next, authority: authority, inputs: inputs, index: false)
            if recoverAllocation {
                var interrupted = store
                interrupted.retentionBoundary = { if $0 == "allocation_intent" { throw Injected.stop } }
                XCTAssertThrowsError(try interrupted.reserveOperation(authority: authority, kind: "prepare_model"))
            }
            let probe = MigrationLockProbe()
            store.retentionBoundary = { probe.observe($0) }
            try store.maintainRetention()
            XCTAssertEqual(probe.indexDecodes, 2,
                "v4 maintenance decodes the initial receipt and the recaptured post-retirement index")
            XCTAssertEqual(try store.locked { try store.activeSnapshotLocked().count }, 0)
            XCTAssertEqual(try store.indexedRecommendation(authority: authority, inputs: inputs,
                chip: "Fixture Chip", memoryGB: 64, binaryVersion: "fixture")?.transactionID, next.transactionID)
        }
    }

    func testIndexReceiptRejectsReplacementAndSubstitutionBeforeRetirementOrCursor() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for point in ["retirement_captured", "retention_cursor_captured"] {
            for name in ["active.json", "format.json"] {
                let mutations = ["replace", "in_place", "remove", "hardlink", "symlink", "mode"] +
                    (name == "active.json" ? ["generation", "lineage", "membership", "origin", "binding"] : ["schema"])
                for mutation in mutations {
                    let store = try makeStore(), operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
                    if point == "retirement_captured" {
                        _ = try store.reconcile(.init(transactionID: operation.transactionID, target: authority.row.modelID,
                            kind: "prepare_model", operationGeneration: operation.operationGeneration), cancel: true)
                    }
                    let primary = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))
                    let directory = try store.retentionDirectory()
                    let cursor = try directory.metadata("maintenance.json")
                    XCTAssertNil(cursor)
                    let fired = OnceProbe()
                    var interrupted = store
                    interrupted.retentionBoundary = { event in
                        guard event == point, fired.claim() else { return }
                        XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory)
                        let before = try directory.read(name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                        switch mutation {
                        case "replace": try directory.write(before, name: name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                        case "in_place":
                            let fd = try directory.openFile(name, flags: O_WRONLY | O_APPEND)
                            XCTAssertEqual(Darwin.write(fd, " ", 1), 1); close(fd)
                        case "remove": XCTAssertEqual(unlinkat(directory.fd, name, 0), 0)
                        case "hardlink": XCTAssertEqual(linkat(directory.fd, name, directory.fd, "index-copy", 0), 0)
                        case "symlink":
                            try directory.write(before, name: "index-copy", maxBytes: ModelCatalogTransactionStore.indexLimit)
                            XCTAssertEqual(unlinkat(directory.fd, name, 0), 0)
                            XCTAssertEqual(symlinkat("index-copy", directory.fd, name), 0)
                        case "mode": XCTAssertEqual(fchmodat(directory.fd, name, 0o644, 0), 0)
                        default:
                            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
                            if mutation == "generation" { object["generation"] = (object["generation"] as! Int) + 1 }
                            else if mutation == "lineage" { object["migrationID"] = UUID().uuidString.lowercased() }
                            else if mutation == "membership" { object["entries"] = [] }
                            else if mutation == "schema" { object["schema"] = "unrecognized.v9" }
                            else {
                                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                                entries[0][mutation == "origin" ? "originSHA256" : "bindingSHA256"] = String(repeating: "f", count: 64)
                                object["entries"] = entries
                            }
                            try directory.write(JSONSerialization.data(withJSONObject: object), name: name, maxBytes: ModelCatalogTransactionStore.indexLimit)
                        }
                    }
                    XCTAssertThrowsError(try interrupted.maintainRetention(), point + ":" + name + ":" + mutation)
                    XCTAssertTrue(fired.fired)
                    XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json")), primary)
                    XCTAssertNil(try ModelTransactionDirectory.current(store.root).metadata(operation.transactionID + ".retired"))
                    XCTAssertNil(try directory.metadata("maintenance.json"))
                    if mutation == "schema" || mutation == "lineage" {
                        XCTAssertThrowsError(try store.initializeRetention())
                    }
                }
            }
        }
    }

    func testIndexRecaptureRejectsChangedPublishedBytesWithoutLaterCursor() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for malformed in [false, true] {
            let store = try makeStore()
            let prepare = try store.reserveOperation(authority: authority, kind: "prepare_model")
            let evaluate = try store.reserveOperation(authority: authority, kind: "evaluate_model")
            for (operation, kind) in [(prepare, "prepare_model"), (evaluate, "evaluate_model")] {
                _ = try store.reconcile(.init(transactionID: operation.transactionID, target: authority.row.modelID,
                    kind: kind, operationGeneration: operation.operationGeneration), cancel: true)
            }
            let sortedIDs = [prepare.transactionID, evaluate.transactionID].sorted()
            let retention = try store.retentionDirectory()
            let cursorBefore = try retention.read("maintenance.json", maxBytes: 4_096)
            let cursorInfo = try XCTUnwrap(retention.metadata("maintenance.json"))
            let lastID = try XCTUnwrap((JSONSerialization.jsonObject(with: cursorBefore) as? [String: Any])?["lastID"] as? String)
            let ids = sortedIDs.filter { $0 > lastID } + sortedIDs.filter { $0 <= lastID }
            let originals = try ids.map { try store.readPrivate(store.root.appendingPathComponent($0 + ".json")) }
            var interrupted = store
            interrupted.retentionBoundary = { point in
                guard point == "index_before_recapture" else { return }
                let directory = try store.retentionDirectory()
                var bytes = try directory.read("active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
                bytes.append(Data((malformed ? "invalid" : " ").utf8))
                try directory.write(bytes, name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
            }
            XCTAssertThrowsError(try interrupted.maintainRetention()) { error in
                guard case ModelTransactionIndexPublicationError.interrupted = error else { return XCTFail("wrong publication outcome: \(error)") }
            }
            XCTAssertEqual(try retention.read("maintenance.json", maxBytes: 4_096), cursorBefore)
            XCTAssertTrue(ModelTransactionFileEvidence.same(cursorInfo, try XCTUnwrap(retention.metadata("maintenance.json"))),
                "no cursor replacement after interrupted index recapture")
            let directory = try ModelTransactionDirectory.current(store.root)
            XCTAssertNotNil(try directory.metadata(ids[0] + ".retired"))
            XCTAssertNil(try directory.metadata(ids[1] + ".retired"), "no next-UUID publication after failed recapture")
            for (id, primary) in zip(ids, originals) {
                XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(id + ".json")), primary)
            }
            let restarted = ModelCatalogTransactionStore(root: store.root)
            if malformed { XCTAssertThrowsError(try restarted.maintainRetention()) }
            else {
                try restarted.maintainRetention()
                for id in ids {
                    XCTAssertNoThrow(try restarted.validateOriginalBindingEvidence(restarted.load(id, target: authority.row.modelID)))
                }
            }
        }
    }

    func testCompetingProcessAllocationInvalidatesCapturedAndPublishedIndexReceipt() throws {
        let inputs = try fixtureInputs(), authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: inputs)
        for point in ["retirement_captured", "index_before_recapture"] {
            let store = try makeStore(), operation = try store.reserveOperation(authority: authority, kind: "prepare_model")
            _ = try store.reconcile(.init(transactionID: operation.transactionID, target: authority.row.modelID,
                kind: "prepare_model", operationGeneration: operation.operationGeneration), cancel: true)
            let primary = try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json"))
            let captured = ConcurrentIndexProbe()
            var interrupted = store
            interrupted.retentionBoundary = { event in
                guard event == point, captured.once.claim() else { return }
                XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory)
                XCTAssertThrowsError(try store.ownerLock(operation.transactionID))
                try self.retentionChild(store, point: "concurrent_allocate")
                let directory = try store.retentionDirectory()
                captured.capture(index: try directory.read("active.json", maxBytes: ModelCatalogTransactionStore.indexLimit),
                    cursor: try directory.metadata("maintenance.json") == nil ? nil : directory.read("maintenance.json", maxBytes: 4_096))
            }
            XCTAssertThrowsError(try interrupted.maintainRetention(), point)
            XCTAssertTrue(captured.once.fired)
            let directory = try store.retentionDirectory()
            XCTAssertEqual(try directory.read("active.json", maxBytes: ModelCatalogTransactionStore.indexLimit), captured.index)
            let cursor = try directory.metadata("maintenance.json") == nil ? nil : directory.read("maintenance.json", maxBytes: 4_096)
            XCTAssertEqual(cursor, captured.cursor)
            let index = try store.snapshotIndex()
            XCTAssertTrue(index.entries.contains { $0.id != operation.transactionID && $0.provenance == "allocated" })
            XCTAssertEqual(try store.readPrivate(store.root.appendingPathComponent(operation.transactionID + ".json")), primary)
            XCTAssertEqual(try ModelTransactionDirectory.current(store.root).metadata(operation.transactionID + ".retired") != nil,
                point == "index_before_recapture")
            try store.maintainRetention()
        }
    }

    func testReusedIndexReceiptRetainsOriginalDeadline() throws {
        let store = try makeStore()
        try store.initializeRetention()
        let receipt = try store.captureIndexReceipt(budget: .init(seconds: 1))
        Thread.sleep(forTimeInterval: 1.05)
        XCTAssertThrowsError(try store.snapshotIndex(indexReceipt: receipt)) { error in
            guard case ModelCatalogTransactionError.busy = error else { return XCTFail("index receipt refreshed deadline: \(error)") }
        }
    }

    private final class OnceProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !value else { return false }; value = true; return true }
    }
    private final class ConcurrentIndexProbe: @unchecked Sendable {
        let once = OnceProbe()
        private(set) var index: Data?
        private(set) var cursor: Data?
        func capture(index: Data, cursor: Data?) { self.index = index; self.cursor = cursor }
    }

    private final class ReservationPhaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, completed = 0, cursors = 0
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return "scan_started=\(started) scan_completed=\(completed) cursor_published=\(cursors)"
        }
        func observe(_ point: String) {
            lock.lock(); defer { lock.unlock() }
            if point == "reservation_scan_started" { started += 1 }
            if point == "reservation_scan_complete" { completed += 1 }
            if point == "retention_cursor_published" { cursors += 1 }
        }
    }

    private final class MigrationLockProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var observations = 0
        private var decodes = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return observations }
        var indexDecodes: Int { lock.lock(); defer { lock.unlock() }; return decodes }
        func observe(_ point: String) {
            let migration = ["migration_bulk_read", "migration_decode", "migration_validate"].contains(point)
            let index = ["index_bulk_read", "index_decode", "index_encode"].contains(point)
            guard migration || index else { return }
            XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory, point)
            lock.lock()
            if migration { observations += 1 }
            if point == "index_decode" { decodes += 1 }
            lock.unlock()
        }
    }

    private final class MigrationBudgetProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var acknowledged = 0
        private var stalled = false
        func observe(_ point: String) {
            lock.lock()
            if point == "binding_migration_acknowledged" { acknowledged += 1 }
            let shouldStall = point == "bulk_read" && acknowledged >= 16 && !stalled
            if shouldStall { stalled = true }
            lock.unlock()
            if shouldStall {
                XCTAssertFalse(ModelTransactionDirectory.hasScopedDirectory)
                Thread.sleep(forTimeInterval: 8.05)
            }
        }
    }

    private final class OneShotProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        var happened: Bool { lock.lock(); defer { lock.unlock() }; return used }
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    private func completeEvaluation(_ store: ModelCatalogTransactionStore, operation: ModelCatalogTransactionReservation,
                                    authority: ModelCatalogTransactionAuthority, inputs: ModelCatalogRecommendationInputs,
                                    index: Bool, cleanup: Bool = false) throws {
        let data = try fixtureResult(authority, inputs: inputs)
        try store.locked {
            var record = try store.load(operation.transactionID, target: authority.row.modelID)
            if record.startedAt == nil { record.startedAt = Date(); store.append(&record, state: "running") }
            try store.writePrivate(data, to: store.root.appendingPathComponent(operation.transactionID + ".result"))
            record.resultSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            record.committed = true
            try store.write(record)
        }
        let selector = ModelCatalogTransactionSelector(transactionID: operation.transactionID, target: authority.row.modelID,
            kind: "evaluate_model", operationGeneration: operation.operationGeneration)
        let receipt = try store.captureActiveReceipt(selector: selector)
        let terminal = try store.evaluationSuccessTerminal(preterminal: receipt.record, cleanupRequired: cleanup)
        _ = try store.commitEvaluationSuccess(preterminal: receipt, terminal: terminal,
            result: store.evidence(operation.transactionID + ".result", budget: .init()))
        if index { try store.indexCompletedEvaluation(store.load(operation.transactionID, target: authority.row.modelID)) }
    }
    private func prepareCommittedEvaluation(_ store: ModelCatalogTransactionStore,
                                            operation: ModelCatalogTransactionReservation,
                                            authority: ModelCatalogTransactionAuthority,
                                            inputs: ModelCatalogRecommendationInputs) throws
        -> ModelCatalogTransactionSelector {
        let data = try fixtureResult(authority, inputs: inputs)
        try store.locked {
            var record = try store.load(operation.transactionID, target: authority.row.modelID)
            record.startedAt = Date(); store.append(&record, state: "running")
            try store.writePrivate(data, to: store.root.appendingPathComponent(operation.transactionID + ".result"))
            record.resultSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            record.committed = true
            try store.write(record)
        }
        return .init(transactionID: operation.transactionID, target: authority.row.modelID,
                     kind: "evaluate_model", operationGeneration: operation.operationGeneration)
    }
    private func pointerFiles(_ store: ModelCatalogTransactionStore) throws -> [String: Data] {
        let root = store.root.appendingPathComponent(".retention-v2/recommendations")
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var bytes: [String: Data] = [:]
        for case let url as URL in entries where url.pathExtension == "json" { bytes[url.lastPathComponent] = try Data(contentsOf: url) }
        return bytes
    }
    private func fixtureResult(_ authority: ModelCatalogTransactionAuthority, inputs: ModelCatalogRecommendationInputs) throws -> Data {
        // Storage fixture only: this document does not prove a measured runner or physical acceptance.
        try JSONSerialization.data(withJSONObject: [
            "schema_version": "autotune_recommend.v1", "generated_at": ISO8601DateFormatter().string(from: Date()),
            "recommended_model": authority.modelKey, "warnings": [String](),
            "inputs": ["rate_card_version": inputs.rateCard.value.version, "demand_rank_version": inputs.demand.value.version,
                       "candidate_catalog_version": inputs.candidate.value.version],
            "hardware": ["chip": "Fixture Chip", "memory_gb": 64, "binary_version": "fixture"],
            "candidates": [["model": authority.modelKey, "eligible": true]],
            "serve_config": ["model": authority.modelKey, "model_artifact_path": "/fixture/artifact",
                "model_artifact_sha256": authority.row.modelSHA256!, "model_catalog_key": authority.modelKey,
                "model_catalog_model_id": authority.row.modelID, "model_catalog_revision": authority.row.modelRevision!,
                "model_catalog_sha256": authority.row.modelSHA256!, "model_catalog_version": inputs.candidate.value.version,
                "model_catalog_hash": authority.candidateDigest, "max_context_override": 4096,
                "max_concurrency_override": 1, "donor_mode": false]
        ], options: [.sortedKeys])
    }
    private func fixtureInputs() throws -> ModelCatalogRecommendationInputs {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let candidate = try JSONSerialization.data(withJSONObject: corpus["candidate"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        var feed = try XCTUnwrap(corpus["feed"] as? [String: Any])
        feed["candidate_catalog_sha256"] = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate)
        let bytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "fixture-only"
        let qualified = try XCTUnwrap(AutotuneStaticInputs.usableArtifactFeed(bakedBytes: bytes, bakedSignerKeyID: signer,
            candidateBytes: candidate, candidateSignerKeyID: signer, now: ISO8601DateFormatter().date(from: "2026-07-11T00:00:00Z")!))
        let demand = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8), rate = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        return (.init(value: try AutotuneStaticInputs.decodeDemandRank(demand), selectedBytes: demand, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidate), selectedBytes: candidate, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeRateCard(rate), selectedBytes: rate, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: qualified, selectedBytes: bytes, warnings: [], usedFallback: false, signerKeyID: signer))
    }
    private func makeStore() throws -> ModelCatalogTransactionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelCatalogRetentionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ModelCatalogTransactionStore(root: root.appendingPathComponent(".transactions"))
    }
}
