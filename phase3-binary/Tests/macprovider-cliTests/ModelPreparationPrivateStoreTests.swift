import Darwin
import Foundation
@testable import macprovider_cli
import XCTest

final class ModelPreparationPrivateStoreTests: XCTestCase {
    func testAtomicWriteRequiresLockCustodyAndStoresEnvelopeBytesForValidatedInventory() throws {
        let fixture = try makeFixture("model-prep-store-write")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let payload = try inventoryPayload(root: boot.snapshot.rootLocator)

        try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: payload,
            generation: 7,
            rootLocator: boot.snapshot.rootLocator,
            lockCustody: boot.lockCustody
        )

        XCTAssertEqual(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator), payload)
        let target = fixture.authority.appendingPathComponent("published-inventory.json")
        let durableData = try Data(contentsOf: target)
        XCTAssertNotEqual(durableData, payload)
        let durableEnvelope = try ModelPreparationContracts.decode(
            ModelPreparationPrivateStateEnvelope.self,
            from: durableData,
            maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes
        )
        try durableEnvelope.validateDurableTargetLeaf(target.lastPathComponent)
        XCTAssertEqual(durableEnvelope.recordKind, .publishedInventory)
        XCTAssertEqual(durableEnvelope.generation, 7)
        XCTAssertEqual(durableEnvelope.payload, payload)
        try assertMode(target, type: S_IFREG, mode: 0o600, expectedLinkCount: 1)
        try assertNoExtendedACL(target)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.authority.appendingPathComponent("state-tmp", isDirectory: true).path
        ).contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testClosedLockCustodyCannotMutateState() throws {
        let fixture = try makeFixture("model-prep-store-lock-closed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        boot.lockCustody.close()

        XCTAssertThrowsError(try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: try inventoryPayload(root: boot.snapshot.rootLocator),
            generation: 1,
            rootLocator: boot.snapshot.rootLocator,
            lockCustody: boot.lockCustody
        )) { error in
            XCTAssert(String(describing: error).contains("lock custody closed"), String(describing: error))
        }
    }

    func testGatedKindsFailClosedForWriteReadAndRecoveryWithoutMutation() throws {
        let fixture = try makeFixture("model-prep-store-gated-kinds")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let stateTmp = fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        for kind in [ModelPreparationPrivateStateEnvelopeKind.reservations, .cancel, .deletion] {
            let payload = Data(#"{"pending":true}"#.utf8)
            XCTAssertThrowsError(try fixture.store.writeRecord(
                kind: kind,
                payload: payload,
                generation: 1,
                rootLocator: boot.snapshot.rootLocator,
                lockCustody: boot.lockCustody
            )) { error in
                XCTAssert(String(describing: error).contains("pending plan gate"), String(describing: error))
            }

            let durableEnvelope = try ModelPreparationPrivateStateEnvelope(
                recordKind: kind,
                targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind),
                writerUUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                generation: 1,
                payload: payload
            )
            let durableURL = fixture.authority.appendingPathComponent(ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind))
            let durableData = try ModelPreparationContracts.encode(durableEnvelope, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes)
            try durableData.write(to: durableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: durableURL.path)
            XCTAssertThrowsError(try fixture.store.readRecord(kind: kind, rootLocator: boot.snapshot.rootLocator)) { error in
                XCTAssert(String(describing: error).contains("pending plan gate"), String(describing: error))
            }
            XCTAssertEqual(try Data(contentsOf: durableURL), durableData)
            try FileManager.default.removeItem(at: durableURL)

            let tempURL = try writeTemp(
                kind: kind,
                payload: payload,
                generation: 1,
                writer: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                in: stateTmp
            )
            XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
                XCTAssert(String(describing: error).contains("pending plan gate"), String(describing: error))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
            try FileManager.default.removeItem(at: tempURL)
        }
    }

    func testWriteRejectsNonMonotonicGenerationWithoutReplacingDurableEnvelope() throws {
        let fixture = try makeFixture("model-prep-store-generation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let first = try inventoryPayload(root: boot.snapshot.rootLocator)
        try fixture.store.writeRecord(kind: .publishedInventory, payload: first, generation: 3, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        let durableBefore = try Data(contentsOf: fixture.authority.appendingPathComponent("published-inventory.json"))

        XCTAssertThrowsError(try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: first,
            generation: 3,
            rootLocator: boot.snapshot.rootLocator,
            lockCustody: boot.lockCustody
        )) { error in
            XCTAssert(String(describing: error).contains("monotonic"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.authority.appendingPathComponent("published-inventory.json")), durableBefore)
    }

    func testWriteAndReadRejectRootLocatorDriftForRootBearingPayload() throws {
        let fixture = try makeFixture("model-prep-store-root-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let payload = try inventoryPayload(root: boot.snapshot.rootLocator)
        let drifted = try driftedRoot(from: boot.snapshot.rootLocator)

        XCTAssertThrowsError(try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: payload,
            generation: 1,
            rootLocator: drifted,
            lockCustody: boot.lockCustody
        )) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }

        try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: payload,
            generation: 1,
            rootLocator: boot.snapshot.rootLocator,
            lockCustody: boot.lockCustody
        )
        XCTAssertThrowsError(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: drifted)) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }
    }

    func testRecoveryCompletesHighestNewerRecognizedTempRemovesStaleAndEmptyTemps() throws {
        let fixture = try makeFixture("model-prep-store-recover")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        try fixture.store.writeRecord(kind: .publishedInventory, payload: try inventoryPayload(root: boot.snapshot.rootLocator), generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)
        let stateTmp = fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        let staleURL = try writeTemp(kind: .publishedInventory, payload: try inventoryPayload(root: boot.snapshot.rootLocator), generation: 1, writer: "33333333-3333-4333-8333-333333333333", in: stateTmp)
        let newerPayload = try inventoryPayload(root: boot.snapshot.rootLocator)
        let newerURL = try writeTemp(kind: .publishedInventory, payload: newerPayload, generation: 2, writer: "44444444-4444-4444-8444-444444444444", in: stateTmp)
        let empty = stateTmp.appendingPathComponent("published-inventory.json.55555555-5555-4555-8555-555555555555.tmp")
        FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: [.posixPermissions: 0o600])

        let report = try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)

        XCTAssertEqual(report.completed, [newerURL.lastPathComponent])
        XCTAssertEqual(report.removed.sorted(), [empty.lastPathComponent, staleURL.lastPathComponent].sorted())
        XCTAssertEqual(try fixture.store.readRecord(kind: .publishedInventory, rootLocator: boot.snapshot.rootLocator), newerPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testRecoveryFailsClosedForChecksumValidSemanticRootMismatchTemp() throws {
        let fixture = try makeFixture("model-prep-store-semantic-mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let drifted = try driftedRoot(from: boot.snapshot.rootLocator)
        let tempURL = try writeTemp(
            kind: .publishedInventory,
            payload: try inventoryPayload(root: drifted),
            generation: 1,
            writer: "66666666-6666-4666-8666-666666666666",
            in: fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        )

        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("root locator mismatch"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testRecoveryRejectsUnexpectedTempNameAndFIFOTempWithoutRemoving() throws {
        let fixture = try makeFixture("model-prep-store-hostile-temp")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let stateTmp = fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        let fifo = stateTmp.appendingPathComponent("cancel.json.99999999-9999-4999-8999-999999999999.tmp")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("not a regular file"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        try FileManager.default.removeItem(at: fifo)
        let unexpected = stateTmp.appendingPathComponent("notes.tmp")
        try Data().write(to: unexpected)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unexpected.path)
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("unexpected state temp"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testRecoveryCapsRecognizedTempsAtFourPerKindAndSixteenTotal() throws {
        let fixture = try makeFixture("model-prep-store-cap")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let stateTmp = fixture.authority.appendingPathComponent("state-tmp", isDirectory: true)
        for index in 0 ..< 5 {
            _ = try writeTemp(
                kind: .publishedInventory,
                payload: try inventoryPayload(root: boot.snapshot.rootLocator),
                generation: index + 1,
                writer: String(format: "77777777-7777-4777-8777-%012d", index),
                in: stateTmp
            )
        }
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("four per kind"), String(describing: error))
        }
        for index in 0 ..< 5 {
            let leaf = String(format: "published-inventory.json.77777777-7777-4777-8777-%012d.tmp", index)
            try? FileManager.default.removeItem(at: stateTmp.appendingPathComponent(leaf))
        }
        for index in 0 ..< 17 {
            let leaf = String(format: "cancel.json.88888888-8888-4888-8888-%012d.tmp", index)
            FileManager.default.createFile(atPath: stateTmp.appendingPathComponent(leaf).path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        XCTAssertThrowsError(try fixture.store.recoverStateTemps(rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("exceed 16"), String(describing: error))
        }
    }

    func testWriteRejectsExistingWorldReadableRawAndHardLinkedStateWithoutReplacingIt() throws {
        let fixture = try makeFixture("model-prep-store-hostile-durable")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = fixture.authority.appendingPathComponent("published-inventory.json")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: try inventoryPayload(root: boot.snapshot.rootLocator), generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("0600"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
        try FileManager.default.removeItem(at: target)
        try Data("raw-state".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: try inventoryPayload(root: boot.snapshot.rootLocator), generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody))
        XCTAssertEqual(try Data(contentsOf: target), Data("raw-state".utf8))
        try FileManager.default.removeItem(at: target)
        let sentinel = fixture.root.appendingPathComponent("outside-sentinel")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.linkItem(at: sentinel, to: target)
        XCTAssertThrowsError(try fixture.store.writeRecord(kind: .publishedInventory, payload: try inventoryPayload(root: boot.snapshot.rootLocator), generation: 1, rootLocator: boot.snapshot.rootLocator, lockCustody: boot.lockCustody)) { error in
            XCTAssert(String(describing: error).contains("hard link"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: sentinel), "sentinel")
    }

    private func makeFixture(_ name: String) throws -> (root: URL, authority: URL, artifact: URL, store: ModelPreparationPrivateStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifact", isDirectory: true)
        let store = ModelPreparationPrivateStore(
            authorityRoot: authority,
            artifactRoot: artifact,
            randomSource: DeterministicModelPreparationRandomSource(uuids: [
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222",
                "33333333-3333-4333-8333-333333333333",
                "44444444-4444-4444-8444-444444444444",
            ])
        )
        return (root, authority, artifact, store)
    }

    private func cancelPayload(
        transactionID: String = "99999999-9999-4999-8999-999999999999",
        attemptID: String? = nil,
        outcome: ModelPreparationCancelOutcome = .busy
    ) throws -> Data {
        try ModelPreparationContracts.encode(
            try ModelPreparationCancelAcknowledgement(
                transactionID: transactionID,
                attemptID: attemptID,
                outcome: outcome,
                observedAt: "2026-09-12T00:00:00.000Z"
            ),
            maxBytes: ModelPreparationContracts.cancelAcknowledgementMaxBytes
        )
    }

    private func inventoryPayload(root: ModelPreparationRootLocator) throws -> Data {
        try ModelPreparationContracts.encode(
            try ModelPreparationInventoryRecord(root: root, targets: [], generatedAt: "2026-09-12T00:00:00.000Z"),
            maxBytes: ModelPreparationContracts.inventoryMaxBytes
        )
    }

    private func driftedRoot(from root: ModelPreparationRootLocator) throws -> ModelPreparationRootLocator {
        try ModelPreparationRootLocator(
            canonicalPath: root.canonicalPath,
            stDev: root.stDev,
            stIno: root.stIno,
            identityVersion: root.identityVersion,
            rootIdentityDigest: String(repeating: "0", count: 64)
        )
    }

    @discardableResult
    private func writeTemp(
        kind: ModelPreparationPrivateStateEnvelopeKind,
        payload: Data,
        generation: Int,
        writer: String,
        in directory: URL
    ) throws -> URL {
        let temp = try ModelPreparationPrivateStateEnvelope(
            recordKind: kind,
            targetLeaf: ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: kind),
            writerUUID: writer,
            generation: generation,
            payload: payload
        )
        let url = directory.appendingPathComponent(try temp.expectedFilename())
        try ModelPreparationContracts.encode(temp, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
