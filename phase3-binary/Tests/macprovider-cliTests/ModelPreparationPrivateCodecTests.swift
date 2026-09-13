import Foundation
@testable import macprovider_cli
import XCTest

final class ModelPreparationPrivateCodecTests: XCTestCase {
    func testFailedDispatchRoundTripPinsExactClosedSerialization() throws {
        let record = try Self.failedDispatch()
        let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.failedDispatchMaxBytes)
        let json = String(decoding: data, as: UTF8.self)
        let tupleDigest = try Self.tupleDigest()
        XCTAssertEqual(json, #"{"attempt_id":"11111111-1111-4111-8111-111111111111","error_code":"operation_conflict","event_model_key":"catalog/model","event_sequence":1,"live_attempt":false,"projection_binding_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":{"canonical_path":"/tmp/macprovider-root","identity_version":"model_catalog_root_identity.v1","root_identity_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","st_dev":123,"st_ino":456},"schema":"model_catalog_failed_dispatch.v1","terminal_state":"failed","transaction_id":"00000000-0000-4000-8000-000000000001","transaction_kind":"prepare_model","tuple_sha256":"\#(tupleDigest)"}"#)

        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationFailedDispatchRecord.self,
            from: data,
            maxBytes: ModelPreparationContracts.failedDispatchMaxBytes
        )
        XCTAssertEqual(decoded, record)
    }

    func testFailedDispatchRejectsUnknownMissingDuplicateEnumCapAndTerminalMutation() throws {
        let data = try ModelPreparationContracts.encode(Self.failedDispatch())
        var object = try Self.object(data)

        object["provider_identity"] = "provider-1"
        XCTAssertThrowsError(try Self.decodeFailed(object))

        object = try Self.object(data)
        object["completed_at"] = Self.timestamp
        XCTAssertThrowsError(try Self.decodeFailed(object))

        object = try Self.object(data)
        object.removeValue(forKey: "event_model_key")
        XCTAssertThrowsError(try Self.decodeFailed(object))

        let failedJSON = String(decoding: data, as: UTF8.self)
        let duplicate = Data(failedJSON.replacingOccurrences(
            of: #""schema":"model_catalog_failed_dispatch.v1""#,
            with: #""schema":"model_catalog_failed_dispatch.v1","schema":"model_catalog_failed_dispatch.v1""#
        ).utf8)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationFailedDispatchRecord.self,
            from: duplicate,
            maxBytes: ModelPreparationContracts.failedDispatchMaxBytes
        ))

        object = try Self.object(data)
        object["transaction_kind"] = "prepare_model_v3"
        XCTAssertThrowsError(try Self.decodeFailed(object))

        object = try Self.object(data)
        object["live_attempt"] = true
        XCTAssertThrowsError(try Self.decodeFailed(object))

        object = try Self.object(data)
        object["event_sequence"] = 2
        XCTAssertThrowsError(try Self.decodeFailed(object))

        let oversized = Data(count: ModelPreparationContracts.failedDispatchMaxBytes + 1)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationFailedDispatchRecord.self,
            from: oversized,
            maxBytes: ModelPreparationContracts.failedDispatchMaxBytes
        ))
    }

    func testRootIdentityDigestCoversNonceVersionPathDeviceAndInode() throws {
        let identity = try ModelPreparationRootIdentityRecord(
            version: "model_catalog_root_identity.v1",
            nonceHex: String(repeating: "0", count: 64),
            canonicalPath: "/tmp/macprovider-root",
            stDev: 123,
            stIno: 456
        )
        XCTAssertEqual(try identity.digest, "1480a086c13bee4c9a2a9b62e934cbf13e3bdcaf0eca420aebae4fb806ee9465")
        XCTAssertNotEqual(
            try identity.digest,
            try ModelPreparationContracts.rootIdentityDigest(
                version: identity.version,
                nonceHex: String(repeating: "1", count: 64),
                canonicalPath: identity.canonicalPath,
                stDev: identity.stDev,
                stIno: identity.stIno
            )
        )
        XCTAssertNotEqual(
            try identity.digest,
            try ModelPreparationContracts.rootIdentityDigest(
                version: identity.version,
                nonceHex: identity.nonceHex,
                canonicalPath: "/tmp/other-root",
                stDev: identity.stDev,
                stIno: identity.stIno
            )
        )
        XCTAssertNotEqual(
            try identity.digest,
            try ModelPreparationContracts.rootIdentityDigest(
                version: identity.version,
                nonceHex: identity.nonceHex,
                canonicalPath: identity.canonicalPath,
                stDev: 124,
                stIno: identity.stIno
            )
        )

        for invalidPath in ["/tmp/../other", "//tmp/macprovider-root", "/tmp/./macprovider-root", "/tmp/macprovider-root/", "tmp/macprovider-root", "/tmp\\macprovider-root"] {
            XCTAssertThrowsError(try ModelPreparationContracts.rootIdentityDigest(
                version: identity.version,
                nonceHex: identity.nonceHex,
                canonicalPath: invalidPath,
                stDev: identity.stDev,
                stIno: identity.stIno
            ))
            XCTAssertThrowsError(try ModelPreparationRootIdentityRecord(
                version: identity.version,
                nonceHex: identity.nonceHex,
                canonicalPath: invalidPath,
                stDev: identity.stDev,
                stIno: identity.stIno
            ))
            XCTAssertThrowsError(try ModelPreparationRootLocator(
                canonicalPath: invalidPath,
                stDev: identity.stDev,
                stIno: identity.stIno,
                identityVersion: identity.version,
                rootIdentityDigest: Self.hexA
            ))
        }

        var failedDispatch = try Self.object(ModelPreparationContracts.encode(try Self.failedDispatch(), maxBytes: ModelPreparationContracts.failedDispatchMaxBytes))
        var nestedRoot = try XCTUnwrap(failedDispatch["root"] as? [String: Any])
        nestedRoot["canonical_path"] = "/tmp/../other"
        failedDispatch["root"] = nestedRoot
        XCTAssertThrowsError(try Self.decodeFailed(failedDispatch))
    }

    func testReservationRejectsEventKeyAndRootBindingMismatch() throws {
        let tuple = try Self.tuple()
        let tupleDigest = try Self.tupleDigest()
        _ = try ModelPreparationReservationRecord(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            createdAt: Self.timestamp
        )

        XCTAssertThrowsError(try ModelPreparationReservationRecord(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            eventModelKey: "other/model",
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest,
            projectionBindingSHA256: Self.hexB,
            createdAt: Self.timestamp
        ))

        XCTAssertThrowsError(try ModelPreparationReservationRecord(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: Self.hexA,
            projectionBindingSHA256: Self.hexB,
            createdAt: Self.timestamp
        ))

        let otherRoot = try ModelPreparationRootLocator(
            canonicalPath: "/tmp/other-root",
            stDev: 123,
            stIno: 456,
            identityVersion: "model_catalog_root_identity.v1",
            rootIdentityDigest: Self.hexA
        )
        XCTAssertThrowsError(try ModelPreparationReservationRecord(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: otherRoot,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            createdAt: Self.timestamp
        ))

        let prepare = try Self.reservation()
        XCTAssertEqual(prepare.schema, "model_catalog_reservation.v4")
        XCTAssertNil(prepare.sourceTransactionID)
        var prepareObject = try Self.object(try ModelPreparationContracts.encode(prepare, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
        prepareObject["schema"] = "model_catalog_reservation.v3"
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationRecord.self, from: Self.data(prepareObject), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))

        prepareObject = try Self.object(try ModelPreparationContracts.encode(prepare, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
        prepareObject["source_transaction_id"] = NSNull()
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationRecord.self, from: Self.data(prepareObject), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))

        let cleanup = try Self.cleanupStagingReservation()
        XCTAssertEqual(cleanup.sourceTransactionID, Self.sourceTransactionID)
        XCTAssertEqual(cleanup.sourceAttemptID, Self.sourceAttemptID)
        XCTAssertEqual(cleanup.sourceRecordSHA256, Self.hexA)
        _ = try ModelPreparationContracts.decode(
            ModelPreparationReservationRecord.self,
            from: ModelPreparationContracts.encode(cleanup, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes),
            maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes
        )

        var cleanupObject = try Self.object(try ModelPreparationContracts.encode(cleanup, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
        cleanupObject.removeValue(forKey: "source_record_sha256")
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationRecord.self, from: Self.data(cleanupObject), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
    }

    func testReservationsHistoryRoundTripsAndRejectsMalformedBranches() throws {
        let projected = try Self.cleanupStagingReservation()
        let terminal = try Self.terminalHistoryEntry()
        let failedPending = try Self.failedDispatchHistoryEntry()
        let history = try ModelPreparationReservationsHistoryRecord(projectedReservations: [projected], terminalHistory: [terminal, failedPending])
        let data = try ModelPreparationContracts.encode(history, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes)
        let decoded = try ModelPreparationContracts.decode(ModelPreparationReservationsHistoryRecord.self, from: data, maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes)
        XCTAssertEqual(decoded, history)

        XCTAssertThrowsError(try ModelPreparationReservationsHistoryRecord(projectedReservations: [projected, projected], terminalHistory: []))
        XCTAssertThrowsError(try ModelPreparationReservationsHistoryRecord(projectedReservations: Array(repeating: projected, count: 65), terminalHistory: []))
        XCTAssertThrowsError(try ModelPreparationReservationsHistoryRecord(projectedReservations: [], terminalHistory: Array(repeating: terminal, count: 257)))
        XCTAssertNoThrow(try ModelPreparationReservationsHistoryRecord(
            projectedReservations: [projected],
            terminalHistory: [.ordinary(try Self.terminalHistory(
                transactionID: projected.transactionID,
                transactionKind: projected.transactionKind,
                eventModelKey: projected.eventModelKey,
                root: projected.root,
                tupleSHA256: projected.tupleSHA256,
                projectionBindingSHA256: projected.projectionBindingSHA256
            ))]
        ))
        XCTAssertThrowsError(try ModelPreparationReservationsHistoryRecord(
            projectedReservations: [projected],
            terminalHistory: [.ordinary(try Self.terminalHistory(transactionID: projected.transactionID))]
        ))
        XCTAssertNoThrow(try ModelPreparationReservationsHistoryRecord(
            projectedReservations: [],
            terminalHistory: [
                try Self.terminalHistoryEntry(),
                .ordinary(try Self.terminalHistory(attemptID: "88888888-8888-4888-8888-888888888888")),
            ]
        ))
        XCTAssertThrowsError(try ModelPreparationReservationsHistoryRecord(
            projectedReservations: [],
            terminalHistory: [
                try Self.terminalHistoryEntry(),
                .ordinary(try Self.terminalHistory(attemptID: "88888888-8888-4888-8888-888888888888", transactionKind: .cleanupStaging)),
            ]
        ))
        XCTAssertThrowsError(try ModelPreparationTerminalHistoryRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: "catalog/model",
            root: try Self.root(),
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            eventSequence: 0,
            terminalState: .failed,
            errorCode: .operationConflict,
            completedAt: Self.timestamp
        ))
        XCTAssertThrowsError(try ModelPreparationTerminalHistoryRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: "catalog/model",
            root: try Self.root(),
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            eventSequence: 1,
            terminalState: .succeeded,
            errorCode: .operationConflict,
            completedAt: Self.timestamp
        ))
        XCTAssertThrowsError(try ModelPreparationTerminalHistoryRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: "catalog/model",
            root: try Self.root(),
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            eventSequence: 1,
            terminalState: .timedOut,
            errorCode: nil,
            completedAt: Self.timestamp
        ))
        _ = try ModelPreparationContracts.decode(
            ModelPreparationTerminalHistoryRecord.self,
            from: ModelPreparationContracts.encode(try Self.terminalHistory(state: .succeeded, errorCode: nil), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes),
            maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes
        )
        _ = try ModelPreparationContracts.decode(
            ModelPreparationTerminalHistoryRecord.self,
            from: ModelPreparationContracts.encode(try Self.terminalHistory(state: .timedOut, errorCode: .transferFailed), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes),
            maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes
        )

        var object = try Self.object(data)
        object["extra"] = true
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationsHistoryRecord.self, from: Self.data(object), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))

        object = try Self.object(data)
        var terminalHistory = try XCTUnwrap(object["terminal_history"] as? [[String: Any]])
        var failedDispatch = terminalHistory[1]
        failedDispatch["completed_at"] = Self.timestamp
        terminalHistory[1] = failedDispatch
        object["terminal_history"] = terminalHistory
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationsHistoryRecord.self, from: Self.data(object), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
    }

    func testCancelAckOutcomeNullabilityIsClosedAndEncodedNullIsRequired() throws {
        let busy = try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: Self.timestamp
        )
        let data = try ModelPreparationContracts.encode(busy, maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"attempt_id":null,"observed_at":"2026-09-12T00:00:00.000Z","outcome":"busy","schema":"model_catalog_transaction_cancel_ack.v1","transaction_id":"00000000-0000-4000-8000-000000000001"}"#
        )
        _ = try ModelPreparationContracts.decode(
            ModelPreparationCancelAcknowledgement.self,
            from: data,
            maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes
        )

        var object = try Self.object(data)
        object.removeValue(forKey: "attempt_id")
        XCTAssertThrowsError(try Self.decodeAck(object))

        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            outcome: .busy,
            observedAt: Self.timestamp
        ))
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .terminal,
            observedAt: Self.timestamp
        ))
    }

    func testCancelMarkerBindsTransactionAttemptAndProjectionWithoutAckSemantics() throws {
        let marker = try Self.cancelMarker()
        let data = try ModelPreparationContracts.encode(marker, maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"attempt_id":"11111111-1111-4111-8111-111111111111","event_model_key":"catalog/model","projection_binding_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","recorded_at":"2026-09-12T00:00:00Z","root":{"canonical_path":"/tmp/macprovider-root","identity_version":"model_catalog_root_identity.v1","root_identity_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","st_dev":123,"st_ino":456},"schema":"model_catalog_cancel_marker.v1","transaction_id":"00000000-0000-4000-8000-000000000001","transaction_kind":"prepare_model","tuple_sha256":"__TUPLE_DIGEST__"}"#.replacingOccurrences(of: "__TUPLE_DIGEST__", with: try Self.tupleDigest())
        )
        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationCancelMarker.self,
            from: data,
            maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes
        )
        XCTAssertEqual(decoded, marker)

        var object = try Self.object(data)
        object["attempt_id"] = NSNull()
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCancelMarker.self, from: Self.data(object), maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes))

        object = try Self.object(data)
        object["schema"] = "model_catalog_transaction_cancel_ack.v1"
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCancelMarker.self, from: Self.data(object), maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes))

        object = try Self.object(data)
        object["recorded_at"] = Self.timestamp
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCancelMarker.self, from: Self.data(object), maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes))
    }

    func testStagingSourcesRecordsAreReceiptFreeSourceBoundAndSorted() throws {
        let source = try Self.stagingSourceRecord()
        let data = try ModelPreparationContracts.encode(source, maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes)
        let decodedSource = try ModelPreparationContracts.decode(
            ModelPreparationStagingSourceRecord.self,
            from: data,
            maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes
        )
        XCTAssertEqual(decodedSource, source)
        XCTAssertEqual(source.stagingLeaf, Self.stagingSourceLeaf())

        var sourceObject = try Self.object(data)
        sourceObject["receipt"] = NSNull()
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourceRecord.self, from: Self.data(sourceObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))

        let second = try ModelPreparationStagingSourceEntry(
            sourceTransactionID: "33333333-3333-4333-8333-333333333333",
            sourceAttemptID: "44444444-4444-4444-8444-444444444444",
            root: try Self.root(),
            sourceRecordSHA256: Self.hexB
        )
        let first = try Self.stagingSourceEntry()
        let registry = try ModelPreparationStagingSourcesRecord(entries: [first, second])
        let registryData = try ModelPreparationContracts.encode(registry, maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes)
        XCTAssertEqual(
            try ModelPreparationContracts.decode(ModelPreparationStagingSourcesRecord.self, from: registryData, maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes),
            registry
        )
        XCTAssertThrowsError(try ModelPreparationStagingSourcesRecord(entries: [second, first]))
        XCTAssertThrowsError(try ModelPreparationStagingSourcesRecord(entries: [first, first]))
        XCTAssertThrowsError(try ModelPreparationStagingSourcesRecord(entries: Array(repeating: first, count: 257)))

        var registryObject = try Self.object(registryData)
        registryObject["extra"] = true
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourcesRecord.self, from: Self.data(registryObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))

        let cleanupReservationObject = try Self.object(ModelPreparationContracts.encode(try Self.cleanupStagingReservation(), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes))
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourceEntry.self, from: Self.data(cleanupReservationObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))

        registryObject = try Self.object(registryData)
        registryObject["entries"] = [cleanupReservationObject]
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourcesRecord.self, from: Self.data(registryObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .stagingSources,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .stagingSources),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.data(registryObject)
        ))

        let cleanupRecordObject = try Self.object(ModelPreparationContracts.encode(try Self.cleanupRecord(phase: .intent, targetKind: .staging), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourceEntry.self, from: Self.data(cleanupRecordObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))
        registryObject = try Self.object(registryData)
        registryObject["entries"] = [cleanupRecordObject]
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationStagingSourcesRecord.self, from: Self.data(registryObject), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes))
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .stagingSources,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .stagingSources),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.data(registryObject)
        ))
    }

    func testEventRejectsUnknownStateAndIllegalErrorNullability() throws {
        let event = try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: Self.timestamp,
            state: .failed,
            progress: nil,
            errorCode: .operationConflict,
            warningCode: nil
        )
        let data = try ModelPreparationContracts.encode(event, maxBytes: ModelPreparationContracts.eventMaxBytes)
        _ = try ModelPreparationContracts.decode(
            ModelPreparationTransactionEvent.self,
            from: data,
            maxBytes: ModelPreparationContracts.eventMaxBytes
        )

        var object = try Self.object(data)
        object["state"] = "late_cancelled"
        XCTAssertThrowsError(try Self.decodeEvent(object))

        object = try Self.object(data)
        object["error_code"] = NSNull()
        XCTAssertThrowsError(try Self.decodeEvent(object))

        XCTAssertThrowsError(try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: Self.timestamp,
            state: .running,
            progress: nil,
            errorCode: .operationConflict,
            warningCode: nil
        ))
    }

    func testCleanupTargetsBindJCSActionEqualityAndPerCopyDigestAndBytes() throws {
        let rootDigest = Self.hexA
        let receipt = Self.hexB
        let artifactDigest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: "display",
            modelRevision: "rev",
            artifactID: "artifact",
            releaseID: "release",
            rootIdentityDigest: rootDigest,
            receiptSHA256: receipt
        )
        XCTAssertEqual(artifactDigest, "1991b12a7623a90f989e234b802e3a8e3ff7055ec5a0276adb27148114535f3e")

        let action = try ModelPreparationAction(
            available: true,
            requiresConfirmation: true,
            transactionKind: .cleanupPublishedArtifact,
            transactionID: Self.transactionID,
            actionTimeoutSeconds: 30,
            estimatedBytes: 4096,
            unavailableReason: nil,
            artifactIdentityDigest: artifactDigest
        )
        let target = try ModelPreparationCleanupTarget(
            artifactIdentityDigest: artifactDigest,
            displayModelID: "display",
            modelRevision: "rev",
            artifactID: "artifact",
            releaseID: "release",
            modelKey: nil,
            eventModelKey: "catalog/model",
            rootIdentityDigest: rootDigest,
            receiptSHA256: receipt,
            estimatedBytes: 4096,
            keepSetStatus: .reclaimable,
            protectedReason: nil,
            cleanup: action
        )
        try ModelPreparationContracts.validateCleanupBinding(rowAction: action, target: target)
        let targetData = try ModelPreparationContracts.encode(target, maxBytes: ModelPreparationContracts.inventoryMaxBytes)
        let targetJSON = String(decoding: targetData, as: UTF8.self)
        XCTAssertTrue(targetJSON.contains(#""model_key":null"#))
        XCTAssertTrue(targetJSON.contains(#""protected_reason":null"#))
        XCTAssertEqual(
            try ModelPreparationContracts.decode(ModelPreparationCleanupTarget.self, from: targetData, maxBytes: ModelPreparationContracts.inventoryMaxBytes),
            target
        )

        let mismatchedAction = try ModelPreparationAction(
            available: true,
            requiresConfirmation: true,
            transactionKind: .cleanupPublishedArtifact,
            transactionID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            actionTimeoutSeconds: 30,
            estimatedBytes: 4096,
            unavailableReason: nil,
            artifactIdentityDigest: artifactDigest
        )
        XCTAssertThrowsError(try ModelPreparationContracts.validateCleanupBinding(rowAction: mismatchedAction, target: target))

        let wrongSizeAction = try ModelPreparationAction(
            available: true,
            requiresConfirmation: true,
            transactionKind: .cleanupPublishedArtifact,
            transactionID: Self.transactionID,
            actionTimeoutSeconds: 30,
            estimatedBytes: 4097,
            unavailableReason: nil,
            artifactIdentityDigest: artifactDigest
        )
        XCTAssertThrowsError(try ModelPreparationContracts.validateCleanupBinding(rowAction: wrongSizeAction, target: target))

        XCTAssertThrowsError(try ModelPreparationCleanupTarget(
            artifactIdentityDigest: artifactDigest,
            displayModelID: "display",
            modelRevision: "rev",
            artifactID: "artifact",
            releaseID: "release",
            modelKey: nil,
            eventModelKey: "catalog/model",
            rootIdentityDigest: rootDigest,
            receiptSHA256: receipt,
            estimatedBytes: 4097,
            keepSetStatus: .reclaimable,
            protectedReason: nil,
            cleanup: action
        ))
    }


    func testActionConfirmationRulesAndReasonSafeStrings() throws {
        for kind in [
            ModelPreparationTransactionKind.switchModel,
            .switchModelDeferred,
            .prepareModel,
            .cleanupStaging,
            .adoptRecommendation,
            .cleanupPublishedArtifact,
        ] {
            XCTAssertThrowsError(try Self.action(kind: kind, requiresConfirmation: false, estimatedBytes: kind == .cleanupPublishedArtifact ? 1 : nil))
        }
        XCTAssertThrowsError(try Self.action(kind: .evaluateModel, requiresConfirmation: false, estimatedBytes: 1, timeout: 10))
        XCTAssertThrowsError(try Self.action(kind: .evaluateModel, requiresConfirmation: false, estimatedBytes: nil, timeout: 11))
        _ = try Self.action(kind: .evaluateModel, requiresConfirmation: false, estimatedBytes: nil, timeout: 10)

        XCTAssertThrowsError(try ModelPreparationAction(
            available: false,
            requiresConfirmation: false,
            transactionKind: nil,
            transactionID: nil,
            actionTimeoutSeconds: nil,
            estimatedBytes: nil,
            unavailableReason: "bad\nreason",
            artifactIdentityDigest: nil
        ))
        XCTAssertThrowsError(try ModelPreparationAction(
            available: false,
            requiresConfirmation: false,
            transactionKind: nil,
            transactionID: nil,
            actionTimeoutSeconds: nil,
            estimatedBytes: nil,
            unavailableReason: String(repeating: "x", count: 513),
            artifactIdentityDigest: nil
        ))
    }

    func testProgressRejectsMalformedNumbersAndHeartbeatPresence() throws {
        XCTAssertThrowsError(try ModelPreparationTransactionEvent.Progress(
            stageLabelKey: "download",
            bytesCompleted: 11,
            bytesExpected: 10,
            percentComplete: nil,
            heartbeat: nil
        ))
        XCTAssertThrowsError(try ModelPreparationTransactionEvent.Progress(
            stageLabelKey: "download",
            bytesCompleted: nil,
            bytesExpected: nil,
            percentComplete: 100.1,
            heartbeat: nil
        ))
        XCTAssertThrowsError(try ModelPreparationTransactionEvent.Progress(
            stageLabelKey: "download",
            bytesCompleted: nil,
            bytesExpected: 4096,
            percentComplete: nil,
            heartbeat: nil
        ))
        XCTAssertThrowsError(try ModelPreparationTransactionEvent.Progress(
            stageLabelKey: "download",
            bytesCompleted: nil,
            bytesExpected: nil,
            percentComplete: nil,
            heartbeat: false
        ))
        let runningWithoutProgress = try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: Self.timestamp,
            state: .running,
            progress: nil,
            errorCode: nil,
            warningCode: nil
        )
        XCTAssertEqual(
            try ModelPreparationContracts.decode(
                ModelPreparationTransactionEvent.self,
                from: ModelPreparationContracts.encode(runningWithoutProgress, maxBytes: ModelPreparationContracts.eventMaxBytes),
                maxBytes: ModelPreparationContracts.eventMaxBytes
            ),
            runningWithoutProgress
        )
        XCTAssertThrowsError(try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: Self.timestamp,
            state: .succeeded,
            progress: try ModelPreparationTransactionEvent.Progress(stageLabelKey: "download", bytesCompleted: nil, bytesExpected: nil, percentComplete: nil, heartbeat: true),
            errorCode: nil,
            warningCode: nil
        ))
    }

    func testActiveRecordBindsTupleAndRejectsMalformedCountersLeavesAndTerminal() throws {
        let active = try Self.activeRecord()
        let data = try ModelPreparationContracts.encode(active, maxBytes: ModelPreparationContracts.activeRecordMaxBytes)
        _ = try ModelPreparationContracts.decode(ModelPreparationActiveRecord.self, from: data, maxBytes: ModelPreparationContracts.activeRecordMaxBytes)

        let tuple = try Self.tuple()
        XCTAssertThrowsError(try ModelPreparationActiveRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: Self.hexA,
            projectionBindingSHA256: Self.hexB,
            nextEventSequence: 2,
            phase: .transferring,
            counters: try ModelPreparationActiveCounters(bytesCompleted: 0, bytesExpected: 1, filesCompleted: 0, filesExpected: 1),
            recordedLeaves: [Self.hexA],
            barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: false, objectParentFullSynced: false, phaseRecordSynced: false, phaseRecordReadBack: false),
            terminalResult: nil,
            cancellationRequested: false
        ))
        XCTAssertThrowsError(try ModelPreparationActiveCounters(bytesCompleted: 2, bytesExpected: 1, filesCompleted: 0, filesExpected: 1))
        XCTAssertThrowsError(try ModelPreparationActiveRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            nextEventSequence: 2,
            phase: .transferring,
            counters: try ModelPreparationActiveCounters(bytesCompleted: 0, bytesExpected: 1, filesCompleted: 0, filesExpected: 1),
            recordedLeaves: ["../escape"],
            barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: false, objectParentFullSynced: false, phaseRecordSynced: false, phaseRecordReadBack: false),
            terminalResult: nil,
            cancellationRequested: false
        ))
        XCTAssertThrowsError(try ModelPreparationActiveRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            nextEventSequence: 2,
            phase: .terminal,
            counters: try ModelPreparationActiveCounters(bytesCompleted: 1, bytesExpected: 1, filesCompleted: 1, filesExpected: 1),
            recordedLeaves: [Self.hexA],
            barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: true, objectParentFullSynced: true, phaseRecordSynced: true, phaseRecordReadBack: true),
            terminalResult: nil,
            cancellationRequested: false
        ))
        let terminalResult = try ModelPreparationTerminalResult(state: .succeeded, errorCode: nil, completedAt: Self.timestamp)
        let terminalData = try ModelPreparationContracts.encode(terminalResult, maxBytes: ModelPreparationContracts.activeRecordMaxBytes)
        XCTAssertEqual(
            String(decoding: terminalData, as: UTF8.self),
            #"{"completed_at":"2026-09-12T00:00:00.000Z","error_code":null,"state":"succeeded"}"#
        )
        XCTAssertEqual(
            try ModelPreparationContracts.decode(ModelPreparationTerminalResult.self, from: terminalData, maxBytes: ModelPreparationContracts.activeRecordMaxBytes),
            terminalResult
        )
        let terminalActive = try ModelPreparationActiveRecord(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            projectionBindingSHA256: Self.hexB,
            nextEventSequence: 2,
            phase: .terminal,
            counters: try ModelPreparationActiveCounters(bytesCompleted: 1, bytesExpected: 1, filesCompleted: 1, filesExpected: 1),
            recordedLeaves: [Self.hexA],
            barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: true, objectParentFullSynced: true, phaseRecordSynced: true, phaseRecordReadBack: true),
            terminalResult: terminalResult,
            cancellationRequested: false
        )
        XCTAssertEqual(
            try ModelPreparationContracts.decode(
                ModelPreparationActiveRecord.self,
                from: ModelPreparationContracts.encode(terminalActive, maxBytes: ModelPreparationContracts.activeRecordMaxBytes),
                maxBytes: ModelPreparationContracts.activeRecordMaxBytes
            ),
            terminalActive
        )
    }

    func testCleanupRecordRoundTripsIntentTombstonedRemovedAndRejectsUnsafeLeavesAndBindings() throws {
        for phase in [ModelPreparationCleanupPhase.intent, .tombstoned, .removed] {
            for targetKind in [ModelPreparationCleanupTargetKind.published, .staging] {
                let record = try Self.cleanupRecord(phase: phase, targetKind: targetKind)
                let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
                let decoded = try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: data, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
                XCTAssertEqual(decoded, record)
            }
        }

        let published = try Self.cleanupRecord(phase: .intent, targetKind: .published)
        XCTAssertEqual(published.schema, "model_catalog_cleanup_record.v2")
        XCTAssertEqual(published.finalLeaf, try Self.publishedFinalPath())
        XCTAssertEqual(published.tombstoneLeaf, Self.publishedTombstonePath())
        XCTAssertNil(published.sourceTransactionID)
        XCTAssertNil(published.sourceAttemptID)
        XCTAssertNil(published.sourceRecordSHA256)
        XCTAssertNotNil(published.receipt)
        XCTAssertEqual(published.receiptSHA256, try Self.receiptDigest())
        XCTAssertEqual(published.artifactIdentityDigest, try Self.artifactDigest())

        let staging = try Self.cleanupRecord(phase: .intent, targetKind: .staging)
        XCTAssertEqual(staging.schema, "model_catalog_cleanup_record.v2")
        XCTAssertEqual(staging.finalLeaf, Self.stagingFinalPath())
        XCTAssertEqual(staging.tombstoneLeaf, Self.stagingTombstonePath())
        XCTAssertEqual(staging.sourceTransactionID, Self.sourceTransactionID)
        XCTAssertEqual(staging.sourceAttemptID, Self.sourceAttemptID)
        XCTAssertEqual(staging.sourceRecordSHA256, Self.hexA)
        XCTAssertNil(staging.receipt)
        XCTAssertNil(staging.receiptSHA256)
        XCTAssertNil(staging.artifactIdentityDigest)

        var publishedObject = try Self.object(try ModelPreparationContracts.encode(published, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
        publishedObject["source_transaction_id"] = Self.sourceTransactionID
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Self.data(publishedObject), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))

        var stagingObject = try Self.object(try ModelPreparationContracts.encode(staging, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
        stagingObject["receipt"] = NSNull()
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Self.data(stagingObject), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))

        stagingObject = try Self.object(try ModelPreparationContracts.encode(staging, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
        stagingObject["schema"] = "model_catalog_cleanup_record.v1"
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Self.data(stagingObject), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))

        XCTAssertThrowsError(try Self.cleanupRecord(
            phase: .intent,
            targetKind: .published,
            finalLeaf: try Self.artifactDigest()
        ))
        XCTAssertThrowsError(try Self.cleanupRecord(
            phase: .intent,
            targetKind: .published,
            finalLeaf: try Self.publishedFinalPath(),
            tombstoneLeaf: "objects/.tombstone-" + Self.attemptID
        ))

        let tuple = try Self.tuple()
        let receipt = try Self.receipt()
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            finalLeaf: "nested/leaf",
            tombstoneLeaf: "nested.tombstone",
            expectedBytes: 4096,
            expectedFiles: 1,
            receipt: receipt,
            receiptSHA256: try Self.receiptDigest(),
            artifactIdentityDigest: try Self.artifactDigest()
        ))
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try Self.tupleDigest(),
            finalLeaf: try Self.publishedFinalPath(),
            tombstoneLeaf: Self.publishedTombstonePath(),
            expectedBytes: 4096,
            expectedFiles: 1,
            receipt: receipt,
            receiptSHA256: Self.hexA,
            artifactIdentityDigest: try Self.artifactDigest()
        ))
        XCTAssertThrowsError(try Self.cleanupRecord(phase: .intent, targetKind: .published, expectedBytes: 0))
        XCTAssertThrowsError(try Self.cleanupRecord(phase: .intent, targetKind: .staging, finalLeaf: "/absolute"))
    }

    func testCodecMinimumRejectsMalformedUUIDTimestampTrailingBytesAndCaps() throws {
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: "00000000-0000-1000-8000-000000000001",
            attemptID: nil,
            outcome: .busy,
            observedAt: Self.timestamp
        ))
        let secondsAck = try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T00:00:00Z"
        )
        XCTAssertEqual(secondsAck.observedAt, "2026-09-12T00:00:00Z")
        let offsetAck = try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T08:00:00+08:00"
        )
        XCTAssertEqual(offsetAck.observedAt, "2026-09-12T08:00:00+08:00")
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T00:00:00"
        ))
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-02-30T00:00:00Z"
        ))
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T24:00:00Z"
        ))
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T00:00:00+24:00"
        ))
        let secondsEvent = try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: "2026-09-12T00:00:00Z",
            state: .running,
            progress: nil,
            errorCode: nil,
            warningCode: nil
        )
        XCTAssertEqual(secondsEvent.emittedAt, "2026-09-12T00:00:00Z")
        XCTAssertThrowsError(try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: "2026-02-30T00:00:00Z",
            state: .running,
            progress: nil,
            errorCode: nil,
            warningCode: nil
        ))
        var object = try Self.object(try ModelPreparationContracts.encode(try Self.activeRecord()))
        object["next_event_sequence"] = 1.5
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationActiveRecord.self, from: Self.data(object), maxBytes: ModelPreparationContracts.activeRecordMaxBytes))
        let invalidUTF8 = Data([0xFF])
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCancelAcknowledgement.self, from: invalidUTF8, maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes))
        let trailing = Data(#"{"attempt_id":null,"observed_at":"2026-09-12T00:00:00.000Z","outcome":"busy","schema":"model_catalog_transaction_cancel_ack.v1","transaction_id":"00000000-0000-4000-8000-000000000001"}x"#.utf8)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCancelAcknowledgement.self, from: trailing, maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes))
        XCTAssertThrowsError(try ModelPreparationContracts.encode(try Self.activeRecord(), maxBytes: 1))
    }


    func testNonMarkerDurableTimestampsAcceptRFC3339AndRejectInvalidCalendarValues() throws {
        let secondReservation = try Self.reservation(createdAt: "2026-09-12T00:00:00Z")
        XCTAssertEqual(secondReservation.createdAt, "2026-09-12T00:00:00Z")
        let offsetReservation = try Self.reservation(createdAt: "2026-09-12T08:00:00+08:00")
        XCTAssertEqual(offsetReservation.createdAt, "2026-09-12T08:00:00+08:00")
        XCTAssertThrowsError(try Self.reservation(createdAt: "2026-02-30T00:00:00Z"))
        XCTAssertThrowsError(try Self.reservation(createdAt: "2026-09-12T24:00:00Z"))
        XCTAssertThrowsError(try Self.reservation(createdAt: "2026-09-12T00:00:00+24:00"))

        let terminal = try Self.terminalHistory(completedAt: "2026-09-12T08:00:00+08:00")
        XCTAssertEqual(terminal.completedAt, "2026-09-12T08:00:00+08:00")
        XCTAssertThrowsError(try Self.terminalHistory(completedAt: "2026-02-30T00:00:00Z"))

        let receipt = try Self.receipt(publishedAt: "2026-09-12T08:00:00+08:00")
        let receiptData = try ModelPreparationContracts.encode(receipt, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
        XCTAssertEqual(
            try ModelPreparationContracts.publicationReceiptSHA256(from: receiptData),
            ModelPreparationContracts.sha256Hex(for: receiptData)
        )
        XCTAssertThrowsError(try Self.receipt(publishedAt: "2026-02-30T00:00:00Z"))

        let inventory = try Self.inventory(generatedAt: "2026-09-12T08:00:00+08:00")
        XCTAssertEqual(inventory.generatedAt, "2026-09-12T08:00:00+08:00")
        XCTAssertThrowsError(try Self.inventory(generatedAt: "2026-02-30T00:00:00Z"))

        let marker = try ModelPreparationCancelMarker(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: secondReservation.eventModelKey,
            root: secondReservation.root,
            tupleSHA256: secondReservation.tupleSHA256,
            projectionBindingSHA256: secondReservation.projectionBindingSHA256,
            recordedAt: "2026-09-12T00:00:00Z"
        )
        XCTAssertEqual(marker.recordedAt, "2026-09-12T00:00:00Z")
        XCTAssertThrowsError(try ModelPreparationCancelMarker(
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            transactionKind: .prepareModel,
            eventModelKey: secondReservation.eventModelKey,
            root: secondReservation.root,
            tupleSHA256: secondReservation.tupleSHA256,
            projectionBindingSHA256: secondReservation.projectionBindingSHA256,
            recordedAt: "2026-09-12T00:00:00.000Z"
        ))
    }

    func testPublicationReceiptIsNonCircularAndSelfDigesting() throws {
        let receipt = try Self.receipt()
        let data = try ModelPreparationContracts.encode(receipt, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("artifact_identity_digest"))
        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationPublicationReceipt.self,
            from: data,
            maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
        )
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(try Self.receiptDigest(decoded), ModelPreparationContracts.sha256Hex(for: data))
        XCTAssertEqual(try ModelPreparationContracts.publicationReceiptSHA256(from: data), ModelPreparationContracts.sha256Hex(for: data))

        var nonCanonicalReceipt = String(decoding: data, as: UTF8.self)
        nonCanonicalReceipt.insert(" ", at: nonCanonicalReceipt.index(after: nonCanonicalReceipt.startIndex))
        let nonCanonicalReceiptData = Data(nonCanonicalReceipt.utf8)
        XCTAssertThrowsError(try ModelPreparationContracts.publicationReceiptSHA256(from: nonCanonicalReceiptData))
        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationPublicationReceipt.self,
            from: nonCanonicalReceiptData,
            maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
        ))

        var cleanupObject = try Self.object(try ModelPreparationContracts.encode(try Self.cleanupRecord(phase: .intent, targetKind: .published), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
        cleanupObject["receipt"] = try XCTUnwrap(JSONSerialization.jsonObject(with: nonCanonicalReceiptData) as? [String: Any])
        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationCleanupRecord.self,
            from: Self.data(cleanupObject),
            maxBytes: ModelPreparationContracts.deletionRecordMaxBytes
        ))

        let mutatedReceipt = try Self.receipt(publishedAt: "2026-09-12T00:00:01.000Z")
        XCTAssertNotEqual(try Self.receiptDigest(mutatedReceipt), try Self.receiptDigest(receipt))
        let originalReceiptDigest = try Self.receiptDigest(receipt)
        let originalDigest = try Self.artifactDigest(tuple: receipt.tuple, receiptSHA256: originalReceiptDigest)
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: Self.transactionID,
            attemptID: Self.attemptID,
            eventModelKey: receipt.eventModelKey,
            root: receipt.root,
            tuple: receipt.tuple,
            tupleSHA256: receipt.tupleSHA256,
            finalLeaf: try Self.publishedFinalPath(),
            tombstoneLeaf: Self.publishedTombstonePath(),
            expectedBytes: 4096,
            expectedFiles: 1,
            receipt: mutatedReceipt,
            receiptSHA256: originalReceiptDigest,
            artifactIdentityDigest: originalDigest
        ))
    }

    func testPublicationReceiptCorrelationsRejectMutations() throws {
        let record = try Self.cleanupRecord(phase: .intent, targetKind: .published)
        let mutatedReceipt = try Self.receipt(publishedAt: "2026-09-12T00:00:01.000Z")
        let mutatedReceiptSHA256 = try Self.receiptDigest(mutatedReceipt)
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: record.transactionID,
            attemptID: record.attemptID,
            eventModelKey: record.eventModelKey,
            root: record.root,
            tuple: record.tuple,
            tupleSHA256: record.tupleSHA256,
            finalLeaf: record.finalLeaf,
            tombstoneLeaf: record.tombstoneLeaf,
            expectedBytes: record.expectedBytes,
            expectedFiles: record.expectedFiles,
            receipt: mutatedReceipt,
            receiptSHA256: mutatedReceiptSHA256,
            artifactIdentityDigest: record.artifactIdentityDigest
        ))

        XCTAssertThrowsError(try Self.receipt(eventModelKey: "other/model"))
        let otherRoot = try ModelPreparationRootLocator(
            canonicalPath: "/tmp/other-root",
            stDev: 123,
            stIno: 456,
            identityVersion: "model_catalog_root_identity.v1",
            rootIdentityDigest: Self.hexB
        )
        XCTAssertThrowsError(try Self.receipt(root: otherRoot))
        let otherTuple = try ModelPreparationTupleRecord(
            tupleID: "tuple-other",
            eventModelKey: "catalog/model",
            displayModelID: "other-display",
            modelRevision: "rev",
            artifactID: "artifact",
            releaseID: "release",
            artifactSHA256: Self.hexA,
            estimatedBytes: 4096,
            root: try Self.root(),
            authorityOrder: 0
        )
        let otherReceipt = try Self.receipt(tuple: otherTuple)
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: record.transactionID,
            attemptID: record.attemptID,
            eventModelKey: record.eventModelKey,
            root: record.root,
            tuple: record.tuple,
            tupleSHA256: record.tupleSHA256,
            finalLeaf: record.finalLeaf,
            tombstoneLeaf: record.tombstoneLeaf,
            expectedBytes: record.expectedBytes,
            expectedFiles: record.expectedFiles,
            receipt: otherReceipt,
            receiptSHA256: try Self.receiptDigest(otherReceipt),
            artifactIdentityDigest: try Self.artifactDigest(tuple: otherTuple, receiptSHA256: Self.receiptDigest(otherReceipt))
        ))
    }

    func testArtifactIdentityIsRecomputedForCleanupTargetsAndRecords() throws {
        let tuple = try Self.tuple()
        let digest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: tuple.displayModelID,
            modelRevision: tuple.modelRevision,
            artifactID: tuple.artifactID,
            releaseID: tuple.releaseID,
            rootIdentityDigest: tuple.root.rootIdentityDigest,
            receiptSHA256: Self.receiptDigest()
        )
        let action = try ModelPreparationAction(
            available: true,
            requiresConfirmation: true,
            transactionKind: .cleanupPublishedArtifact,
            transactionID: Self.transactionID,
            actionTimeoutSeconds: 30,
            estimatedBytes: 4096,
            unavailableReason: nil,
            artifactIdentityDigest: digest
        )
        _ = try ModelPreparationCleanupTarget(
            artifactIdentityDigest: digest,
            displayModelID: tuple.displayModelID,
            modelRevision: tuple.modelRevision,
            artifactID: tuple.artifactID,
            releaseID: tuple.releaseID,
            modelKey: nil,
            eventModelKey: tuple.eventModelKey,
            rootIdentityDigest: tuple.root.rootIdentityDigest,
            receiptSHA256: Self.receiptDigest(),
            estimatedBytes: 4096,
            keepSetStatus: .reclaimable,
            protectedReason: nil,
            cleanup: action
        )
        for mutation in ["display", "revision", "artifact", "release", "root", "receipt", "enclosing"] {
            XCTAssertThrowsError(try Self.cleanupTargetWithArtifactMutation(mutation, digest: digest, action: action))
        }
        let record = try Self.cleanupRecord(phase: .intent, targetKind: .published)
        XCTAssertEqual(record.artifactIdentityDigest, Optional(digest))
        XCTAssertThrowsError(try Self.cleanupRecord(phase: .intent, targetKind: .published, receiptSHA256: Self.hexA))
        XCTAssertThrowsError(try Self.cleanupRecord(phase: .intent, targetKind: .published, artifactIdentityDigest: Self.hexA))
    }

    func testNumericTokensRejectNoncanonicalIntegerSpellingsBeforeTypedDecode() throws {
        let activeJSON = String(decoding: try ModelPreparationContracts.encode(try Self.activeRecord()), as: UTF8.self)
        for replacement in ["4096.0", "4.096e3", "-0"] {
            let mutated = activeJSON.replacingOccurrences(of: "4096", with: replacement, options: [], range: activeJSON.range(of: "4096"))
            XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationActiveRecord.self, from: Data(mutated.utf8), maxBytes: ModelPreparationContracts.activeRecordMaxBytes))
        }
        let eventJSON = String(decoding: try ModelPreparationContracts.encode(try Self.failedEvent()), as: UTF8.self)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationTransactionEvent.self, from: Data(eventJSON.replacingOccurrences(of: #""event_sequence":1"#, with: #""event_sequence":1.0"#).utf8), maxBytes: ModelPreparationContracts.eventMaxBytes))
        let tempJSON = String(decoding: try ModelPreparationContracts.encode(try Self.privateStateEnvelope()), as: UTF8.self)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationPrivateStateEnvelope.self, from: Data(tempJSON.replacingOccurrences(of: #""generation":1"#, with: #""generation":1.0"#).utf8), maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes))
        let actionJSON = String(decoding: try ModelPreparationContracts.encode(try Self.cleanupRecord(phase: .intent, targetKind: .published)), as: UTF8.self)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Data(actionJSON.replacingOccurrences(of: #""expected_bytes":4096"#, with: #""expected_bytes":4096.0"#).utf8), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
    }

    func testJSONDepthIsBoundedBeforeTypedDecodeAndEnvelopePayloadValidation() throws {
        let depth = ModelPreparationContracts.maxJSONNestingDepth + 2
        let overDepthJSON = Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationFailedDispatchRecord.self, from: overDepthJSON, maxBytes: ModelPreparationContracts.failedDispatchMaxBytes)) { error in
            XCTAssertEqual(error as? ModelPreparationContractError, .malformed("json depth"))
        }
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .active),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: overDepthJSON
        )) { error in
            XCTAssertEqual(error as? ModelPreparationContractError, .malformed("json depth"))
        }
    }

    func testRootIdentityVersionIsClosedAcrossPrivateRecords() throws {
        let records: [(Data, Int, Any.Type)] = [
            (try ModelPreparationContracts.encode(try Self.failedDispatch()), ModelPreparationContracts.failedDispatchMaxBytes, ModelPreparationFailedDispatchRecord.self),
            (try ModelPreparationContracts.encode(try Self.reservation()), ModelPreparationContracts.reservationHistoryMaxBytes, ModelPreparationReservationRecord.self),
            (try ModelPreparationContracts.encode(try Self.activeRecord()), ModelPreparationContracts.activeRecordMaxBytes, ModelPreparationActiveRecord.self),
            (try ModelPreparationContracts.encode(try Self.inventory()), ModelPreparationContracts.inventoryMaxBytes, ModelPreparationInventoryRecord.self),
            (try ModelPreparationContracts.encode(try Self.cleanupRecord(phase: .intent, targetKind: .published)), ModelPreparationContracts.deletionRecordMaxBytes, ModelPreparationCleanupRecord.self),
        ]
        for (data, cap, type) in records {
            let mutated = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "model_catalog_root_identity.v1", with: "model_catalog_root_identity.v2")
            switch type {
            case is ModelPreparationFailedDispatchRecord.Type:
                XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationFailedDispatchRecord.self, from: Data(mutated.utf8), maxBytes: cap))
            case is ModelPreparationReservationRecord.Type:
                XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationReservationRecord.self, from: Data(mutated.utf8), maxBytes: cap))
            case is ModelPreparationActiveRecord.Type:
                XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationActiveRecord.self, from: Data(mutated.utf8), maxBytes: cap))
            case is ModelPreparationInventoryRecord.Type:
                XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationInventoryRecord.self, from: Data(mutated.utf8), maxBytes: cap))
            case is ModelPreparationCleanupRecord.Type:
                XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Data(mutated.utf8), maxBytes: cap))
            default:
                XCTFail("unexpected type")
            }
        }
    }

    func testActionSizeNullabilityAndCaps() throws {
        XCTAssertThrowsError(try Self.action(kind: .prepareModel, requiresConfirmation: true, estimatedBytes: nil))
        XCTAssertThrowsError(try Self.action(kind: .prepareModel, requiresConfirmation: true, estimatedBytes: 0))
        XCTAssertThrowsError(try Self.action(kind: .prepareModel, requiresConfirmation: true, estimatedBytes: Int64(ModelPreparationContracts.maxEstimatedBytes + 1)))
        _ = try Self.action(kind: .prepareModel, requiresConfirmation: true, estimatedBytes: Int64(ModelPreparationContracts.maxEstimatedBytes))
        XCTAssertThrowsError(try Self.action(kind: .adoptRecommendation, requiresConfirmation: true, estimatedBytes: 0))
        XCTAssertThrowsError(try Self.action(kind: .evaluateModel, requiresConfirmation: true, estimatedBytes: Int64(ModelPreparationContracts.maxEstimatedBytes + 1)))
        _ = try Self.action(kind: .evaluateModel, requiresConfirmation: false, estimatedBytes: nil, timeout: 10)
        XCTAssertThrowsError(try ModelPreparationAction(
            available: false,
            requiresConfirmation: false,
            transactionKind: nil,
            transactionID: nil,
            actionTimeoutSeconds: nil,
            estimatedBytes: nil,
            unavailableReason: "not available",
            artifactIdentityDigest: Self.hexA
        ))
        XCTAssertThrowsError(try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: ModelPreparationContracts.maxJavaScriptSafeInteger + 1,
            emittedAt: Self.timestamp,
            state: .failed,
            progress: nil,
            errorCode: .operationConflict,
            warningCode: nil
        ))
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .deletion,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .deletion),
            writerUUID: Self.writerUUID,
            generation: ModelPreparationContracts.maxJavaScriptSafeInteger + 1,
            payload: try Self.activePayload()
        ))
    }

    func testPrivateStateEnvelopeRoundTripSerializationAndFilename() throws {
        let payload = try Self.activePayload()
        let record = try Self.privateStateEnvelope(payload: payload)
        let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        let object = try Self.object(data)
        XCTAssertEqual(object["record_kind"] as? String, "active")
        XCTAssertEqual(object["target_leaf"] as? String, "active.json")
        XCTAssertEqual(object["payload_base64"] as? String, payload.base64EncodedString())
        XCTAssertEqual(object["payload_sha256"] as? String, ModelPreparationContracts.sha256Hex(for: payload))
        let decoded = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: data,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try record.expectedFilename(), "active.json.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.tmp")
        XCTAssertNoThrow(try record.validateTempFilename("active.json.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.tmp"))
        XCTAssertNoThrow(try record.validateDurableTargetLeaf("active.json"))
        XCTAssertThrowsError(try record.validateDurableTargetLeaf("cancel.json"))
    }

    func testPrivateStateEnvelopeRejectsMalformedBindingsAndCaps() throws {
        let record = try Self.privateStateEnvelope()
        let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        var object = try Self.object(data)

        object["record_kind"] = "unknown_kind"
        XCTAssertThrowsError(try Self.decodeTemp(object))

        object = try Self.object(data)
        object["target_leaf"] = "deletion.json"
        XCTAssertThrowsError(try Self.decodeTemp(object))

        object = try Self.object(data)
        object["target_leaf"] = "../active.json"
        XCTAssertThrowsError(try Self.decodeTemp(object))

        object = try Self.object(data)
        object["writer_uuid"] = "22222222-2222-1222-8222-222222222222"
        XCTAssertThrowsError(try Self.decodeTemp(object))

        object = try Self.object(data)
        object["writer_uuid"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".uppercased()
        XCTAssertThrowsError(try Self.decodeTemp(object))

        XCTAssertThrowsError(try record.validateTempFilename("active.json.bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.tmp"))

        object = try Self.object(data)
        object["payload_base64"] = Data(#"{"ok":false}"#.utf8).base64EncodedString()
        XCTAssertThrowsError(try Self.decodeTemp(object))

        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: "active.json",
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.activePayload(),
            payloadSHA256: Self.hexA
        ))

        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            schema: "model_catalog_unique_temp.v2",
            recordKind: .active,
            targetLeaf: "active.json",
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.activePayload()
        ))

        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: "root.identity",
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.activePayload()
        ))

        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: ModelPreparationContracts.encode(try Self.activeRecord()),
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        ))

        object = try Self.object(data)
        object.removeValue(forKey: "payload_sha256")
        XCTAssertThrowsError(try Self.decodeTemp(object))

        object = try Self.object(data)
        object["extra"] = true
        XCTAssertThrowsError(try Self.decodeTemp(object))

        let envelopeJSON = String(decoding: data, as: UTF8.self)
        let duplicate = Data(envelopeJSON.replacingOccurrences(
            of: #""record_kind":"active""#,
            with: #""record_kind":"active","record_kind":"active""#
        ).utf8)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationPrivateStateEnvelope.self, from: duplicate, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes))

        _ = try ModelPreparationPrivateStateEnvelope(
            recordKind: .cancel,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .cancel),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.cancelMarkerPayload()
        )
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .cancel,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .cancel),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: Data(count: ModelPreparationContracts.cancelMarkerMaxBytes + 1)
        ))

        XCTAssertThrowsError(try ModelPreparationContracts.encode(record, maxBytes: data.count - 1))
    }

    func testPrivateStateEnvelopeAllowedKindLeafInventoryAndMaxPayloadCaps() throws {
        XCTAssertEqual(
            ModelPreparationPrivateStateEnvelopeKind.allCases.map { "\($0.rawValue)->\(ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: $0))" },
            [
                "reservations->reservations.json",
                "active->active.json",
                "cancel->cancel.json",
                "published_inventory->published-inventory.json",
                "deletion->deletion.json",
                "staging_sources->staging-sources.json",
                "failed_dispatch_pending->failed-dispatch-pending.json",
            ]
        )

        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .reservations,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .active),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.payload(for: .reservations)
        ))

        for kind in ModelPreparationPrivateStateEnvelopeKind.allCases {
            let payload = try Self.payload(for: kind)
            let record = try ModelPreparationPrivateStateEnvelope(
                recordKind: kind,
                targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind),
                writerUUID: Self.writerUUID,
                generation: 1,
                payload: payload
            )
            let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
            _ = try ModelPreparationContracts.decode(
                ModelPreparationPrivateStateEnvelope.self,
                from: data,
                maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
            )
            XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
                recordKind: kind,
                targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind),
                writerUUID: Self.writerUUID,
                generation: 1,
                payload: Data(count: ModelPreparationPrivateStateEnvelope.payloadMaxBytes(for: kind) + 1)
            ))
        }

        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .stagingSources,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .stagingSources),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.failedDispatchPayload()
        ))
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .failedDispatchPending,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .failedDispatchPending),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.stagingSourcesPayload()
        ))

        var failedDispatch = try Self.object(Self.failedDispatchPayload())
        failedDispatch["completed_at"] = Self.timestamp
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope(
            recordKind: .failedDispatchPending,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .failedDispatchPending),
            writerUUID: Self.writerUUID,
            generation: 1,
            payload: try Self.data(failedDispatch)
        ))
    }

    func testPrivateStateEnvelopeRejectsNoncanonicalBase64AliasesAndKeepsRootIdentityRaw() throws {
        let rootRecord = try ModelPreparationRootIdentityRecord(
            version: "model_catalog_root_identity.v1",
            nonceHex: String(repeating: "0", count: 64),
            canonicalPath: "/tmp/macprovider-root",
            stDev: 123,
            stIno: 456
        )
        let rootData = try ModelPreparationContracts.encode(rootRecord, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        let decodedRoot = try ModelPreparationContracts.decode(
            ModelPreparationRootIdentityRecord.self,
            from: rootData,
            maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes
        )
        XCTAssertEqual(decodedRoot, rootRecord)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: rootData,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        ))
        XCTAssertThrowsError(try ModelPreparationPrivateStateEnvelope.expectedFilename(
            recordKind: .active,
            targetLeaf: "root.identity",
            writerUUID: Self.writerUUID
        ))

        let canonical = try Self.privateStateEnvelope(payload: try Self.activePayload())
        let data = try ModelPreparationContracts.encode(canonical, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
        for alias in ["e31=", "e30=="] {
            var object = try Self.object(data)
            object["payload_base64"] = alias
            XCTAssertThrowsError(try Self.decodeTemp(object))
        }
    }

    func testClosedAdmissionInventoryAndExactCopyConstants() {
        XCTAssertEqual(ModelPreparationAdmissionState.allCases.map(\.rawValue), [
            "local_only",
            "not_offered",
            "offerable",
            "offer_submitted",
            "offer_rejected",
            "sandbox_probe_only",
            "network_visible_unpriced",
            "network_admitted_unsettled",
            "catalog_priced",
            "settlement_capable",
            "withdrawn",
            "revoked",
        ])
        XCTAssertEqual(ModelPreparationContracts.localPrepareLabel, "Prepare locally")
        XCTAssertEqual(
            ModelPreparationContracts.localPrepareDetail,
            "Download and verify this model for local use. This does not offer it to the network or enable earnings."
        )
        XCTAssertEqual(
            ModelPreparationContracts.localOnlyMeaning,
            "Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable."
        )
        XCTAssertEqual(
            ModelPreparationContracts.settlementCapableMeaning,
            "Eligible to earn on qualifying settled requests"
        )
        XCTAssertEqual(
            ModelPreparationContracts.localDefaultNotOfferedMeaning,
            "Coordinator offer state is unavailable or has not been queried."
        )
        XCTAssertEqual(
            ModelPreparationContracts.coordinatorNotOfferedMeaning,
            "Coordinator reports no active network offer for this model."
        )
    }

    private static let transactionID = "00000000-0000-4000-8000-000000000001"
    private static let attemptID = "11111111-1111-4111-8111-111111111111"
    private static let sourceTransactionID = "22222222-2222-4222-8222-222222222222"
    private static let sourceAttemptID = "33333333-3333-4333-8333-333333333333"
    private static let terminalTransactionID = "66666666-6666-4666-8666-666666666666"
    private static let terminalAttemptID = "77777777-7777-4777-8777-777777777777"
    private static let writerUUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let timestamp = "2026-09-12T00:00:00.000Z"
    private static let secondTimestamp = "2026-09-12T00:00:00Z"
    private static let hexA = String(repeating: "a", count: 64)
    private static let hexB = String(repeating: "b", count: 64)

    private static func root() throws -> ModelPreparationRootLocator {
        try ModelPreparationRootLocator(
            canonicalPath: "/tmp/macprovider-root",
            stDev: 123,
            stIno: 456,
            identityVersion: "model_catalog_root_identity.v1",
            rootIdentityDigest: hexA
        )
    }

    private static func tuple() throws -> ModelPreparationTupleRecord {
        try ModelPreparationTupleRecord(
            tupleID: "tuple-1",
            eventModelKey: "catalog/model",
            displayModelID: "display",
            modelRevision: "rev",
            artifactID: "artifact",
            releaseID: "release",
            artifactSHA256: hexB,
            estimatedBytes: 4096,
            root: root(),
            authorityOrder: 0
        )
    }

    private static func tupleDigest() throws -> String {
        try ModelPreparationContracts.tupleSHA256(tuple())
    }

    private static func failedDispatch() throws -> ModelPreparationFailedDispatchRecord {
        try ModelPreparationFailedDispatchRecord(
            transactionID: transactionID,
            attemptID: attemptID,
            transactionKind: .prepareModel,
            eventModelKey: "catalog/model",
            root: root(),
            tupleSHA256: try tupleDigest(),
            projectionBindingSHA256: hexB,
            errorCode: .operationConflict
        )
    }


    private static func cancelMarker() throws -> ModelPreparationCancelMarker {
        let tuple = try tuple()
        return try ModelPreparationCancelMarker(
            transactionID: transactionID,
            attemptID: attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tupleSHA256: try tupleDigest(),
            projectionBindingSHA256: hexB,
            recordedAt: secondTimestamp
        )
    }

    private static func stagingSourceLeaf(
        sourceTransactionID: String = sourceTransactionID,
        sourceAttemptID: String = sourceAttemptID
    ) -> String {
        "work/staging/\(sourceTransactionID)/\(sourceAttemptID)/source.json"
    }

    private static func stagingFinalPath(
        sourceTransactionID: String = sourceTransactionID,
        sourceAttemptID: String = sourceAttemptID
    ) -> String {
        "work/staging/\(sourceTransactionID)/\(sourceAttemptID)"
    }

    private static func stagingTombstonePath(
        sourceTransactionID: String = sourceTransactionID,
        transactionID: String = transactionID
    ) -> String {
        "work/staging/\(sourceTransactionID)/.tombstone-\(transactionID)"
    }

    private static func stagingSourceRecord() throws -> ModelPreparationStagingSourceRecord {
        let tuple = try tuple()
        return try ModelPreparationStagingSourceRecord(
            sourceTransactionID: sourceTransactionID,
            sourceAttemptID: sourceAttemptID,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: try tupleDigest(),
            eventModelKey: tuple.eventModelKey,
            projectionBindingSHA256: hexB,
            stagingLeaf: stagingSourceLeaf()
        )
    }

    private static func stagingSourceEntry() throws -> ModelPreparationStagingSourceEntry {
        try ModelPreparationStagingSourceEntry(
            sourceTransactionID: sourceTransactionID,
            sourceAttemptID: sourceAttemptID,
            root: try root(),
            sourceRecordSHA256: hexA
        )
    }

    private static func action(
        kind: ModelPreparationTransactionKind,
        requiresConfirmation: Bool,
        estimatedBytes: Int64? = nil,
        timeout: Int = 30
    ) throws -> ModelPreparationAction {
        try ModelPreparationAction(
            available: true,
            requiresConfirmation: requiresConfirmation,
            transactionKind: kind,
            transactionID: transactionID,
            actionTimeoutSeconds: timeout,
            estimatedBytes: estimatedBytes,
            unavailableReason: nil,
            artifactIdentityDigest: kind == .cleanupPublishedArtifact ? hexA : nil
        )
    }

    private static func artifactDigest(tuple: ModelPreparationTupleRecord? = nil, receiptSHA256: String? = nil) throws -> String {
        let selectedTuple = try tuple ?? Self.tuple()
        return try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: selectedTuple.displayModelID,
            modelRevision: selectedTuple.modelRevision,
            artifactID: selectedTuple.artifactID,
            releaseID: selectedTuple.releaseID,
            rootIdentityDigest: selectedTuple.root.rootIdentityDigest,
            receiptSHA256: receiptSHA256 ?? Self.receiptDigest()
        )
    }

    private static func receipt(
        tuple: ModelPreparationTupleRecord? = nil,
        eventModelKey: String? = nil,
        root: ModelPreparationRootLocator? = nil,
        tupleSHA256: String? = nil,
        publishedAt: String = timestamp
    ) throws -> ModelPreparationPublicationReceipt {
        let selectedTuple = try tuple ?? Self.tuple()
        return try ModelPreparationPublicationReceipt(
            eventModelKey: eventModelKey ?? selectedTuple.eventModelKey,
            root: root ?? selectedTuple.root,
            tuple: selectedTuple,
            tupleSHA256: tupleSHA256 ?? ModelPreparationContracts.tupleSHA256(selectedTuple),
            publishedAt: publishedAt
        )
    }

    private static func receiptDigest(_ receipt: ModelPreparationPublicationReceipt? = nil) throws -> String {
        try ModelPreparationContracts.receiptSHA256(receipt ?? Self.receipt())
    }

    private static func activeRecord() throws -> ModelPreparationActiveRecord {
        let tuple = try tuple()
        return try ModelPreparationActiveRecord(
            transactionID: transactionID,
            attemptID: attemptID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest(),
            projectionBindingSHA256: hexB,
            nextEventSequence: 2,
            phase: .transferring,
            counters: try ModelPreparationActiveCounters(bytesCompleted: 1, bytesExpected: 4096, filesCompleted: 0, filesExpected: 1),
            recordedLeaves: [hexA],
            barrierProgress: ModelPreparationBarrierProgress(objectParentSynced: false, objectParentFullSynced: false, phaseRecordSynced: false, phaseRecordReadBack: false),
            terminalResult: nil,
            cancellationRequested: false
        )
    }

    private static func publishedFinalPath(artifactIdentityDigest: String? = nil) throws -> String {
        let digest = try artifactIdentityDigest ?? Self.artifactDigest()
        return "objects/\(digest)"
    }

    private static func publishedTombstonePath(transactionID: String = transactionID) -> String {
        "objects/.tombstone-\(transactionID)"
    }

    private static func cleanupRecord(
        phase: ModelPreparationCleanupPhase,
        targetKind: ModelPreparationCleanupTargetKind,
        expectedBytes: Int64 = 4096,
        finalLeaf: String? = nil,
        tombstoneLeaf: String? = nil,
        receiptSHA256: String? = nil,
        artifactIdentityDigest: String? = nil,
        sourceTransactionID: String = sourceTransactionID,
        sourceAttemptID: String = sourceAttemptID,
        sourceRecordSHA256: String = hexA
    ) throws -> ModelPreparationCleanupRecord {
        let tuple = try tuple()
        let receipt = try receipt()
        let selectedReceiptSHA256: String
        if let receiptSHA256 {
            selectedReceiptSHA256 = receiptSHA256
        } else {
            selectedReceiptSHA256 = try Self.receiptDigest(receipt)
        }
        let selectedArtifactDigest: String
        if let artifactIdentityDigest {
            selectedArtifactDigest = artifactIdentityDigest
        } else {
            selectedArtifactDigest = try Self.artifactDigest(tuple: tuple, receiptSHA256: selectedReceiptSHA256)
        }
        let final: String
        if let finalLeaf {
            final = finalLeaf
        } else if targetKind == .published {
            final = try publishedFinalPath(artifactIdentityDigest: selectedArtifactDigest)
        } else {
            final = stagingFinalPath(sourceTransactionID: sourceTransactionID, sourceAttemptID: sourceAttemptID)
        }
        let tombstone: String
        if let tombstoneLeaf {
            tombstone = tombstoneLeaf
        } else if targetKind == .published {
            tombstone = publishedTombstonePath(transactionID: transactionID)
        } else {
            tombstone = stagingTombstonePath(sourceTransactionID: sourceTransactionID, transactionID: transactionID)
        }
        switch targetKind {
        case .published:
            return try ModelPreparationCleanupRecord(
                targetKind: targetKind,
                phase: phase,
                transactionID: transactionID,
                attemptID: attemptID,
                eventModelKey: tuple.eventModelKey,
                root: tuple.root,
                tuple: tuple,
                tupleSHA256: tupleDigest(),
                finalLeaf: final,
                tombstoneLeaf: tombstone,
                expectedBytes: expectedBytes,
                expectedFiles: 1,
                receipt: receipt,
                receiptSHA256: selectedReceiptSHA256,
                artifactIdentityDigest: selectedArtifactDigest
            )
        case .staging:
            return try ModelPreparationCleanupRecord(
                targetKind: targetKind,
                phase: phase,
                transactionID: transactionID,
                attemptID: attemptID,
                eventModelKey: tuple.eventModelKey,
                root: tuple.root,
                tuple: tuple,
                tupleSHA256: tupleDigest(),
                finalLeaf: final,
                tombstoneLeaf: tombstone,
                expectedBytes: expectedBytes,
                expectedFiles: 1,
                sourceTransactionID: sourceTransactionID,
                sourceAttemptID: sourceAttemptID,
                sourceRecordSHA256: sourceRecordSHA256
            )
        }
    }


    private static func cleanupStagingReservation() throws -> ModelPreparationReservationRecord {
        let tuple = try tuple()
        return try ModelPreparationReservationRecord(
            transactionID: transactionID,
            transactionKind: .cleanupStaging,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest(),
            projectionBindingSHA256: hexB,
            createdAt: timestamp,
            sourceTransactionID: sourceTransactionID,
            sourceAttemptID: sourceAttemptID,
            sourceRecordSHA256: hexA
        )
    }

    private static func terminalHistory(
        transactionID: String = terminalTransactionID,
        attemptID: String = terminalAttemptID,
        transactionKind: ModelPreparationTransactionKind = .prepareModel,
        eventModelKey: String = "catalog/model",
        root: ModelPreparationRootLocator? = nil,
        tupleSHA256: String? = nil,
        projectionBindingSHA256: String = hexB,
        state: ModelPreparationHistoryTerminalState = .failed,
        errorCode: ModelPreparationEventErrorCode? = .operationConflict,
        completedAt: String = timestamp
    ) throws -> ModelPreparationTerminalHistoryRecord {
        try ModelPreparationTerminalHistoryRecord(
            transactionID: transactionID,
            attemptID: attemptID,
            transactionKind: transactionKind,
            eventModelKey: eventModelKey,
            root: root ?? Self.root(),
            tupleSHA256: tupleSHA256 ?? tupleDigest(),
            projectionBindingSHA256: projectionBindingSHA256,
            eventSequence: 1,
            terminalState: state,
            errorCode: errorCode,
            completedAt: completedAt
        )
    }

    private static func terminalHistoryEntry() throws -> ModelPreparationReservationsTerminalHistoryEntry {
        .ordinary(try terminalHistory())
    }

    private static func failedDispatchHistoryEntry() throws -> ModelPreparationReservationsTerminalHistoryEntry {
        .failedDispatch(try ModelPreparationFailedDispatchRecord(
            transactionID: "44444444-4444-4444-8444-444444444444",
            attemptID: "55555555-5555-4555-8555-555555555555",
            transactionKind: .prepareModel,
            eventModelKey: "catalog/model",
            root: root(),
            tupleSHA256: tupleDigest(),
            projectionBindingSHA256: hexB,
            errorCode: .operationConflict
        ))
    }

    private static func reservationsHistory() throws -> ModelPreparationReservationsHistoryRecord {
        try ModelPreparationReservationsHistoryRecord(
            projectedReservations: [cleanupStagingReservation()],
            terminalHistory: [try terminalHistoryEntry(), try failedDispatchHistoryEntry()]
        )
    }

    private static func payload(for kind: ModelPreparationPrivateStateEnvelopeKind) throws -> Data {
        switch kind {
        case .reservations: return try reservationsPayload()
        case .active: return try activePayload()
        case .cancel: return try cancelMarkerPayload()
        case .publishedInventory: return try inventoryPayload()
        case .deletion: return try deletionPayload()
        case .stagingSources: return try stagingSourcesPayload()
        case .failedDispatchPending: return try failedDispatchPayload()
        }
    }

    private static func reservationsPayload() throws -> Data {
        try ModelPreparationContracts.encode(reservationsHistory(), maxBytes: ModelPreparationContracts.reservationHistoryMaxBytes)
    }

    private static func activePayload() throws -> Data {
        try ModelPreparationContracts.encode(activeRecord(), maxBytes: ModelPreparationContracts.activeRecordMaxBytes)
    }

    private static func cancelMarkerPayload() throws -> Data {
        try ModelPreparationContracts.encode(cancelMarker(), maxBytes: ModelPreparationContracts.cancelMarkerMaxBytes)
    }

    private static func inventoryPayload() throws -> Data {
        try ModelPreparationContracts.encode(inventory(), maxBytes: ModelPreparationContracts.inventoryMaxBytes)
    }

    private static func deletionPayload() throws -> Data {
        try ModelPreparationContracts.encode(cleanupRecord(phase: .intent, targetKind: .published), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
    }

    private static func stagingSourcesPayload() throws -> Data {
        try ModelPreparationContracts.encode(ModelPreparationStagingSourcesRecord(entries: [stagingSourceEntry()]), maxBytes: ModelPreparationContracts.stagingSourcesMaxBytes)
    }

    private static func failedDispatchPayload() throws -> Data {
        try ModelPreparationContracts.encode(failedDispatch(), maxBytes: ModelPreparationContracts.failedDispatchMaxBytes)
    }

    private static func privateStateEnvelope(payload: Data? = nil) throws -> ModelPreparationPrivateStateEnvelope {
        try ModelPreparationPrivateStateEnvelope(
            recordKind: .active,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .active),
            writerUUID: writerUUID,
            generation: 1,
            payload: payload ?? activePayload()
        )
    }

    private static func failedEvent() throws -> ModelPreparationTransactionEvent {
        try ModelPreparationTransactionEvent(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: timestamp,
            state: .failed,
            progress: nil,
            errorCode: .operationConflict,
            warningCode: nil
        )
    }

    private static func reservation(createdAt: String = timestamp) throws -> ModelPreparationReservationRecord {
        let tuple = try tuple()
        return try ModelPreparationReservationRecord(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest(),
            projectionBindingSHA256: hexB,
            createdAt: createdAt
        )
    }

    private static func inventory(generatedAt: String = timestamp) throws -> ModelPreparationInventoryRecord {
        try ModelPreparationInventoryRecord(schema: "model_catalog_published_inventory.v1", root: root(), targets: [], generatedAt: generatedAt)
    }

    private static func cleanupTargetWithArtifactMutation(_ mutation: String, digest: String, action: ModelPreparationAction) throws -> ModelPreparationCleanupTarget {
        let tuple = try tuple()
        return try ModelPreparationCleanupTarget(
            artifactIdentityDigest: mutation == "enclosing" ? hexA : digest,
            displayModelID: mutation == "display" ? "other-display" : tuple.displayModelID,
            modelRevision: mutation == "revision" ? "other-rev" : tuple.modelRevision,
            artifactID: mutation == "artifact" ? "other-artifact" : tuple.artifactID,
            releaseID: mutation == "release" ? "other-release" : tuple.releaseID,
            modelKey: nil,
            eventModelKey: tuple.eventModelKey,
            rootIdentityDigest: mutation == "root" ? hexB : tuple.root.rootIdentityDigest,
            receiptSHA256: mutation == "receipt" ? hexA : receiptDigest(),
            estimatedBytes: 4096,
            keepSetStatus: .reclaimable,
            protectedReason: nil,
            cleanup: action
        )
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func decodeTemp(_ object: [String: Any]) throws -> ModelPreparationPrivateStateEnvelope {
        try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: data(object),
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
    }

    private static func decodeFailed(_ object: [String: Any]) throws -> ModelPreparationFailedDispatchRecord {
        try ModelPreparationContracts.decode(
            ModelPreparationFailedDispatchRecord.self,
            from: data(object),
            maxBytes: ModelPreparationContracts.failedDispatchMaxBytes
        )
    }

    private static func decodeAck(_ object: [String: Any]) throws -> ModelPreparationCancelAcknowledgement {
        try ModelPreparationContracts.decode(
            ModelPreparationCancelAcknowledgement.self,
            from: data(object),
            maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes
        )
    }

    private static func decodeEvent(_ object: [String: Any]) throws -> ModelPreparationTransactionEvent {
        try ModelPreparationContracts.decode(
            ModelPreparationTransactionEvent.self,
            from: data(object),
            maxBytes: ModelPreparationContracts.eventMaxBytes
        )
    }
}
