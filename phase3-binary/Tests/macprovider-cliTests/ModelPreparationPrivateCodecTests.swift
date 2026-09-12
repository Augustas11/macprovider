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
        object.removeValue(forKey: "event_model_key")
        XCTAssertThrowsError(try Self.decodeFailed(object))

        let duplicate = Data(#"{"schema":"model_catalog_failed_dispatch.v1","schema":"model_catalog_failed_dispatch.v1"}"#.utf8)
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

        let mismatchedAction = try ModelPreparationAction(
            available: true,
            requiresConfirmation: true,
            transactionKind: .cleanupPublishedArtifact,
            transactionID: "22222222-2222-4222-8222-222222222222",
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
            bytesExpected: nil,
            percentComplete: nil,
            heartbeat: false
        ))
        XCTAssertThrowsError(try ModelPreparationTransactionEvent(
            transactionID: Self.transactionID,
            transactionKind: .prepareModel,
            modelKey: "catalog/model",
            eventSequence: 1,
            emittedAt: Self.timestamp,
            state: .running,
            progress: nil,
            errorCode: nil,
            warningCode: nil
        ))
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
    }

    func testCleanupRecordRoundTripsIntentTombstonedRemovedAndRejectsUnsafeLeavesAndBindings() throws {
        for phase in [ModelPreparationCleanupPhase.intent, .tombstoned, .removed] {
            let record = try Self.cleanupRecord(phase: phase, targetKind: .published)
            let data = try ModelPreparationContracts.encode(record, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
            _ = try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: data, maxBytes: ModelPreparationContracts.deletionRecordMaxBytes)
        }
        _ = try Self.cleanupRecord(phase: .intent, targetKind: .staging)

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
            receipt: receipt,
            receiptSHA256: try Self.receiptDigest(),
            artifactIdentityDigest: try Self.artifactDigest(),
            finalLeaf: "nested/leaf",
            tombstoneLeaf: "nested.tombstone",
            expectedBytes: 4096,
            expectedFiles: 1
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
            receipt: receipt,
            receiptSHA256: Self.hexA,
            artifactIdentityDigest: try Self.artifactDigest(),
            finalLeaf: try Self.artifactDigest(),
            tombstoneLeaf: "\(try Self.artifactDigest()).tombstone",
            expectedBytes: 4096,
            expectedFiles: 1
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
        XCTAssertThrowsError(try ModelPreparationCancelAcknowledgement(
            transactionID: Self.transactionID,
            attemptID: nil,
            outcome: .busy,
            observedAt: "2026-09-12T00:00:00Z"
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

        var object = try Self.object(data)
        object["published_at"] = "2026-09-12T00:00:01.000Z"
        let mutatedReceipt = try ModelPreparationContracts.decode(
            ModelPreparationPublicationReceipt.self,
            from: Self.data(object),
            maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes
        )
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
            receipt: mutatedReceipt,
            receiptSHA256: originalReceiptDigest,
            artifactIdentityDigest: originalDigest,
            finalLeaf: originalDigest,
            tombstoneLeaf: "\(originalDigest).tombstone",
            expectedBytes: 4096,
            expectedFiles: 1
        ))
    }

    func testPublicationReceiptCorrelationsRejectMutations() throws {
        let record = try Self.cleanupRecord(phase: .intent, targetKind: .published)
        let mutatedReceipt = try Self.receipt(publishedAt: "2026-09-12T00:00:01.000Z")
        let mutatedReceiptSHA256 = try Self.receiptDigest(mutatedReceipt)
        let mutatedArtifactDigest = try Self.artifactDigest(tuple: record.tuple, receiptSHA256: mutatedReceiptSHA256)
        XCTAssertThrowsError(try ModelPreparationCleanupRecord(
            targetKind: .published,
            phase: .intent,
            transactionID: record.transactionID,
            attemptID: record.attemptID,
            eventModelKey: record.eventModelKey,
            root: record.root,
            tuple: record.tuple,
            tupleSHA256: record.tupleSHA256,
            receipt: mutatedReceipt,
            receiptSHA256: mutatedReceiptSHA256,
            artifactIdentityDigest: mutatedArtifactDigest,
            finalLeaf: record.finalLeaf,
            tombstoneLeaf: record.tombstoneLeaf,
            expectedBytes: record.expectedBytes,
            expectedFiles: record.expectedFiles
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
            receipt: otherReceipt,
            receiptSHA256: try Self.receiptDigest(otherReceipt),
            artifactIdentityDigest: try Self.artifactDigest(tuple: otherTuple, receiptSHA256: Self.receiptDigest(otherReceipt)),
            finalLeaf: record.finalLeaf,
            tombstoneLeaf: record.tombstoneLeaf,
            expectedBytes: record.expectedBytes,
            expectedFiles: record.expectedFiles
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
        XCTAssertEqual(record.artifactIdentityDigest, digest)
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
        let tempJSON = #"{"checksum_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","complete":true,"generation":1.0,"schema":"model_catalog_unique_temp.v1","target_kind":"cleanup"}"#
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationUniqueTempRecord.self, from: Data(tempJSON.utf8), maxBytes: 1024))
        let actionJSON = String(decoding: try ModelPreparationContracts.encode(try Self.cleanupRecord(phase: .intent, targetKind: .published)), as: UTF8.self)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationCleanupRecord.self, from: Data(actionJSON.replacingOccurrences(of: #""estimated_bytes":4096"#, with: #""estimated_bytes":4096.0"#).utf8), maxBytes: ModelPreparationContracts.deletionRecordMaxBytes))
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
        XCTAssertThrowsError(try ModelPreparationUniqueTempRecord(targetKind: "cleanup", generation: ModelPreparationContracts.maxJavaScriptSafeInteger + 1, checksumSHA256: Self.hexA, complete: true))
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
    private static let timestamp = "2026-09-12T00:00:00.000Z"
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

    private static func cleanupRecord(
        phase: ModelPreparationCleanupPhase,
        targetKind: ModelPreparationCleanupTargetKind,
        expectedBytes: Int64 = 4096,
        finalLeaf: String? = nil,
        receiptSHA256: String? = nil,
        artifactIdentityDigest: String? = nil
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
        let final = finalLeaf ?? (targetKind == .published ? selectedArtifactDigest : "\(attemptID).staging")
        let tombstone = targetKind == .published ? "\(selectedArtifactDigest).tombstone" : "\(attemptID).staging.tombstone"
        return try ModelPreparationCleanupRecord(
            targetKind: targetKind,
            phase: phase,
            transactionID: transactionID,
            attemptID: attemptID,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest(),
            receipt: receipt,
            receiptSHA256: selectedReceiptSHA256,
            artifactIdentityDigest: selectedArtifactDigest,
            finalLeaf: final,
            tombstoneLeaf: tombstone,
            expectedBytes: expectedBytes,
            expectedFiles: 1
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

    private static func reservation() throws -> ModelPreparationReservationRecord {
        let tuple = try tuple()
        return try ModelPreparationReservationRecord(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            eventModelKey: tuple.eventModelKey,
            root: tuple.root,
            tuple: tuple,
            tupleSHA256: tupleDigest(),
            projectionBindingSHA256: hexB,
            createdAt: timestamp
        )
    }

    private static func inventory() throws -> ModelPreparationInventoryRecord {
        try ModelPreparationInventoryRecord(schema: "model_catalog_published_inventory.v1", root: root(), targets: [], generatedAt: timestamp)
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
