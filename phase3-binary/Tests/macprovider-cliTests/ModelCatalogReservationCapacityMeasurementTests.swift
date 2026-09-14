import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// Measurement of the supported maximum shape, without a scheduling change or
/// artificial storage delay. A successful scan falsifies the expected starvation.
final class ModelCatalogReservationCapacityMeasurementTests: XCTestCase {
    private enum MeasurementError: Error { case insufficientDisk, setupDeadline, perRecordFeasibility, unexpectedProgress }
    private struct InvariantObservation {
        let phase: String
        let invariant: String
        let expected: String
        let actual: String
        let passes: Bool
        let message: String
    }
    private let primaryBytes = 4_194_304
    private let setupSeconds = 1_500.0

    func testMaximumShapeNaturalStorageReservationProgress() throws {
        let parent = FileManager.default.temporaryDirectory
        let available = try availableBytes(at: parent, scenario: "terminal_last", phase: "resource_preflight",
                                           failure: .insufficientDisk)
        print("RESERVATION_MAX_RESOURCES available_bytes=\(available) required_free_bytes=12884901888")
        try require(available >= 12 * 1_024 * 1_024 * 1_024, scenario: "terminal_last", phase: "resource_preflight",
                    invariant: "available_bytes", expected: ">=12884901888", actual: String(available),
                    message: "maximum-shape measurement requires at least 12 GiB free", failure: .insufficientDisk)
        let root = parent.appendingPathComponent("ReservationMaximumShape-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelCatalogTransactionStore(root: root.appendingPathComponent(".transactions"))
        let authority = try ModelCatalogTransactionAuthority.resolve(target: "test-model", inputs: fixtureInputs())
        let revision = try requireValue(authority.row.modelRevision, scenario: "terminal_last", phase: "fixture_authority",
                                        invariant: "model_revision", expected: "present",
                                        message: "fixture authority must provide a model revision")
        let modelSHA256 = try requireValue(authority.row.modelSHA256, scenario: "terminal_last", phase: "fixture_authority",
                                           invariant: "model_sha256", expected: "present",
                                           message: "fixture authority must provide a model SHA-256")
        try store.initializeRetention()
        var index = try store.snapshotIndex()
        let directory = try ModelTransactionDirectory.current(store.root)
        let started = DispatchTime.now().uptimeNanoseconds
        let setupDeadline = started + UInt64(setupSeconds * 1_000_000_000)
        var blockStarted = started
        var latestBlockSeconds = 0.0
        let createdAt = Date(), timestamp = ModelSwitchingWireCodec.timestamp()
        var baselines: [String: stat] = [:]
        var lastQueued = Data(), lastSelector: ModelCatalogTransactionSelector?
        var totalDecodeSeconds = 0.0, maxDecodeSeconds = 0.0
        let encoder = JSONEncoder()
        for position in 0..<ModelCatalogTransactionStore.activeTransactionLimit {
            try checkSetupDeadline(setupDeadline, started: started, root: root, completedRecords: position,
                                   validatedBytes: position * primaryBytes, latestBlockSeconds: latestBlockSeconds,
                                   phase: "before_record")
            let id = String(format: "%08x-0000-4000-8000-%012x", position + 1, position + 1)
            let generation = String(format: "%08x-0000-4000-8001-%012x", position + 1, position + 1)
            let last = position == ModelCatalogTransactionStore.activeTransactionLimit - 1
            let kind = last ? "evaluate_model" : "prepare_model"
            var record = ModelCatalogTransactionRecord(transactionID: id, target: authority.row.modelID,
                modelKey: authority.modelKey, kind: kind, revision: revision, sha256: modelSHA256,
                candidateDigest: authority.candidateDigest, artifactDigest: authority.artifactDigest,
                signerKeyID: authority.signerKeyID, createdAt: createdAt)
            record.operationGeneration = generation
            store.append(&record, state: "queued")
            let queued = try padded(encoder.encode(record), phase: "queued_primary_padding", id: id)
            let origin = try ModelTransactionOrigin.allocated(record, primarySHA256: store.digest(queued))
            let originBytes = try store.bindingBytes(origin)
            record.startedAt = createdAt
            for sequence in 2...2_048 {
                record.events.append(.init(transactionID: id, transactionKind: kind, operationGeneration: generation,
                    modelKey: authority.modelKey, eventSequence: UInt64(sequence), emittedAt: timestamp,
                    state: last && sequence == 2_048 ? "cancelled" : "running", progress: nil, errorCode: nil, warningCode: nil))
            }
            let bytes = try padded(encoder.encode(record), phase: "terminal_primary_padding", id: id)
            let beganDecode = DispatchTime.now().uptimeNanoseconds
            let decoded = try store.decodeRetentionRecord(bytes, id: id)
            let decodeSeconds = seconds(since: beganDecode)
            totalDecodeSeconds += decodeSeconds; maxDecodeSeconds = max(maxDecodeSeconds, decodeSeconds)
            try validate([
                .init(phase: "record_validation", invariant: "event_count", expected: "2048",
                      actual: String(decoded.events.count), passes: decoded.events.count == 2_048,
                      message: "terminal fixture record \(id) must contain exactly 2,048 events"),
                .init(phase: "record_validation", invariant: "primary_bytes", expected: String(primaryBytes),
                      actual: String(bytes.count), passes: bytes.count == primaryBytes,
                      message: "terminal fixture record \(id) must be exactly 4 MiB"),
                .init(phase: "record_validation", invariant: "record_state", expected: last ? "cancelled" : "running",
                      actual: decoded.events.last?.state ?? "nil",
                      passes: decoded.events.last?.state == (last ? "cancelled" : "running"),
                      message: "terminal fixture record \(id) must retain its intended final state"),
                .init(phase: "record_validation", invariant: "terminal_state", expected: String(last),
                      actual: String(decoded.terminal), passes: decoded.terminal == last,
                      message: "only the final terminal fixture record may be reclaimable"),
                .init(phase: "record_validation", invariant: "committed_or_cleanup_state", expected: "false",
                      actual: String(decoded.committed || decoded.cancelRequested || decoded.cleanupRequired),
                      passes: !(decoded.committed || decoded.cancelRequested || decoded.cleanupRequired),
                      message: "terminal fixture records must remain uncommitted, uncancelled by request, and cleanup-free"),
            ], scenario: "terminal_last")
            try origin.validate(decoded, primarySHA256: store.digest(bytes))
            try directory.write(bytes, name: id + ".json", exclusive: true)
            try directory.write(originBytes, name: id + ".origin", exclusive: true, maxBytes: 16_384)
            baselines[id + ".json"] = try requireValue(try directory.metadata(id + ".json"), scenario: "terminal_last",
                phase: "record_publication", invariant: "primary_metadata_\(id)", expected: "present",
                message: "published primary metadata must be present for \(id)")
            baselines[id + ".origin"] = try requireValue(try directory.metadata(id + ".origin"), scenario: "terminal_last",
                phase: "record_publication", invariant: "origin_metadata_\(id)", expected: "present",
                message: "published origin metadata must be present for \(id)")
            index.entries.append(.init(id: id, phase: "active", originSHA256: store.digest(originBytes), provenance: "allocated"))
            if last { lastQueued = queued; lastSelector = decoded.selector }
            let completedRecords = position + 1
            let completedAt = DispatchTime.now().uptimeNanoseconds
            if (position + 1) % 128 == 0 {
                latestBlockSeconds = intervalSeconds(from: blockStarted, to: completedAt)
                let currentAvailable = try availableBytes(at: root, scenario: "terminal_last", phase: "setup_checkpoint",
                                                         failure: .unexpectedProgress)
                print("RESERVATION_MAX_SETUP records=\(completedRecords) elapsed_seconds=\(intervalSeconds(from: started, to: completedAt)) block_seconds=\(latestBlockSeconds) block_seconds_per_record=\(latestBlockSeconds / 128.0) validated_bytes=\(completedRecords * primaryBytes) available_bytes=\(currentAvailable)")
                blockStarted = completedAt
            }
            try checkSetupDeadline(setupDeadline, now: completedAt, started: started, root: root,
                                   completedRecords: completedRecords, validatedBytes: completedRecords * primaryBytes,
                                   latestBlockSeconds: latestBlockSeconds, phase: "after_record")
        }
        index.generation += 1
        let indexBytes = try store.canonicalData(index), retention = try store.retentionDirectory()
        try checkSetupDeadline(setupDeadline, started: started, root: root,
                               completedRecords: ModelCatalogTransactionStore.activeTransactionLimit,
                               validatedBytes: ModelCatalogTransactionStore.activeTransactionLimit * primaryBytes,
                               latestBlockSeconds: latestBlockSeconds, phase: "before_index_publication")
        try retention.write(indexBytes, name: "active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
        let indexInfo = try requireValue(try retention.metadata("active.json"), scenario: "terminal_last",
            phase: "index_publication", invariant: "active_index_metadata", expected: "present",
            message: "published active index metadata must be present")
        let selector = try requireValue(lastSelector, scenario: "terminal_last", phase: "fixture_shape",
            invariant: "last_selector", expected: "present", message: "last fixture selector must be present")
        let publishedIndex = try store.snapshotIndex()
        let fixtureIDs = publishedIndex.entries.map(\.id)
        let baselineMaintenance = try retention.metadata("maintenance.json")
        try validate([
            .init(phase: "fixture_shape", invariant: "active_index_entries", expected: "1024",
                  actual: String(publishedIndex.entries.count), passes: publishedIndex.entries.count == 1_024,
                  message: "active index must contain exactly 1,024 entries"),
            .init(phase: "fixture_shape", invariant: "distinct_active_ids", expected: "1024",
                  actual: String(Set(fixtureIDs).count), passes: Set(fixtureIDs).count == 1_024,
                  message: "active index must contain 1,024 distinct transaction IDs"),
            .init(phase: "fixture_shape", invariant: "sorted_active_ids", expected: "true",
                  actual: String(fixtureIDs == fixtureIDs.sorted()), passes: fixtureIDs == fixtureIDs.sorted(),
                  message: "active index transaction IDs must be sorted"),
            .init(phase: "fixture_shape", invariant: "active_allocated_entries", expected: "1024",
                  actual: String(publishedIndex.entries.filter { $0.phase == "active" && $0.provenance == "allocated" }.count),
                  passes: publishedIndex.entries.allSatisfy { $0.phase == "active" && $0.provenance == "allocated" },
                  message: "every active index entry must retain allocated provenance"),
            .init(phase: "fixture_shape", invariant: "baseline_maintenance", expected: "absent",
                  actual: baselineMaintenance == nil ? "absent" : "present", passes: baselineMaintenance == nil,
                  message: "baseline maintenance state must be absent"),
            .init(phase: "fixture_shape", invariant: "saved_queued_primary_bytes", expected: String(primaryBytes),
                  actual: String(lastQueued.count), passes: lastQueued.count == primaryBytes,
                  message: "saved queued primary must be exactly 4 MiB"),
        ], scenario: "terminal_last")
        print("RESERVATION_MAX_FIXTURE records=1024 events_each=2048 primary_bytes_each=\(primaryBytes) total_primary_bytes=4294967296 index_bytes=\(indexBytes.count) setup_seconds=\(seconds(since: started)) decode_seconds_total=\(totalDecodeSeconds) decode_seconds_max=\(maxDecodeSeconds)")

        try require(maxDecodeSeconds < 8, scenario: "terminal_last", phase: "single_record_feasibility",
                    invariant: "maximum_decode_seconds", expected: "<8", actual: String(maxDecodeSeconds),
                    message: "single-record strict validation exceeds a call; not evidence of repeated-prefix starvation",
                    failure: .perRecordFeasibility)

        // Validate the actual last-slot origin/index and retirement proof. This
        // does not publish a certificate or otherwise resolve the measured slot.
        var owner: ModelCatalogFileLock? = try store.ownerLock(selector.transactionID)
        let proofStarted = DispatchTime.now().uptimeNanoseconds
        let receipt = try store.captureActiveReceipt(selector: selector)
        let receiptProvenance = try requireValue(receipt.provenance, scenario: "terminal_last", phase: "retirement_proof",
            invariant: "receipt_provenance", expected: "present", message: "last-slot receipt must retain provenance")
        let receiptIndex = try requireValue(receipt.indexReceipt, scenario: "terminal_last", phase: "retirement_proof",
            invariant: "receipt_index", expected: "present", message: "last-slot receipt must retain its active-index receipt")
        let proof = try store.captureRetirementProof(record: receipt.record, primary: receipt.primary,
            provenance: receiptProvenance, budget: receiptIndex.budget)
        try store.locked { try receipt.validateLocked(store: store); try proof.validate(store) }
        let proofSeconds = seconds(since: proofStarted)
        try require(proofSeconds < 8, scenario: "terminal_last", phase: "capture_proof_feasibility",
                    invariant: "capture_and_validation_seconds", expected: "<8", actual: String(proofSeconds),
                    message: "individual record feasibility is distinct from whole-search progress",
                    failure: .perRecordFeasibility)
        print("RESERVATION_MAX_FEASIBILITY decode_seconds_max=\(maxDecodeSeconds) capture_proof_seconds=\(proofSeconds) budget_seconds=8")
        withExtendedLifetime(owner) {}; owner = nil
        // Both scenarios have an available last-slot owner; only natural prefix
        // capture/validation can establish the expected search-budget outcome.
        try measureThreeCalls(store, authority: authority, scenario: "terminal_last", indexBytes: indexBytes, indexInfo: indexInfo)
        let terminalPrimarySHA256 = try requireValue(receipt.primary.sha256, scenario: "terminal_last", phase: "preservation_expected",
            invariant: "terminal_primary_sha256", expected: "present", message: "terminal receipt must contain a primary digest")
        let terminalOriginSHA256 = try requireValue(receiptProvenance.originFile.sha256, scenario: "terminal_last",
            phase: "preservation_expected", invariant: "terminal_origin_sha256", expected: "present",
            message: "terminal receipt must contain an origin digest")
        try assertPreserved(store, baselines: baselines, ids: fixtureIDs, scenario: "terminal_last", selector: selector,
                            expectedPrimarySHA256: terminalPrimarySHA256, expectedOriginSHA256: terminalOriginSHA256)

        // Exact original queued bytes are already bound by the allocated origin.
        // A reusable record necessarily has one event, while the preceding 1023
        // retain 2048 events and all1024 files remain exactly4MiB.
        try directory.write(lastQueued, name: selector.transactionID + ".json")
        let queuedMetadata = try requireValue(try directory.metadata(selector.transactionID + ".json"), scenario: "queued_last",
            phase: "queued_transition", invariant: "updated_primary_metadata", expected: "present",
            message: "queued replacement metadata must be present")
        baselines[selector.transactionID + ".json"] = queuedMetadata
        let queuedReceipt = try store.captureActiveReceipt(selector: selector)
        let queuedProvenance = try requireValue(queuedReceipt.provenance, scenario: "queued_last", phase: "queued_transition",
            invariant: "queued_provenance", expected: "present", message: "queued receipt must retain provenance")
        var allocatedInitialSHA256: String?
        if case .allocated(let allocation) = queuedProvenance.origin.provenance {
            allocatedInitialSHA256 = allocation.initialPrimarySHA256
        }
        let queuedBytes = queuedReceipt.primary.bytes
        let queuedDigest = store.digest(lastQueued)
        let currentQueuedMetadata = try directory.metadata(selector.transactionID + ".json")
        let queuedAge = Date().timeIntervalSince(queuedReceipt.record.createdAt)
        try validate([
            .init(phase: "queued_transition", invariant: "saved_primary_bytes", expected: String(primaryBytes),
                  actual: String(queuedBytes?.count ?? -1), passes: queuedBytes == lastQueued,
                  message: "queued receipt must capture the exact saved 4-MiB primary bytes"),
            .init(phase: "queued_transition", invariant: "updated_primary_metadata", expected: "same",
                  actual: currentQueuedMetadata.map { ModelTransactionFileEvidence.same(queuedMetadata, $0) ? "same" : "changed" } ?? "absent",
                  passes: currentQueuedMetadata.map { ModelTransactionFileEvidence.same(queuedMetadata, $0) } ?? false,
                  message: "queued replacement metadata must remain unchanged through receipt capture"),
            .init(phase: "queued_transition", invariant: "primary_sha256", expected: queuedDigest,
                  actual: queuedReceipt.primary.sha256 ?? "nil", passes: queuedReceipt.primary.sha256 == queuedDigest,
                  message: "queued receipt digest must match the exact saved queued bytes"),
            .init(phase: "queued_transition", invariant: "allocated_provenance", expected: "allocated",
                  actual: queuedProvenance.origin.provenance.name, passes: allocatedInitialSHA256 != nil,
                  message: "queued receipt must retain allocated provenance"),
            .init(phase: "queued_transition", invariant: "initial_primary_sha256", expected: queuedReceipt.primary.sha256 ?? "present",
                  actual: allocatedInitialSHA256 ?? "nil", passes: allocatedInitialSHA256 == queuedReceipt.primary.sha256,
                  message: "queued primary must remain bound to the allocated initial-primary digest"),
            .init(phase: "queued_transition", invariant: "started_at", expected: "nil",
                  actual: queuedReceipt.record.startedAt == nil ? "nil" : "present", passes: queuedReceipt.record.startedAt == nil,
                  message: "queued replacement must not have started"),
            .init(phase: "queued_transition", invariant: "event_count", expected: "1",
                  actual: String(queuedReceipt.record.events.count), passes: queuedReceipt.record.events.count == 1,
                  message: "queued replacement must contain exactly one event"),
            .init(phase: "queued_transition", invariant: "event_state", expected: "queued",
                  actual: queuedReceipt.record.events.first?.state ?? "nil", passes: queuedReceipt.record.events.first?.state == "queued",
                  message: "queued replacement event must remain queued"),
            .init(phase: "queued_transition", invariant: "terminal_or_committed_state", expected: "false",
                  actual: String(queuedReceipt.record.terminal || queuedReceipt.record.committed || queuedReceipt.record.cancelRequested || queuedReceipt.record.cleanupRequired),
                  passes: !(queuedReceipt.record.terminal || queuedReceipt.record.committed || queuedReceipt.record.cancelRequested || queuedReceipt.record.cleanupRequired),
                  message: "queued replacement must remain nonterminal, uncommitted, uncancelled, and cleanup-free"),
            .init(phase: "queued_transition", invariant: "record_age_seconds", expected: "<1800",
                  actual: String(queuedAge), passes: queuedAge < 1_800,
                  message: "queued replacement must remain fresh"),
        ], scenario: "queued_last")
        try store.locked { try queuedReceipt.validateLocked(store: store) }
        try measureThreeCalls(store, authority: authority, scenario: "queued_last", indexBytes: indexBytes, indexInfo: indexInfo)
        let queuedPrimarySHA256 = try requireValue(queuedReceipt.primary.sha256, scenario: "queued_last", phase: "preservation_expected",
            invariant: "queued_primary_sha256", expected: "present", message: "queued receipt must contain a primary digest")
        let queuedOriginSHA256 = try requireValue(queuedProvenance.originFile.sha256, scenario: "queued_last",
            phase: "preservation_expected", invariant: "queued_origin_sha256", expected: "present",
            message: "queued receipt must contain an origin digest")
        try assertPreserved(store, baselines: baselines, ids: fixtureIDs, scenario: "queued_last", selector: selector,
                            expectedPrimarySHA256: queuedPrimarySHA256, expectedOriginSHA256: queuedOriginSHA256)
    }

    private func measureThreeCalls(_ plain: ModelCatalogTransactionStore, authority: ModelCatalogTransactionAuthority,
                                   scenario: String, indexBytes: Data, indexInfo: stat) throws {
        for attempt in 0..<3 {
            var store = plain
            let probe = PhaseProbe()
            store.retentionBoundary = { probe.observe($0) }
            let began = DispatchTime.now().uptimeNanoseconds
            var outcome = "returned"
            do { _ = try store.reserveOperation(authority: authority, kind: "evaluate_model") }
            catch ModelCatalogTransactionError.busy { outcome = "busy" }
            catch {
                print("RESERVATION_MAX_CALL scenario=\(scenario) attempt=\(attempt) outcome=unexpected error=\(error) seconds=\(seconds(since: began)) \(probe.summary)")
                throw error
            }
            let elapsed = seconds(since: began)
            print("RESERVATION_MAX_CALL scenario=\(scenario) attempt=\(attempt) outcome=\(outcome) seconds=\(elapsed) \(probe.summary)")
            let retention = try plain.retentionDirectory()
            let currentIndexInfo = try retention.metadata("active.json")
            let currentIndexBytes = currentIndexInfo == nil ? nil : try retention.read("active.json", maxBytes: ModelCatalogTransactionStore.indexLimit)
            let currentMaintenance = try retention.metadata("maintenance.json")
            let scanStarted = probe.count("reservation_scan_started")
            let scanComplete = probe.count("reservation_scan_complete")
            let retirementCaptured = probe.count("retirement_captured")
            let cursorPublished = probe.count("retention_cursor_published")
            let indexDecode = probe.count("index_decode")
            let bulkReads = probe.count("bulk_read")
            try validate([
                .init(phase: "reservation_result", invariant: "typed_outcome", expected: "busy", actual: outcome,
                      passes: outcome == "busy", message: "natural-storage starvation was falsified; retain the successful progress measurement"),
                .init(phase: "reservation_result", invariant: "elapsed_seconds", expected: ">=8", actual: String(elapsed),
                      passes: elapsed >= 8, message: "reservation call must consume the unchanged eight-second budget"),
                .init(phase: "reservation_counters", invariant: "reservation_scan_started", expected: "1",
                      actual: String(scanStarted), passes: scanStarted == 1,
                      message: "reservation call must start exactly one scan"),
                .init(phase: "reservation_counters", invariant: "reservation_scan_complete", expected: "0",
                      actual: String(scanComplete), passes: scanComplete == 0,
                      message: "reservation call must not complete its scan"),
                .init(phase: "reservation_counters", invariant: "retirement_captured", expected: "0",
                      actual: String(retirementCaptured), passes: retirementCaptured == 0,
                      message: "reservation call must not capture retirement"),
                .init(phase: "reservation_counters", invariant: "retention_cursor_published", expected: "0",
                      actual: String(cursorPublished), passes: cursorPublished == 0,
                      message: "reservation call must not publish a retention cursor"),
                .init(phase: "reservation_counters", invariant: "index_decode", expected: "1",
                      actual: String(indexDecode), passes: indexDecode == 1,
                      message: "reservation call must decode the active index exactly once"),
                .init(phase: "reservation_counters", invariant: "bulk_read_attempts", expected: ">65",
                      actual: String(bulkReads), passes: bulkReads > 65,
                      message: "more than one primary must be feasible per call"),
                .init(phase: "reservation_preservation", invariant: "active_index_bytes", expected: "byte_identical",
                      actual: currentIndexBytes == indexBytes ? "byte_identical" : (currentIndexBytes == nil ? "absent" : "changed"),
                      passes: currentIndexBytes == indexBytes, message: "active index bytes must remain unchanged after each call"),
                .init(phase: "reservation_preservation", invariant: "active_index_metadata", expected: "same",
                      actual: currentIndexInfo.map { ModelTransactionFileEvidence.same(indexInfo, $0) ? "same" : "changed" } ?? "absent",
                      passes: currentIndexInfo.map { ModelTransactionFileEvidence.same(indexInfo, $0) } ?? false,
                      message: "active index metadata must remain unchanged after each call"),
                .init(phase: "reservation_preservation", invariant: "maintenance_state", expected: "absent",
                      actual: currentMaintenance == nil ? "absent" : "present", passes: currentMaintenance == nil,
                      message: "reservation call must not publish maintenance state"),
            ], scenario: scenario, attempt: attempt)
        }
    }

    private func assertPreserved(_ store: ModelCatalogTransactionStore, baselines: [String: stat], ids: [String],
                                 scenario: String, selector: ModelCatalogTransactionSelector,
                                 expectedPrimarySHA256: String, expectedOriginSHA256: String) throws {
        let directory = try ModelTransactionDirectory.current(store.root)
        var observations: [InvariantObservation] = []
        for name in baselines.keys.sorted() {
            let baseline = try requireValue(baselines[name], scenario: scenario, phase: "scenario_preservation",
                invariant: "baseline_\(name)", expected: "present", message: "\(name) baseline metadata must be present")
            let current = try directory.metadata(name)
            observations.append(.init(phase: "scenario_preservation", invariant: "metadata_\(name)", expected: "same",
                actual: current.map { ModelTransactionFileEvidence.same(baseline, $0) ? "same" : "changed" } ?? "absent",
                passes: current.map { ModelTransactionFileEvidence.same(baseline, $0) } ?? false,
                message: "\(name) metadata must remain unchanged"))
        }
        for id in ids {
            for suffix in [".retired", ".result", ".seal", ".cleanup", ".success-binding"] {
                let name = id + suffix
                let metadata = try directory.metadata(name)
                observations.append(.init(phase: "scenario_preservation", invariant: "forbidden_\(name)", expected: "absent",
                    actual: metadata == nil ? "absent" : "present", passes: metadata == nil,
                    message: "\(name) must remain absent"))
            }
            let staging = "staging-" + id
            let metadata = try directory.metadata(staging)
            observations.append(.init(phase: "scenario_preservation", invariant: "forbidden_\(staging)", expected: "absent",
                actual: metadata == nil ? "absent" : "present", passes: metadata == nil,
                message: "\(staging) must remain absent"))
        }
        let recommendations = try store.retentionDirectory().metadata("recommendations")
        observations.append(.init(phase: "scenario_preservation", invariant: "forbidden_recommendations", expected: "absent",
            actual: recommendations == nil ? "absent" : "present", passes: recommendations == nil,
            message: "recommendations must remain absent"))
        try validate(observations, scenario: scenario)

        let current = try store.captureActiveReceipt(selector: selector)
        let provenance = try requireValue(current.provenance, scenario: scenario, phase: "scenario_preservation",
            invariant: "current_provenance", expected: "present", message: "preserved receipt must retain provenance")
        try validate([
            .init(phase: "scenario_preservation", invariant: "primary_sha256", expected: expectedPrimarySHA256,
                  actual: current.primary.sha256 ?? "nil", passes: current.primary.sha256 == expectedPrimarySHA256,
                  message: "final primary digest must match the validated pre-call receipt"),
            .init(phase: "scenario_preservation", invariant: "origin_sha256", expected: expectedOriginSHA256,
                  actual: provenance.originFile.sha256 ?? "nil", passes: provenance.originFile.sha256 == expectedOriginSHA256,
                  message: "final origin digest must match the validated pre-call receipt"),
        ], scenario: scenario)
    }
    private func padded(_ data: Data, phase: String, id: String) throws -> Data {
        try require(data.count <= primaryBytes, scenario: "terminal_last", phase: phase, invariant: "encoded_bytes_\(id)",
                    expected: "<=\(primaryBytes)", actual: String(data.count),
                    message: "encoded fixture record \(id) must fit within 4 MiB")
        var bytes = data; bytes.append(Data(repeating: 0x20, count: primaryBytes - data.count)); return bytes
    }
    private func checkSetupDeadline(_ deadline: UInt64, now supplied: UInt64? = nil, started: UInt64, root: URL,
                                    completedRecords: Int, validatedBytes: Int, latestBlockSeconds: Double,
                                    phase: String) throws {
        let now = supplied ?? DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            let available = try availableBytes(at: root, scenario: "terminal_last", phase: "setup_deadline_resource",
                                               failure: .unexpectedProgress)
            let elapsed = intervalSeconds(from: started, to: now)
            let latestRate = latestBlockSeconds > 0 ? latestBlockSeconds / 128.0 : 0
            try abort(scenario: "terminal_last", phase: phase, invariant: "setup_elapsed_seconds",
                      expected: "<\(setupSeconds)",
                      actual: "elapsed_seconds=\(elapsed) completed_records=\(completedRecords) validated_bytes=\(validatedBytes) latest_block_seconds=\(latestBlockSeconds) latest_block_seconds_per_record=\(latestRate) available_bytes=\(available)",
                      message: "maximum-shape fixture exceeded the 1,500-second setup ceiling", failure: .setupDeadline)
        }
    }
    private func availableBytes(at url: URL, scenario: String, phase: String,
                                failure: MeasurementError) throws -> UInt64 {
        var filesystem = statfs()
        guard statfs(url.path, &filesystem) == 0 else {
            try abort(scenario: scenario, phase: phase, invariant: "statfs", expected: "success", actual: "errno=\(errno)",
                      message: "could not inspect filesystem capacity", failure: failure)
        }
        return UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize)
    }
    private func require(_ condition: Bool, scenario: String, attempt: Int? = nil, phase: String,
                         invariant: String, expected: String, actual: String, message: String,
                         failure: MeasurementError = .unexpectedProgress) throws {
        guard condition else {
            try abort(scenario: scenario, attempt: attempt, phase: phase, invariant: invariant,
                      expected: expected, actual: actual, message: message, failure: failure)
        }
    }
    private func requireValue<T>(_ value: T?, scenario: String, attempt: Int? = nil, phase: String,
                                 invariant: String, expected: String, message: String,
                                 failure: MeasurementError = .unexpectedProgress) throws -> T {
        guard let value else {
            try abort(scenario: scenario, attempt: attempt, phase: phase, invariant: invariant,
                      expected: expected, actual: "nil", message: message, failure: failure)
        }
        return value
    }
    private func validate(_ observations: [InvariantObservation], scenario: String, attempt: Int? = nil,
                          failure: MeasurementError = .unexpectedProgress) throws {
        guard let failed = observations.first(where: { !$0.passes }) else { return }
        try abort(scenario: scenario, attempt: attempt, phase: failed.phase, invariant: failed.invariant,
                  expected: failed.expected, actual: failed.actual, message: failed.message, failure: failure)
    }
    private func abort(scenario: String, attempt: Int? = nil, phase: String, invariant: String,
                       expected: String, actual: String, message: String, failure: MeasurementError) throws -> Never {
        let attemptValue = attempt.map(String.init) ?? "none"
        print("RESERVATION_MAX_ABORT scenario=\(String(reflecting: scenario)) attempt=\(attemptValue) phase=\(String(reflecting: phase)) invariant=\(String(reflecting: invariant)) expected=\(String(reflecting: expected)) actual=\(String(reflecting: actual))")
        XCTFail(message)
        throw failure
    }
    private func intervalSeconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000_000
    }
    private func seconds(since: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since) / 1_000_000_000 }
    private final class PhaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var counters: [String: Int] = [:]
        func observe(_ point: String) {
            guard ["reservation_scan_started", "reservation_scan_complete", "retirement_captured", "retention_cursor_published", "index_decode", "bulk_read"].contains(point) else { return }
            lock.lock(); counters[point, default: 0] += 1; lock.unlock()
        }
        func count(_ point: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[point, default: 0] }
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return counters.keys.sorted().map { "\($0)=\(counters[$0]!)" }.joined(separator: " ")
        }
    }
    private func fixtureInputs() throws -> ModelCatalogRecommendationInputs {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            scenario: "terminal_last", phase: "fixture_inputs", invariant: "fixture_corpus", expected: "JSON object",
            message: "artifact-feed conformance fixture must be a JSON object")
        let candidateObject = try requireValue(corpus["candidate"], scenario: "terminal_last", phase: "fixture_inputs",
            invariant: "candidate_object", expected: "present", message: "fixture candidate object must be present")
        let candidate = try JSONSerialization.data(withJSONObject: candidateObject, options: [.sortedKeys, .withoutEscapingSlashes])
        var feed = try requireValue(corpus["feed"] as? [String: Any], scenario: "terminal_last", phase: "fixture_inputs",
            invariant: "feed_object", expected: "JSON object", message: "fixture feed must be a JSON object")
        feed["candidate_catalog_sha256"] = AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate)
        let bytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "fixture-only"
        let fixtureDate = try requireValue(ISO8601DateFormatter().date(from: "2026-07-11T00:00:00Z"),
            scenario: "terminal_last", phase: "fixture_inputs", invariant: "fixture_date", expected: "valid timestamp",
            message: "fixture timestamp must parse")
        let qualified = try requireValue(AutotuneStaticInputs.usableArtifactFeed(bakedBytes: bytes, bakedSignerKeyID: signer,
            candidateBytes: candidate, candidateSignerKeyID: signer, now: fixtureDate),
            scenario: "terminal_last", phase: "fixture_inputs", invariant: "qualified_artifact_feed", expected: "present",
            message: "fixture artifact feed must qualify")
        let demand = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8), rate = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        return (.init(value: try AutotuneStaticInputs.decodeDemandRank(demand), selectedBytes: demand, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidate), selectedBytes: candidate, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: try AutotuneStaticInputs.decodeRateCard(rate), selectedBytes: rate, warnings: [], usedFallback: false, signerKeyID: signer),
            .init(value: qualified, selectedBytes: bytes, warnings: [], usedFallback: false, signerKeyID: signer))
    }
}
